import XCTest
import MediaPlayer
@testable import SimpleMusic

final class LibraryTests: XCTestCase {
    @MainActor
    func testNowPlayingMetadataAndCommandAvailability() async throws {
        let directory = root.appendingPathComponent("library")
        let report = try await LibraryStore(directory: directory).importFiles([try fixture("wav"), try fixture("flac")])
        let player = MusicPlayer()
        defer { player.stop() }
        player.play(report.tracks[0], in: report.tracks, directory: directory)
        let center = MPRemoteCommandCenter.shared()
        XCTAssertTrue(center.playCommand.isEnabled)
        XCTAssertTrue(center.nextTrackCommand.isEnabled)
        XCTAssertFalse(center.previousTrackCommand.isEnabled)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, report.tracks[0].title)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        player.pause()
        player.seek(to: 0.7)
        let paused = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        XCTAssertEqual(paused[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertEqual(try XCTUnwrap(paused[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double), 0.7, accuracy: 0.05)
        player.next()
        XCTAssertFalse(center.nextTrackCommand.isEnabled)
        XCTAssertTrue(center.previousTrackCommand.isEnabled)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackQueueIndex] as? Int, 1)
        player.stop()
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 0)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String], ["audio"])
    }

    @MainActor
    func testAutomaticAdvanceAndEndOfQueue() async throws {
        let directory = root.appendingPathComponent("library")
        let report = try await LibraryStore(directory: directory).importFiles([try fixture("wav"), try fixture("flac")])
        let preferences = PlaybackPreferences(directory: directory)
        let player = MusicPlayer(preferences: preferences)
        defer { player.stop() }
        player.play(report.tracks[0], in: report.tracks, directory: directory)
        player.seek(to: report.tracks[0].duration - 0.2)
        for _ in 0..<50 {
            if player.current == report.tracks[1] { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(player.current, report.tracks[1])
        XCTAssertTrue(player.isPlaying, player.errorMessage)
        XCTAssertEqual(preferences.count(for: report.tracks[0]), 0)
        XCTAssertEqual(preferences.count(for: report.tracks[1]), 0)
        player.seek(to: report.tracks[1].duration - 0.2)
        for _ in 0..<50 {
            if !player.isPlaying { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.position, player.duration, accuracy: 0.05)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        // Rewinding after completion still starts a new counted session.
        player.seek(to: 0.5)
        player.toggle()
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(preferences.count(for: report.tracks[1]), 0)
    }
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }
    private func fixture(_ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: LibraryTests.self).url(forResource: "fixture", withExtension: ext))
    }

    func testNativeFormatFixturesImportAndReopen() async throws {
        let storageURL = root.appendingPathComponent("library")
        let store = LibraryStore(directory: storageURL)
        let urls = try ["wav", "mp3", "m4a", "aac", "flac"].map { try fixture($0) }
        let report = try await store.importFiles(urls)
        XCTAssertEqual(report.added, 5, report.failures.joined(separator: "\n"))
        XCTAssertTrue(report.failures.isEmpty)
        for track in report.tracks {
            print("FORMAT_DURATION \(track.fileName) \(track.duration)")
            XCTAssertTrue(track.duration > 1.8 && track.duration < 2.3,
                "\(track.fileName): duration=\(track.duration), expected a two-second fixture")
        }
        let reopened = try await LibraryStore(directory: storageURL).load()
        XCTAssertEqual(reopened, report.tracks)
        for track in reopened {
            XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.appendingPathComponent(track.fileName).path))
        }
    }

    func testContentDedupAndSameNameDifferentAudio() async throws {
        let sourceA = root.appendingPathComponent("A")
        let sourceB = root.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: sourceA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceB, withIntermediateDirectories: true)
        let first = sourceA.appendingPathComponent("same.wav")
        let second = sourceB.appendingPathComponent("same.wav")
        let original = try Data(contentsOf: fixture("wav"))
        try original.write(to: first)
        var different = original
        different[100] ^= 1
        try different.write(to: second)
        let store = LibraryStore(directory: root.appendingPathComponent("library"))
        let report = try await store.importFiles([first, first, second])
        XCTAssertEqual(report.added, 2)
        XCTAssertEqual(report.duplicates, 1)
        XCTAssertEqual(Set(report.tracks.map(\.fileName)).count, 2)
        XCTAssertEqual(report.tracks.map(\.title), ["same", "same"])
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertEqual(try Data(contentsOf: second), different)
        try FileManager.default.removeItem(at: first)
        for track in report.tracks {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("library").appendingPathComponent(track.fileName).path))
        }
    }

    func testBadFilesDoNotPreventRemainingImports() async throws {
        let broken = root.appendingPathComponent("broken.wav")
        try Data("invalid audio".utf8).write(to: broken)
        let store = LibraryStore(directory: root.appendingPathComponent("library"))
        let report = try await store.importFiles([
            root.appendingPathComponent("missing.mp3"), broken,
            root.appendingPathComponent("future.opus"), try fixture("wav")
        ])
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.failures.count, 3)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("library").path)
        XCTAssertEqual(names.count, 2)
        XCTAssertFalse(names.contains { $0.hasPrefix(".import-") })
    }

    func testCorruptIndexIsPreserved() async throws {
        let directory = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let index = directory.appendingPathComponent("library.json")
        let damaged = Data("broken index".utf8)
        try damaged.write(to: index)
        let store = LibraryStore(directory: directory)
        do {
            _ = try await store.importFiles([try fixture("wav")])
            XCTFail("Corrupt index must block imports")
        } catch {
            XCTAssertEqual(try Data(contentsOf: index), damaged)
        }
    }

    @MainActor
    func testPlaybackForAllNativeFixturesAndQueueNavigation() async throws {
        let directory = root.appendingPathComponent("library")
        let urls = try ["wav", "mp3", "m4a", "aac", "flac"].map { try fixture($0) }
        let report = try await LibraryStore(directory: directory).importFiles(urls)
        XCTAssertEqual(report.added, 5)
        let player = MusicPlayer()
        defer { player.stop() }
        for track in report.tracks {
            player.play(track, in: report.tracks, directory: directory)
            XCTAssertTrue(player.isPlaying, "\(track.fileName): \(player.errorMessage)")
            player.pause()
        }
        player.play(try XCTUnwrap(report.tracks.first), in: report.tracks, directory: directory)
        XCTAssertFalse(player.canPrevious)
        XCTAssertTrue(player.canNext)
        player.next()
        XCTAssertEqual(player.current, report.tracks[1])
        player.previous()
        XCTAssertEqual(player.current, report.tracks[0])
    }

    @MainActor
    func testPlaybackPauseSeekResumeStop() async throws {
        let directory = root.appendingPathComponent("library")
        let report = try await LibraryStore(directory: directory).importFiles([try fixture("wav")])
        let track = try XCTUnwrap(report.tracks.first)
        let player = MusicPlayer()
        player.play(track, in: report.tracks, directory: directory)
        XCTAssertTrue(player.isPlaying, player.errorMessage)
        player.pause()
        XCTAssertFalse(player.isPlaying)
        player.seek(to: 0.8)
        XCTAssertEqual(player.position, 0.8, accuracy: 0.05)
        player.toggle()
        XCTAssertTrue(player.isPlaying, player.errorMessage)
        player.stop()
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.position, 0, accuracy: 0.05)
    }
}
