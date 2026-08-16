import Foundation

/// The "Custom" transcription tier: any OpenAI-compatible transcription server.
/// `POST /v1/audio/transcriptions` (multipart) with the vocabulary prompt and
/// `chat_template_kwargs={"enable_thinking":false}`. An optional Bearer API key is
/// attached only when set (many local endpoints, e.g. a local server, need none).
/// Instruction-following (omni) models honor the prompt for Styles and vocabulary;
/// plain transcribers return raw text.
struct CustomEndpointProvider: TranscriptionProvider {
    let id = "custom"

    private let baseURL: URL
    private let apiKey: String?
    private let timeout: TimeInterval
    private let session: URLSession

    init(baseURL: URL, timeout: TimeInterval, apiKey: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeout = timeout
        self.session = session
    }

    /// Attach `Authorization: Bearer <key>` only when a non-empty key is set. Nil or
    /// empty sends no auth header, which is what unauthenticated local endpoints expect.
    private func authorize(_ request: inout URLRequest) {
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    /// `GET /health`. Throws the underlying error (network/ATS/local-network/non-200)
    /// so the caller can surface the real reason instead of a generic "unavailable".
    func checkHealth(timeout probeTimeout: TimeInterval) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = probeTimeout
        authorize(&request)
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode
        guard status == 200 else {
            throw TranscriptionError.providerFailed(provider: id, status: status, detail: "health check returned non-200")
        }
    }

    func transcribe(audio: Data, format: AudioUploadFormat, language: String?, prompt: String?) async throws -> String {
        let url = baseURL.appendingPathComponent("v1/audio/transcriptions")
        let boundary = "NockerlVoice-\(UUID().uuidString)"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = Self.multipartBody(
            boundary: boundary, audio: audio, format: format, language: language, prompt: prompt
        )

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse(provider: id)
        }
        guard http.statusCode == 200 else {
            // NEVER surface the raw body to the user. Extract a real message if the server
            // sent one; otherwise a clean, endpoint-agnostic generic. Raw goes to the log.
            let raw = String(data: data, encoding: .utf8).map { String($0.prefix(500)) } ?? "<non-utf8 body>"
            DebugLog.write("custom \(http.statusCode): \(raw)")
            let detail = ProviderErrorText.extractMessage(from: data)
                .map { "The transcription server returned an error: \($0)" }
                ?? "The transcription server returned an error (HTTP \(http.statusCode)). Try again, or check the endpoint in Settings ▸ Transcription ▸ Custom."
            throw TranscriptionError.providerFailed(provider: id, status: http.statusCode, detail: detail)
        }

        struct Payload: Decodable { let text: String }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw TranscriptionError.invalidResponse(provider: id)
        }
        return payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Builds the multipart body. `internal` so unit tests can assert its shape.
    static func multipartBody(boundary: String, audio: Data, format: AudioUploadFormat = .wav, language: String?, prompt: String?) -> Data {
        var body = Data()

        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(format.filename)\"\r\n")
        body.appendString("Content-Type: \(format.contentType)\r\n\r\n")
        body.append(audio)
        body.appendString("\r\n")

        func field(_ name: String, _ value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }

        field("response_format", "json")
        if let language { field("language", language) }
        if let prompt { field("prompt", prompt) }
        field("chat_template_kwargs", "{\"enable_thinking\":false}")

        body.appendString("--\(boundary)--\r\n")
        return body
    }
}
