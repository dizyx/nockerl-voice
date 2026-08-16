import Dispatch
import Foundation

/// What a retry surface should be saying right now.
///
/// Inside a retry sequence the label is a HEARTBEAT, not a running commentary. It ticks
/// once per backoff and says nothing else, so a tick that does not arrive is itself the
/// signal: the attempt is still going, which means it is no longer being rejected. Users
/// read it that way without being told, and it is why the sequence deliberately does NOT
/// try to announce that an attempt is running. Saying so would mean guessing when an
/// attempt has stopped being a rejection, and a wrong guess produces a label that flips
/// back and forth between the two states.
enum TranscriptionRetryPhase: Equatable {
    /// Backing off before the next attempt. The surface should name the wait.
    case waiting(attempt: Int, of: Int)
    /// An ordinary attempt is in flight, with no retrying going on. This is the state a
    /// surface starts in, before any rejection. The retry loop never reports it: once a
    /// sequence has begun the label stays on the count. Both surfaces still use it to name
    /// their normal in-progress state, which is the only place it comes from now.
    case attempting
}

extension TranscriptionRetryPhase {
    /// The words each surface shows for this phase. Defined here, once, so the HUD pill and
    /// the History row cannot drift apart the way their two hand-rolled loops did.
    var label: String {
        switch self {
        case let .waiting(attempt, total):
            return "Server busy, retrying \(attempt) of \(total)"
        case .attempting:
            return "Transcribing…"
        }
    }
}

/// The ONE retry policy, shared by live dictation and by History retry.
///
/// Both surfaces used to carry their own copy of this loop, which is how they drifted: the
/// same 429 handling, the same two second backoff and the same label text, maintained twice.
/// They now differ only in the closure they pass, so the policy cannot drift again.
@MainActor
enum TranscriptionRetry {
    /// Attempts AFTER the first, so a request is issued at most `maxAttempts + 1` times.
    static let maxAttempts = 5

    /// Gap between attempts, and therefore the period of the heartbeat.
    private static let backoffNanos: UInt64 = 2_000_000_000

    /// A 429 from either tier: the only error worth retrying by itself.
    static func isRateLimited(_ error: TranscriptionError) -> Bool {
        if case let .providerFailed(_, status, _) = error, status == 429 { return true }
        return false
    }

    /// Run one transcription, retrying a busy server up to `maxAttempts` times.
    ///
    /// `onPhase` is called only when the surface should change what it says. The caller owns
    /// the wording, so the HUD can be terse and History can be actionable.
    ///
    /// WITHIN A SEQUENCE THE LABEL ONLY EVER COUNTS UP. It changes when the retry count
    /// increments and at no other time, so the surface cannot oscillate. There is deliberately
    /// no timer that promotes a surviving attempt back to the ordinary in-progress label.
    ///
    /// That promotion existed, and it was the defect. It waited half a second before deciding
    /// an attempt was real, but timing this endpoint with the app's own payload put the FASTEST
    /// possible success at 4.67 s, median around 8.5 s. Half a second is roughly a tenth of the
    /// quickest thing that can happen, so nothing was knowable at that point: every attempt
    /// outlived the timer and was announced as running, and every rejection then took the label
    /// back. The flip was guaranteed rather than occasional.
    ///
    /// Tuning that threshold was the obvious repair and it is the wrong one. The rejection
    /// latency it would have to sit above was never measurable (no 429 could be provoked), so
    /// any number would be a guess, and a guess that is wrong reintroduces the same flip. The
    /// count on its own already carries the information: a tick that does not arrive means the
    /// attempt is still running. Removing the timer removes the guess, the machinery that
    /// cancelled it, and the whole class of stale-write bug that machinery existed to prevent.
    ///
    /// THE COST, ACCEPTED KNOWINGLY. While a successful attempt runs, which measurement puts
    /// between 4.67 s and 25.92 s, the label still reads "Server busy, retrying N of 5" rather
    /// than naming the transcription. That is the state the counter stopping already
    /// communicates. Do not add a timer to improve it.
    static func run(
        service: TranscriptionService,
        wav: Data,
        prompt: String?,
        onPhase: @escaping @MainActor (TranscriptionRetryPhase) -> Void
    ) async throws -> TranscriptionService.Outcome {
        var attempt = 0
        while true {
            // Monotonic, so a wall-clock adjustment mid-request cannot corrupt a reading.
            let startedAt = DispatchTime.now().uptimeNanoseconds

            do {
                let outcome = try await service.transcribe(wav: wav, prompt: prompt)
                DebugLog.write("transcribe attempt \(attempt + 1): ok in \(millis(since: startedAt)) ms")
                return outcome
            } catch let error as TranscriptionError where isRateLimited(error) {
                DebugLog.write("transcribe attempt \(attempt + 1): 429 in \(millis(since: startedAt)) ms")
                guard attempt < maxAttempts else { throw error }
                attempt += 1
                // The one label change in the sequence: the count going up. Set BEFORE the
                // sleep, so the new count is on screen for the whole backoff and the next tick
                // is exactly one backoff away.
                onPhase(.waiting(attempt: attempt, of: maxAttempts))
                try? await Task.sleep(nanoseconds: backoffNanos)
            } catch {
                // Timing is recorded for every outcome, not just the interesting ones, so a
                // future question about latency can be answered from the log rather than from
                // another live experiment against the API. The error text is left to the
                // caller, which already reports it.
                DebugLog.write("transcribe attempt \(attempt + 1): failed in \(millis(since: startedAt)) ms")
                throw error
            }
        }
    }

    // MARK: - Timing

    /// `uptimeNanoseconds` is monotonically non-decreasing, so this cannot underflow.
    private static func millis(since start: UInt64) -> UInt64 {
        (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}
