import Foundation
enum OpusImportError: LocalizedError {
    case decoder(Int32)
    var errorDescription: String? {
        switch self {
        case .decoder(-1001): return "連結されたOggストリームは未対応です。"
        case .decoder(-1002): return "Opusはモノラル／ステレオに対応しています。"
        default: return "Ogg Opusを読み取れません（破損・形式・読み取りエラー）。"
        }
    }
}

// Owned by one caller / serial decoding queue. No PCM file or whole-song allocation.
final class OpusDecoder: PCMDecoder {
    private let handle: UnsafeMutableRawPointer
    let frames: Int64
    let channels: Int
    let sampleRate: Double = 48000
    var duration: Double { Double(frames) / 48000 }
    init(_ url: URL) throws {
        var frames: Int64 = 0, channels: Int32 = 0, error: Int32 = 0
        guard let handle = url.path.withCString({ SMOpusOpen($0, &frames, &channels, &error) }) else {
            throw OpusImportError.decoder(error)
        }
        self.handle = handle; self.frames = frames; self.channels = Int(channels)
    }
    deinit { SMOpusClose(handle) }
    func read(into samples: UnsafeMutablePointer<Float>, capacity: Int) throws -> Int {
        let count = SMOpusRead(handle, samples, Int32(capacity))
        guard count >= 0 else { throw OpusImportError.decoder(count) }
        return Int(count)
    }
    func seek(frame: Int64) throws {
        let code = SMOpusSeek(handle, min(max(0, frame), frames))
        guard code == 0 else { throw OpusImportError.decoder(code) }
    }
    var artist: String? {
        var utf8 = [CChar](repeating: 0, count: 65536)
        let count = SMOpusArtist(handle, &utf8, Int32(utf8.count))
        guard count > 0 else { return nil }
        return utf8.withUnsafeBytes { String(bytes: $0.prefix(Int(count)), encoding: .utf8) }
    }
    func validateEdges() throws {
        var samples = [Float](repeating: 0, count: 12000 * channels)
        let first = try samples.withUnsafeMutableBufferPointer { try read(into: $0.baseAddress!, capacity: $0.count) }
        guard first > 0 else { throw LibraryError.invalidAudio }
        try seek(frame: max(0, frames - 12000))
        let last = try samples.withUnsafeMutableBufferPointer { try read(into: $0.baseAddress!, capacity: $0.count) }
        guard last > 0 else { throw LibraryError.invalidAudio }
        try seek(frame: 0)
    }
}

