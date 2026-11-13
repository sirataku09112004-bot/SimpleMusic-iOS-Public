import XCTest
import AVFoundation
@testable import SimpleMusic

final class BatchDeletionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func originals() throws -> [URL] {
        try ["wav", "flac", "opus"].map { try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: $0)) }
    }
    func testSelectedAndAllDeletionLeaveOriginalFilesAndUnselectedTrack() async throws {
        let sources = try originals(), bytes = try originals().map { try Data(contentsOf: $0) }
        let store = LibraryStore(directory: root), report = try await store.importFiles(sources)
        let deleted = try await store.deleteMany([report.tracks[0].id, report.tracks[2].id, UUID()])
        XCTAssertEqual(deleted.tracks, [report.tracks[1]])
        XCTAssertEqual(Set(deleted.deleted.map(\.id)), [report.tracks[0].id, report.tracks[2].id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(report.tracks[1].fileName).path))
        for track in deleted.deleted { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(track.fileName).path)) }
        let all = try await store.deleteMany(Set(deleted.tracks.map(\.id)))
        XCTAssertTrue(all.tracks.isEmpty)
        let loaded = try await LibraryStore(directory: root).load()
        XCTAssertTrue(loaded.isEmpty)
        XCTAssertEqual(try sources.map { try Data(contentsOf: $0) }, bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("batch-deletion.json").path))
    }
    func testInterruptedBatchBeforeAndAfterCommitRestoresOrCleansOnlySelectedAudio() async throws {
        let report = try await LibraryStore(directory: root).importFiles(originals())
        let chosen = Array(report.tracks.prefix(2))
        let intents = chosen.map { DeletionIntent(id: $0.id, fileName: $0.fileName, trashName: ".deleted-\($0.id.uuidString)") }
        let journal = root.appendingPathComponent("batch-deletion.json")
        try JSONEncoder().encode(intents).write(to: journal)
        try FileManager.default.moveItem(at: root.appendingPathComponent(intents[0].fileName), to: root.appendingPathComponent(intents[0].trashName))
        let before = try await LibraryStore(directory: root).load()
        XCTAssertEqual(before, report.tracks)
        for track in chosen { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(track.fileName).path)) }
        try JSONEncoder().encode(intents).write(to: journal)
        for intent in intents { try FileManager.default.moveItem(at: root.appendingPathComponent(intent.fileName), to: root.appendingPathComponent(intent.trashName)) }
        let retained = Array(report.tracks.suffix(1))
        try JSONEncoder().encode(retained).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        let after = try await LibraryStore(directory: root).load()
        XCTAssertEqual(after, retained)
        for intent in intents { XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(intent.trashName).path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(retained[0].fileName).path))
    }
    func testIndexCommitFailureRollsBackAllMovedAudio() async throws {
        let store = LibraryStore(directory: root), report = try await store.importFiles(originals())
        let index = root.appendingPathComponent("library.json"), originalIndex = try Data(contentsOf: root.appendingPathComponent("library.json"))
        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        do { _ = try await store.deleteMany(Set(report.tracks.map(\.id))); XCTFail("Index write must fail") } catch {}
        for track in report.tracks { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(track.fileName).path)) }
        try FileManager.default.removeItem(at: index)
        try originalIndex.write(to: index)
        let restored = try await LibraryStore(directory: root).load()
        XCTAssertEqual(restored, report.tracks)
    }
    @MainActor
    func testPlaybackAndPreferencesCleanInBatchAndDeferNextUntilDeletionEnds() async throws {
        let report = try await LibraryStore(directory: root).importFiles(originals())
        let first = report.tracks[0], second = report.tracks[1], removed = report.tracks[2]
        let prefs = PlaybackPreferences(directory: root)
        prefs.toggleFavorite(second); prefs.toggleFavorite(removed); prefs.recordStart(removed)
        let suite = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let normalization = NormalizationModel(directory: root, defaults: defaults)
        let player = MusicPlayer(preferences: prefs, normalization: normalization)
        defer { player.stop() }
        player.play(first, in: report.tracks, directory: root)
        player.beginLibraryDeletion([removed.id])
        XCTAssertTrue(player.isPlaying)
        XCTAssertFalse(player.canNext)
        for _ in 0..<50 {
            if !player.isPlaying { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.current?.id, first.id)
        player.forgetMany([removed]); player.endLibraryDeletion()
        XCTAssertEqual(player.current?.id, second.id)
        XCTAssertTrue(player.isPlaying, player.errorMessage)
        XCTAssertTrue(prefs.isFavorite(second)); XCTAssertFalse(prefs.isFavorite(removed))
        XCTAssertEqual(prefs.count(for: removed), 0)
        player.beginLibraryDeletion([second.id])
        let original = root.appendingPathComponent(second.fileName), staged = root.appendingPathComponent("staged.flac")
        try FileManager.default.moveItem(at: original, to: staged)
        normalization.setEnabled(true)
        player.updateNormalization() // A late analysis result must not reopen a staged/deleted file.
        XCTAssertTrue(normalization.enabled)
        player.forgetMany([second]); player.endLibraryDeletion()
        try FileManager.default.moveItem(at: staged, to: original)
        XCTAssertNil(player.current); XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.queue.map(\.id), [first.id])
        let restored = PlaybackPreferences(directory: root)
        XCTAssertNil(restored.state.currentID); XCTAssertEqual(restored.state.currentPosition, 0)
        XCTAssertFalse(restored.isFavorite(second))
        prefs.toggleFavorite(removed); prefs.recordStart(removed)
        prefs.reconcileLibrary([first])
        XCTAssertFalse(prefs.isFavorite(removed)); XCTAssertEqual(prefs.count(for: removed), 0)
    }
}
