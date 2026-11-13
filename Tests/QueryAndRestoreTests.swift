import XCTest
@testable import SimpleMusic

final class QueryAndRestoreTests: XCTestCase {
    private func track(_ title: String, artist: String? = nil, date: Double = 0) -> Track {
        Track(id: UUID(), fileName: UUID().uuidString + ".wav", title: title, duration: 30,
              byteCount: 1, importedAt: Date(timeIntervalSince1970: date), sha256: title, artist: artist)
    }
    func testSearchUnicodeMultipleWordsAndFavoriteIntersection() {
        let a = track("夜に駆ける", artist: "YOASOBI")
        let b = track("Ｃａｆé Song", artist: "Artist")
        let tracks = [a,b]
        XCTAssertEqual(LibraryQuery.apply(tracks, search: "夜 yoasobi", favoritesOnly: false,
            favorites: [], counts: [:], sort: .addedOldest), [a])
        XCTAssertEqual(LibraryQuery.apply(tracks, search: "cafe song", favoritesOnly: false,
            favorites: [], counts: [:], sort: .addedOldest), [b])
        XCTAssertTrue(LibraryQuery.apply(tracks, search: "夜", favoritesOnly: true,
            favorites: [b.id], counts: [:], sort: .addedOldest).isEmpty)
    }
    func testEverySortAndInputQueueRemainUnchanged() {
        let a = track("曲10", artist: "Beta", date: 10)
        let b = track("曲2", artist: "Alpha", date: 20)
        let input = [a,b], counts = [a.id: 5, b.id: 1]
        let expectations: [(LibrarySort,[Track])] = [
            (.addedOldest,[a,b]), (.addedNewest,[b,a]), (.title,[b,a]),
            (.artist,[b,a]), (.leastPlayed,[b,a]), (.mostPlayed,[a,b])
        ]
        for (order, expected) in expectations {
            XCTAssertEqual(LibraryQuery.apply(input, search: "", favoritesOnly: false,
                favorites: [], counts: counts, sort: order), expected)
        }
        XCTAssertEqual(input, [a,b])
    }

    @MainActor
    func testOpusPositionRestoresPausedResumesWithoutDoubleCountAndStopResets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "long", withExtension: "opus"))
        let report = try await LibraryStore(directory: root).importFiles([source])
        let track = try XCTUnwrap(report.tracks.first)
        let prefs = PlaybackPreferences(directory: root)
        let original = SimpleMusic.MusicPlayer(preferences: prefs)
        original.play(track, in: [track], directory: root)
        for _ in 0..<150 {
            if original.isPlaying && !original.isPreparing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        original.seek(to: 12)
        original.pause()
        XCTAssertEqual(prefs.state.currentPosition, 12, accuracy: 0.1)
        let reopened = PlaybackPreferences(directory: root)
        let restored = SimpleMusic.MusicPlayer(preferences: reopened)
        restored.restoreQueue(from: report.tracks, directory: root)
        XCTAssertFalse(restored.isPlaying)
        XCTAssertEqual(restored.position, 12, accuracy: 0.1)
        XCTAssertEqual(restored.current?.id, track.id)
        let count = reopened.count(for: track)
        restored.toggle()
        XCTAssertTrue(restored.isPlaying, restored.errorMessage)
        restored.refresh()
        XCTAssertEqual(restored.position, 12, accuracy: 0.2)
        XCTAssertEqual(reopened.count(for: track), count)
        restored.stop()
        let afterStop = PlaybackPreferences(directory: root)
        XCTAssertEqual(afterStop.state.currentPosition, 0)
        XCTAssertFalse(afterStop.state.sessionCounted)
        original.stop()
    }

    @MainActor
    func testOldPositionFieldsMissingAndInvalidPositionProtection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("playback.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(PlaybackState())) as? [String: Any])
        json.removeValue(forKey: "currentPosition"); json.removeValue(forKey: "sessionCounted")
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let old = PlaybackPreferences(directory: root)
        XCTAssertTrue(old.ready); XCTAssertEqual(old.state.currentPosition, 0)
        json["currentPosition"] = -12
        let corrupt = try JSONSerialization.data(withJSONObject: json)
        try corrupt.write(to: file)
        let protected = PlaybackPreferences(directory: root)
        XCTAssertFalse(protected.ready)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
}