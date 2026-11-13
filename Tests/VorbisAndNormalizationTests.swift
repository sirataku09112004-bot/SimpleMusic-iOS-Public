import XCTest
import AVFoundation
@testable import SimpleMusic

final class VorbisAndNormalizationTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func fixture(_ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext))
    }
    func testVorbisImportKeepsCompressedBytesAndCachesArtist() async throws {
        let source = try fixture("tagged", "ogg"), before = try Data(contentsOf: fixture("tagged", "ogg"))
        let report = try await LibraryStore(directory: root).importFiles([source])
        XCTAssertEqual(report.added, 1, report.failures.joined(separator: "\n"))
        let track = try XCTUnwrap(report.tracks.first)
        XCTAssertTrue(track.usesVorbisDecoder)
        XCTAssertEqual(track.artistLabel, "日本語 Artist & ☆ / テスト")
        XCTAssertEqual(track.duration, 2, accuracy: 0.01)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(track.fileName)), before)
        XCTAssertEqual(try Data(contentsOf: source), before)
        let cached = try await LibraryStore(directory: root).loadWithMetadata()
        XCTAssertEqual(cached, report.tracks)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".wav") })
    }
    func testVorbisPCMSeekChangesActualAudioAndRejectsChain() throws {
        let decoder = try VorbisDecoder(fixture("seek-vorbis", "ogg"))
        XCTAssertEqual(decoder.sampleRate, 44100)
        XCTAssertEqual(decoder.channels, 2)
        XCTAssertEqual(decoder.duration, 30, accuracy: 0.01)
        func frequency(_ seconds: Double) throws -> Double {
            try decoder.seek(frame: Int64(seconds * decoder.sampleRate))
            var samples = [Float](repeating: 0, count: 12000 * decoder.channels)
            let frames = try samples.withUnsafeMutableBufferPointer { try decoder.read(into: $0.baseAddress!, capacity: $0.count) }
            var crossings = 0
            for frame in 1..<frames where samples[(frame - 1) * 2] <= 0 && samples[frame * 2] > 0 { crossings += 1 }
            return Double(crossings) * decoder.sampleRate / Double(frames)
        }
        XCTAssertEqual(try frequency(3), 330, accuracy: 10)
        XCTAssertEqual(try frequency(13), 990, accuracy: 10)
        XCTAssertEqual(try frequency(23), 1650, accuracy: 10)
        XCTAssertThrowsError(try VorbisDecoder(fixture("chain-vorbis", "ogg")))
        XCTAssertFalse(AudioDecoder.isVorbis(try fixture("stereo", "opus")))
    }
    func testNormalizationMatchesRMSWithoutModifyingOriginalAndHandlesSilence() throws {
        let quiet = try fixture("quiet", "wav"), loud = try fixture("loud", "wav")
        let original = try Data(contentsOf: quiet)
        let q = try LoudnessAnalyzer.analyze(quiet), l = try LoudnessAnalyzer.analyze(loud)
        XCTAssertGreaterThan(q.gain, 1); XCTAssertLessThan(l.gain, 1)
        XCTAssertEqual(q.rms * q.gain, 0.1, accuracy: 0.0001)
        XCTAssertEqual(l.rms * l.gain, 0.1, accuracy: 0.0001)
        XCTAssertEqual(try Data(contentsOf: quiet), original)
        let silent = try LoudnessAnalyzer.analyze(fixture("silent", "wav"))
        XCTAssertEqual(silent.gain, 1); XCTAssertEqual(silent.rms, 0)
        XCTAssertLessThanOrEqual(LoudnessProfile.make(rms: 0.01, peak: 0.99).gain * 0.99, pow(10, -1.0 / 20) + 0.000001)
        XCTAssertLessThanOrEqual(LoudnessProfile.make(rms: 0.00001, peak: 0.0001).gain, pow(10, 12.0 / 20))
        XCTAssertEqual(PCMVolume.apply(0.2, gain: 2), 0.4, accuracy: 0.000001)
        XCTAssertEqual(PCMVolume.apply(-0.9, gain: 2), -1)
        XCTAssertEqual(PCMVolume.apply(.nan, gain: 1), 0)
    }
    func testAnalysisWorksAcrossAllSupportedFormatsAndRemainsBounded() throws {
        for ext in ["mp3", "m4a", "aac", "flac", "wav", "opus"] {
            let result = try LoudnessAnalyzer.analyze(fixture("fixture", ext))
            XCTAssertTrue(result.valid, ext); XCTAssertGreaterThan(result.rms, 0, ext)
        }
        let vorbis = try LoudnessAnalyzer.analyze(fixture("tagged", "ogg"))
        XCTAssertTrue(vorbis.valid); XCTAssertGreaterThan(vorbis.rms, 0)
        let stream = try OpusStreamPlayer(url: fixture("seek-vorbis", "ogg"))
        XCTAssertEqual(stream.pcmBudgetBytes, 384000)
        XCTAssertEqual(stream.duration, 30, accuracy: 0.01)
    }
    @MainActor
    func testCacheReloadSettingAndCancelledAnalysis() async throws {
        let report = try await LibraryStore(directory: root).importFiles([fixture("quiet", "wav")])
        let track = try XCTUnwrap(report.tracks.first)
        let suite = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = NormalizationModel(directory: root, defaults: defaults)
        model.analyze(report.tracks)
        while model.analyzing { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.hasProfile(track)); XCTAssertEqual(model.gain(for: track), 1)
        model.setEnabled(true)
        let restored = NormalizationModel(directory: root, defaults: defaults)
        XCTAssertTrue(restored.enabled); XCTAssertGreaterThan(restored.gain(for: track), 1)
        // Cached results do not require an audio read.
        try FileManager.default.removeItem(at: root.appendingPathComponent(track.fileName))
        restored.analyze(report.tracks)
        while restored.analyzing { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(restored.message, "解析完了（1曲）")
        let cache = LoudnessCache(directory: root, profiles: [:])
        let cancelled = Task { try await cache.profile(for: track) }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled analysis must fail") } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
    }
    @MainActor
    func testVorbisAndNormalizedQueueInterruptionSeekAndCount() async throws {
        let report = try await LibraryStore(directory: root).importFiles([fixture("seek-vorbis", "ogg"), fixture("fixture", "mp3")])
        XCTAssertEqual(report.added, 2, report.failures.joined(separator: "\n"))
        let first = try XCTUnwrap(report.tracks.first)
        let suite = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let norm = NormalizationModel(directory: root, defaults: defaults)
        norm.analyze(report.tracks)
        while norm.analyzing { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(report.tracks.allSatisfy { norm.hasProfile($0) }, norm.message)
        norm.setEnabled(true)
        let preferences = PlaybackPreferences(directory: root)
        let player = MusicPlayer(preferences: preferences, normalization: norm)
        defer { player.stop() }
        player.play(first, in: report.tracks, directory: root)
        XCTAssertTrue(player.isPlaying, player.errorMessage)
        player.seek(to: 13); player.pause()
        XCTAssertEqual(player.position, 13, accuracy: 0.1)
        norm.setEnabled(false); player.updateNormalization()
        XCTAssertEqual(player.position, 13, accuracy: 0.1)
        player.toggle(); player.handleInterruptionBegan(); player.seek(to: 23); player.toggle()
        XCTAssertTrue(player.isPlaying, player.errorMessage)
        XCTAssertEqual(player.position, 23, accuracy: 0.1)
        XCTAssertEqual(preferences.count(for: first), 0)
        norm.setEnabled(true); player.updateNormalization()
        player.seek(to: 29.7)
        for _ in 0..<40 {
            if player.current?.id != first.id { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(player.current?.id, report.tracks.last?.id)
        XCTAssertTrue(player.isPlaying, player.errorMessage)
        XCTAssertEqual(preferences.count(for: report.tracks.last!), 0)
    }
    @MainActor
    func testEnableNormalizationKeepsNativePositionAndPlaybackCount() async throws {
        let report = try await LibraryStore(directory: root).importFiles([fixture("quiet", "wav")])
        let track = try XCTUnwrap(report.tracks.first)
        let suite = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let norm = NormalizationModel(directory: root, defaults: defaults)
        norm.analyze(report.tracks)
        while norm.analyzing { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(norm.hasProfile(track), norm.message)
        let player = MusicPlayer(preferences: PlaybackPreferences(directory: root), normalization: norm)
        defer { player.stop() }
        player.play(track, in: report.tracks, directory: root); player.pause(); player.seek(to: 1)
        norm.setEnabled(true); player.updateNormalization()
        XCTAssertFalse(player.isPlaying); XCTAssertEqual(player.position, 1, accuracy: 0.01)
        player.toggle(); XCTAssertTrue(player.isPlaying, player.errorMessage)
        let reloaded = PlaybackPreferences(directory: root)
        XCTAssertEqual(reloaded.count(for: track), 0)
    }
}
