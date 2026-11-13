import XCTest
import UIKit
import ImageIO
@testable import SimpleMusic

final class ArtworkTests: XCTestCase {
    func testYouTubeMetadataIDValidationNeverGuessesTitlesOrOtherHosts() {
        let id = "Abcd_123-xy"
        XCTAssertEqual(ArtworkMetadata.videoID("https://youtu.be/\(id)?t=2"), id)
        XCTAssertEqual(ArtworkMetadata.videoID("Source: https://www.youtube.com/watch?v=\(id)"), id)
        XCTAssertEqual(ArtworkMetadata.videoID("https://youtube.com/shorts/\(id)"), id)
        XCTAssertEqual(ArtworkMetadata.videoID(id, allowBare: true), id)
        XCTAssertNil(ArtworkMetadata.videoID(id))
        XCTAssertNil(ArtworkMetadata.videoID("https://youtube.com.evil.example/watch?v=\(id)"))
        XCTAssertNil(ArtworkMetadata.videoID("https://youtu.be/short"))
        XCTAssertNil(ArtworkMetadata.videoID("好きな曲 \(id)"))
        XCTAssertNil(ArtworkMetadata.videoID("file:///watch?v=\(id)"))
    }
    func testCorruptPictureAndCommentsAreBounded() {
        XCTAssertNil(ArtworkMetadata.picture(Data(repeating: 255, count: 40)))
        XCTAssertTrue(ArtworkMetadata.comments(Data(repeating: 255, count: 40)).isEmpty)
        XCTAssertNil(ArtworkMetadata.jpeg(Data(repeating: 0, count: ArtworkMetadata.limit + 1)))
    }
    func testOggOpusNewPipeCommentURLIsReadWithoutFilenameGuessing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        func little(_ value: Int) -> Data { Data([UInt8(value & 255),UInt8((value >> 8) & 255),UInt8((value >> 16) & 255),UInt8((value >> 24) & 255)]) }
        let comment = Data("COMMENT=https://www.youtube.com/watch?v=Abcd_123-xy".utf8)
        let artist = Data("ARTIST=日本語 Artist".utf8)
        let packet = Data("OpusTags".utf8) + little(0) + little(2) + little(comment.count) + comment + little(artist.count) + artist
        XCTAssertLessThan(packet.count,255)
        var header = Data(repeating:0,count:27)
        header.replaceSubrange(0..<4,with:Data("OggS".utf8)); header[26] = 1
        let file = root.appendingPathComponent("名前から推測しない.opus")
        try (header + Data([UInt8(packet.count)]) + packet).write(to:file)
        let result = try ArtworkMetadata.container(file)
        let url = try XCTUnwrap(result.1.first(where:{$0.0 == "COMMENT"})?.1)
        XCTAssertEqual(ArtworkMetadata.videoID(url),"Abcd_123-xy")
        XCTAssertNil(result.0)
    }
    @MainActor
    func testJPEGDimensionsCompressionAndEmbeddedOnlyOfflineDeduplication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 700, height: 400))
        let png = try XCTUnwrap(renderer.image { context in UIColor.red.setFill(); context.fill(CGRect(x: 0,y: 0,width: 700,height: 400)) }.pngData())
        let jpeg = try XCTUnwrap(ArtworkMetadata.jpeg(png))
        let image = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String:Any])
        XCTAssertLessThanOrEqual((properties[kCGImagePropertyPixelWidth as String] as? Int) ?? 999, 256)
        XCTAssertLessThan(jpeg.count, 100000)
        func big(_ value: Int) -> Data { Data([UInt8((value >> 24) & 255),UInt8((value >> 16) & 255),UInt8((value >> 8) & 255),UInt8(value & 255)]) }
        let mime = Data("image/png".utf8)
        let picture = big(3) + big(mime.count) + mime + big(0) + big(700) + big(400) + big(24) + big(0) + big(png.count) + png
        let header = Data([0x86,UInt8((picture.count >> 16) & 255),UInt8((picture.count >> 8) & 255),UInt8(picture.count & 255)])
        let fileName = "embedded.flac"
        try (Data("fLaC".utf8) + header + picture).write(to: root.appendingPathComponent(fileName))
        // Only metadata is needed by this test; no audio decoding or network is performed.
        let a = Track(id: UUID(),fileName: fileName,title: "画像",duration: 1,byteCount: 1,importedAt: Date(),sha256: String(repeating:"a",count:64))
        let b = Track(id: UUID(),fileName: fileName,title: "同じ画像",duration: 1,byteCount: 1,importedAt: Date(),sha256: String(repeating:"b",count:64))
        let store = ArtworkStore(directory: root)
        // Extracted metadata tests are independent of the production audio root.
        let parsed = try ArtworkMetadata.container(root.appendingPathComponent(fileName))
        XCTAssertEqual(parsed.0, png)
        XCTAssertEqual(ArtworkMetadata.jpeg(try XCTUnwrap(parsed.0)), jpeg)
        let successA = await store.acquire(a, retry: true, network: false)
        let successB = await store.acquire(b, retry: true, network: false)
        XCTAssertTrue(successA); XCTAssertTrue(successB)
        let urlA = await store.url(for: a.sha256), urlB = await store.url(for: b.sha256)
        XCTAssertEqual(urlA, urlB); XCTAssertNotNil(urlA)
        let reopened = ArtworkStore(directory: root)
        let offline = await reopened.url(for: a.sha256)
        XCTAssertEqual(offline, urlA)
        let missing = Track(id: UUID(),fileName: "missing.opus",title: "画像なし",duration: 1,byteCount: 1,importedAt: Date(),sha256: String(repeating:"c",count:64))
        let unavailable = await store.acquire(missing, retry: true, network: false)
        XCTAssertFalse(unavailable)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(fileName)), Data("fLaC".utf8) + header + picture)
    }
}
