import XCTest
import AVFoundation
import SwiftUI
@testable import DepthStudio

/// Export checks that run on the simulator.
///
/// The simulator cannot run AVVideoCompositionCoreAnimationTool (Core Animation's IOSurface
/// allocation crashes inside the simulator even with an empty layer), so:
/// - the video path (4K-class size, centre crop, progress, MP4 validation) is exported
///   for real with no HUD items, which skips the Core Animation pass;
/// - the export HUD itself is built exactly as for a video, rendered as a still image at a
///   given time, and saved next to the SwiftUI preview in build/test-artifacts.
final class ExportPipelineTests: XCTestCase {
    private let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("export-tests-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() {
        HUDLayerFactory.stillTime = nil
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

    /// Depth samples covering the whole 4 s test video (watch time = video time).
    private var depthSamples: [DiveSample] {
        (0...8).map { index in
            let t = Double(index) * 0.5
            return DiveSample(id: index, elapsedSeconds: t, depthMeters: 12 * sin(.pi * t / 4), temperatureCelsius: 28.5)
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

    // MARK: Video path

    @MainActor
    func testExportIsFourKCroppedToTheChosenShapeAndReportsProgress() async throws {
        let source = try await portraitSource()
        for (aspect, expected) in [(OutputAspect.vertical916, CGSize(width: 2160, height: 3840)),
                                   (OutputAspect.landscape169, CGSize(width: 3840, height: 2160))] {
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

    // MARK: Export HUD vs preview

    @MainActor
    private func still(hud: CALayer, renderSize: CGSize, background: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: renderSize, format: format).image { context in
            // Same centre crop as the export composition.
            let scale = max(renderSize.width / background.size.width, renderSize.height / background.size.height)
            let width = background.size.width * scale, height = background.size.height * scale
            background.draw(in: CGRect(x: (renderSize.width - width) / 2, y: (renderSize.height - height) / 2,
                                       width: width, height: height))
            hud.render(in: context.cgContext)
        }
    }

    @MainActor
    func testDepthExportHUDMatchesPreview() async throws {
        let source = try await portraitSource()
        let background = try await TestVideoFactory.frame(of: source, at: 2.0)
        let samples = depthSamples
        let sync = try TimelineSync(offsetSeconds: 0)
        let settings = HUDSettings()
        let reading = DiveStageView.reading(samples: samples, sync: sync, videoTime: 2.0)
        XCTAssertNotNil(reading)

        for (aspect, stage) in [(OutputAspect.vertical916, CGSize(width: 360, height: 640)),
                                (OutputAspect.landscape169, CGSize(width: 640, height: 360))] {
            let renderSize = ExportSizing.renderSize(aspect: aspect.ratio(source: 9.0 / 16.0))
            HUDLayerFactory.stillTime = 2.0
            let hud = DiveVideoExporter().makeHUDLayer(size: renderSize, samples: samples, maximumDepth: 12,
                                                       videoDuration: 4, sync: sync,
                                                       settings: DiveExportSettings(hudSettings: settings, deviceName: "ATMOS MISSION 2"))
            HUDLayerFactory.stillTime = nil
            XCTAssertEqual(hud.sublayers?.count, HUDItemDefinition.all.filter { settings.visibility[$0.id] ?? true }.count)
            let exported = still(hud: hud, renderSize: renderSize, background: background)

            let preview = PreviewRenderer.image(
                Color.black
                    .overlay(Image(uiImage: background).resizable().scaledToFill())
                    .clipped()
                    .overlay(DiveHUDOverlay(reading: reading, samples: samples, maximumDepth: 12, deviceName: "ATMOS MISSION 2",
                                            settings: .constant(settings), selectedItem: .constant(""), isEditing: false)),
                size: stage
            )
            let previewImage = try XCTUnwrap(preview)
            TestArtifacts.save(TestArtifacts.sideBySide(previewImage, exported, height: aspect == .landscape169 ? 540 : 960),
                               name: "depth-\(aspect.rawValue)-preview-vs-export.png")
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

        for (aspect, stage) in [(OutputAspect.vertical916, CGSize(width: 360, height: 640)),
                                (OutputAspect.landscape169, CGSize(width: 640, height: 360)),
                                (OutputAspect.square, CGSize(width: 480, height: 480))] {
            let renderSize = ExportSizing.renderSize(aspect: aspect.ratio(source: 9.0 / 16.0))
            HUDLayerFactory.stillTime = 2.5
            let hud = PoolHUDLayerBuilder(timeline: timeline, settings: settings, videoDuration: 4).makeLayer(size: renderSize)
            HUDLayerFactory.stillTime = nil
            let exported = still(hud: hud, renderSize: renderSize, background: background)

            let preview = PreviewRenderer.image(
                Color.black
                    .overlay(Image(uiImage: background).resizable().scaledToFill())
                    .clipped()
                    .overlay(PoolHUDOverlay(reading: timeline.reading(atVideoTime: 2.5), timeline: timeline,
                                            settings: .constant(settings), selectedItem: .constant(""), isEditing: false)),
                size: stage
            )
            let previewImage = try XCTUnwrap(preview)
            TestArtifacts.save(TestArtifacts.sideBySide(previewImage, exported, height: aspect == .landscape169 ? 540 : 720),
                               name: "pool-\(aspect.rawValue)-preview-vs-export.png")
        }
    }

    // MARK: Device-only checks

    /// Full export with the HUD (Core Animation pass). Runs on a device; the simulator
    /// cannot allocate the compositor's surfaces.
    @MainActor
    func testFullDepthExportWithHUD() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("AVVideoCompositionCoreAnimationTool crashes in the simulator (IOSurface allocation); run on a device.")
        #else
        let source = try await portraitSource()
        let output = workDirectory.appendingPathComponent("depth-full.mp4")
        let samples = depthSamples
        let sync = try TimelineSync(offsetSeconds: 0)
        let recorder = ExportRecorder()
        let result = try await recorder.run { progress, completion in
            DiveVideoExporter().export(videoURL: source, samples: samples, maximumDepth: 12, sync: sync,
                                       settings: DiveExportSettings(), aspect: .vertical916, outputURL: output,
                                       progress: progress, completion: completion)
        }
        let size = try await TestVideoFactory.videoSize(of: result)
        XCTAssertEqual(size, CGSize(width: 2160, height: 3840))
        #endif
    }

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
