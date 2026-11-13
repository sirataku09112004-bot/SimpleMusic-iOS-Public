import XCTest
@testable import SimpleMusic

final class PlaybackTests: XCTestCase {
    @MainActor
    func testOldStateMigrationAndRepeatRestoration() throws {
        let selected = track("A")
        var old = PlaybackState()
        old.favorites = [selected.id]
        old.playCounts = [selected.id: 7]
        old.queueIDs = [selected.id]
        old.currentID = selected.id
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "priorityLoop")
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent("playback.json"))
        let migrated = PlaybackPreferences(directory: root)
        XCTAssertTrue(migrated.ready)
        XCTAssertFalse(migrated.state.priorityLoop)
        XCTAssertEqual(migrated.count(for: selected), 7)
        XCTAssertTrue(migrated.isFavorite(selected))
        migrated.saveQueue([selected], current: selected, priorityLoop: true)
        let reopened = PlaybackPreferences(directory: root)
        let player = MusicPlayer(preferences: reopened)
        player.restoreQueue(from: [selected])
        XCTAssertTrue(player.priorityLoop)
        XCTAssertFalse(player.isPlaying)
    }

    @MainActor
    func testPriorityLoopAdvancesAtBoundaryAndCanBeDisabled() async throws {
        let directory = root.appendingPathComponent("library")
        let report = try await LibraryStore(directory: directory).importFiles(fixtures(["wav", "flac"]))
        let preferences = PlaybackPreferences(directory: directory)
        let player = MusicPlayer(preferences: preferences)
        defer { player.stop() }
        let last = try XCTUnwrap(report.tracks.last)
        player.play(last, in: report.tracks, directory: directory)
        player.setPriorityLoop(true)
        XCTAssertTrue(player.canNext)
        player.seek(to: last.duration - 0.2)
        for _ in 0..<50 {
            if player.current != last { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(player.current, report.tracks.first)
        XCTAssertTrue(player.isPlaying)
        XCTAssertTrue(player.priorityLoop)
        XCTAssertEqual(Set(player.queue.map(\.id)), Set(report.tracks.map(\.id)))
        XCTAssertEqual(preferences.count(for: report.tracks[0]), 0)
        player.setPriorityLoop(false)
        let final = try XCTUnwrap(player.queue.last)
        player.playFromQueue(final)
        player.seek(to: final.duration - 0.2)
        for _ in 0..<50 {
            if !player.isPlaying { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.canNext)
    }

    @MainActor
    func testSingleTrackLoopAndClearingCancelsRepeat() async throws {
        let directory = root.appendingPathComponent("library")
        let report = try await LibraryStore(directory: directory).importFiles(fixtures(["wav"]))
        let selected = try XCTUnwrap(report.tracks.first)
        let preferences = PlaybackPreferences(directory: directory)
        let player = MusicPlayer(preferences: preferences)
        defer { player.stop() }
        player.play(selected, in: report.tracks, directory: directory)
        player.setPriorityLoop(true)
        player.seek(to: selected.duration - 0.2)
        for _ in 0..<50 {
            if preferences.count(for: selected) == 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(preferences.count(for: selected), 2)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.queue, [selected])
        player.clearUpcoming()
        XCTAssertFalse(player.priorityLoop)
        XCTAssertFalse(player.canNext)
    }
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func track(_ title: String) -> Track {
        Track(id: UUID(), fileName: "missing.wav", title: title, duration: 2,
            byteCount: 0, importedAt: Date(), sha256: title)
    }
    private func fixtures(_ extensions: [String]) throws -> [URL] {
        try extensions.map { try XCTUnwrap(Bundle(for: PlaybackTests.self).url(forResource: "fixture", withExtension: $0)) }
    }

    @MainActor
    func testFavoritesCountsAndQueueSurviveReopen() throws {
        let preferences = PlaybackPreferences(directory: root)
        let a = track("A"), b = track("B")
        XCTAssertTrue(preferences.ready)
        preferences.toggleFavorite(a)
        preferences.recordStart(b)
        preferences.saveQueue([a, b], current: b)
        let reopened = PlaybackPreferences(directory: root)
        XCTAssertEqual(reopened.state, preferences.state)
        XCTAssertTrue(reopened.isFavorite(a))
        XCTAssertEqual(reopened.count(for: b), 1)
        reopened.toggleFavorite(a)
        XCTAssertFalse(PlaybackPreferences(directory: root).isFavorite(a))
    }

    @MainActor
    func testCorruptPreferencesAreNotOverwritten() throws {
        let file = root.appendingPathComponent("playback.json")
        let damaged = Data("damaged state".utf8)
        try damaged.write(to: file)
        let preferences = PlaybackPreferences(directory: root)
        XCTAssertFalse(preferences.ready)
        XCTAssertFalse(preferences.errorMessage.isEmpty)
        preferences.toggleFavorite(track("A"))
        preferences.recordStart(track("B"))
        preferences.saveQueue([], current: nil)
        XCTAssertEqual(try Data(contentsOf: file), damaged)
    }

    func testWeightedShuffleIsUniqueAndFavorsLowCounts() {
        let rare = track("rare"), frequent = track("frequent")
        var seed: UInt64 = 42
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / 9007199254740992
        }
        var rareFirst = 0
        for _ in 0..<10_000 {
            let order = WeightedShuffle.order([rare, frequent, rare], counts: [frequent.id: 99], random: random)
            XCTAssertEqual(Set(order.map(\.id)), Set([rare.id, frequent.id]))
            XCTAssertEqual(order.count, 2)
            if order.first == rare { rareFirst += 1 }
        }
        XCTAssertGreaterThan(rareFirst, 9700)
        XCTAssertLessThan(rareFirst, 9990)
        XCTAssertEqual(WeightedShuffle.order([], counts: [:]), [])
        XCTAssertEqual(WeightedShuffle.order([rare], counts: [rare.id: Int.max], random: { 0 }), [rare])
        for _ in 0..<100 {
            let cycle = WeightedShuffle.cycle([rare, frequent], counts: [frequent.id: 99], avoiding: rare.id)
            XCTAssertEqual(cycle, [frequent, rare])
        }
    }

    @MainActor
    func testCountsExcludePauseResumeSeekAndFailedStarts() async throws {
        let directory = root.appendingPathComponent("library")
        let report = try await LibraryStore(directory: directory).importFiles(fixtures(["wav"]))
        let selected = try XCTUnwrap(report.tracks.first)
        let preferences = PlaybackPreferences(directory: directory)
        let player = MusicPlayer(preferences: preferences)
        defer { player.stop() }
        player.play(selected, in: report.tracks, directory: directory)
        XCTAssertEqual(preferences.count(for: selected), 0)
        player.pause(); player.seek(to: 0.5); player.toggle()
        XCTAssertEqual(preferences.count(for: selected), 0)
        player.stop(); player.toggle()
        XCTAssertEqual(preferences.count(for: selected), 0)
        player.play(selected, in: report.tracks, directory: directory)
        XCTAssertEqual(preferences.count(for: selected), 0)
        let missing = track("missing")
        player.play(missing, in: [missing], directory: directory)
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.errorMessage.isEmpty)
        XCTAssertEqual(preferences.count(for: missing), 0)
        XCTAssertEqual(PlaybackPreferences(directory: directory).count(for: selected), 0)
    }

    @MainActor
    func testQueueEditsKeepCurrentAudioAndRestorePausedSelection() async throws {
        let directory = root.appendingPathComponent("library")
        let report = try await LibraryStore(directory: directory).importFiles(fixtures(["wav", "flac", "mp3"]))
        let tracks = report.tracks
        XCTAssertEqual(tracks.count, 3)
        let preferences = PlaybackPreferences(directory: directory)
        let player = MusicPlayer(preferences: preferences)
        defer { player.stop() }
        player.play(tracks[1], in: tracks, directory: directory)
        player.enqueue(tracks[0], next: true)
        XCTAssertEqual(player.queue, [tracks[1], tracks[0], tracks[2]])
        player.moveQueue(from: IndexSet(integer: 2), to: 1)
        XCTAssertEqual(player.queue, [tracks[1], tracks[2], tracks[0]])
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(preferences.count(for: tracks[1]), 0)
        player.removeQueue(at: IndexSet(integer: 0))
        XCTAssertEqual(player.queue.count, 3, "Current track is protected")
        player.removeQueue(at: IndexSet(integer: 2))
        XCTAssertEqual(player.queue, [tracks[1], tracks[2]])
        let restored = MusicPlayer(preferences: PlaybackPreferences(directory: directory))
        restored.restoreQueue(from: tracks)
        XCTAssertEqual(restored.queue, player.queue)
        XCTAssertEqual(restored.current, tracks[1])
        XCTAssertFalse(restored.isPlaying)
        XCTAssertEqual(restored.position, 0)
        player.shuffleUpcoming()
        XCTAssertEqual(player.queue.first, tracks[1])
        player.clearUpcoming()
        XCTAssertEqual(player.queue, [tracks[1]])
        XCTAssertFalse(player.canNext)
    }
}
