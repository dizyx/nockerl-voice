import AVFoundation
import CoreAudio
import Foundation

/// Microphone capture via AVAudioEngine. Accumulates 16 kHz mono Int16 samples and,
/// on stop, returns a WAV ready for transcription. Emits input level for the HUD.
/// Live mic capture is validated on real hardware.
@MainActor
final class AudioRecorder {

    enum RecorderError: Error, LocalizedError {
        case converterUnavailable
        case engineStartFailed(String)

        var errorDescription: String? {
            switch self {
            case .converterUnavailable: return "Could not initialize audio conversion."
            case let .engineStartFailed(detail): return "Could not start the microphone: \(detail)"
            }
        }
    }

    /// Drop clips shorter than this (matches the reference "too short" guard).
    private let minDuration: TimeInterval = 0.3
    /// Hard cap on a single recording. Generous (1 hour) so normal long dictations
    /// (and future meeting capture) are never cut short. When hit, the audio is
    /// finalized and handed to `onAutoStop` (NOT discarded). Lets us learn the real
    /// server-side limit for long audio before deciding whether to chunk.
    let maxDuration: TimeInterval

    private var engine = AVAudioEngine()
    private var converter: PCMConverter?
    private var samples: [Int16] = []
    private var startedAt: Date?
    /// System default input we temporarily overrode to record from the chosen mic.
    private var previousDefaultInput: AudioDeviceID?

    /// Called on the main actor with a normalized 0...1 input level.
    var onLevel: ((Float) -> Void)?

    /// Called on the main actor when the duration cap is reached, handing over the
    /// finished WAV so the controller can finalize + transcribe it. Without this the
    /// capped recording was silently dropped and the UI desynced (the 5-min bug).
    var onAutoStop: ((Data) -> Void)?

    private(set) var isRecording = false

    init(maxDuration: TimeInterval = 3600) {
        self.maxDuration = maxDuration
    }

    func start() throws {
        guard !isRecording else { return }
        samples.removeAll(keepingCapacity: true)

        // Route the chosen mic in by making it the default input for this recording,
        // restored on stop. AVAudioEngine reliably records from the default input;
        // forcing a device onto its input node fails for input-only mics (e.g. MV7+).
        routeToSelectedInput()

        // Fresh engine each session so the (possibly just-changed) input takes effect.
        engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = PCMConverter(inputFormat: inputFormat) else {
            restoreDefaultInput()
            throw RecorderError.converterUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            let level = Self.peakLevel(of: buffer)
            let converted = converter.convert(buffer)
            Task { @MainActor [weak self] in
                guard let self, self.isRecording else { return }
                self.samples.append(contentsOf: converted)
                self.onLevel?(level)
                if let started = self.startedAt,
                   Date().timeIntervalSince(started) >= self.maxDuration {
                    // Cap reached: finalize and hand the audio over. Never discard.
                    let wav = self.stop()
                    self.onAutoStop?(wav)
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            restoreDefaultInput()
            throw RecorderError.engineStartFailed(error.localizedDescription)
        }
        isRecording = true
        startedAt = Date()
    }

    /// Stop and return the recorded WAV (empty Data if nothing usable was captured).
    @discardableResult
    func stop() -> Data {
        guard isRecording else { return Data() }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        restoreDefaultInput()
        isRecording = false

        let duration = Double(samples.count) / PCMConverter.targetFormat.sampleRate
        defer { samples.removeAll(keepingCapacity: false); converter = nil; startedAt = nil }
        guard duration >= minDuration, !samples.isEmpty else { return Data() }
        return WAVWriter.wavData(samples: samples, sampleRate: Int(PCMConverter.targetFormat.sampleRate))
    }

    /// Make the user-selected microphone the default input for the recording, saving
    /// the previous default to restore afterwards. No-op for "System Default" or a
    /// missing device, so the default-mic path is completely unchanged.
    private func routeToSelectedInput() {
        previousDefaultInput = nil
        let uid = SettingsStore.shared.selectedMicUID
        guard !uid.isEmpty,
              let target = MicDevices.audioDeviceID(forUID: uid),
              let current = MicDevices.defaultInputDeviceID(),
              current != target else { return }
        if MicDevices.setDefaultInputDevice(target) {
            previousDefaultInput = current
        }
    }

    /// Restore the system default input we changed in `routeToSelectedInput`.
    private func restoreDefaultInput() {
        if let previous = previousDefaultInput {
            MicDevices.setDefaultInputDevice(previous)
            previousDefaultInput = nil
        }
    }

    /// Peak amplitude of a buffer, normalized 0...1 (for the recording indicator).
    private static func peakLevel(of buffer: AVAudioPCMBuffer) -> Float {
        if let f = buffer.floatChannelData {
            let n = Int(buffer.frameLength)
            var peak: Float = 0
            for i in 0..<n { peak = max(peak, abs(f[0][i])) }
            return min(peak, 1)
        }
        if let s = buffer.int16ChannelData {
            let n = Int(buffer.frameLength)
            var peak: Int16 = 0
            for i in 0..<n { peak = max(peak, abs(s[0][i])) }
            return min(Float(peak) / Float(Int16.max), 1)
        }
        return 0
    }
}
