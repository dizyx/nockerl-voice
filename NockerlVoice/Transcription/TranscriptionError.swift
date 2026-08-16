import Foundation

enum TranscriptionError: Error, LocalizedError, Equatable {
    /// Local model unreachable and no fallback configured; `detail` is the real reason.
    case localUnavailable(detail: String?)
    /// A provider returned a non-success status or failed mid-request.
    case providerFailed(provider: String, status: Int?, detail: String)
    /// A provider responded 200 but the body could not be parsed.
    case invalidResponse(provider: String)
    /// Both providers produced an empty transcript.
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case let .localUnavailable(detail):
            if let detail, !detail.isEmpty {
                return "Local model unavailable: \(detail). Add an OpenRouter API key in Settings for a cloud fallback."
            }
            return "The local model is unavailable and no cloud API key is configured."
        case let .providerFailed(provider, status, detail):
            let code = status.map { " (HTTP \($0))" } ?? ""
            return "\(provider) transcription failed\(code): \(detail)"
        case let .invalidResponse(provider):
            return "\(provider) returned an unexpected response."
        case .emptyTranscript:
            return "No speech was detected."
        }
    }

    /// The TERSE line for the HUD pill. Two or three words, no punctuation-heavy sentences,
    /// no instructions and no links: the pill is a small floating capsule with room for a
    /// status, not for advice. Anything the user is supposed to ACT on belongs in
    /// `historyMessage`, which is read on a full screen where acting is possible.
    var hudMessage: String {
        switch self {
        case let .providerFailed(_, status, _):
            return status == 429 ? "Server busy" : "Server error"
        case .localUnavailable:
            return "Local model offline"
        case .invalidResponse:
            return "Server error"
        case .emptyTranscript:
            return "No speech"
        }
    }

    /// The ACTIONABLE line for a History row. Full sentences, and where there is something
    /// concrete to do it links straight to the pane that does it. Never shown in the HUD.
    ///
    /// The verbose `errorDescription` (provider names, HTTP codes, raw detail) stays in the
    /// debug log rather than in front of the user.
    var historyMessage: String {
        switch self {
        case let .providerFailed(_, status, detail):
            // A busy server is the dominant real failure and the one with a real remedy, so it
            // gets fixed wording plus the link rather than whatever the provider said.
            if status == 429 {
                return "The server was busy. Try again later, or choose a different provider in "
                    + "[Transcription settings](\(DashboardLink.transcriptionSettings))."
            }
            // `detail` has already been rewritten into a human message by
            // OpenRouterProvider.friendly() (ZDR mismatch, provider-can't-do-audio, invalid
            // API key, out of credit, and so on). Prefer it; fall back only if it is empty.
            if !detail.isEmpty { return detail }
            return "The server had a problem."
        case let .localUnavailable(detail):
            if let detail, !detail.isEmpty {
                return "Can't reach the local model: \(detail). Add or check your Cloud (OpenRouter) setup in Settings for a fallback."
            }
            return "Can't reach the local model, and no Cloud fallback is set up. Add an OpenRouter API key in Settings."
        case .invalidResponse:
            return "The server sent an unexpected response."
        case .emptyTranscript:
            return "No speech was detected."
        }
    }

}

/// Extracts a human-readable message from an OpenAI / OpenRouter-style error body. Central so
/// EVERY provider surfaces a real sentence to the user, never a raw JSON blob.
enum ProviderErrorText {
    /// The best non-generic message in the body, or nil if none is meaningful. NEVER returns
    /// raw JSON: callers pair a nil result with a clean generic fallback.
    static func extractMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let err = obj["error"] as? [String: Any]
        let candidates: [String?] = [
            (err?["metadata"] as? [String: Any])?["raw"] as? String,   // OpenRouter nests the useful text here
            err?["message"] as? String,
            obj["message"] as? String,
            obj["detail"] as? String,
        ]
        for case let candidate? in candidates {
            let message = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty, !isGeneric(message) else { continue }
            if let prose = prose(from: message) { return prose }
            // Not prose and nothing usable inside it. Try the next candidate rather than
            // returning it, which is what used to put a JSON blob in a History row.
        }
        return nil
    }

    /// A candidate reduced to something a person can read, or nil if there is nothing.
    ///
    /// The first candidate above is `error.metadata.raw`, which on OpenRouter is the
    /// UPSTREAM provider's response body verbatim and is frequently JSON. It is first for a
    /// good reason (it carries the specific upstream sentence when there is one) but it
    /// cannot be trusted to be prose.
    ///
    /// The irony this closes: `errorDetail` already refused to surface raw JSON, but only
    /// on the path where NO candidate was found. A JSON candidate walked straight past the
    /// guard written for exactly it, through `friendly()`, which matched no keyword and
    /// returned it unchanged.
    private static func prose(from candidate: String) -> String? {
        guard isStructured(candidate) else { return candidate }
        // Providers commonly nest the real sentence one level down, so look before
        // discarding: a usable message inside is better than falling back to the generic.
        if let nested = nestedMessage(in: candidate) { return nested }
        DebugLog.write("provider error: discarded structured candidate: \(candidate.prefix(300))")
        return nil
    }

    /// Whether a candidate is machine output rather than a sentence.
    ///
    /// Two tests, either of which disqualifies it. Parsing as JSON is the accurate one.
    /// The leading-brace check catches what parsing cannot: a body that is truncated,
    /// slightly malformed, or double-encoded still starts with a brace and is still not
    /// something to show a person.
    private static func isStructured(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return true }
        guard let data = trimmed.data(using: .utf8) else { return false }
        // Without .allowFragments a bare word or number is NOT valid top-level JSON, which
        // is what keeps ordinary prose from being mistaken for structure here.
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// The first human sentence inside a structured candidate.
    private static func nestedMessage(in json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return firstMessage(in: parsed, depth: 0)
    }

    /// Keys that carry a sentence, in preference order.
    private static let messageKeys = ["message", "error_message", "detail", "description", "reason", "error"]

    private static func firstMessage(in value: Any, depth: Int) -> String? {
        // Providers nest one or two levels in practice. The bound stops a pathological or
        // hostile body from walking a deep structure.
        guard depth < 4 else { return nil }
        if let dict = value as? [String: Any] {
            for key in messageKeys {
                if let candidate = dict[key] as? String {
                    let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, !isGeneric(trimmed), !isStructured(trimmed) { return trimmed }
                }
            }
            // Sorted, because Swift dictionary order is not stable and a user-facing string
            // that changes between runs is its own defect.
            for key in dict.keys.sorted() {
                if let found = firstMessage(in: dict[key] as Any, depth: depth + 1) { return found }
            }
        }
        if let array = value as? [Any] {
            for element in array {
                if let found = firstMessage(in: element, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    /// Server messages so vague they read worse than a clean generic line.
    private static func isGeneric(_ message: String) -> Bool {
        ["error", "internal server error", "bad request", "unknown error", "provider returned error"]
            .contains(message.lowercased())
    }
}
