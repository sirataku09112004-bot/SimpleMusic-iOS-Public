import Foundation
import AVFoundation

enum ArtistMetadata {
    static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : String(result.prefix(4096))
    }
    static func read(_ url: URL) async -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "opus" || ext == "ogg" {
            if let artist = try? oggArtist(url) { return cleaned(artist) }
        }
        if ext == "flac", let artist = try? flacArtist(url), let result = cleaned(artist) { return result }
        if ext == "wav", let artist = try? wavArtist(url), let result = cleaned(artist) { return result }
        let asset = AVURLAsset(url: url)
        var items = (try? await asset.load(.metadata)) ?? []
        items += (try? await asset.load(.commonMetadata)) ?? []
        // ARTIST / lead performer take precedence over album artist or composer.
        for item in items {
            let identifier = item.identifier?.rawValue.lowercased() ?? ""
            let key = (item.key as? String)?.lowercased() ?? ""
            if item.commonKey?.rawValue == "artist" || identifier.contains("tpe1")
                || key == "artist" || identifier.hasSuffix("/©art") {
                if let value = try? await item.load(.stringValue), let artist = cleaned(value) { return artist }
            }
        }
        return nil
    }
    private static func little(_ data: Data, _ offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return (0..<4).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
    }
    static func comments(_ data: Data) -> String? {
        guard let vendor = little(data, 0), vendor <= data.count - 8 else { return nil }
        var offset = 4 + vendor
        guard let count = little(data, offset), count <= 65536 else { return nil }
        offset += 4
        var artists: [String] = []
        for _ in 0..<count {
            guard let length = little(data, offset) else { return nil }
            offset += 4
            guard length <= data.count - offset else { return nil }
            if let text = String(data: data.subdata(in: offset..<offset + length), encoding: .utf8),
               let equals = text.firstIndex(of: "="), text[..<equals].uppercased() == "ARTIST",
               let artist = cleaned(String(text[text.index(after: equals)...])) { artists.append(artist) }
            offset += length
        }
        return artists.isEmpty ? nil : artists.joined(separator: " / ")
    }
    private static func flacArtist(_ url: URL) throws -> String? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try file.read(upToCount: 4) == Data("fLaC".utf8) else { return nil }
        var budget = 4 * 1024 * 1024
        for _ in 0..<128 {
            guard let header = try file.read(upToCount: 4), header.count == 4 else { return nil }
            let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
            guard length <= budget else { return nil }
            budget -= length
            if header[0] & 127 == 4 {
                guard let data = try file.read(upToCount: length), data.count == length else { return nil }
                return comments(data)
            }
            try file.seek(toOffset: file.offsetInFile + UInt64(length))
            if header[0] & 128 != 0 { break }
        }
        return nil
    }
    private static func wavArtist(_ url: URL) throws -> String? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let header = try file.read(upToCount: 12), header.count == 12,
              header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("WAVE".utf8) else { return nil }
        for _ in 0..<128 {
            guard let chunk = try file.read(upToCount: 8), chunk.count == 8, let length = little(chunk, 4) else { return nil }
            if chunk.prefix(4) == Data("LIST".utf8), length <= 1024 * 1024,
               let list = try file.read(upToCount: length), list.count == length, list.starts(with: Data("INFO".utf8)) {
                var offset = 4
                while offset + 8 <= list.count {
                    guard let size = little(list, offset + 4), size <= list.count - offset - 8 else { break }
                    if list.subdata(in: offset..<offset + 4) == Data("IART".utf8) {
                        let value = list.subdata(in: offset + 8..<offset + 8 + size)
                        return cleaned(String(data: value, encoding: .utf8) ?? String(data: value, encoding: .isoLatin1))
                    }
                    offset += 8 + size + (size & 1)
                }
                if length & 1 != 0 { try file.seek(toOffset: file.offsetInFile + 1) }
            } else { try file.seek(toOffset: file.offsetInFile + UInt64(length + (length & 1))) }
        }
        return nil
    }
    // Bounded metadata-only Ogg packet parser, also usable for Vorbis comments.
    private static func oggArtist(_ url: URL) throws -> String? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var packet = Data(), budget = 2 * 1024 * 1024
        for _ in 0..<128 {
            guard let header = try file.read(upToCount: 27), header.count == 27,
                  header.prefix(4) == Data("OggS".utf8), header[4] == 0 else { return nil }
            let count = Int(header[26])
            guard let segments = try file.read(upToCount: count), segments.count == count else { return nil }
            for segment in segments {
                let length = Int(segment)
                budget -= length
                guard budget >= 0, let data = try file.read(upToCount: length), data.count == length else { return nil }
                packet.append(data)
                if length < 255 {
                    if packet.starts(with: Data("OpusTags".utf8)) { return comments(Data(packet.dropFirst(8))) }
                    if packet.starts(with: Data([3]) + Data("vorbis".utf8)) { return comments(Data(packet.dropFirst(7))) }
                    packet.removeAll(keepingCapacity: true)
                }
            }
        }
        return nil
    }
}