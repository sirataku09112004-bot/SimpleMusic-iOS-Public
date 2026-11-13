import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import SwiftUI

enum ArtworkMetadata {
    static let limit = 8 * 1024 * 1024
    static func videoID(_ text: String, allowBare: Bool = false) -> String? {
        func valid(_ value: String?) -> String? {
            guard let value, value.count == 11, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
            return value
        }
        if allowBare, let id = valid(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return id }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let url = match.url, ["http","https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host?.lowercased(), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { continue }
            let path = url.path.split(separator: "/").map(String.init)
            if ["youtu.be","www.youtu.be"].contains(host), path.count == 1, let id = valid(path.first) { return id }
            if ["youtube.com","www.youtube.com","m.youtube.com","music.youtube.com","youtube-nocookie.com","www.youtube-nocookie.com"].contains(host) {
                if url.path == "/watch", let id = valid(parts.queryItems?.first(where: { $0.name == "v" })?.value) { return id }
                if path.count == 2, ["shorts","embed","live"].contains(path[0]), let id = valid(path[1]) { return id }
            }
        }
        return nil
    }
    static func comments(_ data: Data) -> [(String,String)] {
        func little(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return (0..<4).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
        }
        guard let vendor = little(0), vendor <= data.count - 8 else { return [] }
        var offset = 4 + vendor
        guard let count = little(offset), count <= 65536 else { return [] }; offset += 4
        var result: [(String,String)] = []
        for _ in 0..<count {
            guard let length = little(offset) else { return [] }; offset += 4
            guard length <= data.count - offset else { return [] }
            if let text = String(data: data.subdata(in: offset..<offset + length), encoding: .utf8), let equal = text.firstIndex(of: "=") {
                result.append((String(text[..<equal]).uppercased(), String(text[text.index(after: equal)...])))
            }
            offset += length
        }
        return result
    }
    static func picture(_ data: Data) -> Data? {
        func big(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            return (0..<4).reduce(0) { ($0 << 8) | Int(data[offset + $1]) }
        }
        guard let mime = big(4), mime <= data.count - 8 else { return nil }
        var offset = 8 + mime
        guard let description = big(offset), description <= data.count - offset - 4 else { return nil }
        offset += 4 + description + 16
        guard let size = big(offset), size > 0, size <= limit, size <= data.count - offset - 4 else { return nil }
        return data.subdata(in: offset + 4..<offset + 4 + size)
    }
    static func container(_ url: URL) throws -> (Data?, [(String,String)]) {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let signature = try handle.read(upToCount: 4)
        if signature == Data("fLaC".utf8) {
            var image: Data?, tags: [(String,String)] = [], budget = limit
            for _ in 0..<128 {
                guard let header = try handle.read(upToCount: 4), header.count == 4 else { break }
                let length = Int(header[1]) << 16 | Int(header[2]) << 8 | Int(header[3])
                guard length <= budget else { break }; budget -= length
                if [4,6].contains(Int(header[0] & 127)), let bytes = try handle.read(upToCount: length), bytes.count == length {
                    if header[0] & 127 == 6, image == nil { image = picture(bytes) }
                    if header[0] & 127 == 4 { tags = comments(bytes) }
                } else { try handle.seek(toOffset: handle.offsetInFile + UInt64(length)) }
                if header[0] & 128 != 0 { break }
            }
            return (image,tags)
        }
        guard signature == Data("OggS".utf8) else { return (nil,[]) }
        try handle.seek(toOffset: 0)
        var packet = Data(), budget = limit, serial: Data?
        for _ in 0..<256 {
            guard let header = try handle.read(upToCount: 27), header.count == 27, header.prefix(4) == Data("OggS".utf8), header[4] == 0 else { break }
            let pageSerial = header.subdata(in: 14..<18)
            if serial == nil { serial = pageSerial }; guard serial == pageSerial else { break }
            let count = Int(header[26])
            guard let segments = try handle.read(upToCount: count), segments.count == count else { break }
            for lengthByte in segments {
                let length = Int(lengthByte); budget -= length
                guard budget >= 0, let bytes = try handle.read(upToCount: length), bytes.count == length else { return (nil,[]) }
                packet.append(bytes)
                if length < 255 {
                    let skip = packet.starts(with: Data("OpusTags".utf8)) ? 8 : (packet.starts(with: Data([3]) + Data("vorbis".utf8)) ? 7 : 0)
                    if skip > 0 {
                        let tags = comments(Data(packet.dropFirst(skip)))
                        let image = tags.lazy.filter { $0.0 == "METADATA_BLOCK_PICTURE" }.compactMap { Data(base64Encoded: $0.1) }.compactMap(picture).first
                        return (image,tags)
                    }
                    packet.removeAll(keepingCapacity: true)
                }
            }
        }
        return (nil,[])
    }
    static func read(_ url: URL) async -> (Data?, String?) {
        let parsed = (try? container(url)) ?? (nil,[])
        var image = parsed.0, tags = parsed.1
        let asset = AVURLAsset(url: url)
        let items = ((try? await asset.load(.metadata)) ?? []) + ((try? await asset.load(.commonMetadata)) ?? [])
        for item in items {
            let key = ((item.key as? String) ?? item.identifier?.rawValue ?? "").uppercased()
            if image == nil, item.commonKey == .commonKeyArtwork, let bytes = try? await item.load(.dataValue), bytes.count <= limit { image = bytes }
            if let value = try? await item.load(.stringValue), value.utf8.count <= limit { tags.append((key,value)) }
        }
        var id: String?
        for (key,value) in tags where ["URL","PURL","SOURCE","COMMENT","DESCRIPTION","YOUTUBE_ID","YOUTUBE_URL","VIDEO_ID"].contains(key)
            || key.contains("COMMENT") || key.contains("URL") || key.hasSuffix("/COMM") || key.hasSuffix("/©CMT") {
            if let found = videoID(value, allowBare: ["YOUTUBE_ID","VIDEO_ID"].contains(key)) { id = found; break }
        }
        return (image,id)
    }
    static func jpeg(_ data: Data) -> Data? {
        guard data.count <= limit, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

struct ArtworkIndex: Codable {
    var songs: [String:String] = [:]
    var videos: [String:String] = [:]
    var attempted: Set<String> = []
}
actor ArtworkStore {
    private let folder: URL
    private let audioDirectory: URL
    private var index: ArtworkIndex?
    private let session: URLSession
    init(directory: URL = LibraryStore.defaultDirectory) {
        audioDirectory = directory
        folder = directory.appendingPathComponent("artwork", isDirectory: true)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 20; config.urlCache = nil
        session = URLSession(configuration: config)
    }
    private func load() throws -> ArtworkIndex {
        if let index { return index }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("index.json")
        let loaded = FileManager.default.fileExists(atPath: url.path) ? try JSONDecoder().decode(ArtworkIndex.self, from: Data(contentsOf: url)) : ArtworkIndex()
        guard loaded.songs.values.allSatisfy(Self.validHash), loaded.videos.values.allSatisfy(Self.validHash) else { throw BackupError.invalid }
        index = loaded; return loaded
    }
    private static func validHash(_ text: String) -> Bool { text.count == 64 && text.allSatisfy { "0123456789abcdef".contains($0) } }
    func url(for hash: String) -> URL? {
        guard let index = try? load(), let image = index.songs[hash] else { return nil }
        let url = folder.appendingPathComponent(image + ".jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func acquire(_ track: Track, retry: Bool, network: Bool) async -> Bool {
        guard var current = try? load() else { return false }
        if url(for: track.sha256) != nil { return true }
        if !retry && current.attempted.contains(track.sha256) { return false }
        let metadata = await ArtworkMetadata.read(track.audioURL(in: audioDirectory))
        var jpeg = metadata.0.flatMap(ArtworkMetadata.jpeg)
        var existing: String?
        if jpeg == nil, let id = metadata.1 {
            if let hash = current.videos[id], FileManager.default.fileExists(atPath: folder.appendingPathComponent(hash + ".jpg").path) { existing = hash }
            else if network && !Task.isCancelled {
                do {
                    // This fixed host is the only network destination. Never follow arbitrary metadata URLs.
                    let endpoint = URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")!
                    let (bytes,response) = try await session.bytes(from: endpoint)
                    if let response = response as? HTTPURLResponse, response.statusCode == 200,
                       response.mimeType?.hasPrefix("image/") == true, response.expectedContentLength <= Int64(ArtworkMetadata.limit) {
                        var data = Data()
                        for try await byte in bytes { if data.count >= ArtworkMetadata.limit || Task.isCancelled { break }; data.append(byte) }
                        if !Task.isCancelled { jpeg = ArtworkMetadata.jpeg(data) }
                    }
                } catch { }
            }
        }
        guard !Task.isCancelled else { return false }
        // Reload after suspension so a concurrent reader cannot replace newer mappings.
        current = (try? load()) ?? current
        do {
            let hash: String?
            if let jpeg {
                let digest = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
                let destination = folder.appendingPathComponent(digest + ".jpg")
                if !FileManager.default.fileExists(atPath: destination.path) { try jpeg.write(to: destination, options: .atomic) }
                hash = digest
            } else { hash = existing }
            current.attempted.insert(track.sha256)
            if let hash { current.songs[track.sha256] = hash; if let id = metadata.1 { current.videos[id] = hash } }
            try JSONEncoder().encode(current).write(to: folder.appendingPathComponent("index.json"), options: .atomic)
            index = current; return hash != nil
        } catch { return false }
    }
}

@MainActor
final class ArtworkModel: ObservableObject {
    @Published private(set) var revisions: [String:Int] = [:]
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    private let store: ArtworkStore
    private let cache = NSCache<NSString,UIImage>()
    private var task: Task<Void,Never>?
    private var waiting: [Track] = []
    init(directory: URL = LibraryStore.defaultDirectory) {
        store = ArtworkStore(directory: directory)
        cache.totalCostLimit = 10 * 1024 * 1024; cache.countLimit = 80
    }
    func image(for track: Track) async -> UIImage? {
        if let image = cache.object(forKey: track.sha256 as NSString) { return image }
        guard let url = await store.url(for: track.sha256) else { return nil }
        let bytes = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
        guard let bytes, let image = UIImage(data: bytes) else { return nil }
        cache.setObject(image, forKey: track.sha256 as NSString, cost: Int(image.size.width * image.size.height * 4)); return image
    }
    func acquire(_ tracks: [Track], retry: Bool = false) {
        guard !busy else {
            waiting.append(contentsOf: tracks.filter { track in !waiting.contains(where: { $0.id == track.id }) })
            return
        }
        busy = true
        task = Task {
            defer {
                busy = false; task = nil
                let next = waiting; waiting = []
                if !next.isEmpty && !Task.isCancelled { acquire(next) }
            }
            var successes = 0, completed = 0
            for track in tracks {
                guard !Task.isCancelled else { break }
                let network = UserDefaults.standard.object(forKey: "artworkFetchEnabled") == nil || UserDefaults.standard.bool(forKey: "artworkFetchEnabled")
                if await store.acquire(track, retry: retry, network: network) {
                    successes += 1; revisions[track.sha256, default: 0] += 1
                }
                completed += 1
                message = "画像確認 \(completed)/\(tracks.count)・取得済み\(successes)曲"
            }
            message += "。取得できない曲は音符のままです。"
        }
    }
    func cancel() { task?.cancel() }
}

struct ArtworkThumbnail: View {
    @ObservedObject var artwork: ArtworkModel
    let track: Track
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "music.note").frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
        }.frame(width: 44, height: 44).clipped().clipShape(RoundedRectangle(cornerRadius: 5))
            .accessibilityHidden(true)
            .task(id: "\(track.sha256)-\(artwork.revisions[track.sha256, default: 0])") { image = await artwork.image(for: track) }
    }
}

