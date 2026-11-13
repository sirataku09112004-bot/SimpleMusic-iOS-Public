import XCTest
import AVFoundation
@testable import SimpleMusic

final class InterruptionTests: XCTestCase {
    func testSeekDecodesDifferentAudioFromRequestedTime() throws {
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "seek-markers", withExtension: "opus"))
        let decoder = try OpusDecoder(source)
        var samples = [Float](repeating: 0, count: 4800)
        for (seconds, expected) in [(0.0, 66), (12.0, 198), (22.0, 330)] {
            try decoder.seek(frame: Int64(seconds * 48000))
            let frames = try samples.withUnsafeMutableBufferPointer {
                try decoder.read(into: $0.baseAddress!, capacity: $0.count)
            }
            XCTAssertEqual(frames, 4800)
            let crossings = (1..<frames).filter { (samples[$0 - 1] >= 0) != (samples[$0] >= 0) }.count
            XCTAssertEqual(Double(crossings), Double(expected), accuracy: 4,
                "PCM at \(seconds)s must contain that section's tone, not the beginning")
        }
    }


    @MainActor
    private func waitPlaying(_ player: SimpleMusic.MusicPlayer) async throws {
        for _ in 0..<150 {
            if player.isPlaying && !player.isPreparing { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Playback failed: \(player.errorMessage) / \(player.nativeDiagnostic)")
    }

    @MainActor
    func testOpusInterruptionResumeRepeatedSeeksAndCounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "long", withExtension: "opus"))
        let report = try await LibraryStore(directory: root).importFiles([source])
        let track = try XCTUnwrap(report.tracks.first)
        let prefs = PlaybackPreferences(directory: root)
        let player = SimpleMusic.MusicPlayer(preferences: prefs)
        defer { player.stop() }
        player.play(track, in: report.tracks, directory: root)
        try await waitPlaying(player)
        player.seek(to: 6)
        XCTAssertEqual(player.backendLabel, "互換再生（Opusストリーミング）")
        try await Task.sleep(for: .milliseconds(400))
        player.refresh()
        XCTAssertGreaterThan(player.position, 5.9)
        player.handleInterruptionBegan()
        let held = player.position
        try await Task.sleep(for: .milliseconds(150))
        player.refresh()
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.position, held, accuracy: 0.02)
        player.seek(to: 12)
        XCTAssertEqual(player.position, 12, accuracy: 0.01)
        player.toggle()
        try await waitPlaying(player)
        player.refresh()
        XCTAssertEqual(player.position, 12, accuracy: 0.4)
        XCTAssertEqual(prefs.count(for: track), 0)
        player.pause()
        for target in [3.0, 18.0, 9.0, 21.0] { player.seek(to: target) }
        try await Task.sleep(for: .milliseconds(350))
        player.toggle()
        try await waitPlaying(player)
        player.refresh()
        XCTAssertEqual(player.position, 21, accuracy: 0.4)
        XCTAssertEqual(prefs.count(for: track), 0)
        player.handleInterruptionBegan()
        player.toggle()
        try await waitPlaying(player)
        player.refresh()
        XCTAssertGreaterThan(player.position, 20.8)
        XCTAssertEqual(player.current?.id, track.id)
        XCTAssertEqual(prefs.count(for: track), 0)
    }

    @MainActor
    func testNativeWAVInterruptionPreservesManualResumePosition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "fixture", withExtension: "wav"))
        let report = try await LibraryStore(directory: root).importFiles([source])
        let track = try XCTUnwrap(report.tracks.first)
        let player = SimpleMusic.MusicPlayer()
        defer { player.stop() }
        player.play(track, in: [track], directory: root)
        player.seek(to: 0.8)
        player.handleInterruptionBegan()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(player.isPlaying)
        XCTAssertGreaterThanOrEqual(player.position, 0.79)
        player.seek(to: 1.2)
        player.toggle()
        try await waitPlaying(player)
        player.refresh()
        XCTAssertEqual(player.position, 1.2, accuracy: 0.1)
    }

    @MainActor
    func testAuthorizedInterruptionResumesSameTrackOnceAndRespectsPause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "long", withExtension: "opus"))
        let report = try await LibraryStore(directory: root).importFiles([source])
        let track = try XCTUnwrap(report.tracks.first)
        let prefs = PlaybackPreferences(directory: root)
        let player = SimpleMusic.MusicPlayer(preferences: prefs)
        defer { player.stop() }
        player.play(track, in: [track], directory: root)
        try await waitPlaying(player)
        player.seek(to: 11)
        player.handleInterruptionBegan()
        player.handleInterruptionBegan()
        let held = player.position
        XCTAssertFalse(player.isPlaying)
        player.handleInterruptionEnded(shouldResume: true)
        player.handleInterruptionEnded(shouldResume: true)
        try await waitPlaying(player)
        player.refresh()
        XCTAssertEqual(player.current?.id, track.id)
        XCTAssertEqual(player.queue.map(\.id), [track.id])
        XCTAssertEqual(player.position, held, accuracy: 0.4)
        XCTAssertEqual(prefs.count(for: track), 0)

        player.handleInterruptionBegan()
        player.pause()
        player.handleInterruptionEnded(shouldResume: true)
        XCTAssertFalse(player.isPlaying)
        player.handleInterruptionBegan()
        player.handleInterruptionEnded(shouldResume: true)
        XCTAssertFalse(player.isPlaying)

        player.toggle()
        try await waitPlaying(player)
        player.handleInterruptionBegan()
        player.handleInterruptionEnded(shouldResume: false)
        player.handleInterruptionEnded(shouldResume: true)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.position, held, accuracy: 0.5)
    }

    @MainActor
    func testMixDefaultsOnAndCanChangeDuringPlayback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "long", withExtension: "opus"))
        let report = try await LibraryStore(directory: root).importFiles([source])
        let track = try XCTUnwrap(report.tracks.first)
        let player = SimpleMusic.MusicPlayer(defaults: defaults)
        defer { player.stop() }
        player.play(track, in: [track], directory: root)
        try await waitPlaying(player)
        let session = AVAudioSession.sharedInstance()
        XCTAssertEqual(session.category, .playback)
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers))
        defaults.set(false, forKey: PlaybackRecovery.mixKey)
        player.updateAudioMix()
        XCTAssertFalse(session.categoryOptions.contains(.mixWithOthers))
        XCTAssertEqual(player.current?.id, track.id)
    }

    func testRouteLossTransfersInterruptionWithoutSpeakerResume() {
        let track = UUID()
        var recovery = PlaybackRecovery()
        recovery.beginInterruption(track: track, outputs: ["car"], routeLost: false)
        recovery.beginInterruption(track: nil, outputs: ["speaker"], routeLost: true)
        XCTAssertNil(recovery.interruptedTrack)
        XCTAssertEqual(recovery.takeRouteLoss(currentTrack: track, wasPlaying: false), track)
        XCTAssertNil(recovery.takeRouteLoss(currentTrack: track, wasPlaying: false))
        XCTAssertTrue(recovery.interrupted)
        recovery.endInterruption()
        XCTAssertFalse(recovery.interrupted)

        recovery.beginInterruption(track: track, outputs: ["car"], routeLost: true)
        recovery.cancelAutomaticPlayback()
        XCTAssertNil(recovery.takeRouteLoss(currentTrack: track, wasPlaying: false))
    }

    func testCarResumeRequiresSavedTrackSameOutputAndIdleCall() {
        let track = UUID()
        let cases: [(UUID?, UUID, Set<String>, Bool, Bool, Bool)] = [
            (track, track, ["car"], false, false, true),
            (track, track, ["car"], true, false, false),
            (track, track, ["car"], false, true, false),
            (track, track, ["headphones"], false, false, false),
            (track, track, ["speaker", "car"], false, false, false),
            (track, UUID(), ["car"], false, false, false),
            (nil, track, ["car"], false, false, false)
        ]
        for (ticket, current, outputs, interrupted, call, expected) in cases {
            XCTAssertEqual(PlaybackRecovery.canResumeCar(ticket: ticket, currentTrack: current, carID: "car",
                outputs: outputs, interrupted: interrupted, callInProgress: call), expected)
        }
    }
}

