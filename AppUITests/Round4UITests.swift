import XCTest

/// Fourth-round changes in the real app (generated 4 s video, launch argument
/// -uitest-sample-video): the unit is fixed to the live depth / distance value, the
/// vertical depth gauge follows the depth and has its own show/hide switch, and typed pool
/// times are applied to the right point, refused past the end of the video, and the pool
/// HUD values move with the video time.
final class Round4UITests: XCTestCase {
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

    private func field(_ id: String, in app: XCUIApplication) -> XCUIElement {
        stage(app).descendants(matching: .any)["hud.\(id)"]
    }

    private func value(_ element: XCUIElement) -> String { element.value as? String ?? "" }

    /// Scrolls the page (dragging the left margin) until the element is on screen.
    /// `top` 470 keeps controls of the timeline / sync section below the docked preview.
    private func bringIntoView(_ element: XCUIElement, in app: XCUIApplication, top: CGFloat = 140) {
        let window = app.windows.firstMatch.frame
        let topY = window.minY + top, bottomY = window.maxY - 140
        for _ in 0..<10 {
            let midY = element.frame.midY
            if midY >= topY && midY <= bottomY { return }
            let needed = midY - (topY + bottomY) / 2
            let distance = min(abs(needed), bottomY - topY)
            let fromY = needed > 0 ? bottomY : topY
            let toY = needed > 0 ? bottomY - distance : topY + distance
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: 8, dy: fromY))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 8, dy: toY)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
        }
    }

    private func screenshot(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Steps the video by +0.5 s `count` times (the step pauses and seeks).
    private func step(_ count: Int, in app: XCUIApplication) {
        let button = app.buttons["+0.5s"].firstMatch   // the docked preview has the same buttons
        XCTAssertTrue(button.waitForExistence(timeout: 5), "+0.5 s step")
        bringIntoView(button, in: app)
        for _ in 0..<count { button.tap() }
    }

    private func waitForValue(of element: XCUIElement, _ predicate: String, _ argument: String, timeout: TimeInterval = 5) {
        let matched = expectation(for: NSPredicate(format: predicate, argument), evaluatedWith: element)
        wait(for: [matched], timeout: timeout)
    }

    // MARK: Depth

    func testDepthUnitIsFixedToTheDepthValue() {
        let app = launch()
        enter("深度潛水", in: app)
        XCTAssertFalse(app.descendants(matching: .any)["hud.depthUnit"].exists, "no separate unit field")
        step(2, in: app)   // 1.0 s: inside the demo dive
        let depth = field("depthValue", in: app)
        XCTAssertTrue(depth.waitForExistence(timeout: 5))
        waitForValue(of: depth, "value ENDSWITH %@", " M")
        let first = value(depth)
        step(4, in: app)   // 3.0 s
        waitForValue(of: depth, "value != %@", first)
        XCTAssertTrue(value(depth).hasSuffix(" M"), value(depth))
        screenshot("depth-value-with-unit", app)

        // The 03 list has no 深度單位 switch any more.
        let header = app.staticTexts["04 / HUD 資訊顯示與隱藏"]
        bringIntoView(header, in: app)
        header.tap()
        XCTAssertTrue(app.switches["visibility.depthValue"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["visibility.depthUnit"].exists)
    }

    func testDepthGaugeFollowsTheDepthAndHasItsOwnSwitch() {
        let app = launch()
        enter("深度潛水", in: app)
        let gauge = field("depthGauge", in: app)
        XCTAssertTrue(gauge.waitForExistence(timeout: 5), "gauge shown by default")
        step(1, in: app)   // 0.5 s: about 1 m
        waitForValue(of: gauge, "value ENDSWITH %@", "/ 12")   // the demo dive's maximum is 11.9 m
        let shallow = value(gauge)
        step(5, in: app)   // 3.0 s: about 3 m
        waitForValue(of: gauge, "value != %@", shallow)
        print("[ui-test] gauge \(shallow) -> \(value(gauge))")
        XCTAssertTrue(value(gauge).hasPrefix("3 /"), value(gauge))
        bringIntoView(stage(app), in: app)
        screenshot("depth-gauge", app)

        let header = app.staticTexts["04 / HUD 資訊顯示與隱藏"]
        bringIntoView(header, in: app)
        header.tap()
        let toggle = app.switches["visibility.depthGauge"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "垂直深度指示計 switch in 03")
        XCTAssertEqual(toggle.label, "垂直深度指示計")
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        waitForValue(of: toggle, "value == %@", "0")
        let hidden = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: gauge)
        wait(for: [hidden], timeout: 5)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(gauge.waitForExistence(timeout: 5), "shown again")
    }

    // MARK: Pool

    private func typeTime(_ text: String, forNode distance: String, in app: XCUIApplication) {
        let menu = app.buttons["node.menu.\(distance)"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "menu of \(distance) m")
        bringIntoView(menu, in: app, top: 470)
        menu.tap()
        let entry = app.buttons["輸入時間…"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        let alert = app.alerts["輸入影片時間"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        let textField = alert.textFields.firstMatch
        XCTAssertTrue(textField.waitForExistence(timeout: 5))
        textField.tap()
        textField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 14))
        textField.typeText(text)
        alert.buttons["確定"].tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 2))
    }

    func testTypedPoolTimesAreAppliedAndTheHUDMoves() {
        let app = launch()
        enter("泳池平潛", in: app)
        let start = app.buttons["node.time.0.0"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        waitForValue(of: start, "value == %@", "00:00.3")   // marked by the sample setup

        // ":" typed instead of "." — read as 0.50 s because 50 s is past the 4 s video.
        typeTime("00:00:50", forNode: "0.0", in: app)
        waitForValue(of: start, "value == %@", "00:00.5")

        // A time past the end of the video is refused with a message.
        let finish = app.buttons["node.time.150.0"]
        let finishBefore = value(finish)
        typeTime("00:09", forNode: "150.0", in: app)
        let refused = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "超過影片長度")).firstMatch
        XCTAssertTrue(refused.waitForExistence(timeout: 5), "past-the-end message")
        XCTAssertEqual(value(finish), finishBefore, "the finish keeps its time")
        XCTAssertFalse(app.descendants(matching: .any)["timeline.warning"].exists, "the marks fit the video")
        screenshot("pool-time-entry", app)

        // The HUD values follow the video time.
        XCTAssertFalse(app.descendants(matching: .any)["hud.distanceUnit"].exists, "no separate unit field")
        step(2, in: app)   // 1.0 s
        let distance = field("distanceValue", in: app)
        let elapsed = field("elapsedValue", in: app)
        XCTAssertTrue(distance.waitForExistence(timeout: 5))
        waitForValue(of: distance, "value ENDSWITH %@", " M")
        let first = value(distance)
        XCTAssertNotEqual(first, "0.0 M", "moving at 1.0 s")
        step(4, in: app)   // 3.0 s: after the finish
        waitForValue(of: distance, "value != %@", first)
        XCTAssertEqual(value(distance), "150.0 M")
        XCTAssertEqual(value(elapsed), "00:02", "02.2 s from 0.5 s to 2.7 s")
        print("[ui-test] pool distance \(first) -> \(value(distance))")
    }
}
