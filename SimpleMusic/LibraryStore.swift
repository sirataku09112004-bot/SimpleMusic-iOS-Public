import Foundation
import AVFoundation
import CryptoKit
import Combine

enum StorageLocation: String, Codable, Sendable { case documentsMusic }

struct Track: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let fileName: String
    let title: String
    let duration: Double
    let byteCount: Int64
    let importedAt: Date
    let sha256: String
    var storageLocation: StorageLocation? = nil
    func audioURL(in directory: URL = LibraryStore.defaultDirectory) -> URL {
        LibraryStore.audioDirectory(in: directory, location: storageLocation).appendingPathComponent(fileName)
    }
    var sourceExtension: String? = nil
    var artist: String? = nil
    var metadataVersion: Int? = nil
    var nativeOpusMode: String? = nil
    var nativeProbeOS: String? = nil
    var nativeProbeDetail: String? = nil
    var audioCodec: String? = nil
    var usesVorbisDecoder: Bool { audioCodec == "vorbis" }
    var artistLabel: String { ArtistMetadata.cleaned(artist) ?? "不明なアーティスト" }
    var usesOpusDecoder: Bool { ["opus", "ogg"].contains(URL(fileURLWithPath: fileName).pathExtension.lowercased()) }
    var formatLabel: String { (sourceExtension ?? URL(fileURLWithPath: fileName).pathExtension).uppercased() }
}

struct ImportReport: Sendable {
    let tracks: [Track]
    let added: Int
    let duplicates: Int
    let failures: [String]
}

struct DeleteReport: Sendable {
    let tracks: [Track]
    let warning: String
}

struct BatchDeleteReport: Sendable {
    let tracks: [Track]
    let deleted: [Track]
    let warning: String
}

struct DeletionIntent: Codable {
    let id: UUID
    let fileName: String
    let trashName: String
    var storageLocation: StorageLocation? = nil
}

enum LibraryError: LocalizedError {
    case unsupported, invalidAudio, invalidIndex, importInProgress, missingFile
    var errorDescription: String? {
        switch self {
        case .missingFile: return "音楽ファイルが見つかりません。Musicフォルダで移動・削除・名前変更した場合は、同じ内容の音楽を再取り込みしてください。お気に入りと回数を保って紐付け直します。"
        case .unsupported: return "対応する拡張子はMP3、M4A、AAC、FLAC、WAV、OPUS、OGG（Opus／Vorbis）です。"
        case .invalidAudio: return "音声を読み取れません。形式、破損、保護されたファイルでないか確認してください。"
        case .invalidIndex: return "保存した曲一覧を読み取れません。データを保護するため取り込みを停止しました。"
        case .importInProgress: return "取り込み中です。完了後にもう一度選択してください。"
        }
    }
}

actor LibraryStore {
    static let defaultDirectory = FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("SimpleMusic", isDirectory: true)
    let directory: URL
    private var tracks: [Track]?
    private var importing = false
    private let publicMusic: Bool

    static func audioDirectory(in directory: URL, location: StorageLocation?) -> URL {
        guard location == .documentsMusic else { return directory }
        let documents = directory == defaultDirectory ? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] : directory.appendingPathComponent("Documents", isDirectory: true)
        return documents.appendingPathComponent("Music", isDirectory: true)
    }
    init(directory: URL = LibraryStore.defaultDirectory, publicMusic: Bool? = nil) {
        self.directory = directory; self.publicMusic = publicMusic ?? (directory == Self.defaultDirectory)
    }

    func load() throws -> [Track] {
        if let tracks { return tracks }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if publicMusic {
            let music = Self.audioDirectory(in: directory, location: .documentsMusic)
            try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: music.deletingLastPathComponent().appendingPathComponent("Backups"), withIntermediateDirectories: true)
        }
        let index = directory.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: index.path) else {
            try recoverBatchDeletion(library: [])
            try recoverDeletion(library: [])
            try recoverReplacement(library: [])
            tracks = []
            return []
        }
        do {
            let loaded = try JSONDecoder().decode([Track].self, from: Data(contentsOf: index))
            guard Set(loaded.map(\.id)).count == loaded.count,
                  loaded.allSatisfy({ !$0.fileName.isEmpty && !$0.fileName.contains("/")
                    && !$0.fileName.contains("\\") && !$0.fileName.hasPrefix(".")
                    && $0.duration.isFinite && $0.duration > 0 }) else {
                throw LibraryError.invalidIndex
            }
            try recoverBatchDeletion(library: loaded)
            try recoverDeletion(library: loaded)
            try recoverReplacement(library: loaded)
            tracks = loaded
            return loaded
        } catch { throw LibraryError.invalidIndex }
    }

    private func recoverReplacement(library: [Track]) throws {
        let journal = directory.appendingPathComponent("replacement.json")
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: journal))
        guard names.count == 2, names.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\\") && !$0.hasPrefix(".") }) else {
            throw LibraryError.invalidIndex
        }
        let referenced = Set(library.map(\.fileName))
        for name in names where !referenced.contains(name) {
            for folder in [directory, Self.audioDirectory(in: directory, location: .documentsMusic)] {
                let url = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
        }
        try FileManager.default.removeItem(at: journal)
    }

    func loadWithMetadata() async throws -> [Track] {
        var library = try load()
        try recoverBatchDeletion(library: library)
        try recoverReplacement(library: library)
        guard !importing else { throw LibraryError.importInProgress }
        importing = true
        defer { importing = false }
        var changed = false
        for i in library.indices where library[i].metadataVersion != 1 {
            library[i].artist = await ArtistMetadata.read(library[i].audioURL(in: directory))
            library[i].metadataVersion = 1
            changed = true
        }
        for i in library.indices where library[i].usesOpusDecoder && library[i].audioCodec == nil {
            library[i].audioCodec = AudioDecoder.isVorbis(library[i].audioURL(in: directory)) ? "vorbis" : "opus"
            changed = true
        }
        if changed {
            try JSONEncoder().encode(library).write(to: directory.appendingPathComponent("library.json"), options: .atomic)
            tracks = library
        }
        return library
    }

    private func recoverDeletion(library: [Track]) throws {
        let journal = directory.appendingPathComponent("deletion.json")
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let intent = try JSONDecoder().decode(DeletionIntent.self, from: Data(contentsOf: journal))
        guard !intent.fileName.isEmpty, !intent.fileName.contains("/"), !intent.fileName.contains("\\"),
              !intent.fileName.hasPrefix("."), intent.trashName == ".deleted-\(intent.id.uuidString)" else {
            throw LibraryError.invalidIndex
        }
        let audioDirectory = Self.audioDirectory(in: directory, location: intent.storageLocation)
        let original = audioDirectory.appendingPathComponent(intent.fileName)
        let trash = Self.audioDirectory(in: directory, location: intent.storageLocation).appendingPathComponent(intent.trashName)
        if let retained = library.first(where: { $0.id == intent.id }) {
            guard retained.fileName == intent.fileName && retained.storageLocation == intent.storageLocation else { throw LibraryError.invalidIndex }
            if FileManager.default.fileExists(atPath: trash.path) {
                guard !FileManager.default.fileExists(atPath: original.path) else { throw LibraryError.invalidIndex }
                try FileManager.default.moveItem(at: trash, to: original)
            }
        } else if FileManager.default.fileExists(atPath: trash.path) {
            try FileManager.default.removeItem(at: trash)
        }
        try FileManager.default.removeItem(at: journal)
    }

    private func recoverBatchDeletion(library: [Track]) throws {
        let journal = directory.appendingPathComponent("batch-deletion.json")
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let intents = try JSONDecoder().decode([DeletionIntent].self, from: Data(contentsOf: journal))
        let byID = Dictionary(uniqueKeysWithValues: library.map { ($0.id, $0) })
        guard Set(intents.map(\.id)).count == intents.count,
              Set(intents.map(\.fileName)).count == intents.count,
              intents.allSatisfy({ !$0.fileName.isEmpty && !$0.fileName.contains("/") && !$0.fileName.contains("\\")
                  && !$0.fileName.hasPrefix(".") && $0.trashName == ".deleted-\($0.id.uuidString)"
                  && (byID[$0.id] == nil || (byID[$0.id]?.fileName == $0.fileName && byID[$0.id]?.storageLocation == $0.storageLocation)) }) else { throw LibraryError.invalidIndex }
        for intent in intents {
            let audioDirectory = Self.audioDirectory(in: directory, location: intent.storageLocation)
        let original = audioDirectory.appendingPathComponent(intent.fileName)
            let trash = Self.audioDirectory(in: directory, location: intent.storageLocation).appendingPathComponent(intent.trashName)
            if byID[intent.id] != nil {
                if FileManager.default.fileExists(atPath: trash.path) {
                    guard !FileManager.default.fileExists(atPath: original.path) else { throw LibraryError.invalidIndex }
                    try FileManager.default.moveItem(at: trash, to: original)
                }
            } else if FileManager.default.fileExists(atPath: trash.path) {
                try FileManager.default.removeItem(at: trash)
            }
        }
        try FileManager.default.removeItem(at: journal)
    }

    func deleteMany(_ ids: Set<UUID>) throws -> BatchDeleteReport {
        guard !importing else { throw LibraryError.importInProgress }
        let library = try load()
        try recoverBatchDeletion(library: library)
        try recoverDeletion(library: library)
        let deleted = library.filter { ids.contains($0.id) }
        guard !deleted.isEmpty else { return BatchDeleteReport(tracks: library, deleted: [], warning: "") }
        let intents = deleted.map { DeletionIntent(id: $0.id, fileName: $0.fileName, trashName: ".deleted-\($0.id.uuidString)", storageLocation: $0.storageLocation) }
        let journal = directory.appendingPathComponent("batch-deletion.json")
        try JSONEncoder().encode(intents).write(to: journal, options: .atomic)
        do {
            for intent in intents {
                let audioDirectory = Self.audioDirectory(in: directory, location: intent.storageLocation)
        let original = audioDirectory.appendingPathComponent(intent.fileName)
                if FileManager.default.fileExists(atPath: original.path) {
                    try FileManager.default.moveItem(at: original, to: audioDirectory.appendingPathComponent(intent.trashName))
                }
            }
            let candidate = library.filter { !ids.contains($0.id) }
            // One atomic index commit makes the batch all-or-nothing before cleanup.
            try JSONEncoder().encode(candidate).write(to: directory.appendingPathComponent("library.json"), options: .atomic)
            tracks = candidate
        } catch {
            try? recoverBatchDeletion(library: library)
            tracks = nil
            throw error
        }
        var warning = ""
        do { try recoverBatchDeletion(library: tracks ?? []) }
        catch { warning = "残った一時ファイルは次回起動時に再処理します。" }
        return BatchDeleteReport(tracks: tracks ?? [], deleted: deleted, warning: warning)
    }

    func delete(_ id: UUID) throws -> DeleteReport {
        guard !importing else { throw LibraryError.importInProgress }
        let library = try load()
        try recoverBatchDeletion(library: library)
        try recoverDeletion(library: library)
        guard let track = library.first(where: { $0.id == id }) else {
            return DeleteReport(tracks: library, warning: "")
        }
        let original = track.audioURL(in: directory)
        let intent = DeletionIntent(id: id, fileName: track.fileName, trashName: ".deleted-\(id.uuidString)", storageLocation: track.storageLocation)
        let trash = Self.audioDirectory(in: directory, location: intent.storageLocation).appendingPathComponent(intent.trashName)
        let journal = directory.appendingPathComponent("deletion.json")
        try JSONEncoder().encode(intent).write(to: journal, options: .atomic)
        var moved = false
        do {
            if FileManager.default.fileExists(atPath: original.path) {
                try FileManager.default.moveItem(at: original, to: trash)
                moved = true
            }
            let candidate = library.filter { $0.id != id }
            try JSONEncoder().encode(candidate).write(to: directory.appendingPathComponent("library.json"), options: .atomic)
            tracks = candidate
        } catch {
            // Keep the journal if restoration fails, so a new load can recover it.
            if moved { try? FileManager.default.moveItem(at: trash, to: original) }
            if !FileManager.default.fileExists(atPath: trash.path) { try? FileManager.default.removeItem(at: journal) }
            tracks = nil
            throw error
        }
        do {
            try recoverDeletion(library: tracks ?? [])
            return DeleteReport(tracks: tracks ?? [], warning: "")
        } catch {
            return DeleteReport(tracks: tracks ?? [], warning: "残った一時ファイルは次回起動時に再処理します。")
        }
    }

    func importFiles(_ urls: [URL]) async throws -> ImportReport {
        guard !importing else { throw LibraryError.importInProgress }
        importing = true
        defer { importing = false }
        var library = try load()
        try recoverBatchDeletion(library: library)
        try recoverReplacement(library: library)
        var added = 0
        var duplicates = 0
        var failures: [String] = []
        for source in urls {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let ext = source.pathExtension.lowercased()
            let importDirectory = Self.audioDirectory(in: directory, location: publicMusic ? .documentsMusic : nil)
            let staging = importDirectory.appendingPathComponent(".import-\(UUID().uuidString).\(ext)")
            var committedFile: URL?
            var replacementNames: [String]?
            do {
                try FileManager.default.createDirectory(at: importDirectory, withIntermediateDirectories: true)
                guard ["mp3", "m4a", "aac", "flac", "wav", "opus", "ogg"].contains(ext) else {
                    throw LibraryError.unsupported
                }
                // Coordinate with Files providers, including iCloud downloads.
                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: source, options: [],
                    error: &coordinationError) { readable in
                    do { try FileManager.default.copyItem(at: readable, to: staging) }
                    catch { copyError = error }
                }
                if let coordinationError { throw coordinationError }
                if let copyError { throw copyError }
                let digest = try Self.hash(staging)
                let existing = library.firstIndex(where: { $0.sha256 == digest })
                let replaceLegacy = existing.map { (ext == "opus" || ext == "ogg") && !library[$0].usesOpusDecoder } ?? false
                let repairMissing = existing.map { !FileManager.default.fileExists(atPath: library[$0].audioURL(in: directory).path) } ?? false
                if existing != nil && !replaceLegacy && !repairMissing {
                    duplicates += 1
                    try? FileManager.default.removeItem(at: staging)
                    continue
                }
                let preciseDuration: Double
                var nativeProbe: NativeOpusProbe?
                let vorbis = (ext == "ogg" || ext == "opus") && AudioDecoder.isVorbis(staging)
                if vorbis {
                    let decoder = try VorbisDecoder(staging)
                    var samples = [Float](repeating: 0, count: 12000 * decoder.channels)
                    guard try samples.withUnsafeMutableBufferPointer({ try decoder.read(into: $0.baseAddress!, capacity: $0.count) }) > 0 else { throw LibraryError.invalidAudio }
                    try decoder.seek(frame: max(0, decoder.frames - 12000))
                    guard try samples.withUnsafeMutableBufferPointer({ try decoder.read(into: $0.baseAddress!, capacity: $0.count) }) > 0 else { throw LibraryError.invalidAudio }
                    preciseDuration = decoder.duration
                } else if ext == "opus" || ext == "ogg" {
                    let probe = await NativeOpusProbe.inspect(staging)
                    nativeProbe = probe
                    if probe.mode != "decoder", let seconds = probe.duration {
                        preciseDuration = seconds
                    } else {
                        let decoder = try OpusDecoder(staging)
                        try decoder.validateEdges()
                        preciseDuration = decoder.duration
                    }
                } else {
                    do { _ = try AVAudioPlayer(contentsOf: staging) }
                    catch { throw LibraryError.invalidAudio }
                    let asset = AVURLAsset(url: staging, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                    preciseDuration = try await asset.load(.duration).seconds
                }
                guard preciseDuration.isFinite, preciseDuration > 0 else { throw LibraryError.invalidAudio }
                let artist = await ArtistMetadata.read(staging)
                let size = (try FileManager.default.attributesOfItem(atPath: staging.path)[.size]
                    as? NSNumber)?.int64Value ?? 0
                let oldTrack = (replaceLegacy || repairMissing) ? existing.map { library[$0] } : nil
                let id = oldTrack?.id ?? UUID()
                let fileName = "\(id.uuidString).\(ext)"
                let destination = importDirectory.appendingPathComponent(fileName)
                if let oldTrack {
                    replacementNames = [oldTrack.fileName, fileName]
                    try JSONEncoder().encode(replacementNames!).write(to: directory.appendingPathComponent("replacement.json"), options: .atomic)
                }
                try FileManager.default.moveItem(at: staging, to: destination)
                committedFile = destination
                let track = Track(id: id, fileName: fileName,
                    title: source.deletingPathExtension().lastPathComponent,
                    duration: preciseDuration, byteCount: size, importedAt: oldTrack?.importedAt ?? Date(), sha256: digest,
                    storageLocation: publicMusic ? .documentsMusic : nil, sourceExtension: ext, artist: artist, metadataVersion: 1,
                    nativeOpusMode: nativeProbe?.mode, nativeProbeOS: nativeProbe == nil ? nil : NativeOpusProbe.os,
                    nativeProbeDetail: nativeProbe?.detail, audioCodec: vorbis ? "vorbis" : ((ext == "opus" || ext == "ogg") ? "opus" : nil))
                var candidate = library
                if (replaceLegacy || repairMissing), let existing { candidate[existing] = track } else { candidate.append(track) }
                let data = try JSONEncoder().encode(candidate)
                try data.write(to: directory.appendingPathComponent("library.json"), options: .atomic)
                library = candidate
                tracks = library
                committedFile = nil
                try? FileManager.default.removeItem(at: staging)
                if replacementNames != nil { try? recoverReplacement(library: library) }
                added += 1
            } catch {
                // Roll back only the current import; existing music and source files stay intact.
                try? FileManager.default.removeItem(at: staging)
                if let committedFile { try? FileManager.default.removeItem(at: committedFile) }
                if replacementNames != nil { try? recoverReplacement(library: library) }
                failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return ImportReport(tracks: library, added: added, duplicates: duplicates, failures: failures)
    }

    private static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var digest = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var busy = false
    @Published private(set) var ready = false
    @Published var message = ""
    @Published var failures: [String] = []
    private let storage = LibraryStore()

    func load() async {
        guard !ready, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            tracks = try await storage.loadWithMetadata()
            ready = true
        } catch { message = error.localizedDescription }
    }

    func importFiles(_ urls: [URL]) async {
        guard ready, !busy else { return }
        busy = true
        message = "\(urls.count)個のファイルを取り込んでいます…"
        failures = []
        defer { busy = false }
        do {
            let report = try await storage.importFiles(urls)
            tracks = report.tracks
            failures = report.failures
            message = "\(report.added)曲追加・重複\(report.duplicates)曲・失敗\(report.failures.count)個"
        } catch { message = error.localizedDescription }
    }

    func url(for track: Track) -> URL {
        track.audioURL()
    }

    func delete(_ track: Track) async -> Bool {
        guard ready, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            let report = try await storage.delete(track.id)
            tracks = report.tracks
            message = "\(track.title)を削除しました。\(report.warning)"
            return true
        } catch {
            message = "削除できません: \(error.localizedDescription)"
            return false
        }
    }

    func deleteMany(_ ids: Set<UUID>, player: MusicPlayer) async -> Set<UUID> {
        guard ready, !busy, !ids.isEmpty else { return [] }
        busy = true
        player.beginLibraryDeletion(ids)
        defer { busy = false; player.endLibraryDeletion() }
        do {
            let report = try await storage.deleteMany(ids)
            player.forgetMany(report.deleted)
            tracks = report.tracks
            message = "\(report.deleted.count)曲を削除しました。\(report.warning)"
            return Set(report.deleted.map(\.id))
        } catch {
            message = "まとめて削除できません: \(error.localizedDescription)"
            return []
        }
    }
}

