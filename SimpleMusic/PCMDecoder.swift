import AVFoundation
import Foundation

// Each instance belongs to a single serial worker. Reads never allocate whole songs.
protocol PCMDecoder: AnyObject {
    var frames: Int64 { get }
    var channels: Int { get }
    var sampleRate: Double { get }
    var duration: Double { get }
    func read(into: UnsafeMutablePointer<Float>, capacity: Int) throws -> Int
    func seek(frame: Int64) throws
}
extension PCMDecoder {
    var duration: Double { Double(frames) / sampleRate }
}

enum AudioDecoder {
    static func isVorbis(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        guard let header = try? file.read(upToCount: 512), header.starts(with: Data("OggS".utf8)),
              header.count >= 28 else { return false }
        let packet = 27 + Int(header[26])
        guard header.count >= packet + 7 else { return false }
        return header.subdata(in: packet..<(packet + 7)) == Data([1] + Array("vorbis".utf8))
    }
    static func open(_ url: URL) throws -> any PCMDecoder {
        if ["opus", "ogg"].contains(url.pathExtension.lowercased()) {
            if isVorbis(url) { return try VorbisDecoder(url) }
            return try OpusDecoder(url)
        }
        return try SystemPCMDecoder(url)
    }
}

enum VorbisError: LocalizedError {
    case decoder(Int32)
    var errorDescription: String? {
        switch self {
        case .decoder(-1001): return "連結されたOggストリームは未対応です。"
        case .decoder(-1002): return "Ogg Vorbisはモノラル／ステレオに対応しています。"
        default: return "Ogg Vorbisを読み取れません（破損・形式・読み取りエラー）。"
        }
    }
}
final class VorbisDecoder: PCMDecoder {
    private let handle: UnsafeMutableRawPointer
    let frames: Int64
    let channels: Int
    let sampleRate: Double
    init(_ url: URL) throws {
        var frames: Int64 = 0, channels: Int32 = 0, rate: Int32 = 0, error: Int32 = 0
        guard let handle = url.path.withCString({ SMVorbisOpen($0, &frames, &channels, &rate, &error) }) else {
            throw VorbisError.decoder(error)
        }
        self.handle = handle; self.frames = frames; self.channels = Int(channels); sampleRate = Double(rate)
    }
    deinit { SMVorbisClose(handle) }
    func read(into samples: UnsafeMutablePointer<Float>, capacity: Int) throws -> Int {
        let result = SMVorbisRead(handle, samples, Int32(capacity))
        guard result >= 0 else { throw VorbisError.decoder(result) }
        return Int(result)
    }
    func seek(frame: Int64) throws {
        let result = SMVorbisSeek(handle, min(max(0, frame), frames))
        guard result == 0 else { throw VorbisError.decoder(result) }
    }
}

final class SystemPCMDecoder: PCMDecoder {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    let frames: Int64
    let channels: Int
    let sampleRate: Double
    init(_ url: URL) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        frames = file.length; channels = Int(format.channelCount); sampleRate = format.sampleRate
        guard frames > 0, channels > 0, channels <= 2, sampleRate.isFinite, sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12000) else {
            throw LibraryError.invalidAudio
        }
        self.buffer = buffer
    }
    func read(into samples: UnsafeMutablePointer<Float>, capacity: Int) throws -> Int {
        guard capacity >= channels else { throw LibraryError.invalidAudio }
        let remaining = max(0, frames - file.framePosition)
        if remaining == 0 { return 0 }
        let count = min(12000, capacity / channels, Int(min(remaining, 12000)))
        try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        guard let planes = buffer.floatChannelData else { throw LibraryError.invalidAudio }
        let frames = Int(buffer.frameLength)
        for ch in 0..<channels {
            for frame in 0..<frames { samples[frame * channels + ch] = planes[ch][frame] }
        }
        return frames
    }
    func seek(frame: Int64) throws { file.framePosition = min(max(0, frame), frames) }
}
