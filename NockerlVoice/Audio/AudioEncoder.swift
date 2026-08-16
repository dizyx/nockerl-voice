import Foundation
import lame

/// The wire format for uploaded audio. WAV is lossless but ~10x larger; MP3 keeps
/// long meetings under the cloud provider's request-size limit in a single call.
enum AudioUploadFormat {
    case wav
    case mp3

    /// The value for OpenRouter's `input_audio.format` field.
    var openRouter: String { self == .mp3 ? "mp3" : "wav" }
    /// The multipart Content-Type for the custom (OpenAI-compatible) endpoint.
    var contentType: String { self == .mp3 ? "audio/mpeg" : "audio/wav" }
    /// The multipart filename (extension tells the server the format).
    var filename: String { self == .mp3 ? "recording.mp3" : "recording.wav" }
}

/// On-device MP3 encoding. macOS has no native MP3 encoder (AVFoundation/AudioToolbox
/// only decode MP3), so this uses LAME (`import lame`, a source-compiled SPM C target).
///
/// Speech at 16 kHz mono compresses ~10x vs raw PCM WAV with no meaningful ASR loss,
/// which is what lets a full hour-plus meeting upload in one request instead of
/// hitting the provider's payload ceiling (and being chunked, which loses speaker
/// labels after the first chunk).
enum AudioEncoder {

    /// Encode the app's canonical 16 kHz mono 16-bit PCM WAV to CBR mono MP3.
    /// Returns nil on any failure so callers can fall back to the original WAV.
    static func mp3(fromWAV wav: Data, sampleRate: Int32 = 16_000, bitrateKbps: Int32 = 48) -> Data? {
        guard let pcm = pcmSamples(fromWAV: wav), !pcm.isEmpty else { return nil }
        return encode(pcm: pcm, sampleRate: sampleRate, bitrateKbps: bitrateKbps)
    }

    /// Extract interleaved Int16 samples from a PCM WAV by locating the `data`
    /// subchunk (handles the standard 44-byte header and any leading chunks).
    static func pcmSamples(fromWAV wav: Data) -> [Int16]? {
        let n = wav.count
        guard n > 44 else { return nil }
        var dataOffset = 44
        var dataSize = n - 44
        wav.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 12  // after "RIFF"<size>"WAVE"
            while i + 8 <= n {
                let isData = b[i] == 0x64 && b[i + 1] == 0x61 && b[i + 2] == 0x74 && b[i + 3] == 0x61  // "data"
                let size = Int(b[i + 4]) | Int(b[i + 5]) << 8 | Int(b[i + 6]) << 16 | Int(b[i + 7]) << 24
                if isData {
                    dataOffset = i + 8
                    dataSize = min(size, n - dataOffset)
                    break
                }
                if size < 0 { break }
                i += 8 + size + (size & 1)  // chunks are word-aligned
            }
        }
        guard dataSize >= 2, dataOffset + dataSize <= n else { return nil }
        let count = dataSize / 2
        var samples = [Int16](repeating: 0, count: count)
        samples.withUnsafeMutableBytes { dst in
            wav.withUnsafeBytes { src in
                dst.baseAddress!.copyMemory(from: src.baseAddress!.advanced(by: dataOffset), byteCount: count * 2)
            }
        }
        return samples
    }

    /// Encode Int16 mono PCM to CBR MP3. `num_channels = 1` selects mono; LAME
    /// defaults to CBR (vbr_off), so no MPEG_mode / vbr_mode enum calls are needed.
    static func encode(pcm: [Int16], sampleRate: Int32, bitrateKbps: Int32) -> Data? {
        guard !pcm.isEmpty, let gfp = lame_init() else { return nil }
        defer { lame_close(gfp) }
        lame_set_in_samplerate(gfp, sampleRate)
        lame_set_num_channels(gfp, 1)
        lame_set_brate(gfp, bitrateKbps)
        lame_set_quality(gfp, 2)  // 0=best .. 9=worst; 2 is a good speech default
        guard lame_init_params(gfp) >= 0 else { return nil }

        var mp3 = Data()
        let chunk = 8192
        var out = [UInt8](repeating: 0, count: Int(Double(chunk) * 1.25) + 7200)  // LAME worst case
        var i = 0
        while i < pcm.count {
            let take = min(chunk, pcm.count - i)
            let written = pcm.withUnsafeBufferPointer { buf -> Int32 in
                let base = buf.baseAddress! + i
                // Mono: pass the same buffer as L and R; with num_channels == 1 LAME uses L.
                return lame_encode_buffer(gfp, base, base, Int32(take), &out, Int32(out.count))
            }
            guard written >= 0 else { return nil }
            if written > 0 { mp3.append(contentsOf: out.prefix(Int(written))) }
            i += take
        }
        let flushed = lame_encode_flush(gfp, &out, Int32(out.count))
        guard flushed >= 0 else { return nil }
        if flushed > 0 { mp3.append(contentsOf: out.prefix(Int(flushed))) }
        return mp3.isEmpty ? nil : mp3
    }
}
