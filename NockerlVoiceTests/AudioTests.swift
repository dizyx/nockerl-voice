import Foundation
import XCTest

final class AudioTests: XCTestCase {

    // Little-endian byte readers (avoid alignment/endianness pitfalls).
    private func u16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[o]) | (UInt16(d[o + 1]) << 8) }
    private func u32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[o]) | (UInt32(d[o + 1]) << 8) | (UInt32(d[o + 2]) << 16) | (UInt32(d[o + 3]) << 24)
    }
    private func ascii(_ d: Data, _ r: Range<Int>) -> String { String(decoding: d[r], as: UTF8.self) }

    func testWAVHeaderIsValid() {
        let samples = [Int16](repeating: 0, count: 1600)   // 0.1 s @ 16 kHz
        let wav = WAVWriter.wavData(samples: samples, sampleRate: 16_000, channels: 1)

        XCTAssertEqual(ascii(wav, 0..<4), "RIFF")
        XCTAssertEqual(ascii(wav, 8..<12), "WAVE")
        XCTAssertEqual(ascii(wav, 12..<16), "fmt ")
        XCTAssertEqual(u16(wav, 20), 1)                    // PCM
        XCTAssertEqual(u16(wav, 22), 1)                    // mono
        XCTAssertEqual(u32(wav, 24), 16_000)               // sample rate
        XCTAssertEqual(u16(wav, 34), 16)                   // bits/sample
        XCTAssertEqual(ascii(wav, 36..<40), "data")
        XCTAssertEqual(Int(u32(wav, 40)), samples.count * 2)
        XCTAssertEqual(wav.count, 44 + samples.count * 2)
    }

    func testWAVForNoSamplesIsHeaderOnly() {
        XCTAssertEqual(WAVWriter.wavData(samples: [], sampleRate: 16_000).count, 44)
    }

    /// Round-trip: decode the synthesized AIFF, downsample to 16 kHz mono Int16 via
    /// PCMConverter, encode WAV via WAVWriter, transcribe on the live model. Proves
    /// the WAV path is model-compatible without needing a microphone.
    func testWAVRoundTripTranscribesOnLiveModel() async throws {
        let aiff = ProcessInfo.processInfo.environment["NV_TEST_AIFF"] ?? "/tmp/nv-test.aiff"
        guard FileManager.default.fileExists(atPath: aiff) else {
            throw XCTSkip("No /tmp/nv-test.aiff: skipping audio round-trip live test.")
        }
        let samples = try PCMConverter.samples(fromFile: URL(fileURLWithPath: aiff))
        XCTAssertFalse(samples.isEmpty)

        let wav = WAVWriter.wavData(samples: samples, sampleRate: 16_000)
        XCTAssertGreaterThan(wav.count, 44)

        let service = TranscriptionService(config: .default)
        let outcome = try await service.transcribe(wav: wav, prompt: PromptBuilder.build())
        XCTAssertFalse(outcome.text.isEmpty)
        print("AUDIO ROUNDTRIP [\(outcome.provider)]: \(outcome.text)")
    }
}
