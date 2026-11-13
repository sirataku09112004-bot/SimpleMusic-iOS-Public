import XCTest

final class NativeControlUITests: XCTestCase {
    func testNativeControlCenterLaunchesApp() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-library"]
        app.launch()
        XCTAssertTrue(app.sliders["再生位置"].waitForExistence(timeout:15))
        let repeatButton = app.buttons["player-repeat"]
        for _ in 0..<3 { if repeatButton.label == "全曲リピート" { break }; repeatButton.tap() }
        app.terminate()
        XCUIDevice.shared.press(.home)
        let system = XCUIApplication(bundleIdentifier:"com.apple.springboard")
        let from = system.coordinate(withNormalizedOffset:CGVector(dx:0.97,dy:0.01))
        let to = system.coordinate(withNormalizedOffset:CGVector(dx:0.97,dy:0.7))
        from.press(forDuration:0.1,thenDragTo:to)
        print("CONTROL_CENTER_INITIAL\n" + system.debugDescription)
        let add = system.buttons.matching(NSPredicate(format:"label IN %@", ["Add Controls","Add a Control","コントロールを追加"])).firstMatch
        guard add.waitForExistence(timeout:5) else {
            XCTFail("Cannot locate control gallery entry: " + system.debugDescription); return
        }
        add.tap()
        // The top-left plus enters editing; the bottom button opens the gallery.
        let gallery = system.buttons["Add a Control"]
        if gallery.waitForExistence(timeout:3) { gallery.tap() }
        print("CONTROL_GALLERY\n" + system.debugDescription)
        if let search = system.searchFields.allElementsBoundByIndex.first {
            search.tap(); search.typeText("SimpleMusic")
        }
        let control = system.descendants(matching:.any).matching(NSPredicate(format:"label == %@","SimpleMusic シャッフル再生")).firstMatch
        guard control.waitForExistence(timeout:10) else {
            XCTFail("Native control not discoverable: " + system.debugDescription); return
        }
        control.tap()
        print("CONTROL_ADDED\n" + system.debugDescription)
        let done = system.buttons.matching(NSPredicate(format:"label IN %@",["Done","完了"])).firstMatch
        if done.exists { done.tap() }
        else { system.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.08)).tap() }
        let launch = system.buttons.matching(NSPredicate(format:"label CONTAINS %@","SimpleMusic")).firstMatch
        guard launch.waitForExistence(timeout:5) else {
            XCTFail("Native control button not found: " + system.debugDescription); return
        }
        launch.tap()
        guard app.wait(for:.runningForeground,timeout:30) else {
            XCTFail("Control did not open app: " + system.debugDescription); return
        }
        XCTAssertTrue(app.buttons["一時停止"].firstMatch.waitForExistence(timeout:10),app.debugDescription)
        // Exercise the same real control with the containing app already alive.
        app.buttons["一時停止"].firstMatch.tap()
        XCUIDevice.shared.press(.home)
        from.press(forDuration:0.1,thenDragTo:to)
        guard launch.waitForExistence(timeout:5) else {
            XCTFail("Installed control disappeared: " + system.debugDescription); return
        }
        launch.tap()
        XCTAssertTrue(app.wait(for:.runningForeground,timeout:30))
        XCTAssertTrue(app.buttons["一時停止"].firstMatch.waitForExistence(timeout:10),app.debugDescription)
        app.terminate()
    }
}
