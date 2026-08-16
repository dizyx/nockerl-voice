import Foundation

/// Cloud fallback provider: a chosen MiMo-family model on a chosen OpenRouter
/// provider. Everything is EXPLICIT: the user picks the model and the provider in
/// Settings; there is no automatic routing, no cross-provider escalation, and no
/// hidden retry. If a provider rate-limits (429) or can't serve, the
/// error surfaces plainly and the user reselects.
///
/// Request details, all verified against the live API:
/// - **`reasoning: {enabled: false}`**: MiMo is a reasoning model; without this the
///   transcript lands in `reasoning` with `content: null` (and it is ~5× slower). It is
///   OMITTED for the model families that mandate reasoning and reject the key with an
///   HTTP 400, listed in `CloudProviderCatalog.reasoningMandatoryPrefixes`.
/// - **`provider.zdr: true` is sent by DEFAULT**, because zero data retention is the
///   privacy posture this app ships with. It is not unconditional: `enforceZDR` reflects
///   the user's setting, and some providers offer no zero-retention endpoint at all
///   (OpenAI is the live example, where ZDR yields HTTP 404 "No endpoints found matching
///   your data policy"). Those models are flagged in the catalog and the picker says so,
///   rather than the request failing with nothing to explain it.
/// - **`provider.only: [slug]`**: pinned to exactly the selected provider (strict).
struct OpenRouterProvider: TranscriptionProvider {
    let id = "cloud"

    private let apiKey: String
    private let model: String
    /// The selected OpenRouter provider slug (e.g. "deepinfra"). Required.
    private let providerSlug: String
    private let timeout: TimeInterval
    private let enforceZDR: Bool
    private let session: URLSession

    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    init(
        apiKey: String,
        model: String,
        providerSlug: String,
        timeout: TimeInterval,
        enforceZDR: Bool = true,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.providerSlug = providerSlug
        self.timeout = timeout
        self.enforceZDR = enforceZDR
        self.session = session
    }

    /// Transcribe by sending the prompt + base64 audio (WAV or MP3) to the chosen
    /// provider. One request, one provider. No fallback. A 429/failure surfaces so the
    /// user can pick a different provider or model.
    func transcribe(audio: Data, format: AudioUploadFormat, language: String?, prompt: String?) async throws -> String {
        let slug = providerSlug.trimmingCharacters(in: .whitespaces)
        guard !slug.isEmpty, slug != "auto" else {
            throw TranscriptionError.providerFailed(
                provider: id, status: nil,
                detail: "No Cloud provider selected. Pick a model and provider in Settings ▸ Transcription ▸ Cloud."
            )
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Optional OpenRouter attribution headers (surface the app in the OR dashboard).
        request.setValue("https://nockerl.ai", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Nockerl Voice", forHTTPHeaderField: "X-Title")
        request.httpBody = Self.requestBody(
            model: model,
            instruction: Self.instruction(from: prompt),
            audioBase64: audio.base64EncodedString(),
            audioFormat: format.openRouter,
            providerSlug: slug,
            enforceZDR: enforceZDR
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse(provider: id)
        }
        guard http.statusCode == 200 else {
            // `enforceZDR` is this request's ACTUAL setting, threaded through so the
            // data-policy message can describe what is really configured instead of
            // assuming. See the rule on `friendly`.
            throw TranscriptionError.providerFailed(
                provider: id, status: http.statusCode,
                detail: Self.errorDetail(from: data, requireZDR: enforceZDR)
            )
        }
        return Self.cleanTranscript(
            try Self.extractText(from: data, providerID: id, requireZDR: enforceZDR),
            model: model
        )
    }

    /// Per-model output cleanup. Some models append a trailing end-of-message marker or
    /// XML-ish token that is not part of the transcript (e.g. Thinking Machines' Inkling
    /// on longer outputs). Strip any trailing `<…>` / `<|…|>` token(s) so pasted text is
    /// clean. Defensive: only fires for the affected model, and the pattern can't match
    /// normal speech. `internal` + `static` so unit tests can exercise it.
    static func cleanTranscript(_ text: String, model: String) -> String {
        var out = text
        if model.lowercased().contains("inkling") {
            while let r = out.range(of: "\\s*<\\|?[^<>]*\\|?>\\s*$", options: .regularExpression) {
                out.removeSubrange(r)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Response parsing

    private struct ChatResponse: Decodable {
        struct Choice: Decodable { let message: Message? }
        struct Message: Decodable {
            let content: FlexibleContent?
            let reasoning: String?
            let reasoningDetails: [ReasoningDetail]?

            enum CodingKeys: String, CodingKey {
                case content, reasoning
                case reasoningDetails = "reasoning_details"
            }

            struct ReasoningDetail: Decodable { let text: String? }

            /// The transcript. Prefer `content`, but MiMo on some OpenRouter providers
            /// returns the transcript in `reasoning` with content=null (a safety net:
            /// with `reasoning:{enabled:false}` content is now the norm).
            var transcript: String {
                let c = (content?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !c.isEmpty { return c }
                if let r = reasoning?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty { return r }
                return (reasoningDetails ?? []).compactMap(\.text).joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let choices: [Choice]?
    }

    /// OpenAI-style message content: a plain string, an array of typed parts
    /// (`{ "type": "text", "text": "…" }`), or null. MiMo/OpenRouter responses vary,
    /// so decode all three shapes into one text value.
    private enum FlexibleContent: Decodable {
        case string(String)
        case parts([String])

        var text: String {
            switch self {
            case let .string(s): return s
            case let .parts(p): return p.joined()
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) { self = .string(s); return }
            struct Part: Decodable { let text: String? }
            if let arr = try? container.decode([Part].self) {
                self = .parts(arr.compactMap(\.text)); return
            }
            self = .string("")   // null / unexpected shape → empty
        }
    }

    /// Pull the transcript out of a 200 chat-completions body, tolerating the shape
    /// variance above and surfacing an OpenRouter/provider `error` returned WITH a 200.
    /// On any failure the raw body is logged (truncated) so the cause is diagnosable.
    /// `internal` + `static` so unit tests can exercise it without a network call.
    /// `requireZDR` is threaded only so a 200-with-error body can be described accurately;
    /// it plays no part in parsing. It is optional because the tests that exercise parsing
    /// have no setting to supply and should not have to invent one, and because "unknown"
    /// is a state `friendly` handles honestly rather than guessing at.
    static func extractText(from data: Data, providerID: String, requireZDR: Bool? = nil) throws -> String {
        // OpenRouter sometimes returns HTTP 200 with an `{ "error": {…} }` body
        // (e.g. a rate limit, or ZDR routing finds no endpoint).
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["error"] != nil {
            DebugLog.write("cloud 200-error: \(snippet(data))")
            throw TranscriptionError.providerFailed(
                provider: providerID, status: 200,
                detail: errorDetail(from: data, requireZDR: requireZDR)
            )
        }
        guard let payload = try? JSONDecoder().decode(ChatResponse.self, from: data) else {
            DebugLog.write("cloud parse-fail: \(snippet(data))")
            throw TranscriptionError.invalidResponse(provider: providerID)
        }
        let trimmed = payload.choices?.first?.message?.transcript ?? ""
        guard !trimmed.isEmpty else {
            DebugLog.write("cloud empty-content: \(snippet(data))")
            throw TranscriptionError.emptyTranscript
        }
        return trimmed
    }

    /// Extract a human-readable error message from an OpenRouter error body, rewriting
    /// opaque messages into actionable guidance. `internal` for unit tests.
    static func errorDetail(from data: Data, requireZDR: Bool? = nil) -> String {
        if let message = ProviderErrorText.extractMessage(from: data) {
            return friendly(message, requireZDR: requireZDR)
        }
        // Nothing meaningful in the body. NEVER surface raw JSON. Log the raw for diagnosis.
        DebugLog.write("cloud error (no usable message): \(snippet(data))")
        return "The transcription server returned an error. Try again, or pick a different provider in Settings."
    }

    /// Map a server message to actionable guidance.
    ///
    /// THE RULE FOR EVERY BRANCH HERE: this function must not assert application state it
    /// cannot see. It receives a string and whatever state is threaded in explicitly, and
    /// nothing else. A branch that says "X is on" when it has no way to know whether X is
    /// on will eventually be wrong, and a message that confidently describes the wrong
    /// cause is worse than a vague one, because it sends the user to fix something that is
    /// not broken. That is exactly what the data-policy branch used to do.
    ///
    /// `requireZDR` is `nil` when the caller genuinely does not know. That is a real state,
    /// not a default to paper over: the branch below then says something true either way
    /// rather than guessing. Passing it in, rather than reading a singleton, keeps this
    /// function pure and testable, which is worth more than the two threaded parameters
    /// cost.
    static func friendly(_ message: String, requireZDR: Bool?) -> String {
        let lower = message.lowercased()
        if lower.contains("data policy") || lower.contains("zero data retention") || lower.contains("zdr") {
            // Matched as explicit Optional cases. Writing `case true` relies on optional
            // pattern promotion, which one Swift version accepts as exhaustive and another
            // rejects: this compiled locally and failed CI with 'switch must be exhaustive'.
            // Spelling the cases out is version independent.
            switch requireZDR {
            case .some(true):
                // The requirement really is on. Name it and offer BOTH ways out: some
                // models (the OpenAI family today) have no zero-retention endpoint on any
                // provider, so changing model is a real fix and not just changing provider.
                return "Zero data retention is on, and this model has no provider that offers it. Pick a different model or provider in Settings ▸ Transcription ▸ Cloud, or turn the requirement off there."
            case .some(false):
                // The requirement is OFF, so this rejection did not come from us. OpenRouter
                // has ACCOUNT level data policy settings that are independent of the
                // per-request flag, and a provider can refuse on its own terms. Telling
                // someone to turn off a setting that is already off is how this branch sent
                // people in circles.
                return "The provider refused this request on data policy grounds. Zero data retention is off here, so this came from the provider or from your OpenRouter account data policy. Check your data policy at openrouter.ai, or pick a different model or provider in Settings ▸ Transcription ▸ Cloud."
            case .none:
                // Called without the setting threaded through. Describe both possibilities
                // and assert neither.
                return "The provider refused this request on data policy grounds. Check the zero data retention requirement in Settings ▸ Transcription ▸ Cloud, and your account data policy at openrouter.ai."
            }
        }
        if lower.contains("failed to convert") || lower.contains("no endpoints found") || lower.contains("no allowed providers") {
            return "The selected Cloud provider can't process audio for this model. Pick a different provider (or model) in Settings ▸ Transcription ▸ Cloud."
        }
        if lower.contains("rate-limit") || lower.contains("rate limit") || lower.contains("429") || lower.contains("temporarily rate") {
            return "The server stayed busy after several retries. Please try again in a moment, or pick a different provider in Settings. Funding your OpenRouter account raises these limits."
        }
        if lower.contains("no auth") || lower.contains("unauthorized") || lower.contains("invalid api key") || lower.contains("no api key") || lower.contains("credentials") || lower.contains("401") {
            return "Your OpenRouter API key looks missing or invalid. Check it in Settings ▸ Transcription ▸ Cloud."
        }
        if lower.contains("timed out") || lower.contains("timeout") || lower.contains("too long") || lower.contains("deadline") {
            return "The request took too long and timed out. Try again, use a shorter recording, or pick a faster provider in Settings."
        }
        if lower.contains("insufficient") || lower.contains("quota") || lower.contains("more credits") || lower.contains("payment required") || lower.contains("402") || lower.contains("fund") {
            return "Your OpenRouter account is out of credit for this request. Add credit at openrouter.ai, or pick a cheaper provider in Settings."
        }
        // Unmapped, so the server's own words reach the user. Prefixed so a History row
        // reads as a status line rather than as debris: an unlabelled server fragment in a
        // list of transcripts looks like something the app broke, not something it was
        // told. `extractMessage` has already guaranteed this is prose and not JSON.
        return "Server error: \(message)"
    }

    private static func snippet(_ data: Data) -> String {
        String(data: data, encoding: .utf8).map { String($0.prefix(600)) } ?? "<\(data.count) bytes, non-utf8>"
    }

    /// The transcription instruction sent as the text content part. The vocabulary
    /// prompt already opens with "Transcribe this audio…", so it doubles as the chat
    /// instruction; a short guard suppresses any chat-model preamble ("Sure, here's…").
    /// When no prompt is supplied, a bare transcription instruction is used. `internal`
    /// so unit tests can assert its shape.
    static func instruction(from prompt: String?) -> String {
        let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (trimmed?.isEmpty == false) ? trimmed! : "Transcribe this audio to text."
        return base + " Respond with ONLY the transcript text -- no preamble, headings, or commentary."
    }

    /// The `provider` routing object: strict pin to the chosen provider, ZDR always
    /// enforced. No sort, no fallbacks: the selection is explicit.
    static func providerRouting(for slug: String, enforceZDR: Bool = true) -> [String: Any] {
        enforceZDR ? ["zdr": true, "only": [slug]] : ["only": [slug]]
    }

    /// Builds the chat-completions JSON body: one user message combining the text
    /// instruction and the base64 WAV `input_audio` part, reasoning disabled, and the
    /// ZDR-enforced strict provider routing. `internal` + `static` so unit tests can
    /// assert its shape without a network call.
    static func requestBody(model: String, instruction: String, audioBase64: String, audioFormat: String = "wav", providerSlug: String, enforceZDR: Bool = true) -> Data {
        var payload: [String: Any] = [
            "model": model,
            // Deterministic transcription (no creative sampling).
            "temperature": 0,
            "provider": providerRouting(for: providerSlug, enforceZDR: enforceZDR),
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": instruction],
                    ["type": "input_audio", "input_audio": ["data": audioBase64, "format": audioFormat]],
                ],
            ]],
        ]
        // Disable reasoning so `content` is the clean transcript. This is the
        // OpenRouter-unified control; MiMo-native chat_template_kwargs is ignored by some
        // providers.
        //
        // OMITTED ENTIRELY for the families that mandate reasoning: they reject the key
        // with HTTP 400 rather than ignoring it, so sending it broke them outright. Which
        // families those are is DATA, in the catalog, not a condition hidden here. Dropping
        // the key globally is not an option: without it MiMo returns the transcript in
        // `reasoning` with `content: null`, and much slower. The models that lose it are
        // covered by the parser's fallback to `reasoning`.
        if !CloudProviderCatalog.mandatesReasoning(model) {
            payload["reasoning"] = ["enabled": false]
        }
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    }
}
