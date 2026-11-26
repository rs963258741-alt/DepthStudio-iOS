import XCTest
import AVFoundation
@testable import DepthStudio

final class ExportSizingTests: XCTestCase {
    func testStandardShapesHaveExactFourKSizes() {
        XCTAssertEqual(ExportSizing.renderSize(aspect: 9.0 / 16.0), CGSize(width: 2160, height: 3840))
        XCTAssertEqual(ExportSizing.renderSize(aspect: 16.0 / 9.0), CGSize(width: 3840, height: 2160))
        XCTAssertEqual(ExportSizing.renderSize(aspect: 1), CGSize(width: 2880, height: 2880))
    }

    func testEveryShapeIsFourKClassEvenAndWithinH264Limits() {
        for aspect in OutputAspect.allCases {
            for source in [0.5625, 0.75, 1.0, 1.7778] as [CGFloat] {
                let ratio = aspect.ratio(source: source)
                let size = ExportSizing.renderSize(aspect: ratio)
                XCTAssertTrue(ExportSizing.isFourKClass(size), "\(aspect) \(size)")
                XCTAssertEqual(Int(size.width) % 2, 0)
                XCTAssertEqual(Int(size.height) % 2, 0)
                XCTAssertEqual(size.width / size.height, ratio, accuracy: ratio * 0.01, "\(aspect)")
                XCTAssertLessThanOrEqual(size.width * size.height, 9_437_184, "H.264 level 5.2 frame size")
            }
        }
    }

    func testOriginalFollowsTheSourceAndFallsBackToPortrait() {
        XCTAssertEqual(OutputAspect.original.ratio(source: 0.75), 0.75)
        XCTAssertEqual(OutputAspect.original.ratio(source: nil), 9.0 / 16.0)
        XCTAssertEqual(OutputAspect.vertical916.ratio(source: 1.7778), 9.0 / 16.0)
        XCTAssertEqual(OutputAspect.allCases.map(\.title), ["原始", "1:1", "4:5", "9:16", "16:9"])
    }

    func testHUDUnitIsTheShortSide() {
        XCTAssertEqual(HUDMetrics.unit(for: CGSize(width: 2160, height: 3840)), 2160)
        XCTAssertEqual(HUDMetrics.unit(for: CGSize(width: 3840, height: 2160)), 2160)
        XCTAssertEqual(HUDMetrics.point(unit: 360), 1)
    }

    func testFrameRateIsCappedAtSixty() {
        XCTAssertEqual(DiveVideoExporter.outputFrameDuration(source: CMTime(value: 1, timescale: 240)), CMTime(value: 1, timescale: 60))
        XCTAssertEqual(DiveVideoExporter.outputFrameDuration(source: CMTime(value: 1, timescale: 30)), CMTime(value: 1, timescale: 30))
        XCTAssertEqual(DiveVideoExporter.outputFrameDuration(source: .invalid), CMTime(value: 1, timescale: 30))
    }

    func testExportProgressShowsTimeRemaining() {
        let now = Date()
        let clock = ExportProgressClock(startedAt: now.addingTimeInterval(-10))
        XCTAssertEqual(clock.label(progress: 0.5, now: now), "輸出進度 50%，預估剩餘 10 秒")
        XCTAssertEqual(clock.label(progress: 0.25, now: now), "輸出進度 25%，預估剩餘 30 秒")
        XCTAssertTrue(clock.label(progress: 0.01, now: now).contains("正在估算"))
        XCTAssertTrue(clock.label(progress: 1, now: now).contains("正在檢查"))
        let long = ExportProgressClock(startedAt: now.addingTimeInterval(-60))
        XCTAssertEqual(long.label(progress: 0.2, now: now), "輸出進度 20%，預估剩餘 4 分 00 秒")
    }
}

final class LayoutDefaultsTests: XCTestCase {
    private var store: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "LayoutDefaultsTests-\(UUID().uuidString)"
        store = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDepthRestoreUsesBuiltInLayoutUntilADefaultIsSaved() {
        var settings = HUDSettings()
        settings.positions["depthValue"] = HUDPoint(x: 70, y: 70)
        settings.resetLayout(using: store)
        XCTAssertEqual(settings.positions, HUDSettings().positions)
        XCTAssertNil(HUDSettings.customDefaultLayout(in: store))
    }

    func testDepthSavedDefaultIsRestoredAfterRestartUntilCleared() {
        var settings = HUDSettings()
        settings.positions["depthValue"] = HUDPoint(x: 30, y: 40)
        settings.transforms["elapsedValue"] = HUDTransform(scale: 1.5, rotation: 90)
        settings.saveLayoutAsDefault(in: store)

        settings.positions["depthValue"] = HUDPoint(x: 80, y: 80)
        settings.transforms["elapsedValue"] = HUDTransform()
        settings.resetLayout(using: store)
        XCTAssertEqual(settings.positions["depthValue"], HUDPoint(x: 30, y: 40))
        XCTAssertEqual(settings.transforms["elapsedValue"], HUDTransform(scale: 1.5, rotation: 90))

        // A fresh settings value (as after relaunching the app) restores the same default.
        var relaunched = HUDSettings()
        relaunched.resetLayout(using: store)
        XCTAssertEqual(relaunched.positions["depthValue"], HUDPoint(x: 30, y: 40))

        HUDSettings.clearCustomDefaultLayout(in: store)
        relaunched.resetLayout(using: store)
        XCTAssertEqual(relaunched.positions, HUDSettings().positions)
    }

    func testPoolSavedDefaultIsSeparateFromDepth() {
        var pool = PoolHUDSettings()
        pool.positions["distanceValue"] = HUDPoint(x: 55, y: 22)
        pool.saveLayoutAsDefault(in: store)
        XCTAssertNil(HUDSettings.customDefaultLayout(in: store))

        pool.positions["distanceValue"] = HUDPoint(x: 10, y: 10)
        pool.resetLayout(using: store)
        XCTAssertEqual(pool.positions["distanceValue"], HUDPoint(x: 55, y: 22))
        // Items without a saved position fall back to the built-in layout.
        XCTAssertEqual(pool.positions["lapValue"], PoolHUDSettings().positions["lapValue"])
    }
}
