import XCTest
import AVFoundation
import CoreImage
import SwiftUI
@testable import DepthStudio

/// Real exports on the simulator, with the HUD.
///
/// Since 1.3 every exported frame is composed by HUDVideoCompositor (Core Image), which
/// also runs on the simulator, so these tests export real videos with the HUD and check
/// the frames: the size follows the source, the HUD values change with the time, live
/// fields appear inside the dive, and each frame equals the video plus the HUD rendered
/// for that time. Preview-vs-export images are saved in build/test-artifacts for review.
final class ExportPipelineTests: XCTestCase {
    private let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("export-tests-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDirectory)
        super.tearDown()
    }

    private func portraitSource() async throws -> URL {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let url = workDirectory.appendingPathComponent("source-portrait.mp4")
        if !FileManager.default.fileExists(atPath: url.path) {
            try await TestVideoFactory.makeVideo(url: url, size: CGSize(width: 720, height: 1280), duration: 4)
        }
        return url
    }

    /// Depth samples from 0.5 s to 3.5 s of the 4 s test video (watch time = video time),
    /// so the live fields are hidden before 0.5 s and shown afterwards.
    private var depthSamples: [DiveSample] {
        (0...12).map { index in
            let t = 0.5 + Double(index) * 0.25
            return DiveSample(id: index, elapsedSeconds: t, depthMeters: 12 * sin(.pi * (t - 0.5) / 3),
                              temperatureCelsius: 28.5 - Double(index) * 0.1)
        }
    }

    private func makePoolTimeline() throws -> PoolTimeline {
        // 0 m at 0.5 s, 2 m at 2 s, 4 m at 3.5 s inside the 4 s test video.
        var session = PoolSession(poolLength: 25, finalDistance: 4)
        for node in session.nodes { session.setTime(node.distance == 0 ? 0.5 : 3.5, for: node.id) }
        session.addCheckpoint(distance: 2)
        if let checkpoint = session.nodes.first(where: { $0.kind == .checkpoint }) {
            session.setTime(2.0, for: checkpoint.id)
        }
        return try PoolTimeline(session: session)
    }

    /// Depth settings with user styles on a few fields (colour, shadow, contrast, rotation).
    private var styledDepthSettings: HUDSettings {
        var settings = HUDSettings()
        settings.setStyle(HUDItemStyle(color: HUDColor(red: 1, green: 0.55, blue: 0.1), shadow: 1, contrast: 1.3), for: "depthValue")
        settings.setStyle(HUDItemStyle(shadow: 0.6, contrast: 1.5), for: "tempValue")
        settings.setStyle(HUDItemStyle(color: HUDColor(red: 1, green: 0.85, blue: 0.2), contrast: 0.8), for: "profileBlock")
        settings.transforms["tempValue"] = HUDTransform(scale: 1.2, rotation: 30)
        return settings
    }

    /// The source frame at `time`, filled into the output size with the export's centre crop.
    private func sourceFrame(_ url: URL, at time: Double, size: CGSize) async throws -> CIImage {
        let image = try await TestVideoFactory.frame(of: url, at: time, maximumSize: CGSize(width: 4000, height: 4000))
        return try XCTUnwrap(filled(image, size: size))
    }

    private func exportedFrame(_ url: URL, at time: Double) async throws -> CGImage {
        let image = try await TestVideoFactory.frame(of: url, at: time, maximumSize: CGSize(width: 4000, height: 4000))
        return try XCTUnwrap(image.cgImage)
    }

    // MARK: Video path

    @MainActor
    func testExportFollowsTheSourceQualityCropsToTheShapeAndReportsProgress() async throws {
        let source = try await portraitSource()
        // A 720 × 1280 source keeps its pixel count in every shape.
        for (aspect, expected) in [(OutputAspect.vertical916, CGSize(width: 720, height: 1280)),
                                   (OutputAspect.landscape169, CGSize(width: 1280, height: 720)),
                                   (OutputAspect.square, CGSize(width: 960, height: 960))] {
            let output = workDirectory.appendingPathComponent("bare-\(aspect.rawValue).mp4")
            let recorder = ExportRecorder()
            let result = try await recorder.run { progress, completion in
                DiveVideoExporter().exportVideo(videoURL: source, outputURL: output, aspect: aspect,
                                                progress: progress, completion: completion,
                                                makeHUD: { size, _ in
                                                    let layer = CALayer()
                                                    layer.frame = CGRect(origin: .zero, size: size)
                                                    return layer
                                                })
            }
            let size = try await TestVideoFactory.videoSize(of: result)
            XCTAssertEqual(size, expected, "\(aspect)")
            XCTAssertEqual(recorder.progressValues.last, 1)
            XCTAssertTrue(recorder.progressValues.contains { $0 > 0.02 && $0 < 0.98 },
                          "progress should move during the export: \(recorder.progressValues)")
            let frame = try await TestVideoFactory.frame(of: result, at: 2.0, maximumSize: CGSize(width: 960, height: 960))
            TestArtifacts.save(frame, name: "video-path-\(aspect.rawValue).png")
        }
    }

    /// A phone video is stored landscape with a 90° rotation; the export must be upright.
    @MainActor
    func testRotatedSourceIsExportedUpright() async throws {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let source = workDirectory.appendingPathComponent("source-rotated.mp4")
        let rotate = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 720, ty: 0)
        try await TestVideoFactory.makeVideo(url: source, size: CGSize(width: 1280, height: 720), duration: 3, transform: rotate)
        let output = workDirectory.appendingPathComponent("rotated-out.mp4")
        let result = try await ExportRecorder().run { progress, completion in
            DiveVideoExporter().exportVideo(videoURL: source, outputURL: output, aspect: .original,
                                            progress: progress, completion: completion,
                                            makeHUD: { size, _ in CALayer() })
        }
        let size = try await TestVideoFactory.videoSize(of: result)
        XCTAssertEqual(size, CGSize(width: 720, height: 1280))
        let expected = try await TestVideoFactory.frame(of: source, at: 1.5, maximumSize: CGSize(width: 720, height: 1280))
        let exported = try await TestVideoFactory.frame(of: result, at: 1.5, maximumSize: CGSize(width: 720, height: 1280))
        let difference = PixelCompare.meanDifference(try XCTUnwrap(expected.cgImage), try XCTUnwrap(exported.cgImage),
                                                     size: CGSize(width: 180, height: 320))
        TestArtifacts.save(TestArtifacts.sideBySide(expected, exported, height: 640), name: "rotated-source-vs-export.png")
        XCTAssertLessThan(difference, 10, "the exported frame should be the upright source frame")
    }

    // MARK: Full exports with the HUD (the 1.2 device bug: values did not move, fields missing)

    @MainActor
    func testDepthExportWithHUDShowsTheValuesOfEachFrame() async throws {
        let source = try await portraitSource()
        let samples = depthSamples
        let sync = try TimelineSync(offsetSeconds: 0)
        let settings = styledDepthSettings
        let exportSettings = DiveExportSettings(hudSettings: settings, deviceName: "ATMOS MISSION 2")
        let output = workDirectory.appendingPathComponent("depth-hud.mp4")
        let started = Date()
        let result = try await ExportRecorder().run { progress, completion in
            DiveVideoExporter().export(videoURL: source, samples: samples, maximumDepth: 12, sync: sync,
                                       settings: exportSettings, aspect: .vertical916, outputURL: output,
                                       progress: progress, completion: completion)
        }
        print("[export-test] depth 4 s 720×1280 export with HUD took \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        let size = try await TestVideoFactory.videoSize(of: result)
        XCTAssertEqual(size, CGSize(width: 720, height: 1280))

        // The same HUD the exporter drew, rendered for checking.
        let hud = DiveVideoExporter().makeHUDLayer(size: size, samples: samples, maximumDepth: 12, videoDuration: 4,
                                                   sync: sync, settings: exportSettings)
        let renderer = HUDOverlayRenderer(root: hud)
        let visible = HUDItemDefinition.all.filter { settings.visibility[$0.id] ?? true }
        let live = visible.filter { HUDItemDefinition.liveIDs.contains($0.id) }
        XCTAssertEqual(renderer.visibleItemCount(at: 0.2), visible.count - live.count, "live fields hidden before the dive")
        XCTAssertEqual(renderer.visibleItemCount(at: 1.5), visible.count, "every field shown during the dive")

        let compareSize = CGSize(width: 360, height: 640)
        var stills: [Double: CGImage] = [:]
        for time in [0.2, 1.5, 3.0] {
            let background = try await sourceFrame(source, at: time, size: size)
            let exported = try await exportedFrame(result, at: time)
            // Tagged like the decoded frame, so only real differences count.
            let expected = try XCTUnwrap(renderer.still(at: time, background: background, colorSpace: exported.colorSpace))
            stills[time] = expected
            let difference = PixelCompare.meanDifference(expected, exported, size: compareSize)
            print("[export-test] depth frame \(time) s differs from the expected frame by \(difference)")
            XCTAssertLessThan(difference, 5, "exported frame at \(time) s should be the video plus the HUD of that time")
            TestArtifacts.save(TestArtifacts.sideBySide(UIImage(cgImage: expected), UIImage(cgImage: exported), height: 960),
                               name: "depth-hud-frame-\(time)s-expected-vs-exported.png")
        }

        // The values move: the 1.5 s frame matches the 1.5 s HUD much better than the 3.0 s HUD.
        let exported15 = try await exportedFrame(result, at: 1.5)
        let depthRegion = PixelCompare.region(around: settings.positions["depthValue"]!, halfWidth: 0.16, halfHeight: 0.05)
        let own = PixelCompare.meanDifference(try XCTUnwrap(stills[1.5]), exported15, size: compareSize, region: depthRegion)
        let other = PixelCompare.meanDifference(try XCTUnwrap(stills[3.0]), exported15, size: compareSize, region: depthRegion)
        print("[export-test] depth value region: own time \(own), other time \(other)")
        XCTAssertGreaterThan(other, own + 4, "the depth value must change between 1.5 s and 3.0 s")

        // DIVE TIME, WATER TEMP, the labels, the name and the chart are drawn: in the HUD
        // itself and in the exported frame (compared with the bare video frame).
        let overlay = try XCTUnwrap(renderer.still(at: 1.5))
        let bareBackground = try await sourceFrame(source, at: 1.5, size: size)
        let exportedFrame = try await exportedFrame(result, at: 1.5)
        let bare = try XCTUnwrap(Self.bitmap(bareBackground, size: size, colorSpace: exportedFrame.colorSpace))
        for id in ["elapsedValue", "elapsedLabel", "tempValue", "tempLabel", "speedValue", "speedLabel",
                   "identityGroup", "profileBlock", "depthGauge"] {
            let region = id == "profileBlock"
                ? PixelCompare.region(around: settings.positions[id]!, halfWidth: 0.42, halfHeight: 0.08)
                : id == "depthGauge"
                ? PixelCompare.region(around: settings.positions[id]!, halfWidth: 0.09, halfHeight: 0.12)
                : PixelCompare.region(around: settings.positions[id]!)
            let alpha = PixelCompare.meanAlpha(overlay, size: compareSize, region: region)
            XCTAssertGreaterThan(alpha, 3, "\(id) should be drawn at 1.5 s (alpha \(alpha))")
            let drawn = PixelCompare.meanDifference(bare, exportedFrame, size: compareSize, region: region)
            print("[export-test] \(id): HUD alpha \(alpha), exported frame vs bare video \(drawn)")
            // The chart is thin lines over a wide area, so its average change is smaller.
            // (An area without HUD differs by about 0.2 from the bare frame.)
            XCTAssertGreaterThan(drawn, id == "profileBlock" ? 1 : 3, "\(id) should be in the exported frame at 1.5 s")
        }
    }

    @MainActor
    func testPoolExportWithHUDShowsTheValuesOfEachFrame() async throws {
        let source = try await portraitSource()
        let timeline = try makePoolTimeline()
        var settings = PoolHUDSettings()
        settings.visibility["averageSpeed"] = true
        settings.setStyle(HUDItemStyle(color: HUDColor(red: 0.4, green: 1, blue: 0.5), shadow: 0.8), for: "distanceValue")
        let output = workDirectory.appendingPathComponent("pool-hud.mp4")
        let result = try await ExportRecorder().run { progress, completion in
            DiveVideoExporter().exportPool(videoURL: source, timeline: timeline, settings: settings, aspect: .landscape169,
                                           outputURL: output, progress: progress, completion: completion)
        }
        let size = try await TestVideoFactory.videoSize(of: result)
        XCTAssertEqual(size, CGSize(width: 1280, height: 720))

        let renderer = HUDOverlayRenderer(root: PoolHUDLayerBuilder(timeline: timeline, settings: settings, videoDuration: 4)
            .makeLayer(size: size))
        let compareSize = CGSize(width: 640, height: 360)
        var stills: [Double: CGImage] = [:]
        for time in [1.0, 3.0] {
            let background = try await sourceFrame(source, at: time, size: size)
            let exported = try await exportedFrame(result, at: time)
            let expected = try XCTUnwrap(renderer.still(at: time, background: background, colorSpace: exported.colorSpace))
            stills[time] = expected
            let difference = PixelCompare.meanDifference(expected, exported, size: compareSize)
            print("[export-test] pool frame \(time) s differs from the expected frame by \(difference)")
            XCTAssertLessThan(difference, 5, "exported frame at \(time) s should be the video plus the HUD of that time")
            TestArtifacts.save(TestArtifacts.sideBySide(UIImage(cgImage: expected), UIImage(cgImage: exported), height: 540),
                               name: "pool-hud-frame-\(time)s-expected-vs-exported.png")
        }
        let exported1 = try await exportedFrame(result, at: 1.0)
        let region = PixelCompare.region(around: settings.positions["distanceValue"]!, halfWidth: 0.12, halfHeight: 0.08)
        let own = PixelCompare.meanDifference(try XCTUnwrap(stills[1.0]), exported1, size: compareSize, region: region)
        let other = PixelCompare.meanDifference(try XCTUnwrap(stills[3.0]), exported1, size: compareSize, region: region)
        XCTAssertGreaterThan(other, own + 4, "the distance value must change between 1 s and 3 s")
    }

    // MARK: Export HUD vs preview (images for review)

    @MainActor
    func testDepthExportHUDMatchesPreview() async throws {
        let source = try await portraitSource()
        let background = try await TestVideoFactory.frame(of: source, at: 2.0)
        let samples = depthSamples
        let sync = try TimelineSync(offsetSeconds: 0)
        let reading = DiveStageView.reading(samples: samples, sync: sync, videoTime: 2.0)
        XCTAssertNotNil(reading)

        for (name, settings) in [("default", HUDSettings()), ("styled", styledDepthSettings)] {
            for (aspect, stage) in [(OutputAspect.vertical916, CGSize(width: 360, height: 640)),
                                    (OutputAspect.landscape169, CGSize(width: 640, height: 360))] {
                // A 4K source: the export is 2160 × 3840 / 3840 × 2160.
                let renderSize = ExportSizing.renderSize(aspect: aspect.ratio(source: 9.0 / 16.0),
                                                         sourceSize: CGSize(width: 2160, height: 3840))
                let hud = DiveVideoExporter().makeHUDLayer(size: renderSize, samples: samples, maximumDepth: 12,
                                                           videoDuration: 4, sync: sync,
                                                           settings: DiveExportSettings(hudSettings: settings, deviceName: "ATMOS MISSION 2"))
                XCTAssertEqual(hud.sublayers?.count, HUDItemDefinition.all.filter { settings.visibility[$0.id] ?? true }.count)
                let ciBackground = filled(background, size: renderSize)
                let exported = try XCTUnwrap(HUDOverlayRenderer(root: hud).still(at: 2.0, background: ciBackground))

                let preview = PreviewRenderer.image(
                    Color.black
                        .overlay(Image(uiImage: background).resizable().scaledToFill())
                        .clipped()
                        .overlay(DiveHUDOverlay(reading: reading, samples: samples, maximumDepth: 12, deviceName: "ATMOS MISSION 2",
                                                settings: .constant(settings), selectedItem: .constant(""), isEditing: false)),
                    size: stage
                )
                let previewImage = try XCTUnwrap(preview)
                TestArtifacts.save(TestArtifacts.sideBySide(previewImage, UIImage(cgImage: exported),
                                                            height: aspect == .landscape169 ? 540 : 960),
                                   name: "depth-\(name)-\(aspect.rawValue)-preview-vs-export.png")
                let difference = PixelCompare.meanDifference(try XCTUnwrap(previewImage.cgImage), exported,
                                                             size: CGSize(width: stage.width, height: stage.height))
                print("[export-test] depth \(name) \(aspect.rawValue) preview vs export difference \(difference)")
                XCTAssertLessThan(difference, 12, "preview and export should look the same")
            }
        }
    }

    @MainActor
    func testPoolExportHUDMatchesPreview() async throws {
        let source = try await portraitSource()
        let background = try await TestVideoFactory.frame(of: source, at: 2.5)
        let timeline = try makePoolTimeline()
        var settings = PoolHUDSettings()
        settings.visibility["totalDistance"] = true
        settings.visibility["averageSpeed"] = true
        settings.setStyle(HUDItemStyle(color: HUDColor(red: 1, green: 0.4, blue: 0.6), shadow: 1), for: "lapValue")

        for (aspect, stage) in [(OutputAspect.vertical916, CGSize(width: 360, height: 640)),
                                (OutputAspect.landscape169, CGSize(width: 640, height: 360)),
                                (OutputAspect.square, CGSize(width: 480, height: 480))] {
            let renderSize = ExportSizing.renderSize(aspect: aspect.ratio(source: 9.0 / 16.0),
                                                     sourceSize: CGSize(width: 2160, height: 3840))
            let hud = PoolHUDLayerBuilder(timeline: timeline, settings: settings, videoDuration: 4).makeLayer(size: renderSize)
            let exported = try XCTUnwrap(HUDOverlayRenderer(root: hud).still(at: 2.5, background: filled(background, size: renderSize)))

            let preview = PreviewRenderer.image(
                Color.black
                    .overlay(Image(uiImage: background).resizable().scaledToFill())
                    .clipped()
                    .overlay(PoolHUDOverlay(reading: timeline.reading(atVideoTime: 2.5), timeline: timeline,
                                            settings: .constant(settings), selectedItem: .constant(""), isEditing: false)),
                size: stage
            )
            let previewImage = try XCTUnwrap(preview)
            TestArtifacts.save(TestArtifacts.sideBySide(previewImage, UIImage(cgImage: exported),
                                                        height: aspect == .landscape169 ? 540 : 720),
                               name: "pool-\(aspect.rawValue)-preview-vs-export.png")
            let difference = PixelCompare.meanDifference(try XCTUnwrap(previewImage.cgImage), exported, size: stage)
            print("[export-test] pool \(aspect.rawValue) preview vs export difference \(difference)")
            XCTAssertLessThan(difference, 12, "preview and export should look the same")
        }
    }

    /// The floating preview is small; its HUD must be the stage's HUD scaled down.
    @MainActor
    func testSmallPreviewHasTheSameProportionsAsTheStage() throws {
        let samples = depthSamples
        let reading = DiveStageView.reading(samples: samples, sync: try TimelineSync(offsetSeconds: 0), videoTime: 2.0)
        func render(_ size: CGSize, scale: CGFloat) -> CGImage? {
            PreviewRenderer.image(
                Color.black.overlay(DiveHUDOverlay(reading: reading, samples: samples, maximumDepth: 12, deviceName: "ATMOS",
                                                   settings: .constant(styledDepthSettings), selectedItem: .constant(""),
                                                   isEditing: false)),
                size: size, scale: scale
            )?.cgImage
        }
        let stage = try XCTUnwrap(render(CGSize(width: 360, height: 640), scale: 1))
        let small = try XCTUnwrap(render(CGSize(width: 170, height: 302.2), scale: 360.0 / 170.0))
        let difference = PixelCompare.meanDifference(stage, small, size: CGSize(width: 180, height: 320))
        TestArtifacts.save(TestArtifacts.sideBySide(UIImage(cgImage: stage), UIImage(cgImage: small), height: 640),
                           name: "stage-vs-floating-preview.png")
        print("[export-test] stage vs small preview difference \(difference)")
        XCTAssertLessThan(difference, 6, "the small preview should be the stage scaled down")
    }

    /// A Core Image frame as a bitmap (no colour conversion, like the export).
    private static func bitmap(_ image: CIImage, size: CGSize, colorSpace: CGColorSpace?) -> CGImage? {
        let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let frame = CGRect(origin: .zero, size: size)
        return context.createCGImage(image.cropped(to: frame), from: frame, format: .RGBA8, colorSpace: colorSpace)
    }

    /// `image` scaled to fill `size` with a centre crop, like the export.
    private func filled(_ image: UIImage, size: CGSize) -> CIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let source = CIImage(cgImage: cgImage, options: [.colorSpace: NSNull()])
        let scale = max(size.width / source.extent.width, size.height / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled.transformed(by: CGAffineTransform(translationX: (size.width - scaled.extent.width) / 2,
                                                        y: (size.height - scaled.extent.height) / 2))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    // MARK: Device-only checks

    @MainActor
    func testMotionAnalyzerProducesASignal() async throws {
        let source = try await portraitSource()
        let analyzer = PoolMotionAnalyzer(url: source, startTime: 0.2, endTime: 3.8, sampleRate: 5)
        let signal: PoolMotionSignal
        do {
            signal = try await analyzer.analyze { _ in }
        } catch PoolMotionAnalyzer.AnalysisError.noFrames(let reason) {
            #if targetEnvironment(simulator)
            // Vision's optical flow may not run on the simulator; report why instead of failing.
            throw XCTSkip("Vision optical flow unavailable on the simulator: \(reason)")
            #else
            XCTFail("analysis failed: \(reason)")
            return
            #endif
        }
        XCTAssertGreaterThanOrEqual(signal.times.count, 8)
        XCTAssertEqual(signal.times.count, signal.values.count)
        XCTAssertTrue(signal.values.allSatisfy { $0.isFinite && $0 >= 0 })
        XCTAssertGreaterThan(signal.values.max() ?? 0, 0, "the moving lanes and swimmer should register motion")
        XCTAssertTrue((0...1).contains(signal.detectionRate))
    }
}
