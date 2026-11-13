import XCTest
import AppIntents
@testable import SimpleMusic

final class ControlShuffleTests: XCTestCase {
    @available(iOS 18.0, *)
    func testControlIsDiscoverableForegroundAudioAction() {
        func requiresAudioIntent<T: AudioPlaybackIntent>(_ intent: T) {}
        requiresAudioIntent(ControlShuffleIntent())
        XCTAssertTrue(ControlShuffleIntent.isDiscoverable)
        XCTAssertTrue(ControlShuffleIntent.openAppWhenRun)
    }
    @available(iOS 27.0, *)
    func testAudioControlAndLegacyOpenActionExecuteOnlyInMainApp() {
        XCTAssertEqual(ControlShuffleIntent.allowedExecutionTargets, .main)
        XCTAssertEqual(ShufflePlaybackIntent.allowedExecutionTargets, .main)
    }
    @MainActor
    func testIntentReceiptPersistsWithoutCreatingPlaybackRequest() throws {
        let suite = "control-receipt-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let requests = ControlRequests(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1000)
        requests.recordAppIntent(now: now)
        XCTAssertEqual(ControlRequests(defaults: defaults).lastAppIntentDate, now)
        XCTAssertFalse(requests.consume(now: now))
    }
    @available(iOS 18.0, *)
    func testControlIntentExplicitlyOpensAppWithFixedShuffleTarget() {
        func requiresOpenIntent<T: OpenIntent>(_ intent: T) {}
        let intent = ShufflePlaybackIntent()
        requiresOpenIntent(intent)
        XCTAssertEqual(intent.target, .shuffle)
        XCTAssertTrue(ShufflePlaybackIntent.openAppWhenRun)
    }
    @MainActor
    func testColdPendingRequestSurvivesRecreationAndOnlyConsumesOnce() throws {
        let suite = "controls-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName:suite))
        defer { defaults.removePersistentDomain(forName:suite) }
        let date = Date(timeIntervalSince1970:1000)
        let first = ControlRequests(defaults:defaults)
        XCTAssertTrue(first.submit(now:date))
        XCTAssertFalse(first.submit(now:date.addingTimeInterval(0.1)))
        let recreated = ControlRequests(defaults:defaults)
        XCTAssertTrue(recreated.consume(now:date.addingTimeInterval(1)))
        XCTAssertFalse(recreated.consume(now:date.addingTimeInterval(1)))
        XCTAssertFalse(recreated.submit(now:date.addingTimeInterval(1.5)))
        XCTAssertTrue(recreated.submit(now:date.addingTimeInterval(3)))
        XCTAssertFalse(recreated.consume(now:date.addingTimeInterval(64)))
    }
    func testCurrentQueueMembershipIsPreservedAndEmptyQueueUsesLibrary() {
        func track(_ title: String) -> Track {
            Track(id:UUID(),fileName:title + ".wav",title:title,duration:2,byteCount:1,importedAt:Date(),sha256:title)
        }
        let a = track("A"), b = track("B"), c = track("C")
        XCTAssertEqual(ControlShufflePolicy.targets(library:[a,b,c],queue:[c,a,c]),[c,a])
        XCTAssertEqual(ControlShufflePolicy.targets(library:[a,b,c],queue:[]),[a,b,c])
        XCTAssertTrue(ControlShufflePolicy.targets(library:[],queue:[a]).isEmpty)
        let targets = ControlShufflePolicy.targets(library:[a,b,c],queue:[c,a])
        XCTAssertEqual(Set(WeightedShuffle.order(targets,counts:[a.id:100]).map(\.id)),[a.id,c.id])
    }
}
