import XCTest

/// Third-round fixes, driven in the real app with a generated video
/// (launch argument -uitest-sample-video): presets 1/2, centre snapping in each output
/// shape, the live proportional floating preview, the AI reminder, the style controls and
/// the source-quality export settings.
final class Round3UITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launch(reset: Bool = true, video: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        if reset { app.launchArguments += ["-uitest-reset"] }
        if video { app.launchArguments += ["-uitest-sample-video"] }
        app.launch()
        let splash = app.descendants(matching: .any)["launchAnimation"]
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: splash)
        wait(for: [gone], timeout: 15)
        return app
    }

    private func enter(_ mode: String, in app: XCUIApplication, waitForVideo: Bool = true) {
        let card = app.buttons["進入\(mode)模式"]
        XCTAssertTrue(card.waitForExistence(timeout: 10), "mode card \(mode)")
        card.tap()
        XCTAssertTrue(stage(app).waitForExistence(timeout: 10), "preview stage")
        if waitForVideo {
            XCTAssertTrue(app.buttons["aspect.landscape169"].waitForExistence(timeout: 30), "sample video loaded")
        }
    }

    private func stage(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["previewStage"] }

    /// A field of the main stage (the floating preview has fields with the same ids).
    private func field(_ id: String, in app: XCUIApplication) -> XCUIElement {
        stage(app).descendants(matching: .any)["hud.\(id)"]
    }

    private func relative(_ element: XCUIElement, in container: XCUIElement) -> CGPoint {
        let box = container.frame, frame = element.frame
        return CGPoint(x: (frame.midX - box.minX) / max(1, box.width), y: (frame.midY - box.minY) / max(1, box.height))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    private func drag(_ element: XCUIElement, dx: CGFloat, dy: CGFloat) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: dx, dy: dy)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    /// Scrolls the page (dragging the left margin) until the element is on screen.
    private func bringIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch.frame
        let topY = window.minY + 140, bottomY = window.maxY - 140
        for _ in 0..<8 {
            let midY = element.frame.midY
            if midY >= topY && midY <= bottomY { return }
            let needed = midY - window.midY
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

    // MARK: Presets

    func testPresetOneAndTwoAreSavedAppliedAndKeptAfterRestart() {
        var app = launch(video: false)
        enter("深度潛水", in: app, waitForVideo: false)
        let item = field("tempValue", in: app)
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["layout.applyPreset1"].isEnabled, "nothing saved yet")

        drag(item, dx: -40, dy: 40)
        let first = relative(item, in: stage(app))
        app.buttons["layout.savePreset1"].tap()
        XCTAssertTrue(app.buttons["設為預設1"].waitForExistence(timeout: 5))
        app.buttons["設為預設1"].tap()

        drag(item, dx: 60, dy: -70)
        let second = relative(item, in: stage(app))
        XCTAssertGreaterThan(distance(first, second), 0.05)
        app.buttons["layout.savePreset2"].tap()
        XCTAssertTrue(app.buttons["設為預設2"].waitForExistence(timeout: 5))
        app.buttons["設為預設2"].tap()

        app.buttons["layout.applyPreset1"].tap()
        XCTAssertLessThan(distance(first, relative(item, in: stage(app))), 0.015, "預設1 applied")
        app.buttons["layout.applyPreset2"].tap()
        XCTAssertLessThan(distance(second, relative(item, in: stage(app))), 0.015, "預設2 applied")

        // After a restart (settings and presets kept), 預設1 still restores its layout.
        app.terminate()
        app = launch(reset: false, video: false)
        enter("深度潛水", in: app, waitForVideo: false)
        let again = field("tempValue", in: app)
        XCTAssertTrue(again.waitForExistence(timeout: 5))
        XCTAssertLessThan(distance(second, relative(again, in: stage(app))), 0.015, "the last layout is kept")
        app.buttons["layout.applyPreset1"].tap()
        XCTAssertLessThan(distance(first, relative(again, in: stage(app))), 0.015, "預設1 after restart")
    }

    func testPoolPresetsWork() {
        let app = launch(video: false)
        enter("泳池平潛", in: app, waitForVideo: false)
        let item = field("lapValue", in: app)
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        drag(item, dx: -50, dy: 50)
        let saved = relative(item, in: stage(app))
        app.buttons["layout.savePreset2"].tap()
        XCTAssertTrue(app.buttons["設為預設2"].waitForExistence(timeout: 5))
        app.buttons["設為預設2"].tap()
        drag(item, dx: 40, dy: -40)
        app.buttons["layout.applyPreset2"].tap()
        XCTAssertLessThan(distance(saved, relative(item, in: stage(app))), 0.015)
    }

    // MARK: Centre snapping in every output shape

    private func assertChartSnapsToCentre(mode: String, in app: XCUIApplication) {
        continueAfterFailure = true
        for aspect in ["original", "landscape169", "square", "portrait45"] {
            let tile = app.buttons["aspect.\(aspect)"]
            bringIntoView(tile, in: app)
            tile.tap()
            let chart = field("profileBlock", in: app)
            XCTAssertTrue(chart.waitForExistence(timeout: 5))
            bringIntoView(chart, in: app)
            let width = stage(app).frame.width
            drag(chart, dx: width * 0.09, dy: 0)
            XCTAssertGreaterThan(abs(chart.frame.midX - stage(app).frame.midX), width * 0.05, "\(mode) \(aspect): moved away")
            drag(chart, dx: -width * 0.075, dy: 0)   // ends about 1.5 % right of the centre
            let offset = chart.frame.midX - stage(app).frame.midX
            print("[ui-test] \(mode) \(aspect): chart centre offset \(offset) pt, stage width \(width)")
            if abs(offset) > 1.5 { screenshot("snap-\(mode)-\(aspect)", app) }
            XCTAssertLessThan(abs(offset), 1.5, "\(mode) \(aspect): the chart snaps to the centre of the image")
            XCTAssertTrue(app.descendants(matching: .any)["snap.centerX"].exists, "\(mode) \(aspect): centre guide shown")
        }
    }

    func testDepthChartSnapsToTheCentreOfEachShape() {
        let app = launch()
        enter("深度潛水", in: app)
        assertChartSnapsToCentre(mode: "depth", in: app)
    }

    func testPoolChartSnapsToTheCentreOfEachShape() {
        let app = launch()
        enter("泳池平潛", in: app)
        assertChartSnapsToCentre(mode: "pool", in: app)
    }

    // MARK: Floating preview

    private func assertFloatingPreviewIsLiveAndProportional(fieldID: String, in app: XCUIApplication) {
        let toggle = app.buttons.matching(identifier: "floatingPreview.toggle").firstMatch
        bringIntoView(toggle, in: app)
        toggle.tap()
        let floating = app.descendants(matching: .any)["floatingPreview.stage"]
        XCTAssertTrue(floating.waitForExistence(timeout: 5), "floating preview shown")
        let small = floating.descendants(matching: .any)["hud.\(fieldID)"]
        XCTAssertTrue(small.waitForExistence(timeout: 5))
        let big = field(fieldID, in: app)

        func compare(_ label: String) {
            let a = relative(big, in: stage(app)), b = relative(small, in: floating)
            let ratioBig = big.frame.width / max(1, stage(app).frame.width)
            let ratioSmall = small.frame.width / max(1, floating.frame.width)
            print("[ui-test] \(label): stage \(a) \(ratioBig), floating \(b) \(ratioSmall)")
            XCTAssertLessThan(distance(a, b), 0.03, "\(label): same place in the floating preview")
            XCTAssertEqual(ratioSmall, ratioBig, accuracy: ratioBig * 0.15, "\(label): same proportions")
        }
        compare("initial")

        // Changes show immediately in the floating preview.
        bringIntoView(big, in: app)
        drag(big, dx: 30, dy: 40)
        compare("after drag")
        let slider = app.sliders["hud.fontScaleSlider"]
        bringIntoView(slider, in: app)
        slider.adjust(toNormalizedSliderPosition: 1.0)
        compare("after font size")
        screenshot("floating-preview", app)
    }

    func testDepthFloatingPreviewIsLiveAndProportional() {
        let app = launch()
        enter("深度潛水", in: app)
        assertFloatingPreviewIsLiveAndProportional(fieldID: "depthValue", in: app)
    }

    func testPoolFloatingPreviewIsLiveAndProportional() {
        let app = launch()
        enter("泳池平潛", in: app)
        // The pool HUD editor (03) starts collapsed.
        let header = app.staticTexts["03 / HUD 外觀與自由排版"]
        bringIntoView(header, in: app)
        header.tap()
        XCTAssertTrue(app.sliders["hud.fontScaleSlider"].waitForExistence(timeout: 5), "section 03 expanded")
        assertFloatingPreviewIsLiveAndProportional(fieldID: "distanceValue", in: app)
    }

    // MARK: AI reminder

    func testAIReminderIsShownBeforeTheAnalysis() {
        let app = launch()
        enter("泳池平潛", in: app)
        let analyze = app.buttons["ai.analyze"]
        bringIntoView(analyze, in: app)
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: analyze)
        wait(for: [enabled], timeout: 15)
        analyze.tap()
        let alert = app.alerts["AI 即時速率提醒"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "reminder shown")
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "容易受到影片中移動的物體干擾")).firstMatch.exists)
        screenshot("ai-reminder", app)
        alert.buttons["取消"].tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 2))
        XCTAssertEqual(analyze.label, "開始分析", "cancel does not start the analysis")
        analyze.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["開始分析"].tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 2))
    }

    // MARK: Style controls and export settings

    func testStyleControlsChangeTheSelectedField() {
        let app = launch(video: false)
        enter("深度潛水", in: app, waitForVideo: false)
        field("speedValue", in: app).tap()   // select
        let shadow = app.sliders["style.shadow"]
        bringIntoView(shadow, in: app)
        XCTAssertTrue(app.descendants(matching: .any)["style.color"].exists, "colour picker")
        shadow.adjust(toNormalizedSliderPosition: 1.0)
        XCTAssertEqual(app.staticTexts["style.shadow.value"].label, "100%")
        app.sliders["style.contrast"].adjust(toNormalizedSliderPosition: 0.0)
        XCTAssertEqual(app.staticTexts["style.contrast.value"].label, "50%")
        screenshot("style-controls", app)
        app.buttons["style.reset"].tap()
        XCTAssertEqual(app.staticTexts["style.shadow.value"].label, "0%")
        XCTAssertEqual(app.staticTexts["style.contrast.value"].label, "100%")
    }

    func testExportButtonAndSizeFollowTheSource() {
        let app = launch()
        enter("深度潛水", in: app)
        let spec = app.staticTexts["export.spec"]
        bringIntoView(spec, in: app)
        let expectSpec = { (text: String) in
            let found = expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: spec)
            wait(for: [found], timeout: 10)
        }
        expectSpec("720 × 1280（720P")
        let exportButton = app.buttons["export.start"]
        XCTAssertTrue(exportButton.exists)
        XCTAssertTrue(exportButton.label.contains("輸出影片"), exportButton.label)
        XCTAssertFalse(exportButton.label.contains("4K"), exportButton.label)
        let landscape = app.buttons["aspect.landscape169"]
        bringIntoView(landscape, in: app)
        landscape.tap()
        bringIntoView(spec, in: app)
        expectSpec("1280 × 720（720P")
    }
}
