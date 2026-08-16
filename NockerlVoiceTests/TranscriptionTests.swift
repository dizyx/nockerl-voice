import XCTest
// Code under test (NockerlVoice/Transcription/*) is compiled directly into this
// non-hosted test bundle, so no module import is needed.

final class TranscriptionTests: XCTestCase {

    // MARK: - Offline unit tests

    func testPromptBuilderIncludesVocabularyAndRules() {
        let sample = [
            VocabularyTerm(word: "Kubernetes", misspellings: ["cooper netties"]),
            VocabularyTerm(word: "PostgreSQL"),
        ]
        let prompt = PromptBuilder.build(terms: sample)
        XCTAssertTrue(prompt.contains("Kubernetes"))
        XCTAssertTrue(prompt.contains("PostgreSQL"))
        XCTAssertTrue(prompt.contains("cooper netties becomes Kubernetes"))  // correction phrasing
        XCTAssertTrue(prompt.contains("do NOT include"))     // filler-word rule
        XCTAssertTrue(prompt.contains("EXACTLY this spelling"))
    }

    func testDefaultVocabularyShipsEmpty() {
        // The public build ships no bundled vocabulary; base rules still apply.
        XCTAssertTrue(PromptBuilder.defaultTerms.isEmpty)
        let prompt = PromptBuilder.build()
        XCTAssertTrue(prompt.contains("do NOT include"))       // filler-word rule present
        XCTAssertFalse(prompt.contains("Domain vocabulary"))    // no vocab block when empty
    }

    func testMultipartBodyHasRequiredFields() {
        let wav = Data([0x52, 0x49, 0x46, 0x46]) // "RIFF"
        let body = CustomEndpointProvider.multipartBody(
            boundary: "BOUNDARY", audio: wav, format: .wav, language: "en", prompt: "hello world"
        )
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"file\"; filename=\"recording.wav\""))
        XCTAssertTrue(text.contains("Content-Type: audio/wav"))
        XCTAssertTrue(text.contains("name=\"response_format\""))
        XCTAssertTrue(text.contains("name=\"language\""))
        XCTAssertTrue(text.contains("name=\"prompt\""))
        XCTAssertTrue(text.contains("name=\"chat_template_kwargs\""))
        XCTAssertTrue(text.contains("{\"enable_thinking\":false}"))
        XCTAssertTrue(text.contains("--BOUNDARY--"))
    }

    func testMultipartOmitsLanguageWhenNil() {
        let body = CustomEndpointProvider.multipartBody(
            boundary: "B", audio: Data(), format: .wav, language: nil, prompt: nil
        )
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains("name=\"language\""))
        XCTAssertFalse(text.contains("name=\"prompt\""))
        XCTAssertTrue(text.contains("name=\"response_format\""))
    }

    func testMultipartMP3UsesMpegContentType() {
        let body = CustomEndpointProvider.multipartBody(
            boundary: "B", audio: Data([0x49, 0x44, 0x33]), format: .mp3, language: "en", prompt: nil
        )
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("filename=\"recording.mp3\""))
        XCTAssertTrue(text.contains("Content-Type: audio/mpeg"))
    }

    func testRequestBodyCarriesMP3Format() {
        let body = OpenRouterProvider.requestBody(
            model: "xiaomi/mimo-v2.5",
            instruction: "Transcribe.",
            audioBase64: "SUQz",           // "ID3" base64
            audioFormat: "mp3",
            providerSlug: "deepinfra"
        )
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("\"format\":\"mp3\""))
        XCTAssertFalse(text.contains("\"format\":\"wav\""))
    }

    func testAudioEncoderProducesMP3FromWAV() {
        // 0.5s of 16 kHz mono silence -> a valid, smaller MP3.
        let wav = WAVWriter.wavData(samples: [Int16](repeating: 0, count: 8_000), sampleRate: 16_000)
        let mp3 = AudioEncoder.mp3(fromWAV: wav)
        XCTAssertNotNil(mp3)
        XCTAssertGreaterThan(mp3?.count ?? 0, 0)
        let startsValid = (mp3?.first == 0xFF) || (mp3?.starts(with: Data([0x49, 0x44, 0x33])) ?? false)
        XCTAssertTrue(startsValid, "MP3 should start with a frame sync (0xFF) or an ID3 tag")
        XCTAssertLessThan(mp3?.count ?? .max, wav.count)  // compressed smaller than the WAV
    }

    func testServiceWithoutFallbackThrowsWhenCustomDown() async {
        // Custom engine pointed at an unreachable endpoint: the error surfaces (no fallback).
        let config = TranscriptionConfig(
            customEndpoint: URL(string: "http://127.0.0.1:9")!,   // discard port
            engine: .custom,
            healthProbeTimeout: 1,
            transcriptionTimeout: 2
        )
        let service = TranscriptionService(config: config)
        do {
            _ = try await service.transcribe(wav: Data([0x52, 0x49, 0x46, 0x46]), prompt: nil)
            XCTFail("Expected the custom endpoint to fail")
        } catch {
            // Any error is acceptable; the point is it throws instead of silently falling back.
        }
    }

    // MARK: - Cloud (OpenRouter) provider

    func testOpenRouterRequestBodyPinnedHasAudioPromptReasoning() {
        let body = OpenRouterProvider.requestBody(
            model: "xiaomi/mimo-v2.5",
            instruction: "Transcribe this audio. Vocabulary: Kubernetes.",
            audioBase64: "UklGRgABAABXQVZF",   // "RIFF..WAVE" base64-ish sample
            providerSlug: "deepinfra"
        )
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("input_audio"))
        XCTAssertTrue(text.contains("UklGRgABAABXQVZF"))          // the audio payload
        XCTAssertTrue(text.contains("Vocabulary: Kubernetes"))     // the prompt is sent
        XCTAssertTrue(text.contains("\"format\""))
        XCTAssertTrue(text.contains("wav"))
        XCTAssertTrue(text.contains("reasoning"))                  // unified reasoning control
        XCTAssertTrue(text.contains("enabled"))                    // reasoning:{enabled:false}
        XCTAssertTrue(text.contains("zdr"))                        // ZDR always enforced
        XCTAssertTrue(text.contains("\"only\""))                   // strict pin
        XCTAssertTrue(text.contains("deepinfra"))
        XCTAssertFalse(text.contains("chat_template_kwargs"))      // removed (provider-ignored)
        XCTAssertFalse(text.contains("sort"))                      // no automatic routing
        XCTAssertFalse(text.contains("ignore"))                    // no automatic exclusions
    }

    func testOpenRouterExtractsStringContent() throws {
        let json = #"{"choices":[{"message":{"content":"hello world"}}]}"#.data(using: .utf8)!
        let text = try OpenRouterProvider.extractText(from: json, providerID: "cloud")
        XCTAssertEqual(text, "hello world")
    }

    func testOpenRouterExtractsArrayContent() throws {
        // Some providers return content as an array of typed parts.
        let json = #"{"choices":[{"message":{"content":[{"type":"text","text":"part one "},{"type":"text","text":"part two"}]}}]}"#.data(using: .utf8)!
        let text = try OpenRouterProvider.extractText(from: json, providerID: "cloud")
        XCTAssertEqual(text, "part one part two")
    }

    func testOpenRouterExtractsReasoningWhenContentNull() throws {
        // Real MiMo-on-DeepInfra shape: transcript lands in `reasoning`, content=null.
        let json = #"{"choices":[{"message":{"content":null,"reasoning":"Check. One, two."}}]}"#.data(using: .utf8)!
        let text = try OpenRouterProvider.extractText(from: json, providerID: "cloud")
        XCTAssertEqual(text, "Check. One, two.")
    }

    func testOpenRouterExtractsReasoningDetailsWhenReasoningEmpty() throws {
        let json = #"{"choices":[{"message":{"content":null,"reasoning":"","reasoning_details":[{"type":"reasoning.text","text":"Hello there."}]}}]}"#.data(using: .utf8)!
        let text = try OpenRouterProvider.extractText(from: json, providerID: "cloud")
        XCTAssertEqual(text, "Hello there.")
    }

    func testOpenRouterPrefersContentOverReasoning() throws {
        let json = #"{"choices":[{"message":{"content":"final text","reasoning":"thinking noise"}}]}"#.data(using: .utf8)!
        let text = try OpenRouterProvider.extractText(from: json, providerID: "cloud")
        XCTAssertEqual(text, "final text")
    }

    func testOpenRouterSurfaces200ErrorBodyWithActionableZDRMessage() {
        let json = #"{"error":{"message":"No endpoints found matching your data policy","code":404}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try OpenRouterProvider.extractText(from: json, providerID: "cloud")) { error in
            guard case let TranscriptionError.providerFailed(_, _, detail) = error else {
                return XCTFail("expected providerFailed, got \(error)")
            }
            XCTAssertTrue(detail.lowercased().contains("zero data retention"))   // actionable guidance
            XCTAssertTrue(detail.contains("Settings"))                           // points to where to fix it
        }
    }

    func testOpenRouterSurfacesRawRateLimitMessage() {
        // OpenRouter wraps the useful text in error.metadata.raw; the top-level message
        // is a generic "Provider returned error". Surface the raw one.
        let json = #"{"error":{"message":"Provider returned error","code":429,"metadata":{"raw":"xiaomi/mimo-v2.5 is temporarily rate-limited upstream. Please retry shortly."}}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try OpenRouterProvider.extractText(from: json, providerID: "cloud")) { error in
            guard case let TranscriptionError.providerFailed(_, _, detail) = error else {
                return XCTFail("expected providerFailed, got \(error)")
            }
            XCTAssertTrue(detail.lowercased().contains("busy"))                  // human-readable "server busy"
            XCTAssertFalse(detail.contains("Provider returned error"))           // generic top-level not surfaced
        }
    }

    func testProviderErrorTextSkipsGenericAndNeverLeaksRawJSON() {
        // A useless generic message → nil (caller substitutes a clean generic, not raw JSON).
        let generic = #"{"error":{"message":"Error","type":null,"param":null,"code":null}}"#.data(using: .utf8)!
        XCTAssertNil(ProviderErrorText.extractMessage(from: generic))
        // A real message is surfaced.
        XCTAssertEqual(
            ProviderErrorText.extractMessage(from: #"{"error":{"message":"You are out of credit"}}"#.data(using: .utf8)!),
            "You are out of credit"
        )
        // OpenRouter's nested metadata.raw is preferred over the vague top-level message.
        XCTAssertEqual(
            ProviderErrorText.extractMessage(from: #"{"error":{"message":"Provider returned error","metadata":{"raw":"model is rate-limited upstream"}}}"#.data(using: .utf8)!),
            "model is rate-limited upstream"
        )
        // Non-JSON → nil, never a crash.
        XCTAssertNil(ProviderErrorText.extractMessage(from: Data("not json".utf8)))
    }

    func testErrorDetailNeverReturnsRawJSON() {
        // The exact body that leaked into the History row before hardening.
        let leaked = #"{"error":{"message":"Error","type":null,"param":null,"code":null}}"#.data(using: .utf8)!
        let detail = OpenRouterProvider.errorDetail(from: leaked)
        XCTAssertFalse(detail.contains("{"))              // no raw JSON braces
        XCTAssertFalse(detail.contains("null"))           // no raw JSON fields
        XCTAssertNotEqual(detail.lowercased(), "error")   // not the useless generic
        XCTAssertFalse(detail.isEmpty)
    }

    func testOpenRouterEmptyContentThrowsEmptyTranscript() {
        let json = #"{"choices":[{"message":{"content":null}}]}"#.data(using: .utf8)!
        XCTAssertThrowsError(try OpenRouterProvider.extractText(from: json, providerID: "cloud")) { error in
            guard case TranscriptionError.emptyTranscript = error else {
                return XCTFail("expected emptyTranscript, got \(error)")
            }
        }
    }

    func testOpenRouterProviderRoutingIsStrictPin() {
        let routing = OpenRouterProvider.providerRouting(for: "venice")
        XCTAssertEqual(routing["zdr"] as? Bool, true)
        XCTAssertEqual(routing["only"] as? [String], ["venice"])
        XCTAssertNil(routing["sort"])       // no automatic sort
        XCTAssertNil(routing["ignore"])     // no automatic exclusions
    }

    func testOpenRouterInstructionKeepsPromptAndGuardsPreamble() {
        let instruction = OpenRouterProvider.instruction(from: "Transcribe this audio. Kubernetes, PostgreSQL.")
        XCTAssertTrue(instruction.contains("Kubernetes"))
        XCTAssertTrue(instruction.contains("PostgreSQL"))
        XCTAssertTrue(instruction.lowercased().contains("only"))   // no-preamble guard
        // Falls back to a bare transcription instruction when no prompt is supplied.
        let fallback = OpenRouterProvider.instruction(from: nil)
        XCTAssertTrue(fallback.lowercased().contains("transcribe"))
    }

    // MARK: - Cloud provider catalog

    func testCatalogParsesEndpointsPricingAndBaseSlug() {
        let json = #"""
        {"data":{"endpoints":[
          {"provider_name":"DeepInfra","tag":"deepinfra/bf16","pricing":{"prompt":"0.0000004","completion":"0.000002"},"throughput_last_30m":{"p50":35}},
          {"provider_name":"DigitalOcean","tag":"digitalocean","pricing":{"prompt":"0.000000105","completion":"0.00000028"}}
        ]}}
        """#.data(using: .utf8)!
        let eps = CloudProviderCatalog.parseEndpoints(json)
        XCTAssertEqual(eps?.count, 2)
        let di = eps?.first { $0.slug == "deepinfra" }
        XCTAssertEqual(di?.name, "DeepInfra")
        XCTAssertEqual(di?.slug, "deepinfra")   // base slug (quant suffix stripped)
        XCTAssertEqual(di?.throughput, 35)
    }

    func testCatalogProvidersExcludeAudioIncompatibleCheapestFirst() {
        let eps = [
            CloudProviderCatalog.Endpoint(name: "DeepInfra", slug: "deepinfra", promptPrice: 0.0000004, completionPrice: 0.000002, throughput: 35),
            CloudProviderCatalog.Endpoint(name: "Parasail", slug: "parasail", promptPrice: 0.00000014, completionPrice: 0.00000028, throughput: nil),
            CloudProviderCatalog.Endpoint(name: "DigitalOcean", slug: "digitalocean", promptPrice: 0.000000105, completionPrice: 0.00000028, throughput: 11),
            CloudProviderCatalog.Endpoint(name: "Xiaomi", slug: "xiaomi", promptPrice: 0.00000014, completionPrice: 0.00000028, throughput: 37),
        ]
        let list = CloudProviderCatalog.providers(from: eps)
        // Audio-incompatible providers are excluded (DigitalOcean); every other provider is
        // kept, cheapest first. ZDR is enforced at REQUEST time now (provider.zdr=true), not
        // pre-filtered, so Xiaomi is no longer dropped here.
        XCTAssertEqual(list.count, 3)
        XCTAssertFalse(list.contains { $0.slug == "digitalocean" })
        XCTAssertEqual(Set(list.map(\.slug)), ["parasail", "xiaomi", "deepinfra"])
        XCTAssertEqual(list.last?.slug, "deepinfra")   // most expensive sorts last
        XCTAssertEqual(list.first?.promptPricePer1M ?? 0, 0.14, accuracy: 0.001)
    }

    func testCatalogParsesAudioModelsOnly() {
        let json = #"""
        {"data":[
          {"id":"xiaomi/mimo-v2.5","name":"Xiaomi: MiMo-V2.5","architecture":{"input_modalities":["text","audio","image"],"output_modalities":["text"]}},
          {"id":"openai/gpt-5","name":"GPT-5","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}},
          {"id":"openai/gpt-audio","name":"GPT Audio","architecture":{"input_modalities":["text","audio"],"output_modalities":["text"]}}
        ]}
        """#.data(using: .utf8)!
        let models = CloudProviderCatalog.parseModels(json)
        XCTAssertEqual(models?.map(\.id).sorted(), ["openai/gpt-audio", "xiaomi/mimo-v2.5"])  // audio-only
        XCTAssertFalse(models?.contains { $0.id == "openai/gpt-5" } ?? true)                  // text/image excluded
    }

    func testModelCurationExcludesBrokenAndTagsRecommended() {
        let json = #"""
        {"data":[
          {"id":"some/untested-omni","name":"Untested Omni","architecture":{"input_modalities":["audio"],"output_modalities":["text"]}},
          {"id":"xiaomi/mimo-v2.5","name":"Xiaomi: MiMo-V2.5","architecture":{"input_modalities":["audio"],"output_modalities":["text"]}},
          {"id":"openrouter/auto","name":"Auto Router","architecture":{"input_modalities":["audio"],"output_modalities":["text"]}},
          {"id":"meta/muse-spark-1.1","name":"Muse Spark","architecture":{"input_modalities":["audio"],"output_modalities":["text"]}}
        ]}
        """#.data(using: .utf8)!
        let models = CloudProviderCatalog.parseModels(json) ?? []
        let ids = Set(models.map(\.id))
        XCTAssertTrue(ids.contains("xiaomi/mimo-v2.5"))       // recommended, shown
        XCTAssertTrue(ids.contains("some/untested-omni"))     // unknown but audio-capable, shown
        XCTAssertFalse(ids.contains("openrouter/auto"))       // excluded: auto-routes, no ZDR control
        XCTAssertFalse(ids.contains("meta/muse-spark-1.1"))   // excluded: returns empty on audio
        XCTAssertEqual(models.first(where: { $0.id == "xiaomi/mimo-v2.5" })?.recommended, true)
        XCTAssertEqual(models.first(where: { $0.id == "some/untested-omni" })?.recommended, false)
        XCTAssertEqual(models.first?.id, "xiaomi/mimo-v2.5")  // recommended sorted first
    }

    func testInklingTranscriptStripsTrailingMarker() {
        // Inkling appends a trailing end-of-message token on longer outputs; strip it.
        XCTAssertEqual(
            OpenRouterProvider.cleanTranscript("Good morning everyone. <|end|>", model: "thinkingmachines/inkling"),
            "Good morning everyone."
        )
        // Multiple trailing tokens + trailing whitespace.
        XCTAssertEqual(
            OpenRouterProvider.cleanTranscript("Hello. <end> <|stop|>\n", model: "thinkingmachines/inkling"),
            "Hello."
        )
        // A mid-sentence "<" with no closing ">" at the end is NOT stripped.
        XCTAssertEqual(
            OpenRouterProvider.cleanTranscript("The value is < 5", model: "thinkingmachines/inkling"),
            "The value is < 5"
        )
        // Other models are never touched (guards against false stripping).
        XCTAssertEqual(
            OpenRouterProvider.cleanTranscript("Meet at 3pm <keep>", model: "xiaomi/mimo-v2.5"),
            "Meet at 3pm <keep>"
        )
    }

    // MARK: - Live integration test (live endpoint required)

    /// Runs only when NV_TEST_WAV points at a 16 kHz mono WAV. The runner script
    /// synthesizes a throwaway WAV via `say`/`afconvert` (no committed audio).
    func testLocalTranscriptionAgainstLiveModel() async throws {
        let envPath = ProcessInfo.processInfo.environment["NV_TEST_WAV"]
        let defaultPath = "/tmp/nv-test.wav"
        let candidate = envPath ?? defaultPath
        guard FileManager.default.fileExists(atPath: candidate) else {
            throw XCTSkip("No test WAV, so skipping the live test (set NV_TEST_WAV or place /tmp/nv-test.wav).")
        }
        let wav = try Data(contentsOf: URL(fileURLWithPath: candidate))
        let service = TranscriptionService(config: .default)
        let outcome = try await service.transcribe(wav: wav, prompt: PromptBuilder.build())
        XCTAssertEqual(outcome.provider, "custom")
        XCTAssertFalse(outcome.text.isEmpty)
        print("LIVE TRANSCRIPT [\(outcome.provider)]: \(outcome.text)")
    }
}
