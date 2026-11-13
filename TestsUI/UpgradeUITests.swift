import XCTest

final class UpgradeUITests: XCTestCase {
    func testMenuStaysPresentedDuringPlaybackAndImportIsOnlyInsideMenu() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-library"]
        app.launch()
        XCTAssertTrue(app.sliders["再生位置"].waitForExistence(timeout:15))
        XCTAssertFalse(app.navigationBars.staticTexts["SimpleMusic"].exists)
        XCTAssertFalse(app.buttons["menu-import-music"].exists)
        app.buttons["再生"].firstMatch.tap()
        app.buttons["メニュー"].coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        let menu = app.navigationBars["メニュー"]
        XCTAssertTrue(menu.waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["menu-import-music"].isEnabled)
        let disappear = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:menu)
        disappear.isInverted = true
        wait(for:[disappear],timeout:3)
        XCTAssertTrue(app.buttons["バックアップ・復元"].exists)
        app.buttons["閉じる"].tap()
        XCTAssertFalse(app.buttons["menu-import-music"].exists)
        app.terminate()
    }
    func testRepeatCyclesInPlaceAndBackupAndStatisticsAreAccessible() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-library"]
        app.launch()
        let repeatButton = app.buttons["player-repeat"]
        XCTAssertTrue(repeatButton.waitForExistence(timeout:15))
        // Reach OFF regardless of the mode persisted by an earlier test.
        for _ in 0..<3 { if repeatButton.label == "リピートOFF" { break }; repeatButton.tap() }
        XCTAssertEqual(repeatButton.label,"リピートOFF")
        repeatButton.tap(); XCTAssertEqual(repeatButton.label,"全曲リピート")
        repeatButton.tap(); XCTAssertEqual(repeatButton.label,"1曲リピート")
        repeatButton.tap(); XCTAssertEqual(repeatButton.label,"リピートOFF")
        app.buttons["メニュー"].coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        app.buttons["バックアップ・復元"].tap()
        XCTAssertTrue(app.buttons["バックアップを保存"].waitForExistence(timeout:5))
        XCTAssertTrue(app.buttons["バックアップから復元"].exists)
        app.buttons["閉じる"].tap()
        app.buttons["メニュー"].coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        app.buttons["再生統計"].tap()
        XCTAssertTrue(app.staticTexts["累計再生時間"].waitForExistence(timeout:5))
        let image = XCTAttachment(screenshot:app.screenshot())
        image.name = "Japanese lightweight listening statistics"; image.lifetime = .keepAlways; add(image)
        app.buttons["閉じる"].tap(); app.terminate()
    }
}
