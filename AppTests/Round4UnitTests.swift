import XCTest
import CoreImage
import SwiftUI
@testable import DepthStudio

/// Fourth-round changes: the depth / distance unit is part of the live value (fixed at its
/// bottom right), the vertical depth gauge, and typed pool times (the cause of a pool HUD
/// that stayed at 0.0 m / 00:00: a start time past the end of the video).
final class Round4UnitTests: XCTestCase {
    private let size = CGSize(width: 720, height: 1280)

    /// 0.5 s … 3.5 s, deepest (12 m) at 2.0 s.
    private var samples: [DiveSample] {
        (0...12).map { index in
            let t = 0.5 + Double(index) * 0.25
            return DiveSample(id: index, elapsedSeconds: t, depthMeters: 12 * sin(.pi * (t - 0.5) / 3),
                              temperatureCelsius: 28.5)
        }
    }

    private func onlyDepth(_ ids: [String]) -> HUDSettings {
        var settings = HUDSettings()
        settings.setAllVisible(false)
        for id in ids { settings.visibility[id] = true }
        settings.opacity = 1
        return settings
    }

    private func depthRenderer(_ settings: HUDSettings) throws -> HUDOverlayRenderer {
        let hud = DiveVideoExporter.committedHUD {
            DiveVideoExporter().makeHUDLayer(size: size, samples: samples, maximumDepth: 12, videoDuration: 4,
                                             sync: try! TimelineSync(offsetSeconds: 0),
                                             settings: DiveExportSettings(hudSettings: settings))
        }
        return HUDOverlayRenderer(root: hud)
    }

    private var black: CIImage { CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: size)) }

    @MainActor
    private func preview(_ settings: HUDSettings, at time: Double) throws -> CGImage {
        let reading = DiveStageView.reading(samples: samples, sync: try TimelineSync(offsetSeconds: 0), videoTime: time)
        let view = ZStack {
            Color.black
            DiveHUDOverlay(reading: reading, samples: samples, maximumDepth: 12, deviceName: "TEST",
                           settings: .constant(settings), selectedItem: .constant(""), isEditing: false)
        }
        return try XCTUnwrap(PreviewRenderer.image(view, size: size, scale: 1)?.cgImage)
    }

    private static func isWhite(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> Bool { r > 225 && g > 225 && b > 225 }
    /// The unit letter's cyan (97, 232, 255). The glows are at most 95% of it, so they are
    /// not counted.
    private static func isUnitCyan(_ r: Int, _ g: Int, _ b: Int, _ a: Int) -> Bool { r < 140 && g > 223 && b > 246 }

    // MARK: Unit fixed to the value

    func testTheUnitIsPartOfTheValueInBothModes() throws {
        XCTAssertFalse(HUDItemDefinition.all.contains { $0.id == "depthUnit" })
        XCTAssertFalse(PoolHUDItemDefinition.all.contains { $0.id == "distanceUnit" })
        XCTAssertEqual(DiveVideoExporter.textSpec(for: "depthValue", maximumDepth: 10, deviceName: "")?.unit, "M")
        let timeline = try? PoolTimeline(session: PoolSession.demo)
        XCTAssertEqual(PoolHUDLayerBuilder(timeline: try XCTUnwrap(timeline), settings: PoolHUDSettings(), videoDuration: 160)
            .textSpec(for: "distanceValue")?.unit, "M")
    }

    func testSettingsFromVersion13DropTheSeparateUnitAndShowTheGauge() throws {
        let old = """
        {"positions":{"depthValue":{"x":17,"y":18},"depthUnit":{"x":34,"y":24}},
         "transforms":{"depthUnit":{"scale":1.2,"rotation":0}},
         "visibility":{"depthValue":true,"depthUnit":true},
         "styles":{"depthUnit":{"shadow":0.5,"contrast":1}},
         "opacity":0.9,"fontScale":0.9,"verticalOffset":0,"syncOffset":0,"displayName":"A",
         "country":"roc","identityScale":0.8,"divingType":"CWT"}
        """
        let settings = try JSONDecoder().decode(HUDSettings.self, from: Data(old.utf8)).mergingDefaults()
        XCTAssertNil(settings.positions["depthUnit"])
        XCTAssertNil(settings.transforms["depthUnit"])
        XCTAssertNil(settings.visibility["depthUnit"])
        XCTAssertNil(settings.styles["depthUnit"])
        XCTAssertEqual(settings.positions["depthValue"], HUDPoint(x: 17, y: 18), "the user's position is kept")
        XCTAssertEqual(settings.visibility["depthGauge"], true, "the new gauge is listed and shown")
        XCTAssertEqual(settings.displayName, "A")

        let pool = """
        {"positions":{"distanceUnit":{"x":43,"y":24}},"visibility":{"distanceUnit":false}}
        """
        let poolSettings = try JSONDecoder().decode(PoolHUDSettings.self, from: Data(pool.utf8)).mergingDefaults()
        XCTAssertNil(poolSettings.positions["distanceUnit"])
        XCTAssertNil(poolSettings.visibility["distanceUnit"])
    }

    @MainActor
    func testTheUnitSitsAtTheBottomRightOfTheValueInPreviewAndExport() throws {
        let settings = onlyDepth(["depthValue"])
        let renderer = try depthRenderer(settings)
        for time in [1.0, 2.0, 3.2] {
            let exported = try XCTUnwrap(renderer.still(at: time, background: black))
            let shown = try preview(settings, at: time)
            for (name, image) in [("export", exported), ("preview", shown)] {
                let number = try XCTUnwrap(PixelCompare.box(image, where: Self.isWhite), "\(name) number at \(time)")
                let unit = try XCTUnwrap(PixelCompare.box(image, where: Self.isUnitCyan), "\(name) unit at \(time)")
                print("[round4] \(name) \(time) s: number \(number.rect), unit \(unit.rect)")
                XCTAssertGreaterThanOrEqual(unit.rect.minX, number.rect.maxX - 2, "\(name): unit right of the number")
                XCTAssertLessThan(unit.rect.minX - number.rect.maxX, number.rect.height * 0.6, "\(name): unit next to the number")
                XCTAssertGreaterThan(unit.rect.minY, number.rect.minY + number.rect.height * 0.3, "\(name): unit low")
                XCTAssertLessThan(abs(unit.rect.maxY - number.rect.maxY), number.rect.height * 0.15, "\(name): same baseline")
            }
            TestArtifacts.save(TestArtifacts.sideBySide(UIImage(cgImage: shown), UIImage(cgImage: exported), height: 640),
                               name: "depth-value-unit-\(time)s-preview-vs-export.png")
        }
    }

    // MARK: Depth gauge

    func testGaugeScaleAndPositions() {
        XCTAssertTrue(DepthGaugeGeometry.scale(for: 87) == (100, 10))
        XCTAssertTrue(DepthGaugeGeometry.scale(for: 25) == (30, 5))
        XCTAssertTrue(DepthGaugeGeometry.scale(for: 11.9) == (20, 2))
        XCTAssertTrue(DepthGaugeGeometry.scale(for: 0) == (10, 1))
        XCTAssertEqual(DepthGaugeGeometry.scale(for: 420).limit, 450)
        let gauge = DepthGaugeGeometry(unit: 720, maximumDepth: 87)
        XCTAssertEqual(gauge.majorDepths, stride(from: 0.0, through: 100, by: 10).map { $0 })
        XCTAssertEqual(gauge.y(forDepth: 0), gauge.scaleTop, accuracy: 0.001)
        XCTAssertEqual(gauge.y(forDepth: 100), gauge.scaleBottom, accuracy: 0.001)
        XCTAssertEqual(gauge.y(forDepth: 150), gauge.scaleBottom, accuracy: 0.001, "clamped to the scale")
        XCTAssertEqual(gauge.badgeText(27.6), "28")
        XCTAssertEqual(gauge.maximumText, "87")
        XCTAssertEqual(gauge.size.height / 720, DepthGaugeGeometry.heightFraction, accuracy: 0.001)
        XCTAssertTrue(HUDItemDefinition.all.contains { $0.id == "depthGauge" && $0.title == "垂直深度指示計" })
    }

    /// Where the gauge's point for `depth` is in the frame (the gauge is placed at its HUD
    /// position, scaled by the HUD size).
    private func frameY(forDepth depth: Double, settings: HUDSettings) -> CGFloat {
        let gauge = DepthGaugeGeometry(unit: HUDMetrics.unit(for: size), maximumDepth: 12)
        let center = size.height * CGFloat(settings.positions["depthGauge"]!.y / 100)
        let scale = CGFloat(settings.fontScale)
        return center + (gauge.y(forDepth: depth) - gauge.size.height / 2) * scale
    }

    /// The cyan current-depth badge (left of the bar), in frame pixels.
    private func currentBadge(_ image: CGImage, settings: HUDSettings) -> (rect: CGRect, center: CGPoint, count: Int)? {
        let gauge = DepthGaugeGeometry(unit: HUDMetrics.unit(for: size), maximumDepth: 12)
        let scale = CGFloat(settings.fontScale)
        let centerX = size.width * CGFloat(settings.positions["depthGauge"]!.x / 100)
        let barLeft = centerX + (gauge.bar.minX - gauge.size.width / 2) * scale
        let region = CGRect(x: 0, y: 0, width: barLeft - 1, height: size.height)
        // Badge fill (107, 219, 250); the bar's light blue lies right of `barLeft`.
        return PixelCompare.box(image, region: region) { r, g, b, _ in r > 80 && r < 140 && g > 195 && b > 230 }
    }

    @MainActor
    func testGaugeBadgeFollowsTheDepthAndShowsItInTheExport() throws {
        var settings = onlyDepth(["depthGauge"])
        settings.fontScale = 1
        let renderer = try depthRenderer(settings)
        XCTAssertNil(currentBadge(try XCTUnwrap(renderer.still(at: 0.2, background: black)), settings: settings),
                     "no current-depth badge before the dive")
        var crops: [CGImage] = []
        for (time, depth) in [(1.0, 6.0), (2.0, 12.0), (3.4, 12 * sin(.pi * 2.9 / 3))] {
            let image = try XCTUnwrap(renderer.still(at: time, background: black))
            let badge = try XCTUnwrap(currentBadge(image, settings: settings), "badge at \(time) s")
            let expected = frameY(forDepth: depth, settings: settings)
            print("[round4] gauge badge at \(time) s: centre y \(badge.rect.midY), expected \(expected)")
            XCTAssertEqual(badge.rect.midY, expected, accuracy: 3, "badge at the depth of \(time) s")
            crops.append(try XCTUnwrap(PixelCompare.crop(image, badge.rect)))
            TestArtifacts.save(UIImage(cgImage: image), name: "depth-gauge-export-\(time)s.png")
        }
        // The badge shows the depth: "6" and "12" differ (the badge image is redrawn).
        let compare = CGSize(width: 40, height: 20)
        let difference = PixelCompare.meanDifference(crops[0], crops[1], size: compare)
        print("[round4] badge 6 m vs 12 m difference \(difference)")
        XCTAssertGreaterThan(difference, 8)
    }

    @MainActor
    func testGaugePreviewMatchesTheExport() throws {
        let settings = onlyDepth(["depthGauge"])
        let renderer = try depthRenderer(settings)
        let gauge = DepthGaugeGeometry(unit: HUDMetrics.unit(for: size), maximumDepth: 12)
        let center = CGPoint(x: size.width * CGFloat(settings.positions["depthGauge"]!.x / 100),
                             y: size.height * CGFloat(settings.positions["depthGauge"]!.y / 100))
        let scale = CGFloat(settings.fontScale)
        let box = CGRect(x: center.x - gauge.size.width * scale / 2, y: center.y - gauge.size.height * scale / 2,
                         width: gauge.size.width * scale, height: gauge.size.height * scale).insetBy(dx: -4, dy: -4)
        let region = CGRect(x: box.minX / size.width, y: box.minY / size.height,
                            width: box.width / size.width, height: box.height / size.height)
        for time in [1.0, 2.0] {
            let exported = try XCTUnwrap(renderer.still(at: time, background: black))
            let shown = try preview(settings, at: time)
            let difference = PixelCompare.meanDifference(shown, exported, size: size, region: region)
            print("[round4] gauge preview vs export at \(time) s: \(difference)")
            XCTAssertLessThan(difference, 12, "the gauge looks the same in the preview and the video")
            TestArtifacts.save(TestArtifacts.sideBySide(UIImage(cgImage: shown), UIImage(cgImage: exported), height: 1280),
                               name: "depth-gauge-\(time)s-preview-vs-export.png")
        }
    }

    // MARK: Typed pool times

    func testTypedTimesFitTheVideo() {
        // The app's own format and plain seconds.
        XCTAssertEqual(PoolFormat.parseTime("00:12.5", videoDuration: 60), 12.5)
        XCTAssertEqual(PoolFormat.parseTime("12.5", videoDuration: 60), 12.5)
        // ":" typed instead of "." — 12 minutes would be past the 60 s video.
        XCTAssertEqual(PoolFormat.parseTime("00:12:30", videoDuration: 60)!, 12.3, accuracy: 1e-9)
        XCTAssertEqual(PoolFormat.parseTime("00:12:5", videoDuration: 60)!, 12.5, accuracy: 1e-9)
        XCTAssertEqual(PoolFormat.parseTime("1:05:2", videoDuration: 90)!, 65.2, accuracy: 1e-9)
        // A real h:m:s inside a long video stays h:m:s; without the video length too.
        XCTAssertEqual(PoolFormat.parseTime("1:02:30", videoDuration: 4000), 3750)
        XCTAssertEqual(PoolFormat.parseTime("00:12:30"), 750)
        // Past the video either way: returned as typed, so the app can refuse it.
        XCTAssertEqual(PoolFormat.parseTime("05:00", videoDuration: 60), 300)
        // Other ways of typing.
        XCTAssertEqual(PoolFormat.parseTime("１２.５"), 12.5)
        XCTAssertEqual(PoolFormat.parseTime("12,5"), 12.5)
        XCTAssertEqual(PoolFormat.parseTime("1分05秒"), 65)
        XCTAssertEqual(PoolFormat.parseTime(" 2：30 "), 150)
        XCTAssertNil(PoolFormat.parseTime("1:2:3:4"))
        XCTAssertEqual(PoolFormat.parseTime("1分"), 60)
    }

    func testAStartAfterTheVideoKeepsTheHUDAtZeroAndAStartInsideMovesIt() throws {
        // What the user saw: typed times past the end of a short video.
        var session = PoolSession(poolLength: 25, finalDistance: 50)
        for node in session.nodes {
            session.setTime(node.distance == 0 ? 750 : node.distance == 25 ? 780 : 810, for: node.id)
        }
        let late = try PoolTimeline(session: session)
        for time in stride(from: 0.0, through: 60, by: 10) {
            let reading = late.reading(atVideoTime: time)
            XCTAssertEqual(reading.distance, 0)
            XCTAssertEqual(PoolFormat.clock(reading.elapsedSeconds), "00:00")
        }
        // The same times read as typed with ":" for "." fit a 60 s video and move the HUD.
        for node in session.nodes {
            let typed = node.distance == 0 ? "00:12:30" : node.distance == 25 ? "00:30:0" : "00:50:0"
            session.setTime(PoolFormat.parseTime(typed, videoDuration: 60), for: node.id)
        }
        let fitted = try PoolTimeline(session: session)
        XCTAssertEqual(fitted.startTime, 12.3, accuracy: 0.001)
        XCTAssertGreaterThan(fitted.reading(atVideoTime: 30).distance, 20)
        XCTAssertGreaterThan(fitted.reading(atVideoTime: 40).distance, fitted.reading(atVideoTime: 30).distance)
    }
}
