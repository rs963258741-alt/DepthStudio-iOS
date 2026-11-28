import XCTest
import AVFoundation
import CoreImage
@testable import DepthStudio

/// Smart Sync update (1.5): the shared sync core of the three modes, export file naming,
/// and the preview and the exported video using the same sync result.
final class SmartSyncTests: XCTestCase {
    private func sample(_ index: Int, _ time: Double, _ depth: Double) -> DiveSample {
        DiveSample(id: index, elapsedSeconds: time, depthMeters: depth, temperatureCelsius: 28)
    }

    /// Surface at 0–5 s, down to 30 m at 35 s, stays to 38 s, back at the surface at 65 s.
    private var fullDive: [DiveSample] {
        var samples: [DiveSample] = []
        for t in stride(from: 0.0, through: 70, by: 1) {
            let depth: Double
            switch t {
            case ..<5: depth = 0
            case ..<35: depth = (t - 5) / 30 * 30
            case ...38: depth = 30
            case ..<65: depth = 30 - (t - 38) / 27 * 30
            default: depth = 0
            }
            samples.append(sample(samples.count, t, depth))
        }
        return samples
    }

    // MARK: Landmarks

    func testLandmarksComeFromTheRecordedSamplesOnly() throws {
        let marks = try XCTUnwrap(DiveLogLandmarks(samples: fullDive))
        XCTAssertEqual(marks.maximumDepth, 30, accuracy: 0.001)
        XCTAssertEqual(marks.firstMaximumTime, 35, "first arrival at the maximum")
        XCTAssertEqual(marks.lastMaximumTime, 38, "end of the stay at the maximum")
        XCTAssertEqual(marks.holdDuration, 3)
        XCTAssertEqual(marks.maximumTime(for: .ascentStart), 38)
        XCTAssertEqual(marks.descentStartTime, 5, "last surface sample before the descent")
        XCTAssertEqual(marks.surfaceTime, 65, "first surface sample after the maximum")

        // A log that starts and ends below the surface: no descent / surface to compare.
        let partial = fullDive.filter { $0.elapsedSeconds >= 10 && $0.elapsedSeconds <= 55 }
        let partialMarks = try XCTUnwrap(DiveLogLandmarks(samples: partial))
        XCTAssertNil(partialMarks.descentStartTime)
        XCTAssertNil(partialMarks.surfaceTime)
        XCTAssertEqual(partialMarks.firstMaximumTime, 35)

        XCTAssertNil(DiveLogLandmarks(samples: [sample(0, 0, 0)]), "not enough data")
    }

    // MARK: 智慧同步

    func testSmartSyncPutsTheMaximumAtTheMarkedVideoTime() throws {
        // Watch maximum 00:35.0, video maximum 00:42.3 → data shown 7.3 s later.
        var samples = fullDive.filter { $0.elapsedSeconds <= 34 || $0.elapsedSeconds >= 36 }
        samples.append(sample(999, 35, 30))
        let marks = try XCTUnwrap(DiveLogLandmarks(samples: samples))
        var state = DiveSyncState()
        XCTAssertEqual(state.mode, .smart, "smart is the default")
        XCTAssertEqual(state.delay, 0)
        state.set(.maximum, to: 42.3, landmarks: marks)
        XCTAssertEqual(state.delay, 7.3, accuracy: 0.001)
        XCTAssertEqual(state.timelineSync.watchTime(forVideoTime: 42.3), 35, accuracy: 0.001)
        XCTAssertEqual(state.watchTime(forVideoTime: 50), 42.7, accuracy: 0.001)
        XCTAssertEqual(DiveSyncState.describe(state.delay), "數據延後 7.3 秒顯示")
        XCTAssertEqual(DiveSyncState.signedSeconds(-2), "−2.0 秒")

        // The stay at the maximum: the user chooses which event the video time marks.
        state.setMaximumEvent(.ascentStart, landmarks: marks)
        XCTAssertEqual(state.delay, 42.3 - 38, accuracy: 0.001)

        // Clearing the required time removes the offset instead of keeping a stale one.
        state.set(.maximum, to: nil, landmarks: marks)
        XCTAssertEqual(state.delay, 0)
    }

    // MARK: 進階同步

    func testAdvancedSyncChecksTheExtraPointsWithoutChangingTheData() throws {
        // The example: watch 00:05 / 00:35 / 01:05, video 00:13 / 00:42 / 01:13.
        let marks = try XCTUnwrap(DiveLogLandmarks(samples: fullDive))
        var state = DiveSyncState(mode: .advanced)
        state.set(.maximum, to: 42, landmarks: marks)
        state.set(.descentStart, to: 13, landmarks: marks)
        state.set(.surface, to: 73, landmarks: marks)
        XCTAssertEqual(state.delay, 7, "the maximum is the offset")
        let checks = Dictionary(uniqueKeysWithValues: state.checks(marks).map { ($0.anchor, $0) })
        XCTAssertEqual(checks[.descentStart]?.difference, 8)
        XCTAssertEqual(checks[.descentStart]?.error, 1)
        XCTAssertEqual(checks[.descentStart]?.level, .good)
        XCTAssertEqual(checks[.surface]?.difference, 8)
        XCTAssertEqual(checks[.surface]?.level, .good)
        XCTAssertEqual(checks[.maximum]?.error, 0)

        XCTAssertEqual(SyncCheck.level(forError: 2.4), .adjust)
        XCTAssertEqual(SyncCheck.level(forError: -3.5), .recheck)

        // Not recorded by the watch → cannot be checked (nothing is invented).
        let partial = try XCTUnwrap(DiveLogLandmarks(samples: fullDive.filter { $0.elapsedSeconds >= 10 && $0.elapsedSeconds <= 55 }))
        let partialChecks = state.checks(partial)
        XCTAssertEqual(partialChecks.first { $0.anchor == .descentStart }?.level, .noData)
        XCTAssertEqual(partialChecks.first { $0.anchor == .surface }?.level, .noData)

        // Optional points left empty are fine.
        var minimal = DiveSyncState(mode: .advanced)
        minimal.set(.maximum, to: 42, landmarks: marks)
        XCTAssertEqual(minimal.checks(marks).first { $0.anchor == .surface }?.level, .notSet)
    }

    func testTimesMustBeInsideTheVideoAndInTheDiveOrder() {
        var state = DiveSyncState()
        XCTAssertNotNil(state.problem(setting: 70, for: .maximum, videoDuration: 60), "past the end of the video")
        XCTAssertNil(state.problem(setting: 42, for: .maximum, videoDuration: 60))
        state.set(.maximum, to: 42, landmarks: nil)
        XCTAssertNotNil(state.problem(setting: 45, for: .descentStart, videoDuration: 60), "descent before the maximum")
        XCTAssertNil(state.problem(setting: 13, for: .descentStart, videoDuration: 60))
        XCTAssertNotNil(state.problem(setting: 40, for: .surface, videoDuration: 60), "surface after the maximum")
        XCTAssertNil(state.problem(setting: 55, for: .surface, videoDuration: 60))
    }

    // MARK: 手動同步 and switching modes

    func testModesShareTheTimesAndManualChangesAreNotSilentlyReplaced() throws {
        let marks = try XCTUnwrap(DiveLogLandmarks(samples: fullDive))
        var state = DiveSyncState()
        state.set(.maximum, to: 42.3, landmarks: marks)
        state.select(.advanced)
        XCTAssertEqual(state.videoMaximum, 42.3, "smart → advanced keeps the maximum time")
        XCTAssertEqual(state.delay, 7.3, accuracy: 0.001)
        state.select(.manual)
        XCTAssertEqual(state.delay, 7.3, accuracy: 0.001, "advanced → manual keeps the offset")
        XCTAssertEqual(state.residual(marks), 0)

        state.nudge(by: 0.1)
        state.nudge(by: 0.1)
        XCTAssertEqual(state.delay, 7.5, accuracy: 0.001)
        XCTAssertEqual(state.residual(marks) ?? 0, -0.2, accuracy: 0.001, "orange and blue markers 0.2 s apart")

        state.select(.smart)
        XCTAssertEqual(state.delay, 7.5, accuracy: 0.001, "manual → smart does not overwrite the offset")
        XCTAssertEqual(state.pendingCalculation(marks) ?? 0, 7.3, accuracy: 0.001, "the new calculation is shown")
        XCTAssertTrue(state.applyCalculation(marks))
        XCTAssertEqual(state.delay, 7.3, accuracy: 0.001)
        XCTAssertNil(state.pendingCalculation(marks))

        // Manual mode without a maximum time; typed offsets beyond the slider.
        var manual = DiveSyncState(mode: .manual)
        manual.set(.maximum, to: 10, landmarks: marks)
        XCTAssertEqual(manual.delay, 0, "in manual mode the maximum time only places the marker")
        manual.setDelay(DiveSyncState.parseDelay("+250") ?? 0)
        XCTAssertEqual(manual.delay, 250)
        XCTAssertEqual(DiveSyncState.parseDelay("−2.5秒"), -2.5)
        XCTAssertNil(DiveSyncState.parseDelay("abc"))
        XCTAssertNil(DiveSyncState.parseDelay("99999"))

        // 任意時間點定位.
        manual.set(.point, to: 20, landmarks: marks)
        XCTAssertFalse(manual.applyPoint(), "needs both points")
        manual.setPointWatchTime(12.5)
        XCTAssertTrue(manual.applyPoint())
        XCTAssertEqual(manual.delay, 7.5, accuracy: 0.001)

        // 重設 keeps the mode and clears the rest.
        manual.reset()
        XCTAssertEqual(manual.mode, .manual)
        XCTAssertNil(manual.videoMaximum)
        XCTAssertNil(manual.pointWatchTime)
        XCTAssertEqual(manual.delay, 0)
    }

    // MARK: Preview and export use the same sync

    /// 0.5 s … 3.5 s of the log, deepest (12 m) at 2.0 s.
    private var shortDive: [DiveSample] {
        (0...12).map { index in
            let t = 0.5 + Double(index) * 0.25
            return sample(index, t, 12 * sin(.pi * (t - 0.5) / 3))
        }
    }

    func testPreviewAndExportReadTheSameMomentOfTheLog() throws {
        var state = DiveSyncState(mode: .manual)
        state.setDelay(1.0)   // data 1 s later: the log's 0.5 s shows at video 1.5 s
        let sync = state.timelineSync
        let size = CGSize(width: 360, height: 640)
        let hud = DiveVideoExporter.committedHUD {
            DiveVideoExporter().makeHUDLayer(size: size, samples: shortDive, maximumDepth: 12, videoDuration: 4,
                                             sync: sync, settings: DiveExportSettings())
        }
        let renderer = HUDOverlayRenderer(root: hud)
        let shown = HUDItemDefinition.all.filter { HUDSettings().visibility[$0.id] ?? true }
        let live = shown.filter { HUDItemDefinition.liveIDs.contains($0.id) }
        for (time, inside) in [(1.2, false), (1.6, true), (3.9, true)] {
            let reading = DiveStageView.reading(samples: shortDive, sync: sync, videoTime: time)
            XCTAssertEqual(reading != nil, inside, "preview at \(time) s")
            XCTAssertEqual(renderer.visibleItemCount(at: time), inside ? shown.count : shown.count - live.count,
                           "export at \(time) s")
        }
        let reading = try XCTUnwrap(DiveStageView.reading(samples: shortDive, sync: sync, videoTime: 3.0))
        XCTAssertEqual(reading.elapsedSeconds, 2.0, accuracy: 0.001, "applied once: video 3.0 s = log 2.0 s")
        XCTAssertEqual(reading.depthMeters, 12, accuracy: 0.001)
    }

    @MainActor
    func testExportedVideoUsesTheSyncOfThePreview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smart-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("DJI_20261128.mp4")
        try await TestVideoFactory.makeVideo(url: source, size: CGSize(width: 720, height: 1280), duration: 4)
        let sourceData = try Data(contentsOf: source)

        var state = DiveSyncState(mode: .manual)
        state.setDelay(1.0)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "smart-sync-\(UUID().uuidString)"))
        let output = ExportNaming.nextOutputURL(originalName: source.lastPathComponent, sourceURL: source,
                                                directory: directory, store: defaults)
        XCTAssertEqual(output.lastPathComponent, "DJI_20261128_DepthStudio.mp4")
        let settings = DiveExportSettings(hudSettings: HUDSettings(), deviceName: "TEST")
        let result = try await ExportRecorder().run { progress, completion in
            DiveVideoExporter().export(videoURL: source, samples: shortDive, maximumDepth: 12, sync: state.timelineSync,
                                       settings: settings, aspect: .original, outputURL: output,
                                       progress: progress, completion: completion)
        }
        XCTAssertEqual(result, output)
        XCTAssertEqual(try Data(contentsOf: source), sourceData, "the source video is unchanged")

        let hud = DiveVideoExporter().makeHUDLayer(size: CGSize(width: 720, height: 1280), samples: shortDive,
                                                   maximumDepth: 12, videoDuration: 4, sync: state.timelineSync,
                                                   settings: settings)
        let renderer = HUDOverlayRenderer(root: hud)
        for time in [1.2, 3.0] {
            let sourceImage = try await TestVideoFactory.frame(of: source, at: time, maximumSize: CGSize(width: 4000, height: 4000))
            let exportedImage = try await TestVideoFactory.frame(of: result, at: time, maximumSize: CGSize(width: 4000, height: 4000))
            let exported = try XCTUnwrap(exportedImage.cgImage)
            let background = CIImage(cgImage: try XCTUnwrap(sourceImage.cgImage), options: [.colorSpace: NSNull()])
            let expected = try XCTUnwrap(renderer.still(at: time, background: background, colorSpace: exported.colorSpace))
            let difference = PixelCompare.meanDifference(expected, exported, size: CGSize(width: 360, height: 640))
            print("[smart-sync] exported frame \(time) s vs the preview's sync: \(difference)")
            XCTAssertLessThan(difference, 5, "frame at \(time) s shows the log moment the preview shows")
            TestArtifacts.save(TestArtifacts.sideBySide(UIImage(cgImage: expected), UIImage(cgImage: exported), height: 640),
                               name: "smart-sync-\(time)s-expected-vs-exported.png")
        }
    }

    // MARK: Export file names

    func testExportsAreNewFilesThatNeverOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("naming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "naming-\(UUID().uuidString)"))
        func next(_ name: String = "DJI_20261128.mp4", source: URL? = nil) -> URL {
            ExportNaming.nextOutputURL(originalName: name, sourceURL: source, directory: directory, store: defaults)
        }
        func finish(_ url: URL, _ name: String = "DJI_20261128.mp4") throws {
            try Data("x".utf8).write(to: url)
            ExportNaming.recordExport(at: url, originalName: name, store: defaults)
        }

        let first = next()
        XCTAssertEqual(first.lastPathComponent, "DJI_20261128_DepthStudio.mp4")
        try finish(first)
        let second = next()
        XCTAssertEqual(second.lastPathComponent, "DJI_20261128_DepthStudio_02.mp4")
        try finish(second)
        // A file that already has the next name is skipped, not overwritten.
        try Data("y".utf8).write(to: directory.appendingPathComponent("DJI_20261128_DepthStudio_03.mp4"))
        XCTAssertEqual(next().lastPathComponent, "DJI_20261128_DepthStudio_04.mp4")
        // The numbering continues even after the earlier files are gone (e.g. a new launch).
        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: second)
        XCTAssertEqual(next().lastPathComponent, "DJI_20261128_DepthStudio_04.mp4")
        // A failed export (no recordExport) does not use up a number.
        XCTAssertEqual(next().lastPathComponent, "DJI_20261128_DepthStudio_04.mp4")

        // Never the source itself; re-exporting an export does not stack the suffix.
        let source = directory.appendingPathComponent("IMG_0001_DepthStudio.mp4")
        let other = next("IMG_0001_DepthStudio.mp4", source: source)
        XCTAssertEqual(other.lastPathComponent, "IMG_0001_DepthStudio_02.mp4")
        XCTAssertNotEqual(other, source)
        XCTAssertEqual(ExportNaming.baseName(fromOriginal: "IMG_0001_DepthStudio_02.MOV"), "IMG_0001")
        XCTAssertEqual(ExportNaming.baseName(fromOriginal: nil), "DepthStudio")
        XCTAssertEqual(ExportNaming.baseName(fromOriginal: "a/b:c.mov"), "a_b_c")
    }
}
