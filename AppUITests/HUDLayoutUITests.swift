import XCTest

/// Drives the real app: every HUD field must follow a drag while layout editing is on,
/// stay put while it is off, and 「恢復預設位置」 must return to the saved default layout.
final class HUDLayoutUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-reset"]
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
        XCTAssertTrue(app.descendants(matching: .any)["previewStage"].waitForExistence(timeout: 10), "preview stage")
    }

    private func field(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["hud.\(id)"]
    }

    /// Centre of an element relative to the preview stage (0...1), unaffected by scrolling.
    private func relativeCenter(of element: XCUIElement, in app: XCUIApplication) -> CGPoint {
        let stage = app.descendants(matching: .any)["previewStage"].frame
        let frame = element.frame
        return CGPoint(x: (frame.midX - stage.minX) / max(1, stage.width),
                       y: (frame.midY - stage.minY) / max(1, stage.height))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    /// Scrolls the page until the element is on screen. The preview is taller than the
    /// space below the header, so its lower fields start off screen. Scrolls by dragging
    /// the left margin, outside the preview, and holds at the end so it does not coast.
    private func bringIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        let topY = window.minY + 140
        let bottomY = window.maxY - 140
        for _ in 0..<5 {
            let midY = element.frame.midY
            if midY >= topY && midY <= bottomY { return }
            let needed = midY - window.midY   // > 0: content has to move up
            let distance = min(abs(needed), bottomY - topY)
            let fromY = needed > 0 ? bottomY : topY
            let toY = needed > 0 ? bottomY - distance : topY + distance
            let origin = app.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: 8, dy: fromY))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 8, dy: toY)),
                       withVelocity: .slow, thenHoldForDuration: 0.3)
        }
    }

    private func drag(_ element: XCUIElement, dx: CGFloat, dy: CGFloat) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: dx, dy: dy)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    /// Drags each field and checks it moved; records every result (and a screenshot for
    /// failures) instead of stopping at the first one.
    private func assertEveryFieldMoves(_ ids: [String], in app: XCUIApplication) {
        continueAfterFailure = true
        let stage = app.descendants(matching: .any)["previewStage"]
        for id in ids {
            let item = field(id, in: app)
            XCTAssertTrue(item.waitForExistence(timeout: 5), "\(id) exists")
            bringIntoView(item, in: app)
            let stageBefore = stage.frame
            let frameBefore = item.frame
            let before = relativeCenter(of: item, in: app)
            drag(item, dx: 20, dy: -24)
            let after = relativeCenter(of: item, in: app)
            let moved = distance(before, after)
            print("[ui-test] \(id): frame \(frameBefore) -> \(item.frame), stage \(stageBefore) -> \(stage.frame), moved \(moved)")
            if moved <= 0.02 {
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "drag-failed-\(id)"
                shot.lifetime = .keepAlways
                add(shot)
            }
            XCTAssertGreaterThan(moved, 0.02, "\(id) should follow the drag (moved \(moved))")
        }
    }

    func testEveryDepthHUDFieldCanBeDragged() {
        let app = launch()
        enter("深度潛水", in: app)
        assertEveryFieldMoves(["depthValue", "depthUnit", "elapsedValue", "elapsedLabel", "tempValue", "tempLabel",
                               "speedValue", "speedLabel", "identityGroup", "profileBlock"], in: app)
    }

    func testEveryPoolHUDFieldCanBeDragged() {
        let app = launch()
        enter("泳池平潛", in: app)
        assertEveryFieldMoves(["distanceValue", "distanceUnit", "elapsedValue", "elapsedLabel", "lapValue", "lapLabel",
                               "speedValue", "speedLabel", "identityGroup", "footerBrand", "profileBlock"], in: app)
    }

    func testLayoutOffKeepsFieldsInPlaceAndSwitchStaysInSync() {
        let app = launch()
        enter("深度潛水", in: app)
        let freeToggle = app.switches["layout.freeToggle"]
        XCTAssertTrue(freeToggle.waitForExistence(timeout: 5))
        XCTAssertEqual(freeToggle.value as? String, "1", "layout editing starts on")

        app.buttons["layout.toggle"].tap()   // 排版：關
        XCTAssertEqual(freeToggle.value as? String, "0", "02 switch follows the preview button")

        let item = field("elapsedValue", in: app)
        let before = relativeCenter(of: item, in: app)
        drag(item, dx: 30, dy: -30)
        XCTAssertLessThan(distance(before, relativeCenter(of: item, in: app)), 0.01, "fields stay put when layout is off")
    }

    func testSavedDefaultLayoutIsRestored() {
        let app = launch()
        enter("深度潛水", in: app)
        let item = field("tempValue", in: app)
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        drag(item, dx: -40, dy: 40)
        let saved = relativeCenter(of: item, in: app)

        app.buttons["layout.saveDefault"].tap()
        let confirm = app.buttons["設為預設"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        drag(item, dx: 30, dy: -60)
        XCTAssertGreaterThan(distance(saved, relativeCenter(of: item, in: app)), 0.03)

        let restore = app.buttons["恢復預設位置"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.tap()
        XCTAssertLessThan(distance(saved, relativeCenter(of: item, in: app)), 0.015, "restored to the saved default")
    }

    func testPoolModeOpensAndModeSwitchReturnsToPicker() {
        let app = launch()
        enter("泳池平潛", in: app)
        XCTAssertTrue(app.buttons["ai.analyze"].exists)
        app.buttons["目前為泳池平潛模式，點一下切換模式"].tap()
        let back = app.buttons["回到模式選擇"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.buttons["進入深度潛水模式"].waitForExistence(timeout: 5))
    }
}
