import XCTest
import AVFoundation
import MediaPlayer
@testable import SimpleMusic

final class StreamingAndArtistTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    }

    @MainActor
    private func waitUntilPlaying(_ player: SimpleMusic.MusicPlayer) async throws {
        for _ in 0..<100 {
            if player.isPlaying && !player.isPreparing { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Playback did not start: \(player.errorMessage) / \(player.nativeDiagnostic)")
    }

    func testArtistTagsAcrossFormatsAndUnknownFallback() async throws {
        for ext in ["opus", "mp3", "m4a", "flac", "wav", "ogg"] {
            let artist = await ArtistMetadata.read(try fixture("tagged", ext))
            XCTAssertEqual(artist, "日本語 Artist & ☆ / テスト", ext)
        }
        let report = try await LibraryStore(directory: root).importFiles([
            try fixture("tagged", "opus"), try fixture("tagged", "mp3"), try fixture("tagged", "m4a"),
            try fixture("tagged", "flac"), try fixture("tagged", "wav"), try fixture("fixture", "aac")
        ])
        XCTAssertEqual(report.added, 6, report.failures.joined(separator: "\n"))
        XCTAssertTrue(report.tracks.prefix(5).allSatisfy { $0.artistLabel == "日本語 Artist & ☆ / テスト" })
        XCTAssertEqual(report.tracks.last?.artistLabel, "不明なアーティスト")
        XCTAssertTrue(report.tracks.allSatisfy { $0.metadataVersion == 1 })
        let cached = try await LibraryStore(directory: root).loadWithMetadata()
        XCTAssertEqual(cached, report.tracks)
    }

    @MainActor
    func testStandardAPIsWithOriginalOpusAndNativePlayerControls() async throws {
        let original = try fixture("stereo", "opus")
        let before = try Data(contentsOf: original)
        let audio = await NativeOpusProbe.inspect(original)
        let asset = await NativeOpusProbe.inspectAVPlayer(original)
        print("OPUS_NATIVE_PROBE os=\(NativeOpusProbe.os) audio=\(audio.mode):\(audio.detail) avPlayer=\(asset.mode):\(asset.detail)")
        XCTAssertEqual(try Data(contentsOf: original), before)
        // A positive preparation result is followed by an actual playback attempt.
        if audio.mode == "audioPlayer" {
            let player = try AVAudioPlayer(contentsOf: original)
            XCTAssertTrue(player.play())
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertGreaterThan(player.currentTime, 0)
            player.stop()
        }
        if asset.mode == "avPlayer" {
            let player = NativeFilePlayer(url: original)
            player.play()
            for _ in 0..<50 {
                if player.isPlaying && player.currentTime > 0 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(player.isPlaying)
            XCTAssertGreaterThan(player.currentTime, 0)
            player.stop()
        }
        let native = NativeFilePlayer(url: try fixture("fixture", "wav"))
        var starts = 0, finished = false
        native.onStart = { starts += 1 }
        native.onFinish = { error in XCTAssertNil(error); finished = true }
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        native.play()
        for _ in 0..<50 {
            if native.isPlaying && starts > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(native.isPlaying)
        native.pause()
        XCTAssertFalse(native.isPlaying)
        native.seek(to: 1.5)
        XCTAssertEqual(native.currentTime, 1.5, accuracy: 0.03)
        native.play()
        for _ in 0..<50 {
            if finished { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(finished)
        XCTAssertGreaterThanOrEqual(starts, 2)
        native.stop()
    }


    func testMalformedCommentsAndLongUnicodeArtist() throws {
        XCTAssertNil(ArtistMetadata.comments(Data([255,255,255,255])))
        XCTAssertNil(ArtistMetadata.cleaned(" \n "))
        let long = String(repeating: "音☆", count: 3000)
        XCTAssertEqual(ArtistMetadata.cleaned(long)?.count, 4096)
        var bytes = Data([0,0,0,0,1,0,0,0])
        let tag = Data("ARTIST=日本語 & ☆".utf8), n = UInt32(tag.count)
        bytes.append(contentsOf: (0..<4).map { UInt8((n >> ($0 * 8)) & 255) })
        bytes.append(tag)
        XCTAssertEqual(ArtistMetadata.comments(bytes), "日本語 & ☆")
    }

    @MainActor
    func testLegacyWAVReplacementRetainsIdentityAndStatistics() async throws {
        let source = try fixture("tagged", "opus")
        let store = LibraryStore(directory: root)
        let report = try await store.importFiles([source])
        let compressed = try XCTUnwrap(report.tracks.first)
        let prefs = PlaybackPreferences(directory: root)
        prefs.toggleFavorite(compressed)
        prefs.recordStart(compressed)
        prefs.saveQueue([compressed], current: compressed, priorityLoop: true)
        let oldName = "\(compressed.id.uuidString).wav"
        let legacy = Track(id: compressed.id, fileName: oldName, title: compressed.title,
            duration: compressed.duration, byteCount: 352844, importedAt: compressed.importedAt,
            sha256: compressed.sha256, sourceExtension: "opus")
        try FileManager.default.removeItem(at: root.appendingPathComponent(compressed.fileName))
        try FileManager.default.copyItem(at: try fixture("fixture", "wav"), to: root.appendingPathComponent(oldName))
        try JSONEncoder().encode([legacy]).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        let result = try await LibraryStore(directory: root).importFiles([source])
        XCTAssertEqual(result.added, 1)
        XCTAssertEqual(result.tracks.first?.id, legacy.id)
        XCTAssertEqual(result.tracks.first?.importedAt, legacy.importedAt)
        XCTAssertEqual(result.tracks.first?.artistLabel, "日本語 Artist & ☆ / テスト")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(oldName).path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(compressed.fileName)), try Data(contentsOf: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("replacement.json").path))
        let restored = PlaybackPreferences(directory: root)
        XCTAssertTrue(restored.isFavorite(legacy))
        XCTAssertEqual(restored.count(for: legacy), 1)
        XCTAssertEqual(restored.state.currentID, legacy.id)
    }

    func testInterruptedReplacementKeepsOnlyIndexedAudio() async throws {
        let report = try await LibraryStore(directory: root).importFiles([try fixture("stereo", "opus")])
        let track = try XCTUnwrap(report.tracks.first)
        let legacyName = "\(track.id.uuidString).wav"
        let legacy = Track(id: track.id, fileName: legacyName, title: track.title, duration: track.duration,
            byteCount: 1, importedAt: track.importedAt, sha256: track.sha256, sourceExtension: "opus")
        let index = root.appendingPathComponent("library.json")
        let journal = root.appendingPathComponent("replacement.json")
        let old = root.appendingPathComponent(legacyName), new = root.appendingPathComponent(track.fileName)
        try FileManager.default.copyItem(at: try fixture("fixture", "wav"), to: old)
        try JSONEncoder().encode([legacy]).write(to: index, options: .atomic)
        try JSONEncoder().encode([legacyName, track.fileName]).write(to: journal, options: .atomic)
        let beforeCommit = try await LibraryStore(directory: root).load()
        XCTAssertEqual(beforeCommit.first?.fileName, legacyName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path))
        try FileManager.default.copyItem(at: try fixture("stereo", "opus"), to: new)
        try JSONEncoder().encode([track]).write(to: index, options: .atomic)
        try JSONEncoder().encode([legacyName, track.fileName]).write(to: journal, options: .atomic)
        let afterCommit = try await LibraryStore(directory: root).load()
        XCTAssertEqual(afterCommit.first?.fileName, track.fileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: new.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
    }


    @MainActor
    func testStreamingPauseSeekStopRepeatAndMixedQueue() async throws {
        let report = try await LibraryStore(directory: root).importFiles([try fixture("stereo", "opus"), try fixture("fixture", "mp3")])
        let opus = try XCTUnwrap(report.tracks.first)
        let prefs = PlaybackPreferences(directory: root)
        let player = MusicPlayer(preferences: prefs)
        defer { player.stop() }
        player.play(opus, in: report.tracks, directory: root)
        try await waitUntilPlaying(player)
        XCTAssertTrue(player.isPlaying, player.errorMessage)
        XCTAssertEqual(prefs.count(for: opus), 0)
        try await Task.sleep(for: .milliseconds(350))
        player.refresh()
        XCTAssertGreaterThan(player.position, 0)
        player.pause()
        let paused = player.position
        try await Task.sleep(for: .milliseconds(150))
        player.refresh()
        XCTAssertEqual(player.position, paused, accuracy: 0.02)
        player.seek(to: 1.25)
        XCTAssertEqual(player.position, 1.25, accuracy: 0.01)
        player.toggle()
        try await waitUntilPlaying(player)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(prefs.count(for: opus), 0)
        player.seek(to: 1.8)
        for _ in 0..<40 {
            if player.current?.id != opus.id { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(player.current?.id, report.tracks.last?.id)
        print("OPUS_END_CHECK position=\(player.position) playing=\(player.isPlaying) backend=\(player.backendLabel) diagnostic=\(player.nativeDiagnostic) error=\(player.errorMessage)")
        XCTAssertTrue(player.isPlaying, player.errorMessage)
        player.play(opus, in: [opus], directory: root)
        try await waitUntilPlaying(player)
        player.setPriorityLoop(true)
        let count = prefs.count(for: opus)
        player.seek(to: 1.8)
        for _ in 0..<40 {
            if prefs.count(for: opus) > count { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(prefs.count(for: opus), count + 1)
        XCTAssertTrue(player.priorityLoop)
        player.stop()
        XCTAssertEqual(player.position, 0, accuracy: 0.01)
        player.toggle()
        try await waitUntilPlaying(player)
        XCTAssertTrue(player.isPlaying, player.errorMessage)
        XCTAssertEqual(prefs.count(for: opus), count + 1)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".wav") })
    }

    @MainActor
    func testLongFileHasBoundedPCMBudgetAndGraphRecovery() async throws {
        let source = try fixture("long", "opus")
        let stream = try OpusStreamPlayer(url: source)
        defer { stream.stop() }
        XCTAssertEqual(stream.duration, 30, accuracy: 0.001)
        XCTAssertEqual(stream.pcmBudgetBytes, 192000) // 1 sec mono, independent of song duration.
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        try stream.play()
        try await Task.sleep(for: .milliseconds(400))
        let before = stream.currentTime
        try stream.reconfigure()
        XCTAssertTrue(stream.isPlaying)
        XCTAssertEqual(stream.currentTime, before, accuracy: 0.05)
        stream.pause()
        try stream.seek(to: 29.5)
        XCTAssertEqual(stream.currentTime, 29.5, accuracy: 0.01)
        try stream.play()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertFalse(stream.isPlaying)
        XCTAssertEqual(stream.currentTime, 30, accuracy: 0.01)
    }
}


