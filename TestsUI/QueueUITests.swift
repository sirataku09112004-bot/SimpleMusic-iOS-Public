import XCTest

final class QueueUITests: XCTestCase {
    private func dismissDeletionConfirmation(_ app: XCUIApplication) {
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["キャンセル", "Cancel"])).firstMatch
        if cancel.waitForExistence(timeout: 2) {
            cancel.tap()
        } else {
            // iOS 27 may omit the cancel row in a confirmation popover.
            // Dismiss its backdrop, then assert below that no song was deleted.
            print("DELETE_CONFIRMATION_BEFORE_DISMISS\\n" + app.debugDescription)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        }
    }
    func testBulkSelectionCancelThenDeleteAllThroughMenu() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-library"]
        app.launch()
        XCTAssertTrue(app.sliders["再生位置"].waitForExistence(timeout: 15))
        app.buttons["メニュー"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["曲をまとめて削除"].tap()
        let delete = app.buttons["bulk-delete-selected"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled)
        app.buttons["bulk-row-UI曲1"].tap()
        app.buttons["bulk-row-UI曲3"].tap()
        XCTAssertTrue(app.staticTexts["選択中 2曲 / 全3曲"].exists)
        delete.tap()
        XCTAssertTrue(app.buttons["bulk-confirm-delete"].firstMatch.waitForExistence(timeout: 5))
        dismissDeletionConfirmation(app)
        XCTAssertTrue(app.buttons["bulk-row-UI曲1"].exists)
        app.buttons["bulk-select-all"].tap()
        XCTAssertTrue(app.staticTexts["選択中 3曲 / 全3曲"].exists)
        delete.tap(); app.buttons["bulk-confirm-delete"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["選択中 0曲 / 全0曲"].waitForExistence(timeout: 10))
        XCTAssertFalse(delete.isEnabled)
        app.buttons["閉じる"].tap()
        XCTAssertTrue(app.staticTexts["音楽を追加しましょう"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.sliders["再生位置"].exists)
        app.terminate()
    }
    func testNormalizationSettingsAnalyzeAndPersistWithoutResumingPausedPlayback() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-library"]
        app.launch()
        let slider = app.sliders["再生位置"]
        XCTAssertTrue(slider.waitForExistence(timeout: 15))
        slider.adjust(toNormalizedSliderPosition: 0.6)
        app.buttons["メニュー"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["音量正規化"].tap()
        let toggle = app.switches["normalization-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        app.buttons["analyze-loudness"].tap()
        XCTAssertTrue(app.staticTexts["解析完了（3曲）"].waitForExistence(timeout: 15))
        if (toggle.value as? String) != "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed, app.debugDescription)
        app.buttons["閉じる"].tap()
        XCTAssertTrue(app.buttons["再生"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["0:01"].firstMatch.exists)
        app.terminate()
        app.launchArguments = ["-ui-test-library", "-ui-test-preserve-position"]
        app.launch()
        XCTAssertTrue(app.buttons["メニュー"].waitForExistence(timeout: 15))
        app.buttons["メニュー"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap(); app.buttons["音量正規化"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "1")
        if (toggle.value as? String) == "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        } // Leave the app's default off for the other UI checks.
        app.terminate()
    }
    func testLibrarySearchFiltersRowsAndShowsNoResults() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-library"]
        app.launch()
        XCTAssertTrue(app.otherElements["library-row-UI曲2"].firstMatch.waitForExistence(timeout: 15))
        app.swipeDown()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("UI曲2")
        XCTAssertTrue(app.otherElements["library-row-UI曲2"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["library-row-UI曲3"].firstMatch.exists)
        search.typeText("存在しない曲")
        XCTAssertTrue(app.staticTexts["検索結果がありません"].waitForExistence(timeout: 5))
        app.terminate()
    }
    func testSeekWhilePausedChangesDisplayedPosition() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-library"]
        app.launch()
        let slider = app.sliders["再生位置"]
        XCTAssertTrue(slider.waitForExistence(timeout: 15))
        slider.adjust(toNormalizedSliderPosition: 0.6)
        XCTAssertTrue(app.staticTexts["0:01"].firstMatch.waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["-ui-test-library", "-ui-test-preserve-position"]
        app.launch()
        XCTAssertTrue(app.staticTexts["0:01"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["再生"].firstMatch.exists, "Relaunch must remain paused")
        app.terminate()
    }
    func testRightSwipeDeletionRequiresConfirmation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-library"]
        app.launch()
        let row = app.otherElements["library-row-UI曲1"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        // Rows exist in the accessibility tree before they clear the bottom player.
        // Bring the song section into view before performing its horizontal gesture.
        app.swipeUp()
        row.swipeRight()
        let remove = app.buttons["library-delete-UI曲1"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        let confirm = app.buttons["confirm-library-delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        dismissDeletionConfirmation(app)
        XCTAssertTrue(app.staticTexts["UI曲1"].firstMatch.exists)
        row.swipeRight()
        remove.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["UI曲1"].firstMatch)
        wait(for: [gone], timeout: 5)
        XCTAssertTrue(app.staticTexts["UI曲2"].firstMatch.exists)
        app.terminate()
    }
    func testEditToggleStaysStableAndRowActionsAreIndependent() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-library"]
        app.launch()
        let open = app.buttons["open-queue"]
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        let rowReady = app.staticTexts["UI曲1"].firstMatch
        XCTAssertTrue(rowReady.waitForExistence(timeout: 15))
        open.tap()
        let edit = app.buttons["queue-edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        XCTAssertEqual(edit.label, "編集")
        for _ in 0..<3 {
            edit.tap()
            XCTAssertEqual(edit.label, "完了")
            let flip = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "編集"), object: edit)
            flip.isInverted = true
            wait(for: [flip], timeout: 1.5)
            XCTAssertTrue(app.buttons["queue-down-UI曲1"].exists)
            XCTAssertFalse(app.buttons["queue-play-UI曲1"].exists)
            edit.tap()
            XCTAssertEqual(edit.label, "編集")
        }
        edit.tap()
        app.buttons["queue-up-UI曲3"].tap()
        XCTAssertEqual(edit.label, "完了")
        XCTAssertFalse(app.buttons["queue-remove-UI曲1"].isEnabled)
        app.buttons["queue-remove-UI曲2"].tap()
        XCTAssertFalse(app.buttons["queue-remove-UI曲2"].exists)
        XCTAssertTrue(app.buttons["queue-remove-UI曲3"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Queue editing after independent move and delete"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        edit.tap()
        XCTAssertEqual(edit.label, "編集")
        app.buttons["閉じる"].tap()
        XCTAssertTrue(app.staticTexts["UI曲2"].exists, "Queue deletion must retain library audio")
    }
}
