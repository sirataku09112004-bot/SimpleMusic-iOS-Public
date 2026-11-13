import XCTest
@testable import SimpleMusic

final class StatisticsTests: XCTestCase {
    func testBlockBasedAudioClockDoesNotLoseShortTrackPlayback() {
        var meter = ListeningMeter()
        meter.reset(position: 0, time: 0, playing: true)
        var listened = 0.0
        for index in 1...8 {
            let wall = Double(index) * 0.25
            let media = wall + (index.isMultiple(of: 2) ? 0 : 0.07)
            listened += meter.sample(position: media, time: wall, playing: index != 8)
            XCTAssertLessThanOrEqual(listened, wall)
        }
        XCTAssertEqual(listened, 2, accuracy: 0.0001)
        XCTAssertTrue(ListeningMeter.shouldCount(listened: listened, duration: 2, completed: true))
        XCTAssertEqual(meter.sample(position: 2, time: 100, playing: false), 0)
        meter.reset(position: 50, time: 101, playing: true) // seek adds no time
        XCTAssertEqual(meter.sample(position: 50.5, time: 101.5, playing: true), 0.5, accuracy: 0.0001)
    }
    func testMeasuredSecondsExcludePauseAndSeekJumpsAndBufferStalls() {
        var meter = ListeningMeter()
        meter.reset(position: 0,time: 100,playing: true)
        XCTAssertEqual(meter.sample(position: 2,time: 102,playing: true), 2)
        XCTAssertEqual(meter.sample(position: 2,time: 103,playing: true), 0)
        XCTAssertEqual(meter.sample(position: 3,time: 104,playing: false), 1)
        XCTAssertEqual(meter.sample(position: 3,time: 200,playing: false), 0)
        meter.reset(position: 90,time: 200,playing: true)
        XCTAssertEqual(meter.sample(position: 91,time: 201,playing: true), 1)
        meter.reset(position: 10,time: 201,playing: true)
        XCTAssertEqual(meter.sample(position: 12,time: 203,playing: true), 2)
        XCTAssertEqual(ListeningMeter.countThreshold(duration: 180), 10)
        XCTAssertEqual(ListeningMeter.countThreshold(duration: 2), 2)
        XCTAssertEqual(ListeningMeter.countThreshold(duration: 0.1), 0.1)
    }
    func testTenSecondCountRequiresMeasuredTimeAndShortTracksRequireCompletion() {
        XCTAssertFalse(ListeningMeter.shouldCount(listened:9.999,duration:180,completed:false))
        XCTAssertTrue(ListeningMeter.shouldCount(listened:10,duration:180,completed:false))
        XCTAssertTrue(ListeningMeter.shouldCount(listened:10,duration:10,completed:false))
        XCTAssertFalse(ListeningMeter.shouldCount(listened:0.1,duration:180,completed:true))
        XCTAssertFalse(ListeningMeter.shouldCount(listened:8,duration:8,completed:false))
        XCTAssertTrue(ListeningMeter.shouldCount(listened:8,duration:8,completed:true))
        XCTAssertFalse(ListeningMeter.shouldCount(listened:4,duration:8,completed:true))
        XCTAssertFalse(ListeningMeter.shouldCount(listened:10,duration:0,completed:true))
        XCTAssertFalse(ListeningMeter.shouldCount(listened:.nan,duration:30,completed:true))
        var meter = ListeningMeter()
        meter.reset(position:0,time:0,playing:true)
        let before = meter.sample(position:2,time:2,playing:false)
        meter.reset(position:50,time:3,playing:false)
        XCTAssertEqual(meter.sample(position:50,time:30,playing:false),0)
        meter.reset(position:50,time:30,playing:true)
        let after = meter.sample(position:57,time:37,playing:true)
        XCTAssertFalse(ListeningMeter.shouldCount(listened:before+after,duration:180,completed:false))
        let last = meter.sample(position:58,time:38,playing:true)
        XCTAssertTrue(ListeningMeter.shouldCount(listened:before+after+last,duration:180,completed:false))
    }
    @MainActor
    func testTenSecondsOfOpusPlaybackAddsOnceAndPreservesExistingData() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"long",withExtension:"opus"))
        let report = try await LibraryStore(directory:root).importFiles([source])
        let song = try XCTUnwrap(report.tracks.first)
        var old = PlaybackState()
        old.favorites = [song.id]; old.playCounts[song.id] = 17
        old.listeningSeconds[song.id] = 1234
        old.queueIDs = [song.id]; old.currentID = song.id
        old.currentPosition = 20; old.sessionListened = 9; old.statisticsSince = Date(timeIntervalSince1970:123)
        try JSONEncoder().encode(old).write(to:root.appendingPathComponent("playback.json"))
        let prefs = PlaybackPreferences(directory:root), player = MusicPlayer(preferences:prefs)
        defer { player.stop() }
        player.restoreQueue(from:[song],directory:root)
        XCTAssertEqual(prefs.state,old)
        // Restored nine seconds do not count just because the seek position is beyond ten.
        player.seek(to:25); player.checkpoint()
        XCTAssertEqual(prefs.count(for:song),17)
        player.toggle()
        try await Task.sleep(for:.seconds(1.5)); player.pause()
        XCTAssertEqual(prefs.count(for:song),18)
        player.seek(to:10); player.toggle()
        try await Task.sleep(for:.milliseconds(300)); player.pause()
        XCTAssertEqual(prefs.count(for:song),18)
        let reopened = PlaybackPreferences(directory:root)
        XCTAssertEqual(reopened.count(for:song),18)
        XCTAssertTrue(reopened.isFavorite(song))
        XCTAssertEqual(reopened.state.queueIDs,[song.id])
        XCTAssertGreaterThan(reopened.state.listeningSeconds[song.id] ?? 0,1234)
        XCTAssertEqual(reopened.state.statisticsSince,old.statisticsSince)
    }
    @MainActor
    func testShortSkipsDoNotCountAndRealPlaybackPersistsWithoutDoubleCounting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(Bundle(for:Self.self).url(forResource: "fixture",withExtension: "wav"))
        let report = try await LibraryStore(directory: root).importFiles([source])
        let song = try XCTUnwrap(report.tracks.first)
        let prefs = PlaybackPreferences(directory: root), player = MusicPlayer(preferences: prefs)
        defer { player.stop() }
        player.play(song,in:[song],directory:root)
        player.seek(to: song.duration - 0.1)
        try await Task.sleep(for: .milliseconds(300))
        player.refresh(); player.checkpoint()
        XCTAssertEqual(prefs.count(for:song),0)
        XCTAssertLessThan(prefs.state.listeningSeconds[song.id] ?? 0,0.5)
        player.play(song,in:[song],directory:root)
        try await Task.sleep(for: .seconds(ListeningMeter.countThreshold(duration:song.duration) + 0.3))
        player.pause()
        XCTAssertEqual(prefs.count(for:song),1)
        let listened = prefs.state.listeningSeconds[song.id] ?? 0
        try await Task.sleep(for: .milliseconds(300))
        player.refresh(); player.checkpoint()
        XCTAssertEqual(prefs.state.listeningSeconds[song.id] ?? 0,listened,accuracy:0.01)
        player.seek(to:0.4); player.toggle(); player.pause()
        XCTAssertEqual(prefs.count(for:song),1)
        let reopened = PlaybackPreferences(directory:root)
        XCTAssertEqual(reopened.count(for:song),1)
        XCTAssertGreaterThan(reopened.state.listeningSeconds[song.id] ?? 0,0)
        XCTAssertNotNil(reopened.state.statisticsSince)
    }
    @MainActor
    func testRepeatModesPersistOneAllowsManualNextAndOffStopsAtQueueEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try ["wav","flac"].map { try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:$0)) }
        let report = try await LibraryStore(directory:root).importFiles(urls)
        let prefs = PlaybackPreferences(directory:root), player = MusicPlayer(preferences:prefs)
        defer { player.stop() }
        player.play(report.tracks[0],in:report.tracks,directory:root)
        XCTAssertEqual(player.repeatMode,.off)
        player.cycleRepeat(); XCTAssertEqual(player.repeatMode,.all)
        player.cycleRepeat(); XCTAssertEqual(player.repeatMode,.one)
        player.next(); XCTAssertEqual(player.current,report.tracks[1])
        player.next(); XCTAssertEqual(player.current,report.tracks[0])
        player.previous(); XCTAssertEqual(player.current,report.tracks[1])
        player.seek(to:report.tracks[1].duration - 0.15)
        try await Task.sleep(for:.milliseconds(400)); player.refresh()
        XCTAssertEqual(player.current,report.tracks[1]); XCTAssertTrue(player.isPlaying)
        XCTAssertLessThan(player.position,report.tracks[1].duration - 0.3)
        player.pause()
        let restored = MusicPlayer(preferences:PlaybackPreferences(directory:root))
        restored.restoreQueue(from:report.tracks,directory:root)
        XCTAssertEqual(restored.repeatMode,.one)
        player.cycleRepeat(); XCTAssertEqual(player.repeatMode,.off)
        player.toggle(); player.seek(to:player.duration - 0.15)
        try await Task.sleep(for:.milliseconds(400)); player.refresh()
        XCTAssertFalse(player.isPlaying); XCTAssertFalse(player.canNext)
        restored.stop()
    }
    @MainActor
    func testArtistAggregationRetainsLegacyCountsWithoutInferringPastSeconds() {
        let track = Track(id:UUID(),fileName:"x.wav",title:"曲",duration:10,byteCount:1,importedAt:Date(),sha256:String(repeating:"a",count:64),artist:"テスト")
        var state = PlaybackState(); state.playCounts[track.id] = 100
        let artist = StatisticsQuery.artists(tracks:[track],state:state).first
        XCTAssertEqual(artist?.count,100); XCTAssertEqual(artist?.seconds,0)
        state.listeningSeconds[track.id] = 37
        let backup = BackupCodec.make(tracks:[track],state:state)
        let pending = try? BackupCodec.restored(backup,tracks:[])
        let unimported = BackupCodec.make(tracks:[],state:pending ?? PlaybackState()).songs
        XCTAssertEqual(StatisticsQuery.artists(songs:unimported).first?.seconds,37)
    }
}
