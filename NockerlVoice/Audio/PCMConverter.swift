import AVFoundation
import Foundation

/// Converts arbitrary input PCM (e.g. 48 kHz float from the mic) into 16 kHz mono
/// Int16 samples. One instance per recording: `AVAudioConverter` keeps
/// sample-rate-conversion state across chunks.
final class PCMConverter {

    /// 16 kHz mono signed-16-bit, interleaved: the target the backends expect.
    static let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true
    )!

    private let converter: AVAudioConverter

    init?(inputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat) else {
            return nil
        }
        self.converter = converter
    }

    /// Convert one input buffer, returning the produced Int16 samples.
    func convert(_ input: AVAudioPCMBuffer) -> [Int16] {
        let ratio = Self.targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else {
            return []
        }
        var consumed = false
        let status = converter.convert(to: output, error: nil) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error else { return [] }
        return WAVWriter.int16Samples(from: output)
    }

    /// One-shot helper: decode an audio file and return 16 kHz mono Int16 samples.
    /// Used by tests to round-trip non-mic audio through the WAV path.
    static func samples(fromFile url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return []
        }
        try file.read(into: input)
        guard let converter = PCMConverter(inputFormat: format) else { return [] }
        return converter.convert(input)
    }
}
