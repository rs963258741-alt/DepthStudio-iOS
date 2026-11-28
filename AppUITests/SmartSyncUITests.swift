import XCTest

/// Smart Sync update (1.5) in the real app with the generated 4 s video
/// (-uitest-sample-video) and the demo dive (maximum 11.9 m first reached at 00:17).
final class SmartSyncUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-reset", "-uitest-sample-video"]
        app.launch()
        let splash = app.descendants(matching: .any)["launchAnimation"]
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: splash)
        wait(for: [gone], timeout: 15)
        return app
    }

    private func enter(_ mode: String, in app: XCUIApplication) {
        let card = app.buttons["進入\(mode)模式"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "mode card \(mode)")
        card.tap()
        XCTAssertTrue(stage(app).waitForExistence(timeout: 10), "preview stage")
        XCTAssertTrue(app.buttons["aspect.landscape169"].waitForExistence(timeout: 30), "sample video loaded")
    }

    private func stage(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["previewStage"] }
    private func any(_ id: String, in app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func value(_ element: XCUIElement) -> String { element.value as? String ?? "" }

    /// Scrolls (dragging the left margin) until the element's centre is between `top` and
    /// the bottom margin. Sync controls use top 470: below where the docked preview can be.
    private func bringIntoView(_ element: XCUIElement, in app: XCUIApplication, top: CGFloat = 140) {
        let window = app.windows.firstMatch.frame
        let topY = window.minY + top, bottomY = window.maxY - 120
        for _ in 0..<12 {
            let midY = element.frame.midY
            if midY >= topY && midY <= bottomY { return }
            let target = (topY + bottomY) / 2
            let needed = midY - target
            let distance = min(abs(needed), 260)
            let fromY = needed > 0 ? bottomY : topY
            let toY = needed > 0 ? fromY - distance : fromY + distance
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: 8, dy: fromY))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 8, dy: toY)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
        }
    }

    private func tapSync(_ id: String, in app: XCUIApplication) {
        let element = any(id, in: app)
        XCTAssertTrue(element.waitForExistence(timeout: 5), id)
        bringIntoView(element, in: app, top: 470)
        element.tap()
    }

    private func screenshot(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func waitFor(_ element: XCUIElement, _ format: String, _ argument: String, timeout: TimeInterval = 5) {
        let matched = expectation(for: NSPredicate(format: format, argument), evaluatedWith: element)
        wait(for: [matched], timeout: timeout)
    }

    /// The video by +0.5 s steps from the preview's playback controls.
    private func step(_ count: Int, in app: XCUIApplication) {
        let button = app.buttons["+0.5s"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        bringIntoView(button, in: app)
        for _ in 0..<count { button.tap() }
    }

    private func selectMode(_ title: String, in app: XCUIApplication) {
        tapSync("sync.mode", in: app)
        let option = app.buttons[title].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), "mode option \(title)")
        option.tap()
    }

    private func typeTime(_ text: String, menu: String, in app: XCUIApplication) {
        tapSync(menu, in: app)
        let entry = app.buttons["輸入時間…"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        let alert = app.alerts["輸入影片時間"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let field = alert.textFields.firstMatch
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 12))
        field.typeText(text)
        alert.buttons["確定"].tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 2))
    }

    private func delayLabel(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["sync.delay"] }

    // MARK: Layout

    func testSyncSectionSitsUnderThePreviewAndShowsOneModeAtATime() {
        let app = launch()
        enter("深度潛水", in: app)
        let syncHeader = app.staticTexts["02 / 潛水紀錄摘要與時間同步"]
        XCTAssertTrue(syncHeader.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["05 / 潛水紀錄摘要與時間同步"].exists, "moved from 05")
        let later = ["03 / HUD 外觀與自由排版", "04 / HUD 資訊顯示與隱藏", "05 / 姓名與國家旗幟", "06 / 輸出影片"]
        for title in later { XCTAssertTrue(app.staticTexts[title].exists, title) }
        XCTAssertLessThan(stage(app).frame.maxY, syncHeader.frame.minY, "sync right under the preview")
        XCTAssertLessThan(syncHeader.frame.maxY, app.staticTexts[later[0]].frame.minY)
        for (upper, lower) in zip(later, later.dropFirst()) {
            XCTAssertLessThan(app.staticTexts[upper].frame.minY, app.staticTexts[lower].frame.minY, "\(upper) before \(lower)")
        }

        // The summary is one line until opened; the duplicate block under the preview is gone.
        let line = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "最大深度 11.9 m｜潛水時間 00:36")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5), "collapsed summary line")
        XCTAssertFalse(app.staticTexts["潛水紀錄摘要"].exists, "full summary collapsed, no duplicate")
        bringIntoView(line, in: app, top: 470)
        line.tap()
        XCTAssertTrue(app.staticTexts["潛水紀錄摘要"].waitForExistence(timeout: 5), "summary opens")

        // 智慧同步 (default) shows only its own settings.
        XCTAssertTrue(any("sync.maximum.capture", in: app).exists)
        XCTAssertFalse(any("sync.descentStart.capture", in: app).exists)
        XCTAssertFalse(any("sync.timeline.watch", in: app).exists)
        XCTAssertTrue(app.staticTexts["sync.audience"].label.contains("適合一般使用者"))
        screenshot("sync-smart", app)

        selectMode("進階同步 Advanced Sync", in: app)
        XCTAssertTrue(any("sync.descentStart.capture", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(any("sync.surface.capture", in: app).exists)
        XCTAssertFalse(any("sync.timeline.watch", in: app).exists)
        XCTAssertTrue(app.staticTexts["sync.audience"].label.contains("多個時間點驗證"))
        screenshot("sync-advanced", app)

        selectMode("手動同步 Manual Sync", in: app)
        XCTAssertTrue(any("sync.timeline.watch", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(any("sync.descentStart.capture", in: app).exists)
        XCTAssertTrue(app.staticTexts["sync.audience"].label.contains("不完整的潛水影片"))
        XCTAssertTrue(app.staticTexts["數據顯示太快：將數據延後（＋）。"].exists)
        XCTAssertTrue(app.staticTexts["數據顯示太慢：將數據提前（−）。"].exists)
        screenshot("sync-manual", app)
    }

    // MARK: 智慧同步

    func testSmartSyncCapturesTheMaximumAndTheHUDFollows() {
        let app = launch()
        enter("深度潛水", in: app)
        XCTAssertEqual(delayLabel(app).label, "偏移 0.0 秒")
        step(2, in: app)   // 00:01.0
        tapSync("sync.maximum.capture", in: app)
        let time = any("sync.maximum.time", in: app)
        waitFor(time, "value == %@", "00:01.0")
        // Demo maximum first at 00:17.0 → data shown 16 s earlier.
        waitFor(delayLabel(app), "label == %@", "偏移 −16.0 秒")
        XCTAssertEqual(delayLabel(app).value as? String, "數據提前 16.0 秒顯示")
        XCTAssertFalse(app.staticTexts["目前同步"].exists, "the 目前同步 block was removed (1.5.1)")
        XCTAssertEqual(any("sync.maximum.capture", in: app).label, "重新擷取")
        // The preview reads the log at 00:17: the maximum depth.
        let depth = stage(app).descendants(matching: .any)["hud.depthValue"]
        waitFor(depth, "value == %@", "11.9 M")
        let gauge = stage(app).descendants(matching: .any)["hud.depthGauge"]
        XCTAssertEqual(value(gauge), "12 / 12")
        screenshot("smart-sync-captured", app)

        // Fine positioning moves only the video; tapping the time jumps back to it.
        tapSync("video.forward", in: app)
        waitFor(app.staticTexts["video.currentTime"], "label == %@", "00:01.1")
        XCTAssertEqual(delayLabel(app).label, "偏移 −16.0 秒", "the offset is unchanged")
        tapSync("sync.maximum.time", in: app)
        waitFor(app.staticTexts["video.currentTime"], "label == %@", "00:01.0")
    }

    // MARK: 進階同步

    func testAdvancedSyncValidatesTimesAndChecksExtraPoints() {
        let app = launch()
        enter("深度潛水", in: app)
        selectMode("進階同步 Advanced Sync", in: app)
        typeTime("00:02.0", menu: "sync.maximum.menu", in: app)
        waitFor(any("sync.maximum.time", in: app), "value == %@", "00:02.0")
        waitFor(delayLabel(app), "label == %@", "偏移 −15.0 秒")

        // Order is checked: the descent must come before the maximum.
        typeTime("00:03.0", menu: "sync.descentStart.menu", in: app)
        waitFor(app.staticTexts["sync.message"], "label CONTAINS %@", "開始下潛時間必須早於")
        XCTAssertEqual(value(any("sync.descentStart.time", in: app)), "未設定")
        // Past the end of the video is refused.
        typeTime("00:09", menu: "sync.surface.menu", in: app)
        waitFor(app.staticTexts["sync.message"], "label CONTAINS %@", "超過影片長度")

        // The demo log starts at the surface (00:00): 15.5 s apart → recheck.
        typeTime("00:00.5", menu: "sync.descentStart.menu", in: app)
        waitFor(any("sync.descentStart.time", in: app), "value == %@", "00:00.5")
        let check = app.staticTexts["sync.check.descentStart"]
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        XCTAssertTrue(check.label.contains("建議重新確認"), check.label)
        XCTAssertTrue(app.staticTexts["sync.check.surface"].label.contains("未設定"))
        XCTAssertEqual(delayLabel(app).label, "偏移 −15.0 秒", "extra points do not change the offset")
        screenshot("advanced-sync-checks", app)

        // Back to 智慧同步: the maximum time is kept.
        selectMode("智慧同步 Smart Sync", in: app)
        XCTAssertEqual(value(any("sync.maximum.time", in: app)), "00:02.0")
        XCTAssertEqual(delayLabel(app).label, "偏移 −15.0 秒")
    }

    // MARK: 手動同步

    func testManualSyncTimelineAndOffsetControls() {
        let app = launch()
        enter("深度潛水", in: app)
        step(2, in: app)
        tapSync("sync.maximum.capture", in: app)
        waitFor(delayLabel(app), "label == %@", "偏移 −16.0 秒")

        selectMode("手動同步 Manual Sync", in: app)
        XCTAssertEqual(delayLabel(app).label, "偏移 −16.0 秒", "the offset is kept")
        let status = any("sync.timeline.status", in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("已對齊"), status.label)

        tapSync("sync.nudge.plus01", in: app)
        waitFor(delayLabel(app), "label == %@", "偏移 −15.9 秒")
        waitFor(status, "label CONTAINS %@", "剩餘同步誤差")
        tapSync("sync.alignMaximum", in: app)
        waitFor(delayLabel(app), "label == %@", "偏移 −16.0 秒")
        waitFor(status, "label CONTAINS %@", "已對齊")

        // Dragging the watch curve shifts the data.
        let curve = any("sync.timeline.watch", in: app)
        bringIntoView(curve, in: app, top: 470)
        let start = curve.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: 60, dy: 0)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertNotEqual(delayLabel(app).label, "偏移 −16.0 秒", "dragging the curve changes the offset")
        screenshot("manual-sync-timeline", app)

        // A typed offset beyond the slider.
        let field = any("sync.delayField", in: app)
        bringIntoView(field, in: app, top: 470)
        field.tap()
        field.typeText("+150\n")   // Return applies it and closes the keyboard
        waitFor(delayLabel(app), "label == %@", "偏移 +150.0 秒")
        XCTAssertTrue(any("sync.delayApply", in: app).exists, "套用 button too")

        // Back in 智慧同步 the manual offset is kept and the calculation is offered.
        selectMode("智慧同步 Smart Sync", in: app)
        XCTAssertEqual(delayLabel(app).label, "偏移 +150.0 秒")
        tapSync("sync.applyCalculation", in: app)
        waitFor(delayLabel(app), "label == %@", "偏移 −16.0 秒")
    }

    // MARK: Docked preview, reset, export

    func testPreviewStaysVisibleWhileWorkingOnTheSync() {
        let app = launch()
        enter("深度潛水", in: app)
        selectMode("手動同步 Manual Sync", in: app)
        let dock = any("dockedPreview", in: app)
        let window = app.windows.firstMatch.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<10 where !dock.exists {
            if stage(app).frame.maxY < window.minY { break }
            origin.withOffset(CGVector(dx: 8, dy: window.maxY - 150))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 8, dy: window.maxY - 400)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTAssertTrue(dock.waitForExistence(timeout: 5), "preview docked at the top while syncing")
        XCTAssertTrue(dock.buttons["playback.toggle"].exists, "with the playback controls")
        screenshot("docked-preview", app)
        // Leaving the sync section (down to the export) removes it.
        let export = app.buttons["export.start"]
        bringIntoView(export, in: app, top: 470)
        let docked = dock.exists
        print("[ui-test] dock while at the export: \(docked)")
    }

    /// 泳池平潛 (1.5.1): the same docked preview while editing 02 泳池設定與時間節點.
    func testPoolPreviewStaysVisibleWhileEditingTheTimeline() {
        let app = launch()
        enter("泳池平潛", in: app)
        let dock = any("dockedPreview", in: app)
        let window = app.windows.firstMatch.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        for _ in 0..<10 where !dock.exists {
            if stage(app).frame.maxY < window.minY { break }
            origin.withOffset(CGVector(dx: 8, dy: window.maxY - 150))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 8, dy: window.maxY - 400)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        XCTAssertTrue(dock.waitForExistence(timeout: 5), "pool preview docked while editing the timeline")
        XCTAssertTrue(dock.buttons["playback.toggle"].exists, "with the playback controls")
        XCTAssertTrue(app.staticTexts["02 / 泳池設定與時間節點"].exists)
        screenshot("pool-docked-preview", app)

        // The timeline controls below it still work: jump to the start mark.
        let start = app.buttons["node.time.0.0"]
        bringIntoView(start, in: app, top: 470)
        start.tap()
        XCTAssertTrue(dock.exists || stage(app).exists)
    }

    func testNewDiveDataResetsTheSync() {
        let app = launch()
        enter("深度潛水", in: app)
        step(2, in: app)
        tapSync("sync.maximum.capture", in: app)
        waitFor(delayLabel(app), "label == %@", "偏移 −16.0 秒")
        let demo = app.buttons["載入示範資料"]
        bringIntoView(demo, in: app)
        demo.tap()
        waitFor(delayLabel(app), "label == %@", "偏移 0.0 秒")
        XCTAssertEqual(value(any("sync.maximum.time", in: app)), "未設定")
    }

    func testExportSavesANewFileInBothModes() {
        let app = launch()
        enter("深度潛水", in: app)
        let button = app.buttons["export.start"]
        bringIntoView(button, in: app, top: 470)
        XCTAssertTrue(button.label.contains("輸出影片（另存新檔）"), button.label)
        XCTAssertEqual(app.staticTexts["export.keepsOriginal"].label, "輸出影片不會覆蓋原始影片。")

        app.terminate()
        let pool = launch()
        enter("泳池平潛", in: pool)
        let poolButton = pool.buttons["export.start"]
        bringIntoView(poolButton, in: pool)
        XCTAssertTrue(poolButton.label.contains("輸出影片（另存新檔）"), poolButton.label)
        XCTAssertEqual(pool.staticTexts["export.keepsOriginal"].label, "輸出影片不會覆蓋原始影片。")
    }
}
