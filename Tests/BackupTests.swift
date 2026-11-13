import XCTest
@testable import SimpleMusic

final class BackupTests: XCTestCase {
    private func track(_ index: Int, renamed: Bool = false) -> Track {
        Track(id: UUID(), fileName: UUID().uuidString + ".opus", title: renamed ? "別名" : "曲\(index)", duration: 180,
            byteCount: 4000000, importedAt: Date(), sha256: String(format: "%064x", index), artist: "日本語 Artist & ♪")
    }
    func test265SongsRoundTripRelinksRenamedFilesWithoutAudioOrCache() throws {
        let originals = (1...265).map { track($0) }
        var state = PlaybackState()
        state.favorites = [originals[2].id]; state.playCounts[originals[2].id] = 123
        state.listeningSeconds[originals[2].id] = 73; state.lastPlayedAt[originals[2].id] = Date(timeIntervalSince1970: 100)
        state.queueIDs = originals.map(\.id); state.currentID = originals[2].id
        state.currentPosition = 42; state.repeatMode = .one
        let backup = BackupCodec.make(tracks: originals, state: state)
        let bytes = try backup.encoded()
        XCTAssertLessThan(bytes.count, 200000)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("fileName"))
        let renamed = (1...265).map { track($0, renamed: true) }
        let restored = try BackupCodec.restored(BackupEnvelope.decode(bytes), tracks: renamed)
        XCTAssertEqual(restored.queueIDs, renamed.map(\.id))
        XCTAssertEqual(restored.currentID, renamed[2].id)
        XCTAssertEqual(restored.currentPosition, 42)
        XCTAssertTrue(restored.favorites.contains(renamed[2].id))
        XCTAssertEqual(restored.playCounts[renamed[2].id], 123)
        XCTAssertEqual(restored.listeningSeconds[renamed[2].id], 73)
        XCTAssertEqual(restored.repeatMode, .one)
    }
    @MainActor
    func testRestoreBeforeImportSurvivesRestartAndAppliesOnlyOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = track(1), imported = track(1, renamed: true)
        var old = PlaybackState(); old.favorites = [original.id]; old.playCounts[original.id] = 7
        old.queueIDs = [original.id]; old.currentID = original.id; old.currentPosition = 12
        let backup = BackupCodec.make(tracks: [original], state: old)
        let prefs = PlaybackPreferences(directory: root)
        try prefs.replaceState(BackupCodec.restored(backup, tracks: []))
        XCTAssertEqual(prefs.state.pendingRestore?.remaining, 1)
        let reopened = PlaybackPreferences(directory: root)
        XCTAssertTrue(try reopened.applyPendingRestore([imported]))
        XCTAssertEqual(reopened.state.currentID, imported.id)
        XCTAssertEqual(reopened.state.currentPosition, 12)
        XCTAssertEqual(reopened.count(for: imported), 7)
        reopened.toggleFavorite(imported); reopened.recordStart(imported)
        XCTAssertFalse(try reopened.applyPendingRestore([imported]))
        XCTAssertFalse(reopened.isFavorite(imported)); XCTAssertEqual(reopened.count(for: imported), 8)
    }
    func testUserEditedQueueIsNotOverwrittenByLaterImport() throws {
        let a = track(1), b = track(2)
        var state = PlaybackState(); state.queueIDs = [a.id,b.id]; state.currentID = a.id
        let backup = BackupCodec.make(tracks: [a,b], state: state)
        var restored = try BackupCodec.restored(backup, tracks: [a])
        restored.queueIDs = [b.id]; restored.currentID = b.id
        var pending = try XCTUnwrap(restored.pendingRestore)
        pending.apply(to: &restored, tracks: [a,b], initial: false)
        XCTAssertEqual(restored.queueIDs, [b.id]); XCTAssertFalse(pending.queueActive)
    }
    @MainActor
    func testMalformedBackupAndInvalidReplacementPreserveExistingBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let prefs = PlaybackPreferences(directory: root), song = track(1)
        prefs.toggleFavorite(song)
        let file = root.appendingPathComponent("playback.json"), before = try Data(contentsOf: file)
        XCTAssertThrowsError(try BackupEnvelope.decode(Data("{bad}".utf8)))
        XCTAssertThrowsError(try BackupEnvelope.decode(Data(repeating: 0, count: 8 * 1024 * 1024 + 1)))
        var bad = prefs.state; bad.currentPosition = -.infinity
        XCTAssertThrowsError(try prefs.replaceState(bad))
        XCTAssertEqual(try Data(contentsOf: file), before)
    }
    func testPublicAndLegacyPathsRemainDistinctWithoutMigration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "wav"))
        let legacy = try await LibraryStore(directory: root).importFiles([source])
        let old = try XCTUnwrap(legacy.tracks.first)
        let store = LibraryStore(directory: root, publicMusic: true)
        _ = try await store.load()
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.audioURL(in: root).path))
        XCTAssertNil(old.storageLocation)
        var changed = try Data(contentsOf: source); changed[changed.count - 1] ^= 13
        let nextSource = root.appendingPathComponent("new.wav"); try changed.write(to: nextSource)
        let imported = try await store.importFiles([nextSource])
        let fresh = try XCTUnwrap(imported.tracks.last)
        XCTAssertEqual(fresh.storageLocation, .documentsMusic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.audioURL(in: root).path))
        _ = try await store.deleteMany([fresh.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.audioURL(in: root).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.audioURL(in: root).path))
    }
}

