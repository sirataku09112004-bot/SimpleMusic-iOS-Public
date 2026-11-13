import Foundation

enum RepeatMode: String, Codable, CaseIterable, Hashable {
    case off, all, one
    var next: Self { self == .off ? .all : (self == .all ? .one : .off) }
    var label: String { self == .off ? "リピートOFF" : (self == .all ? "全曲リピート" : "1曲リピート") }
}

struct BackupSong: Codable, Equatable, Identifiable {
    var id: String { hash }
    let hash: String
    let title: String
    let artist: String?
    let duration: Double
    let favorite: Bool
    let count: Int
    var listeningSeconds: Double = 0
    var lastPlayed: Date? = nil
}
struct BackupEnvelope: Codable, Equatable {
    let format: String
    let version: Int
    let createdAt: Date
    let songs: [BackupSong]
    let queue: [String]
    let current: String?
    let position: Double
    let sessionCounted: Bool
    var sessionListened: Double = 0
    let repeatMode: RepeatMode
    let shuffle: Bool
    let normalization: Bool
    let librarySort: String
    var statisticsSince: Date? = nil
    var artworkEnabled: Bool = true
    var mixAudioWithOtherApps: Bool? = nil

    func validate() throws {
        let hashes = Set(songs.map(\.hash))
        guard format == "SimpleMusicSettingsBackup", version == 1, songs.count <= 20000,
              hashes.count == songs.count, Set(queue).count == queue.count,
              queue.allSatisfy({ hashes.contains($0) }), current == nil || queue.contains(current!),
              position.isFinite, position >= 0, position <= 1e12,
              sessionListened.isFinite, sessionListened >= 0, sessionListened <= 1e12,
              LibrarySort(rawValue: librarySort) != nil,
              createdAt.timeIntervalSince1970.isFinite,
              songs.allSatisfy({ song in
                  song.hash.count == 64 && song.hash.allSatisfy { "0123456789abcdef".contains($0) }
                  && song.title.utf8.count <= 4096 && (song.artist?.utf8.count ?? 0) <= 16384
                  && song.duration.isFinite && song.duration > 0 && song.duration <= 1e12
                  && song.count >= 0 && song.listeningSeconds.isFinite && song.listeningSeconds >= 0
                  && song.listeningSeconds <= 1e12
                  && (song.lastPlayed?.timeIntervalSince1970.isFinite ?? true)
              }), statisticsSince?.timeIntervalSince1970.isFinite ?? true else { throw BackupError.invalid }
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8 * 1024 * 1024 else { throw BackupError.tooLarge }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        do { let result = try decoder.decode(Self.self, from: data); try result.validate(); return result }
        catch { throw BackupError.invalid }
    }
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let result = try encoder.encode(self)
        guard result.count <= 8 * 1024 * 1024 else { throw BackupError.tooLarge }
        return result
    }
}
enum BackupError: LocalizedError {
    case invalid, tooLarge, unavailable
    var errorDescription: String? {
        switch self {
        case .invalid: return "バックアップの形式・版・内容が不正です。既存データは変更していません。"
        case .tooLarge: return "バックアップJSONは8MBまでです。音声や画像を含むファイルは選ばないでください。"
        case .unavailable: return "設定を安全に保存できません。現在のデータを保護して処理を停止しました。"
        }
    }
}

struct PendingRestore: Codable, Equatable {
    let backup: BackupEnvelope
    var applied: Set<String> = []
    var queueActive = true
    var lastQueue: [UUID] = []
    var lastCurrent: UUID? = nil
    var settingsPending = true
    var remaining: Int { backup.songs.filter { !applied.contains($0.hash) }.count }

    mutating func apply(to state: inout PlaybackState, tracks: [Track], initial: Bool) {
        let byHash = Dictionary(tracks.map { ($0.sha256, $0) }, uniquingKeysWith: { first, _ in first })
        if !initial && (state.queueIDs != lastQueue || state.currentID != lastCurrent) { queueActive = false }
        for song in backup.songs where !applied.contains(song.hash) {
            guard let track = byHash[song.hash] else { continue }
            if song.favorite { state.favorites.insert(track.id) }
            let oldCount = initial ? 0 : (state.playCounts[track.id] ?? 0)
            state.playCounts[track.id] = oldCount > Int.max - song.count ? Int.max : oldCount + song.count
            state.listeningSeconds[track.id] = min(1e12, (initial ? 0 : state.listeningSeconds[track.id] ?? 0) + song.listeningSeconds)
            if let date = song.lastPlayed { state.lastPlayedAt[track.id] = max(date, state.lastPlayedAt[track.id] ?? .distantPast) }
            applied.insert(song.hash)
        }
        if queueActive {
            state.queueIDs = backup.queue.compactMap { byHash[$0]?.id }
            let restored = backup.current.flatMap { byHash[$0] }
            if initial || state.currentID != restored?.id {
                state.currentID = restored?.id
                state.currentPosition = restored.map { min(backup.position, $0.duration) } ?? 0
                state.sessionCounted = backup.sessionCounted && restored != nil
                state.sessionListened = restored == nil ? 0 : backup.sessionListened
            }
            if initial {
                state.repeatMode = backup.repeatMode
                state.shuffleEnabled = backup.shuffle
                state.priorityLoop = backup.shuffle && backup.repeatMode == .all
            }
        }
        state.statisticsSince = state.statisticsSince ?? backup.statisticsSince
        lastQueue = state.queueIDs; lastCurrent = state.currentID
    }
}

enum BackupCodec {
    static func make(tracks: [Track], state: PlaybackState, defaults: UserDefaults = .standard) -> BackupEnvelope {
        var records = Dictionary((state.pendingRestore?.backup.songs ?? []).filter {
            !(state.pendingRestore?.applied.contains($0.hash) ?? true)
        }.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for track in tracks {
            records[track.sha256] = BackupSong(hash: track.sha256, title: track.title, artist: track.artist,
                duration: track.duration, favorite: state.favorites.contains(track.id), count: state.playCounts[track.id] ?? 0,
                listeningSeconds: state.listeningSeconds[track.id] ?? 0, lastPlayed: state.lastPlayedAt[track.id])
        }
        let pending = state.pendingRestore
        let usePendingQueue = pending?.queueActive == true && state.queueIDs == pending?.lastQueue && state.currentID == pending?.lastCurrent
        return BackupEnvelope(format: "SimpleMusicSettingsBackup", version: 1, createdAt: Date(),
            songs: records.values.sorted { $0.hash < $1.hash },
            queue: usePendingQueue ? pending!.backup.queue : state.queueIDs.compactMap { byID[$0]?.sha256 },
            current: usePendingQueue ? pending!.backup.current : state.currentID.flatMap { byID[$0]?.sha256 },
            position: usePendingQueue && state.currentID == nil ? pending!.backup.position : state.currentPosition,
            sessionCounted: usePendingQueue && state.currentID == nil ? pending!.backup.sessionCounted : state.sessionCounted,
            sessionListened: usePendingQueue && state.currentID == nil ? pending!.backup.sessionListened : state.sessionListened,
            repeatMode: state.priorityLoop ? .all : state.repeatMode,
            shuffle: state.priorityLoop || state.shuffleEnabled,
            normalization: defaults.bool(forKey: "normalizationEnabled"),
            librarySort: defaults.string(forKey: "librarySort") ?? LibrarySort.addedOldest.rawValue,
            statisticsSince: state.statisticsSince,
            artworkEnabled: defaults.object(forKey: "artworkFetchEnabled") == nil || defaults.bool(forKey: "artworkFetchEnabled"),
            mixAudioWithOtherApps: defaults.object(forKey: PlaybackRecovery.mixKey) as? Bool ?? true)
    }
    static func restored(_ backup: BackupEnvelope, tracks: [Track]) throws -> PlaybackState {
        try backup.validate()
        var state = PlaybackState(), pending = PendingRestore(backup: backup)
        pending.apply(to: &state, tracks: tracks, initial: true)
        state.pendingRestore = pending
        return state
    }
}

actor BackupReader {
    func read(_ url: URL) throws -> BackupEnvelope {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var data: Data?, readError: Error?, coordination: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordination) { readable in
            do {
                let handle = try FileHandle(forReadingFrom: readable); defer { try? handle.close() }
                data = try handle.read(upToCount: 8 * 1024 * 1024 + 1)
            } catch { readError = error }
        }
        if let coordination { throw coordination }; if let readError { throw readError }
        guard let data else { throw BackupError.invalid }
        return try BackupEnvelope.decode(data)
    }
}
