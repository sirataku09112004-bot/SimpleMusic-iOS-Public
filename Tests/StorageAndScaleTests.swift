import XCTest
@testable import SimpleMusic

final class StorageAndScaleTests: XCTestCase {
    func test265OriginalShortAudioFilesImportAndReloadWithoutDependingOnSources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let sourceFolder = root.appendingPathComponent("sources",isDirectory:true)
        let appFolder = root.appendingPathComponent("application",isDirectory:true)
        try FileManager.default.createDirectory(at:sourceFolder,withIntermediateDirectories:true)
        let fixture = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
        let original = try Data(contentsOf:fixture)
        var urls: [URL] = []
        for number in 1...265 {
            var bytes = original
            bytes[bytes.count - 1] ^= UInt8((number >> 8) & 255)
            bytes[bytes.count - 2] ^= UInt8(number & 255)
            let url = sourceFolder.appendingPathComponent("曲\(number).wav")
            try bytes.write(to:url); urls.append(url)
        }
        let store = LibraryStore(directory:appFolder,publicMusic:true)
        let report = try await store.importFiles(urls)
        XCTAssertEqual(report.added,265,report.failures.joined(separator:"\n"))
        XCTAssertEqual(Set(report.tracks.map(\.sha256)).count,265)
        try FileManager.default.removeItem(at:sourceFolder)
        let reopened = try await LibraryStore(directory:appFolder,publicMusic:true).load()
        XCTAssertEqual(reopened.count,265)
        let summary = StorageDiagnostics.inspect(tracks:reopened,directory:appFolder)
        XCTAssertEqual(summary.found,265); XCTAssertEqual(summary.missing,0)
        XCTAssertEqual(summary.publicFiles,265)
        XCTAssertEqual(summary.logicalBytes,Int64(original.count * 265))
    }
    @MainActor
    func testMissingPublishedFileReimportRepairsIDAndRetainsFavoritesCounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"fixture",withExtension:"wav"))
        let store = LibraryStore(directory:root,publicMusic:true)
        let report = try await store.importFiles([source])
        let song = try XCTUnwrap(report.tracks.first)
        let preferences = PlaybackPreferences(directory:root)
        preferences.toggleFavorite(song); preferences.recordStart(song)
        let renamed = song.audioURL(in:root).deletingLastPathComponent().appendingPathComponent("renamed.wav")
        try FileManager.default.moveItem(at:song.audioURL(in:root),to:renamed)
        let movedFolder = renamed.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("KeptMusic",isDirectory:true)
        try FileManager.default.moveItem(at:renamed.deletingLastPathComponent(),to:movedFolder)
        let movedSource = movedFolder.appendingPathComponent(renamed.lastPathComponent)
        let summary = StorageDiagnostics.inspect(tracks:report.tracks,directory:root)
        XCTAssertEqual(summary.missing,1)
        let repaired = try await store.importFiles([movedSource])
        XCTAssertEqual(repaired.tracks.count,1); XCTAssertEqual(repaired.added,1)
        let restored = try XCTUnwrap(repaired.tracks.first)
        XCTAssertEqual(restored.id,song.id); XCTAssertTrue(preferences.isFavorite(restored))
        XCTAssertEqual(preferences.count(for:restored),1)
        XCTAssertTrue(FileManager.default.fileExists(atPath:restored.audioURL(in:root).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:movedSource.path))
    }
}

