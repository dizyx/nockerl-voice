import AVFoundation
import Foundation

/// Encodes 16-bit PCM samples into a canonical little-endian WAV container.
/// Both transcription backends accept WAV.
enum WAVWriter {

    /// Build a WAV file (RIFF/WAVE, PCM) from interleaved Int16 samples.
    static func wavData(samples: [Int16], sampleRate: Int, channels: Int = 1) -> Data {
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let blockAlign = channels * bytesPerSample
        let byteRate = sampleRate * blockAlign
        let dataSize = samples.count * bytesPerSample

        var data = Data(capacity: 44 + dataSize)
        func appendU32(_ value: UInt32) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        func appendU16(_ value: UInt16) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        func appendASCII(_ s: String) { data.append(s.data(using: .ascii)!) }

        appendASCII("RIFF")
        appendU32(UInt32(36 + dataSize))     // chunk size
        appendASCII("WAVE")

        appendASCII("fmt ")
        appendU32(16)                         // PCM fmt chunk size
        appendU16(1)                          // audio format = PCM
        appendU16(UInt16(channels))
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(byteRate))
        appendU16(UInt16(blockAlign))
        appendU16(UInt16(bitsPerSample))

        appendASCII("data")
        appendU32(UInt32(dataSize))
        // arm64 is little-endian, so the Int16 array bytes are already correct.
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        return data
    }

    /// Extract interleaved Int16 samples from an Int16 PCM buffer (channel 0 for mono).
    static func int16Samples(from buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let channel = buffer.int16ChannelData else { return [] }
        let count = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channel[0], count: count))
    }
}
