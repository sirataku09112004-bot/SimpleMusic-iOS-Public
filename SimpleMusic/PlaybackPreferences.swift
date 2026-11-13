import Foundation
import Combine

struct PlaybackState: Codable, Equatable {
    var favorites: Set<UUID> = []
    var playCounts: [UUID: Int] = [:]
    var queueIDs: [UUID] = []
    var currentID: UUID?
    var priorityLoop = false
    var currentPosition: Double = 0
    var sessionCounted = false
    var sessionListened: Double = 0
    var listeningSeconds: [UUID: Double] = [:]
    var lastPlayedAt: [UUID: Date] = [:]
    var statisticsSince: Date? = nil
    var repeatMode: RepeatMode = .off
    var shuffleEnabled = false
    var pendingRestore: PendingRestore? = nil

    init() {}
    private enum CodingKeys: String, CodingKey {
        case favorites, playCounts, queueIDs, currentID, priorityLoop, currentPosition, sessionCounted
        case sessionListened, listeningSeconds, lastPlayedAt, statisticsSince, repeatMode, shuffleEnabled, pendingRestore
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        favorites = try values.decode(Set<UUID>.self, forKey: .favorites)
        playCounts = try values.decode([UUID: Int].self, forKey: .playCounts)
        queueIDs = try values.decode([UUID].self, forKey: .queueIDs)
        currentID = try values.decodeIfPresent(UUID.self, forKey: .currentID)
        priorityLoop = try values.decodeIfPresent(Bool.self, forKey: .priorityLoop) ?? false
        currentPosition = try values.decodeIfPresent(Double.self, forKey: .currentPosition) ?? 0
        sessionCounted = try values.decodeIfPresent(Bool.self, forKey: .sessionCounted) ?? false
        sessionListened = try values.decodeIfPresent(Double.self, forKey: .sessionListened) ?? 0
        listeningSeconds = try values.decodeIfPresent([UUID: Double].self, forKey: .listeningSeconds) ?? [:]
        lastPlayedAt = try values.decodeIfPresent([UUID: Date].self, forKey: .lastPlayedAt) ?? [:]
        statisticsSince = try values.decodeIfPresent(Date.self, forKey: .statisticsSince)
        repeatMode = try values.decodeIfPresent(RepeatMode.self, forKey: .repeatMode) ?? (priorityLoop ? .all : .off)
        shuffleEnabled = try values.decodeIfPresent(Bool.self, forKey: .shuffleEnabled) ?? priorityLoop
        pendingRestore = try values.decodeIfPresent(PendingRestore.self, forKey: .pendingRestore)
    }

    func validate() throws {
        guard currentPosition.isFinite, currentPosition >= 0, sessionListened.isFinite, sessionListened >= 0,
              playCounts.values.allSatisfy({ $0 >= 0 }),
              listeningSeconds.values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1e12 }),
              lastPlayedAt.values.allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              statisticsSince?.timeIntervalSince1970.isFinite ?? true,
              Set(queueIDs).count == queueIDs.count, currentID == nil || queueIDs.contains(currentID!) else { throw BackupError.invalid }
        if let pendingRestore {
            try pendingRestore.backup.validate()
            guard pendingRestore.applied.isSubset(of: Set(pendingRestore.backup.songs.map(\.hash))),
                  Set(pendingRestore.lastQueue).count == pendingRestore.lastQueue.count else { throw BackupError.invalid }
        }
    }
}

@MainActor
final class PlaybackPreferences: ObservableObject {
    @Published private(set) var state = PlaybackState()
    @Published private(set) var ready = false
    @Published private(set) var errorMessage = ""
    private let file: URL

    init(directory: URL = LibraryStore.defaultDirectory) {
        file = directory.appendingPathComponent("playback.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                let loaded = try JSONDecoder().decode(PlaybackState.self, from: Data(contentsOf: file))
                try loaded.validate()
                guard loaded.currentPosition.isFinite, loaded.currentPosition >= 0,
                      loaded.playCounts.values.allSatisfy({ $0 >= 0 }),
                      Set(loaded.queueIDs).count == loaded.queueIDs.count,
                      loaded.currentID == nil || loaded.queueIDs.contains(loaded.currentID!) else {
                    throw LibraryError.invalidIndex
                }
                state = loaded
            }
            ready = true
        } catch {
            errorMessage = "お気に入り・再生履歴を読み取れません。保存データを保護しています。"
        }
    }

    func isFavorite(_ track: Track) -> Bool { state.favorites.contains(track.id) }
    func count(for track: Track) -> Int { state.playCounts[track.id] ?? 0 }

    func toggleFavorite(_ track: Track) {
        mutate { candidate in
            if candidate.favorites.contains(track.id) { candidate.favorites.remove(track.id) }
            else { candidate.favorites.insert(track.id) }
        }
    }

    func recordStart(_ track: Track) {
        mutate { candidate in
            let old = candidate.playCounts[track.id] ?? 0
            candidate.playCounts[track.id] = old < Int.max ? old + 1 : Int.max
        }
    }

    func forget(_ track: Track) {
        mutate { candidate in
            candidate.favorites.remove(track.id)
            candidate.playCounts.removeValue(forKey: track.id)
            candidate.listeningSeconds.removeValue(forKey: track.id); candidate.lastPlayedAt.removeValue(forKey: track.id)
            candidate.queueIDs.removeAll { $0 == track.id }
            if candidate.currentID == track.id { candidate.currentID = nil; candidate.currentPosition = 0; candidate.sessionCounted = false; candidate.sessionListened = 0 }
            if candidate.queueIDs.isEmpty { candidate.priorityLoop = false }
        }
    }

    func saveQueue(_ tracks: [Track], current: Track?, priorityLoop: Bool = false,
                   repeatMode: RepeatMode? = nil, shuffle: Bool? = nil) {
        mutate { candidate in
            if candidate.currentID != current?.id {
                candidate.currentPosition = 0
                candidate.sessionCounted = false
                candidate.sessionListened = 0
            }
            candidate.queueIDs = tracks.map(\.id)
            candidate.currentID = current?.id
            candidate.priorityLoop = priorityLoop
            candidate.repeatMode = repeatMode ?? (priorityLoop ? .all : .off)
            candidate.shuffleEnabled = shuffle ?? priorityLoop
        }
    }

    func forgetMany(_ tracks: [Track]) {
        let ids = Set(tracks.map(\.id))
        mutate { candidate in
            candidate.favorites.subtract(ids)
            for id in ids { candidate.playCounts.removeValue(forKey: id); candidate.listeningSeconds.removeValue(forKey: id); candidate.lastPlayedAt.removeValue(forKey: id) }
            candidate.queueIDs.removeAll { ids.contains($0) }
            if let current = candidate.currentID, ids.contains(current) {
                candidate.currentID = nil; candidate.currentPosition = 0; candidate.sessionCounted = false
            }
            if candidate.queueIDs.isEmpty { candidate.priorityLoop = false }
        }
    }

    func reconcileLibrary(_ tracks: [Track]) {
        let ids = Set(tracks.map(\.id))
        mutate { candidate in
            candidate.favorites.formIntersection(ids)
            candidate.playCounts = candidate.playCounts.filter { ids.contains($0.key) }
            candidate.listeningSeconds = candidate.listeningSeconds.filter { ids.contains($0.key) }
            candidate.lastPlayedAt = candidate.lastPlayedAt.filter { ids.contains($0.key) }
            candidate.queueIDs.removeAll { !ids.contains($0) }
            if let current = candidate.currentID, !ids.contains(current) {
                candidate.currentID = nil; candidate.currentPosition = 0; candidate.sessionCounted = false
            }
            if candidate.queueIDs.isEmpty { candidate.priorityLoop = false }
        }
    }

    func saveProgress(for track: Track, seconds: Double, counted: Bool, listened: Double? = nil,
                      additional: Double = 0, lastPlayed: Date? = nil, incrementCount: Bool = false) {
        guard state.currentID == track.id, seconds.isFinite else { return }
        mutate { candidate in
            candidate.currentPosition = min(max(0, seconds), track.duration)
            candidate.sessionCounted = counted
            if let listened { candidate.sessionListened = listened }
            candidate.listeningSeconds[track.id] = min(1e12, (candidate.listeningSeconds[track.id] ?? 0) + max(0, additional))
            if let lastPlayed { candidate.lastPlayedAt[track.id] = lastPlayed }
            if incrementCount {
                let old = candidate.playCounts[track.id] ?? 0
                candidate.playCounts[track.id] = old < Int.max ? old + 1 : Int.max
            }
            if candidate.statisticsSince == nil { candidate.statisticsSince = Date() }
        }
    }

    private func mutate(_ change: (inout PlaybackState) -> Void) {
        guard ready else { return }
        var candidate = state
        change(&candidate)
        guard candidate != state else { return }
        do {
            let data = try JSONEncoder().encode(candidate)
            try data.write(to: file, options: .atomic)
            state = candidate
            errorMessage = ""
        } catch {
            errorMessage = "お気に入り・再生履歴を保存できません: \(error.localizedDescription)"
        }
    }

    func replaceState(_ candidate: PlaybackState) throws {
        guard ready else { throw BackupError.unavailable }
        try candidate.validate()
        try JSONEncoder().encode(candidate).write(to: file, options: .atomic)
        state = candidate; errorMessage = ""
    }
    @discardableResult
    func applyPendingRestore(_ tracks: [Track]) throws -> Bool {
        guard var pending = state.pendingRestore else { return false }
        var candidate = state
        pending.apply(to: &candidate, tracks: tracks, initial: false)
        candidate.pendingRestore = pending
        guard candidate != state else { return false }
        try replaceState(candidate)
        return true
    }
    func applyRestoredSettings(normalization: NormalizationModel, defaults: UserDefaults = .standard) throws {
        guard var pending = state.pendingRestore, pending.settingsPending else { return }
        normalization.setEnabled(pending.backup.normalization)
        defaults.set(pending.backup.librarySort, forKey: "librarySort")
        defaults.set(pending.backup.artworkEnabled, forKey: "artworkFetchEnabled")
        if let mix = pending.backup.mixAudioWithOtherApps { defaults.set(mix, forKey: PlaybackRecovery.mixKey) }
        pending.settingsPending = false
        var candidate = state; candidate.pendingRestore = pending
        try replaceState(candidate)
    }
}

enum WeightedShuffle {
    static func cycle(_ tracks: [Track], counts: [UUID: Int], avoiding previousID: UUID?) -> [Track] {
        let eligible = tracks.filter { $0.id != previousID }
        guard let first = order(eligible.isEmpty ? tracks : eligible, counts: counts).first else { return [] }
        return [first] + order(tracks.filter { $0.id != first.id }, counts: counts)
    }
    // Exponential race: each remaining track is selected with weight 1 / (count + 1).
    // A permutation contains each ID once, rather than repeatedly sampling a track.
    static func order(_ tracks: [Track], counts: [UUID: Int],
                      random: () -> Double = { Double.random(in: 0..<1) }) -> [Track] {
        var seen = Set<UUID>()
        return tracks.enumerated().compactMap { index, track -> (Int, Double, Track)? in
            guard seen.insert(track.id).inserted else { return nil }
            let value = random()
            let unit = value.isFinite ? min(max(value, Double.leastNonzeroMagnitude), 1) : 0.5
            let score = -log(unit) * (Double(max(0, counts[track.id] ?? 0)) + 1)
            return (index, score, track)
        }.sorted { a, b in a.1 == b.1 ? a.0 < b.0 : a.1 < b.1 }.map { $0.2 }
    }
}
