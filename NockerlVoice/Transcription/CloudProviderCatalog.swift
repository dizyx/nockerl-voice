import Foundation

/// An audio-capable model available on OpenRouter (for the Model dropdown).
struct CloudModelInfo: Identifiable, Sendable, Equatable {
    let id: String     // model slug, e.g. "xiaomi/mimo-v2.5"
    let name: String   // display name, e.g. "Xiaomi: MiMo-V2.5"
    /// True for models empirically verified to transcribe well through our path (shown
    /// with a "Recommended" tag). Everything else audio-capable is shown as "Untested".
    var recommended: Bool = false
    /// True when the model has NO zero-data-retention endpoint on OpenRouter, so it
    /// cannot be used while the ZDR requirement is on. The model stays selectable and the
    /// privacy default stays on; the picker warns instead of hiding or silently
    /// downgrading. See `CloudProviderCatalog.isZDRIncompatible`.
    var zdrIncompatible: Bool = false
}

/// One selectable cloud provider, merged from OpenRouter's model-endpoints API
/// (pricing + throughput) and the provider data-policy list (ZDR status). Only
/// zero-data-retention, audio-capable providers are ever surfaced.
struct CloudProviderInfo: Identifiable, Sendable, Equatable {
    /// Base provider slug used for `provider.only` routing (e.g. "deepinfra").
    let slug: String
    /// Display name (e.g. "DeepInfra").
    let name: String
    let promptPricePer1M: Double       // USD per 1M input tokens
    let completionPricePer1M: Double   // USD per 1M output tokens
    let throughputTps: Int?            // p50 tokens/sec, if known

    var id: String { slug }

    var priceLabel: String {
        String(format: "$%.3f / $%.2f per 1M", promptPricePer1M, completionPricePer1M)
    }
}

/// Fetches the live audio-model list and the ZDR provider list (with pricing) for the
/// Cloud settings dropdowns.
///
/// Sources:
///   - `GET /api/v1/models`                    → audio-capable models (`input_modalities`)
///   - `GET /api/v1/models/{model}/endpoints`  → providers, pricing, throughput
///
/// ZDR is NOT sourced here: OpenRouter removed `/api/frontend/all-providers` (it now serves
/// HTML), and no public endpoint exposes per-provider data policy. The ZDR mandate is enforced
/// at REQUEST time instead: `provider.zdr=true` on every transcription (see OpenRouterProvider).
/// Degrades gracefully: on any failure the fetch returns an empty list.
enum CloudProviderCatalog {

    /// ZDR providers that reject `input_audio` for MiMo ("failed to convert request").
    /// Excluded from the provider list: empirically determined; the API says they are
    /// audio-capable models but the provider's endpoint can't actually take audio.
    static let audioIncompatibleProviders = ["digitalocean"]

    /// Models verified to work through the app's own request path. Shown with a
    /// "Recommended" tag and sorted first; every other audio-capable model is shown as
    /// "Untested" (selectable, at the user's risk).
    ///
    /// This list is only as good as its last probe, and it has been wrong before: an
    /// earlier version claimed every entry was verified while half of them were in fact
    /// broken, some by our own payload rather than by the model. Re-run
    /// `scripts/verify-cloud-models.py` after changing this list, or after changing
    /// anything in `OpenRouterProvider.requestBody`, rather than trusting the comment.
    /// The provider chosen by default when the current pick is not valid for the model,
    /// ahead of the cheapest. DeepInfra serves the default MiMo model reliably; sorting on
    /// price alone put new users on a provider that fails the request on its own side, so
    /// their first transcription errored for a reason they could not see. Falls back to
    /// cheapest when DeepInfra does not serve the selected model.
    static let preferredProviderSlug = "deepinfra"

    static let recommendedModelIDs: Set<String> = [
        "xiaomi/mimo-v2.5",
        "openai/gpt-audio",
        "google/gemini-2.5-pro",
        "google/gemini-3.5-flash",
        "google/gemini-3.6-flash",
        "thinkingmachines/inkling",
        "thinkingmachines/inkling-small",
    ]

    /// Model families whose endpoint REJECTS the `reasoning` control the app sends by
    /// default. Google returns HTTP 400 "Reasoning is mandatory for this endpoint" when
    /// `reasoning: {enabled: false}` is present, which broke every Gemini model in the
    /// list above: the failure was caused by our own payload, not by the model.
    ///
    /// Omitting the key entirely (rather than sending `enabled: true`) is what was
    /// verified to work. This is data, not an `if` inside the provider, so the next model
    /// family with the same constraint is one line here.
    ///
    /// Only these models lose the control. Everyone else keeps `reasoning:
    /// {enabled: false}`, which is what keeps the transcript in `content` for MiMo, and
    /// the response parser already falls back to `reasoning` when `content` is null, so
    /// the models listed here stay safe without it.
    static let reasoningMandatoryPrefixes: [String] = ["google/"]

    /// Whether `model` rejects the `reasoning` control (see `reasoningMandatoryPrefixes`).
    static func mandatesReasoning(_ model: String) -> Bool {
        let id = model.lowercased()
        return reasoningMandatoryPrefixes.contains { id.hasPrefix($0) }
    }

    /// Model families with NO zero-data-retention endpoint on OpenRouter. Sending
    /// `provider: {zdr: true}` for these returns HTTP 404 "No endpoints found matching
    /// your data policy", so they simply cannot run while the ZDR requirement is on.
    ///
    /// They are deliberately NOT excluded: they transcribe correctly with the requirement
    /// off, so the choice belongs to the user. The privacy default stays on and the picker
    /// warns; nothing auto-disables ZDR and nothing silently drops the flag.
    static let zdrIncompatiblePrefixes: [String] = ["openai/"]

    /// Whether `model` has no ZDR endpoint (see `zdrIncompatiblePrefixes`).
    static func isZDRIncompatible(_ model: String) -> Bool {
        let id = model.lowercased()
        return zdrIncompatiblePrefixes.contains { id.hasPrefix($0) }
    }

    /// Models hidden from the Model picker entirely: either they don't actually
    /// transcribe via our path (return empty / refuse the audio), or they auto-route and
    /// discard ZDR + provider control (unsafe under our zero-data-retention default).
    static let excludedModelIDs: Set<String> = [
        "openrouter/auto",                                     // auto-routes: no ZDR / provider control
        "openrouter/auto-beta",
        "meta/muse-spark-1.1",                                 // returns an empty response on audio
        "mistralai/voxtral-small-24b-2507",                    // returns an empty response on audio
        "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free",  // refuses: never receives the audio
        // Never receives the audio part at all. Asked to DESCRIBE what it hears, with an
        // explicit NO_AUDIO_RECEIVED escape hatch, it returned exactly NO_AUDIO_RECEIVED
        // for both mp3 and wav, with and without provider routing, while the full-size
        // openai/gpt-audio answered correctly on the identical payload.
        "openai/gpt-audio-mini",
    ]

    // MARK: - Audio models

    /// Audio-capable models on OpenRouter, sorted by name. Empty on failure.
    static func fetchAudioModels(apiKey: String, session: URLSession = .shared) async -> [CloudModelInfo] {
        guard let data = await get("https://openrouter.ai/api/v1/models", apiKey: apiKey, session: session) else { return [] }
        return parseModels(data) ?? []
    }

    /// Parse `/api/v1/models`, keeping only models whose `input_modalities` include
    /// "audio" (and produce text).
    static func parseModels(_ data: Data) -> [CloudModelInfo]? {
        struct Payload: Decodable {
            struct Model: Decodable {
                let id: String
                let name: String?
                let architecture: Arch?
                struct Arch: Decodable {
                    let inputModalities: [String]?
                    let outputModalities: [String]?
                }
            }
            let data: [Model]
        }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        guard let p = try? dec.decode(Payload.self, from: data) else { return nil }
        return p.data
            .filter { !excludedModelIDs.contains($0.id) }
            .filter { ($0.architecture?.inputModalities ?? []).contains("audio") }
            .filter { ($0.architecture?.outputModalities ?? ["text"]).contains("text") }
            .map {
                CloudModelInfo(
                    id: $0.id,
                    name: $0.name ?? $0.id,
                    recommended: recommendedModelIDs.contains($0.id),
                    zdrIncompatible: isZDRIncompatible($0.id)
                )
            }
            // Recommended first, then alphabetical.
            .sorted {
                if $0.recommended != $1.recommended { return $0.recommended }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    // MARK: - Providers (pricing + ZDR)

    /// Audio-capable providers that serve `model`, cheapest first. Empty on failure. ZDR is
    /// NOT pre-filtered here: OpenRouter removed the public per-provider data-policy endpoint
    /// (`/api/frontend/all-providers` now serves HTML); the ZDR mandate is enforced at REQUEST
    /// time instead via `provider.zdr=true` (see OpenRouterProvider).
    static func fetchProviders(model: String, apiKey: String, session: URLSession = .shared) async -> [CloudProviderInfo] {
        guard let eps = (await get("https://openrouter.ai/api/v1/models/\(model)/endpoints", apiKey: apiKey, session: session))
            .flatMap(parseEndpoints) else { return [] }
        return providers(from: eps)
    }

    struct Endpoint: Equatable {
        let name: String
        let slug: String
        let promptPrice: Double
        let completionPrice: Double
        let throughput: Int?
    }

    /// Parse the model `/endpoints` response into provider pricing/speed rows.
    /// Uses explicit CodingKeys (not `convertFromSnakeCase`, which mis-maps the
    /// digit-bearing `throughput_last_30m` key).
    static func parseEndpoints(_ data: Data) -> [Endpoint]? {
        struct Payload: Decodable {
            struct Body: Decodable { let endpoints: [EP] }
            struct EP: Decodable {
                let providerName: String
                let tag: String
                let pricing: Pricing
                let throughput: Throughput?
                enum CodingKeys: String, CodingKey {
                    case providerName = "provider_name"
                    case tag, pricing
                    case throughput = "throughput_last_30m"
                }
                struct Pricing: Decodable { let prompt: String; let completion: String }
                struct Throughput: Decodable { let p50: Double? }
            }
            let data: Body
        }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return p.data.endpoints.map { ep in
            Endpoint(
                name: ep.providerName,
                slug: ep.tag.split(separator: "/").first.map(String.init) ?? ep.tag,
                promptPrice: Double(ep.pricing.prompt) ?? 0,
                completionPrice: Double(ep.pricing.completion) ?? 0,
                throughput: ep.throughput?.p50.map { Int($0) }
            )
        }
    }

    /// The model's audio-capable providers, cheapest first. ZERO-DATA-RETENTION is no longer
    /// pre-filtered here: OpenRouter removed the public provider data-policy endpoint
    /// (`/api/frontend/all-providers` now serves HTML, and neither `/endpoints` nor
    /// `/api/v1/providers` carries ZDR). The ZDR MANDATE instead holds at REQUEST time:
    /// OpenRouterProvider always sends `provider.zdr=true`, so OpenRouter refuses to route
    /// audio to any non-ZDR provider (declined server-side with a clear "pick a different
    /// provider" message; the audio is never sent).
    static func providers(from endpoints: [Endpoint]) -> [CloudProviderInfo] {
        endpoints
            .filter { !audioIncompatibleProviders.contains($0.slug.lowercased()) } // audio-capable only
            .map { ep in
                CloudProviderInfo(
                    slug: ep.slug,
                    name: ep.name,
                    promptPricePer1M: ep.promptPrice * 1_000_000,
                    completionPricePer1M: ep.completionPrice * 1_000_000,
                    throughputTps: ep.throughput
                )
            }
            .sorted { $0.promptPricePer1M < $1.promptPricePer1M }
    }

    // MARK: - Network

    private static func get(_ urlString: String, apiKey: String, session: URLSession) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
