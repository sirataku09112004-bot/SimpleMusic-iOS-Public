import XCTest
import UIKit
import MediaPlayer
@testable import SimpleMusic

final class LockScreenArtworkTests: XCTestCase {
    @MainActor
    func testCachedCoverIsPublishedOfflineAndClearedForNextSongWithoutCover() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let files = try ["wav","mp3"].map { try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:$0)) }
        let report = try await LibraryStore(directory:root).importFiles(files)
        let first = try XCTUnwrap(report.tracks.first)
        let folder = root.appendingPathComponent("artwork",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let image = UIGraphicsImageRenderer(size:CGSize(width:64,height:64)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x:0,y:0,width:64,height:64))
        }
        let hash = String(repeating:"d",count:64)
        try XCTUnwrap(image.jpegData(compressionQuality:0.65)).write(to:folder.appendingPathComponent(hash + ".jpg"))
        var index = ArtworkIndex(); index.songs[first.sha256] = hash
        try JSONEncoder().encode(index).write(to:folder.appendingPathComponent("index.json"))
        let model = ArtworkModel(directory:root)
        let player = MusicPlayer(preferences:PlaybackPreferences(directory:root),artwork:model)
        defer { player.stop(); MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
        player.play(first,in:report.tracks,directory:root); player.pause()
        for _ in 0..<100 {
            if MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] != nil { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        let cover = try XCTUnwrap(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork)
        let displayed = try XCTUnwrap(cover.image(at:CGSize(width:44,height:44)))
        XCTAssertGreaterThan(displayed.size.width,0)
        XCTAssertLessThanOrEqual(displayed.size.width,256)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String,first.title)
        player.next(); player.pause()
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork])
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertNil(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork])
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String,report.tracks[1].title)
        XCTAssertEqual(MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double,0)
    }
}

