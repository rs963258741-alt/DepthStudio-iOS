import XCTest
import QuartzCore
@testable import DepthStudio

/// Third-round changes: time tracks of the export HUD, per-field styles, presets 1/2 and
/// centre snapping.
final class HUDTrackTests: XCTestCase {
    func testTextPositionAndVisibilityFollowTheVideoTime() {
        let text = CATextLayer()
        HUDLayerFactory.addSampledText(to: text, times: [0, 0.1, 0.2, 0.3, 1.0], duration: 2, key: "t") { time in
            time < 0.15 ? "A" : (time < 0.5 ? "B" : "C")
        }
        let tracks = HUDLayerTracks.of(text)
        XCTAssertEqual(tracks.textValues, ["A", "B", "C"], "repeats are merged")
        XCTAssertEqual(tracks.text(at: 0), "A")
        XCTAssertEqual(tracks.text(at: 0.19), "A")
        XCTAssertEqual(tracks.text(at: 0.2), "B")
        XCTAssertEqual(tracks.text(at: 5), "C")
        XCTAssertEqual(text.string as? String, "A")

        let dot = CALayer()
        HUDLayerFactory.addPositionAnimation(to: dot, times: [1, 2], duration: 4, key: "p") { time in
            CGPoint(x: time * 10, y: 0)
        }
        let moving = HUDLayerTracks.of(dot)
        XCTAssertEqual(moving.position(at: 1.5)?.x ?? -1, 15, accuracy: 0.001)
        XCTAssertEqual(moving.position(at: 0)?.x ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(moving.position(at: 9)?.x ?? -1, 40, accuracy: 0.001)

        HUDLayerFactory.addVisibility(to: dot, start: 1, end: 3, duration: 4, key: "v")
        XCTAssertFalse(moving.isVisible(at: 0.5))
        XCTAssertTrue(moving.isVisible(at: 2))
        XCTAssertFalse(moving.isVisible(at: 3.5))
    }

    func testRendererShowsLiveFieldsOnlyInsideTheDive() throws {
        let samples = (0...8).map { DiveSample(id: $0, elapsedSeconds: 1 + Double($0) * 0.25, depthMeters: Double($0), temperatureCelsius: 27) }
        let hud = DiveVideoExporter().makeHUDLayer(size: CGSize(width: 360, height: 640), samples: samples, maximumDepth: 8,
                                                   videoDuration: 5, sync: try TimelineSync(offsetSeconds: 0),
                                                   settings: DiveExportSettings())
        let renderer = HUDOverlayRenderer(root: hud)
        let shown = HUDItemDefinition.all.filter { HUDSettings().visibility[$0.id] ?? true }
        let live = shown.filter { HUDItemDefinition.liveIDs.contains($0.id) }
        XCTAssertEqual(renderer.visibleItemCount(at: 0.5), shown.count - live.count)
        XCTAssertEqual(renderer.visibleItemCount(at: 2), shown.count)
        XCTAssertEqual(renderer.visibleItemCount(at: 4.5), shown.count - live.count)
        // Different times give different images (the values move).
        let early = try XCTUnwrap(renderer.still(at: 1.2)), late = try XCTUnwrap(renderer.still(at: 2.9))
        XCTAssertGreaterThan(PixelCompare.meanDifference(early, late, size: CGSize(width: 180, height: 320)), 0.2)
    }
}

final class HUDStyleTests: XCTestCase {
    func testContrastColourAndShadow() {
        let style = HUDItemStyle()
        XCTAssertEqual(style.text(.muted), .muted, "default keeps the original colour")
        XCTAssertNil(style.dropShadow)

        let red = HUDColor(red: 1, green: 0, blue: 0)
        let coloured = HUDItemStyle(color: red)
        XCTAssertEqual(coloured.text(.white), red)
        XCTAssertEqual(coloured.text(HUDColor.white.opacity(0.85)).alpha, 0.85, accuracy: 0.001, "keeps the field's transparency")
        XCTAssertEqual(coloured.glow(.cyan), red, "the glow follows the chosen colour")
        XCTAssertEqual(HUDItemStyle().glow(.cyan), .cyan)

        let strong = HUDItemStyle(contrast: 1.5)
        XCTAssertEqual(strong.adjusted(HUDColor(red: 0.7, green: 0.3, blue: 0.5)).red, 0.8, accuracy: 0.001)
        XCTAssertEqual(strong.adjusted(HUDColor(red: 0.7, green: 0.3, blue: 0.5)).green, 0.2, accuracy: 0.001)
        XCTAssertEqual(strong.glowOpacity(0.5), 0.75, accuracy: 0.001)
        XCTAssertEqual(HUDItemStyle(contrast: 0.5).adjusted(.white).red, 0.75, accuracy: 0.001)

        let shadow = HUDItemStyle(shadow: 1).dropShadow
        XCTAssertNotNil(shadow)
        XCTAssertEqual(shadow?.opacity ?? 0, 0.85, accuracy: 0.001)
        XCTAssertEqual(HUDItemStyle(shadow: 7, contrast: 9).sanitized, HUDItemStyle(shadow: 1, contrast: 1.5))
    }

    func testSettingsFromOlderVersionsStillLoadAndStylesAreSaved() throws {
        // A 1.2 settings JSON: no `styles` key. It must keep the user's layout.
        var old = HUDSettings()
        old.positions["depthValue"] = HUDPoint(x: 33, y: 44)
        old.displayName = "Diver"
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "styles")
        let decoded = try JSONDecoder().decode(HUDSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.positions["depthValue"], HUDPoint(x: 33, y: 44))
        XCTAssertEqual(decoded.displayName, "Diver")
        XCTAssertTrue(decoded.styles.isEmpty)

        var pool = PoolHUDSettings()
        pool.discipline = "DNF"
        var poolJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pool)) as? [String: Any])
        poolJSON.removeValue(forKey: "styles")
        XCTAssertEqual(try JSONDecoder().decode(PoolHUDSettings.self, from: JSONSerialization.data(withJSONObject: poolJSON)).discipline, "DNF")

        var styled = HUDSettings()
        styled.setStyle(HUDItemStyle(color: HUDColor(red: 0.2, green: 0.4, blue: 0.6), shadow: 0.5, contrast: 1.2), for: "tempValue")
        styled.setStyle(HUDItemStyle(), for: "depthValue")
        XCTAssertNil(styled.styles["depthValue"], "a default style is not stored")
        let roundTrip = try JSONDecoder().decode(HUDSettings.self, from: JSONEncoder().encode(styled))
        XCTAssertEqual(roundTrip.style(for: "tempValue"), styled.style(for: "tempValue"))
    }

    func testExportBuilderUsesTheStyle() {
        let style = HUDItemStyle(color: HUDColor(red: 1, green: 0, blue: 0), shadow: 1, contrast: 1)
        let made = HUDLayerFactory.textItem("12.3", look: .depthValue, style: style, unit: 2160)
        let color = UIColor(cgColor: made.text.foregroundColor!)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1, accuracy: 0.01)
        XCTAssertEqual(g, 0, accuracy: 0.01)
        // text glow, the big number's dark shadow and the user's drop shadow
        var shadows = 0
        var layer: CALayer? = made.text
        while let current = layer { if current.shadowOpacity > 0 { shadows += 1 }; layer = current.superlayer }
        XCTAssertEqual(shadows, 3)
    }
}

final class PresetTests: XCTestCase {
    private var store: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "PresetTests-\(UUID().uuidString)"
        store = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testTwoPresetsAreSavedAndAppliedSeparately() {
        var settings = HUDSettings()
        XCTAssertTrue(HUDSettings.savedPresetSlots(in: store).isEmpty)
        XCTAssertFalse(settings.applyPreset(1, using: store), "an empty slot does nothing")

        settings.positions["tempValue"] = HUDPoint(x: 20, y: 30)
        settings.setStyle(HUDItemStyle(shadow: 0.7), for: "tempValue")
        settings.fontScale = 1.2
        settings.savePreset(1, in: store)

        settings.positions["tempValue"] = HUDPoint(x: 70, y: 60)
        settings.setStyle(HUDItemStyle(color: HUDColor(red: 0, green: 1, blue: 0)), for: "tempValue")
        settings.visibility["maxDepth"] = true
        settings.fontScale = 0.8
        settings.savePreset(2, in: store)
        XCTAssertEqual(HUDSettings.savedPresetSlots(in: store), [1, 2])

        var fresh = HUDSettings()   // as after a restart
        XCTAssertTrue(fresh.applyPreset(1, using: store))
        XCTAssertEqual(fresh.positions["tempValue"], HUDPoint(x: 20, y: 30))
        XCTAssertEqual(fresh.style(for: "tempValue"), HUDItemStyle(shadow: 0.7))
        XCTAssertEqual(fresh.fontScale, 1.2, accuracy: 0.0001)
        XCTAssertEqual(fresh.visibility["maxDepth"], false)

        XCTAssertTrue(fresh.applyPreset(2, using: store))
        XCTAssertEqual(fresh.positions["tempValue"], HUDPoint(x: 70, y: 60))
        XCTAssertEqual(fresh.style(for: "tempValue").color, HUDColor(red: 0, green: 1, blue: 0))
        XCTAssertEqual(fresh.visibility["maxDepth"], true)
        XCTAssertEqual(fresh.fontScale, 0.8, accuracy: 0.0001)

        // 「恢復預設位置」 uses preset 1's positions only.
        fresh.resetLayout(using: store)
        XCTAssertEqual(fresh.positions["tempValue"], HUDPoint(x: 20, y: 30))
        XCTAssertEqual(fresh.fontScale, 0.8, accuracy: 0.0001)
    }

    func testPresetSavedBy12BecomesPreset1() throws {
        // 1.2 saved only positions and transforms under the old default key.
        let legacy = ["positions": ["distanceValue": ["x": 12.0, "y": 34.0]],
                      "transforms": ["distanceValue": ["scale": 1.5, "rotation": 90.0]]]
        store.set(try JSONSerialization.data(withJSONObject: legacy), forKey: PoolHUDSettings.customDefaultLayoutKey)
        XCTAssertEqual(PoolHUDSettings.savedPresetSlots(in: store), [1])
        var pool = PoolHUDSettings()
        pool.setStyle(HUDItemStyle(shadow: 0.4), for: "lapValue")
        XCTAssertTrue(pool.applyPreset(1, using: store))
        XCTAssertEqual(pool.positions["distanceValue"], HUDPoint(x: 12, y: 34))
        XCTAssertEqual(pool.transforms["distanceValue"], HUDTransform(scale: 1.5, rotation: 90))
        XCTAssertEqual(pool.style(for: "lapValue"), HUDItemStyle(shadow: 0.4), "parts the old preset lacks are kept")
    }
}

final class SnappingTests: XCTestCase {
    func testTheStageCentreWinsAndUsesTheShownPosition() {
        // Another field at 51.5 % does not pull the chart off the centre.
        XCTAssertEqual(HUDSnapping.snap(x: 51.2, y: 70, verticalOffset: 0, others: [HUDPoint(x: 51.5, y: 10)]).x, 50)
        // Away from the centre, other fields' centres still snap.
        XCTAssertEqual(HUDSnapping.snap(x: 56.1, y: 70, verticalOffset: 0, others: [HUDPoint(x: 55, y: 10)]).x, 55)
        XCTAssertEqual(HUDSnapping.snap(x: 60, y: 70, verticalOffset: 0, others: [HUDPoint(x: 55, y: 10)]).x, 60)
        // Vertical centre is where the field is shown (position + HUD vertical offset).
        XCTAssertEqual(HUDSnapping.snap(x: 30, y: 39.5, verticalOffset: 10, others: []).y, 40)
        XCTAssertTrue(HUDSnapping.isCentered(50))
    }
}
