import XCTest

final class ControlLaunchUITests: XCTestCase {
    func testColdAndWarmURLRequestsStartExistingWeightedShuffle() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-library"]
        app.launch()
        XCTAssertTrue(app.sliders["再生位置"].waitForExistence(timeout:15))
        let repeatButton = app.buttons["player-repeat"]
        for _ in 0..<3 { if repeatButton.label == "全曲リピート" { break }; repeatButton.tap() }
        XCTAssertEqual(repeatButton.label,"全曲リピート")
        app.terminate()
        // The fixture and queue are already persisted. Launch through the OS URL
        // resolver, as Shortcuts does, rather than XCTest's special app launcher.
        app.launchArguments = []
        XCUIDevice.shared.system.open(URL(string:"simplemusic://shuffle")!)
        guard app.buttons["一時停止"].firstMatch.waitForExistence(timeout:15) else {
            XCTFail("Cold shuffle did not start: " + app.debugDescription); return
        }
        Thread.sleep(forTimeInterval:2.2)
        app.buttons["一時停止"].firstMatch.tap()
        XCUIDevice.shared.system.open(URL(string:"simplemusic://shuffle")!)
        // Rapid duplicate activation must not restart or build a second engine.
        XCUIDevice.shared.system.open(URL(string:"simplemusic://shuffle")!)
        XCTAssertTrue(app.buttons["一時停止"].firstMatch.waitForExistence(timeout:10))
        app.terminate()
    }
}

