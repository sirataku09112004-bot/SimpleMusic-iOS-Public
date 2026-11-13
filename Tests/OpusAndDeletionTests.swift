import XCTest
import AVFoundation
import MediaPlayer
@testable import SimpleMusic

final class OpusAndDeletionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    }

    func testOpusMonoStereoTrimAudioAndDedup() async throws {
        let mono = try fixture("fixture", "opus"), stereo = try fixture("stereo", "opus")
        let original = try Data(contentsOf: mono)
        let store = LibraryStore(directory: root)
        let report = try await store.importFiles([mono, stereo, mono])
        XCTAssertEqual(report.added, 2, report.failures.joined(separator: "\n"))
        XCTAssertEqual(report.duplicates, 1)
        for (index, track) in report.tracks.enumerated() {
            XCTAssertEqual(track.sourceExtension, "opus")
            XCTAssertEqual(track.duration, 2, accuracy: 1.0 / 48000)
            let stored = root.appendingPathComponent(track.fileName)
            XCTAssertEqual(stored.pathExtension, "opus")
            XCTAssertEqual(try Data(contentsOf: stored), try Data(contentsOf: index == 0 ? mono : stereo))
            XCTAssertEqual(track.byteCount, Int64(try Data(contentsOf: stored).count))
            let decoder = try OpusDecoder(stored)
            XCTAssertEqual(decoder.channels, index + 1)
            XCTAssertEqual(decoder.frames, 96000)
            var total: Int64 = 0, energy = 0.0
            var samples = [Float](repeating: 0, count: 12000 * decoder.channels)
            while true {
                let count = try samples.withUnsafeMutableBufferPointer {
                    try decoder.read(into: $0.baseAddress!, capacity: $0.count)
                }
                if count == 0 { break }
                total += Int64(count)
                for sample in samples.prefix(count * decoder.channels) {
                    XCTAssertTrue(sample.isFinite)
                    energy += Double(sample * sample)
                }
            }
            XCTAssertEqual(total, 96000)
            XCTAssertGreaterThan(energy, 1)
            try decoder.seek(frame: 48000)
            var remainder = 0
            while true {
                let count = try samples.withUnsafeMutableBufferPointer {
                    try decoder.read(into: $0.baseAddress!, capacity: $0.count)
                }
                if count == 0 { break }
                remainder += count
            }
            XCTAssertEqual(remainder, 48000)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".wav") })
        XCTAssertEqual(try Data(contentsOf: mono), original)
        let reopened = try await LibraryStore(directory: root).load()
        XCTAssertEqual(reopened, report.tracks)
    }

    func testMalformedAndChainedOpusDoNotBlockValidImport() async throws {
        let report = try await LibraryStore(directory: root).importFiles([
            try fixture("corrupt", "opus"), try fixture("chain", "opus"), try fixture("fixture", "opus")
        ])
        let probe = await NativeOpusProbe.inspect(try fixture("chain", "opus"))
        XCTAssertEqual(report.added, probe.mode == "decoder" ? 1 : 2)
        XCTAssertEqual(report.failures.count, probe.mode == "decoder" ? 2 : 1)
        XCTAssertThrowsError(try OpusDecoder(try fixture("chain", "opus")), "External fallback rejects chained input")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".import-") })
    }

    @MainActor
    func testImportedOpusPlaybackSeekAndLicenseResource() async throws {
        let report = try await LibraryStore(directory: root).importFiles([try fixture("stereo", "opus")])
        let track = try XCTUnwrap(report.tracks.first)
        let player = MusicPlayer()
        defer { player.stop() }
        player.play(track, in: report.tracks, directory: root)
        for _ in 0..<100 {
            if player.isPlaying && !player.isPreparing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(player.isPlaying, player.errorMessage)
        player.pause(); player.seek(to: 1.25)
        XCTAssertEqual(player.position, 1.25, accuracy: 0.01)
        player.toggle()
        for _ in 0..<100 {
            if player.isPlaying && !player.isPreparing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(player.isPlaying)
        let notices = try String(contentsOf: XCTUnwrap(Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt")), encoding: .utf8)
        XCTAssertTrue(notices.contains("opus-1.6.1/COPYING"))
        XCTAssertTrue(notices.contains("opusfile-0.12/COPYING"))
        XCTAssertTrue(notices.contains("libogg-1.3.6/COPYING"))
        XCTAssertTrue(notices.contains("datatracker.ietf.org/ipr/"))
    }

    func testDeletionRemovesOnlyAppCopyAndAllowsReimport() async throws {
        let source = try fixture("fixture", "wav")
        let original = try Data(contentsOf: source)
        let store = LibraryStore(directory: root)
        let imported = try await store.importFiles([source])
        let track = try XCTUnwrap(imported.tracks.first)
        let report = try await store.delete(track.id)
        XCTAssertTrue(report.tracks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(track.fileName).path))
        XCTAssertEqual(try Data(contentsOf: source), original)
        let reopened = try await LibraryStore(directory: root).load()
        XCTAssertTrue(reopened.isEmpty)
        let reimported = try await store.importFiles([source])
        XCTAssertEqual(reimported.added, 1)
        XCTAssertNotEqual(reimported.tracks.first?.id, track.id)
    }

    func testFailedIndexWriteRollsBackAudio() async throws {
        let store = LibraryStore(directory: root)
        let imported = try await store.importFiles([try fixture("fixture", "wav")])
        let track = try XCTUnwrap(imported.tracks.first)
        let index = root.appendingPathComponent("library.json")
        let backup = root.appendingPathComponent("saved-index.json")
        try FileManager.default.moveItem(at: index, to: backup)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        do { _ = try await store.delete(track.id); XCTFail("Write must fail") }
        catch { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(track.fileName).path)) }
        try FileManager.default.removeItem(at: index)
        try FileManager.default.moveItem(at: backup, to: index)
        let reopened = try await LibraryStore(directory: root).load()
        XCTAssertEqual(reopened, imported.tracks)
    }

    func testInterruptedDeleteRestoresOrFinishesFromJournal() async throws {
        let imported = try await LibraryStore(directory: root).importFiles([try fixture("fixture", "wav")])
        let track = try XCTUnwrap(imported.tracks.first)
        let intent = DeletionIntent(id: track.id, fileName: track.fileName, trashName: ".deleted-\(track.id.uuidString)")
        let journal = root.appendingPathComponent("deletion.json")
        let original = root.appendingPathComponent(track.fileName)
        let trash = root.appendingPathComponent(intent.trashName)
        try JSONEncoder().encode(intent).write(to: journal)
        try FileManager.default.moveItem(at: original, to: trash)
        let restored = try await LibraryStore(directory: root).load()
        XCTAssertEqual(restored, imported.tracks)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        try JSONEncoder().encode(intent).write(to: journal)
        try FileManager.default.moveItem(at: original, to: trash)
        try JSONEncoder().encode([Track]()).write(to: root.appendingPathComponent("library.json"))
        let finished = try await LibraryStore(directory: root).load()
        XCTAssertTrue(finished.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trash.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }

    @MainActor
    func testDeletingSelectedTrackStopsAndClearsQueueAndStats() async throws {
        let imported = try await LibraryStore(directory: root).importFiles([try fixture("fixture", "wav"), try fixture("fixture", "flac")])
        let track = try XCTUnwrap(imported.tracks.first)
        let preferences = PlaybackPreferences(directory: root)
        preferences.toggleFavorite(track)
        let player = MusicPlayer(preferences: preferences)
        player.play(track, in: imported.tracks, directory: root)
        player.setPriorityLoop(true)
        player.forget(track)
        XCTAssertFalse(player.isPlaying)
        XCTAssertNil(player.current)
        XCTAssertFalse(player.queue.contains(track))
        XCTAssertFalse(preferences.isFavorite(track))
        XCTAssertEqual(preferences.count(for: track), 0)
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        let reopened = PlaybackPreferences(directory: root)
        XCTAssertFalse(reopened.state.queueIDs.contains(track.id))
    }
}