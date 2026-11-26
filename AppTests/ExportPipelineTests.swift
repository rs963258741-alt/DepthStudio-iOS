import XCTest
import AVFoundation
import SwiftUI
@testable import DepthStudio

/// Exports a generated test video in both modes and saves "preview | exported frame"
/// images to build/test-artifacts for visual comparison.
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
        try await TestVideoFactory.makeVideo(url: url, size: CGSize(width: 720, height: 1280), duration: 4)
        return url
    }

    /// Depth samples covering the whole 4 s test video (watch time = video time).
    private var depthSamples: [DiveSample] {
        (0...8).map { index in
            let t = Double(index) * 0.5
            return DiveSample(id: index, elapsedSeconds: t, depthMeters: 12 * sin(.pi * t / 4), temperatureCelsius: 28.5)
        }
    }

    @MainActor
    func testDepthExportIs4KPortraitMatchesPreviewAndReportsProgress() async throws {
        let source = try await portraitSource()
        let output = workDirectory.appendingPathComponent("depth-916.mp4")
        let samples = depthSamples
        let sync = try TimelineSync(offsetSeconds: 0)
        let settings = HUDSettings()
        let recorder = ExportRecorder()
        let result = try await recorder.run { progress, completion in
            DiveVideoExporter().export(videoURL: source, samples: samples, maximumDepth: 12, sync: sync,
                                       settings: DiveExportSettings(hudSettings: settings, deviceName: "ATMOS MISSION 2"),
                                       aspect: .vertical916, outputURL: output, progress: progress, completion: completion)
        }
        let size = try await TestVideoFactory.videoSize(of: result)
        XCTAssertEqual(size, CGSize(width: 2160, height: 3840))
        XCTAssertTrue(recorder.progressValues.contains { $0 > 0.02 && $0 < 0.98 },
                      "progress should move during the export: \(recorder.progressValues)")
        XCTAssertEqual(recorder.progressValues.last, 1)

        let exported = try await TestVideoFactory.frame(of: result, at: 2.0)
        let still = try await TestVideoFactory.frame(of: source, at: 2.0)
        let reading = DiveStageView.reading(samples: samples, sync: sync, videoTime: 2.0)
        let preview = PreviewRenderer.image(
            ZStack {
                Image(uiImage: still).resizable().scaledToFill()
                DiveHUDOverlay(reading: reading, samples: samples, maximumDepth: 12, deviceName: "ATMOS MISSION 2",
                               settings: .constant(settings), selectedItem: .constant(""), isEditing: false)
            }
            .clipped(),
            size: CGSize(width: 360, height: 640)
        )
        let previewImage = try XCTUnwrap(preview)
        TestArtifacts.save(TestArtifacts.sideBySide(previewImage, exported), name: "depth-916-preview-vs-export.png")
    }

    @MainActor
    func testPoolExportLandscapeAndSquare() async throws {
        let source = try await portraitSource()
        // Pool timeline inside the 4 s video: 0 m at 0.5 s, 2 m at 2 s, 4 m at 3.5 s.
        var session = PoolSession(poolLength: 25, finalDistance: 4)
        for node in session.nodes {
            session.setTime(node.distance == 0 ? 0.5 : 3.5, for: node.id)
        }
        XCTAssertTrue(session.addCheckpoint(distance: 2))
        if let checkpoint = session.nodes.first(where: { $0.kind == .checkpoint }) {
            session.setTime(2.0, for: checkpoint.id)
        }
        let timeline = try PoolTimeline(session: session)
        var settings = PoolHUDSettings()
        settings.visibility["totalDistance"] = true
        settings.visibility["averageSpeed"] = true

        for (aspect, expected, stage) in [
            (OutputAspect.landscape169, CGSize(width: 3840, height: 2160), CGSize(width: 640, height: 360)),
            (OutputAspect.square, CGSize(width: 2880, height: 2880), CGSize(width: 480, height: 480))
        ] {
            let output = workDirectory.appendingPathComponent("pool-\(aspect.rawValue).mp4")
            let recorder = ExportRecorder()
            let result = try await recorder.run { progress, completion in
                DiveVideoExporter().exportPool(videoURL: source, timeline: timeline, settings: settings, aspect: aspect,
                                               outputURL: output, progress: progress, completion: completion)
            }
            let size = try await TestVideoFactory.videoSize(of: result)
            XCTAssertEqual(size, expected, "\(aspect)")

            let exported = try await TestVideoFactory.frame(of: result, at: 2.5)
            let still = try await TestVideoFactory.frame(of: source, at: 2.5)
            let preview = PreviewRenderer.image(
                ZStack {
                    Image(uiImage: still).resizable().scaledToFill()
                    PoolHUDOverlay(reading: timeline.reading(atVideoTime: 2.5), timeline: timeline,
                                   settings: .constant(settings), selectedItem: .constant(""), isEditing: false)
                }
                .clipped(),
                size: stage
            )
            let previewImage = try XCTUnwrap(preview)
            TestArtifacts.save(TestArtifacts.sideBySide(previewImage, exported, height: aspect == .landscape169 ? 540 : 720),
                               name: "pool-\(aspect.rawValue)-preview-vs-export.png")
        }
    }

    @MainActor
    func testMotionAnalyzerProducesASignal() async throws {
        let source = try await portraitSource()
        let analyzer = PoolMotionAnalyzer(url: source, startTime: 0.2, endTime: 3.8, sampleRate: 5)
        let signal = try await analyzer.analyze { _ in }
        XCTAssertGreaterThanOrEqual(signal.times.count, 8)
        XCTAssertEqual(signal.times.count, signal.values.count)
        XCTAssertTrue(signal.values.allSatisfy { $0.isFinite && $0 >= 0 })
        XCTAssertGreaterThan(signal.values.max() ?? 0, 0, "the moving lanes and swimmer should register motion")
        XCTAssertTrue((0...1).contains(signal.detectionRate))
    }
}
