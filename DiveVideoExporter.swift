import Foundation
import AVFoundation
import UIKit
import QuartzCore

struct DiveExportSettings {
    var hudSettings: HUDSettings
    var deviceName: String
    var outputFileType: AVFileType = .mp4

    init(hudSettings: HUDSettings = HUDSettings(), deviceName: String = "DEPTH STUDIO") {
        self.hudSettings = hudSettings
        self.deviceName = deviceName
    }
}

enum DiveExportError: LocalizedError {
    case noVideoTrack
    case invalidDuration
    case invalidSamples
    case cannotCreateExportSession
    case unsupportedOutputType
    case exportFailed(String)
    case invalidMP4(String)
    case outputResolutionTooSmall
    case audioTrackMissing
    case videoPacketValidationFailed(String)
    case videoFrameDecodeFailed

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "找不到可輸出的影片影像軌。"
        case .invalidDuration: return "影片長度無效。"
        case .invalidSamples: return "手錶數據不足或時間戳重複，無法建立 HUD。"
        case .cannotCreateExportSession: return "無法建立影片輸出工作。"
        case .unsupportedOutputType: return "目前輸出格式不受支援，請選擇 MP4。"
        case .exportFailed(let message): return "輸出工作失敗：\(message)"
        case .invalidMP4(let message): return "MP4 完整性檢查失敗：\(message)"
        case .outputResolutionTooSmall: return "輸出影片未達 4K 等級畫素（3840 × 2160 的像素量）。"
        case .audioTrackMissing: return "來源影片含有音訊，但輸出影片沒有保留音訊軌。"
        case .videoPacketValidationFailed(let message): return "輸出影片封包驗證失敗：\(message)"
        case .videoFrameDecodeFailed: return "輸出影片無法解碼首個影格。"
        }
    }
}

/// Native iOS counterpart of the V8.18 web canvas exporter.
///
/// The output frame has the shape chosen in the preview (版型) and the pixel count of 4K
/// UHD (3840 × 2160 → exactly 2160 × 3840 for 9:16); the source video fills it with a
/// centre crop, like the preview. The HUD is rendered with Core Animation from the same
/// settings and the same sizing rules (HUDMetrics) as the SwiftUI preview.
final class DiveVideoExporter {
    /// 深度潛水 export: the depth HUD over the source video.
    func export(
        videoURL: URL,
        samples: [DiveSample],
        maximumDepth: Double,
        sync: TimelineSync,
        settings: DiveExportSettings,
        aspect: OutputAspect = .original,
        outputURL: URL,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let sorted = samples.sorted { $0.elapsedSeconds < $1.elapsedSeconds }
        guard sorted.count >= 2,
              zip(sorted, sorted.dropFirst()).allSatisfy({ $0.elapsedSeconds < $1.elapsedSeconds }) else {
            completion(.failure(DiveExportError.invalidSamples))
            return
        }
        exportVideo(
            videoURL: videoURL,
            outputURL: outputURL,
            outputFileType: settings.outputFileType,
            aspect: aspect,
            progress: progress,
            completion: completion,
            makeHUD: { renderSize, videoDuration in
                self.makeHUDLayer(size: renderSize, samples: sorted, maximumDepth: maximumDepth,
                                  videoDuration: videoDuration, sync: sync, settings: settings)
            }
        )
    }

    /// Shared export path for every mode: renders the source video into the chosen output
    /// shape at 4K-class size, composites the HUD layer from `makeHUD(renderSize, videoDuration)`,
    /// keeps the audio and validates the resulting MP4. `progress` receives 0...1 on the main actor.
    func exportVideo(
        videoURL: URL,
        outputURL: URL,
        outputFileType: AVFileType = .mp4,
        aspect: OutputAspect = .original,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void,
        makeHUD: @escaping (CGSize, Double) -> CALayer
    ) {
        let asset = AVURLAsset(url: videoURL)
        Task {
            do {
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                guard let sourceVideoTrack = videoTracks.first else { throw DiveExportError.noVideoTrack }
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                let duration = try await asset.load(.duration)
                guard duration.seconds.isFinite, duration.seconds > 0 else { throw DiveExportError.invalidDuration }

                let naturalSize = try await sourceVideoTrack.load(.naturalSize)
                let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
                let sourceFrameDuration = try await sourceVideoTrack.load(.minFrameDuration)
                let displayRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
                let sourceSize = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
                guard sourceSize.width > 0, sourceSize.height > 0 else { throw DiveExportError.invalidDuration }

                let renderSize = ExportSizing.renderSize(aspect: aspect.ratio(source: sourceSize.width / sourceSize.height))
                let composition = makeVideoComposition(
                    sourceVideoTrack: sourceVideoTrack,
                    duration: duration,
                    naturalSize: naturalSize,
                    preferredTransform: preferredTransform,
                    sourceFrameDuration: sourceFrameDuration,
                    renderSize: renderSize,
                    hud: makeHUD(renderSize, duration.seconds)
                )

                try? FileManager.default.removeItem(at: outputURL)
                guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                    throw DiveExportError.cannotCreateExportSession
                }
                guard session.supportedFileTypes.contains(outputFileType) else { throw DiveExportError.unsupportedOutputType }
                session.videoComposition = composition
                session.outputURL = outputURL
                session.outputFileType = outputFileType
                // Moving the index to the front rewrites the whole file once more; Photos
                // and sharing do not need it.
                session.shouldOptimizeForNetworkUse = false

                // Poll progress until the session has finished. (It starts in .waiting, so
                // the loop must not stop just because the status is not .exporting yet.)
                let progressTask = Task.detached(priority: .utility) {
                    while !Task.isCancelled {
                        let status = session.status
                        if status == .completed || status == .failed || status == .cancelled { break }
                        let value = Double(session.progress)
                        await MainActor.run { progress?(value) }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
                do {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        session.exportAsynchronously {
                            switch session.status {
                            case .completed: continuation.resume()
                            case .failed: continuation.resume(throwing: session.error ?? DiveExportError.exportFailed("未知錯誤"))
                            case .cancelled: continuation.resume(throwing: CancellationError())
                            default: continuation.resume(throwing: DiveExportError.exportFailed("輸出工作未正常完成（\(session.status.rawValue)）"))
                            }
                        }
                    }
                } catch {
                    progressTask.cancel()
                    throw error
                }
                progressTask.cancel()

                await MainActor.run { progress?(1) }
                try await validateOutput(url: outputURL, expectedSize: renderSize, sourceHadAudio: !audioTracks.isEmpty)
                completion(.success(outputURL))
            } catch {
                try? FileManager.default.removeItem(at: outputURL)
                completion(.failure(error))
            }
        }
    }

    /// Output frame rate: the source's, capped at 60 fps (120/240 fps clips would multiply
    /// the 4K encoding work without visible benefit).
    static func outputFrameDuration(source: CMTime) -> CMTime {
        let fastest = CMTime(value: 1, timescale: 60)
        guard source.isValid, source.seconds.isFinite, source.seconds > 0 else { return CMTime(value: 1, timescale: 30) }
        return source.seconds < fastest.seconds ? fastest : source
    }

    private func makeVideoComposition(
        sourceVideoTrack: AVAssetTrack,
        duration: CMTime,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        sourceFrameDuration: CMTime,
        renderSize: CGSize,
        hud: CALayer
    ) -> AVMutableVideoComposition {
        // Source pixels → upright display coordinates (0...width, 0...height).
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let toDisplay = preferredTransform.concatenating(
            CGAffineTransform(translationX: -displayRect.minX, y: -displayRect.minY)
        )
        let sourceSize = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
        // Fill the output frame and crop the overflow evenly, like the preview's aspect-fill.
        let scale = max(renderSize.width / max(1, sourceSize.width), renderSize.height / max(1, sourceSize.height))
        let fill = CGAffineTransform(scaleX: scale, y: scale).concatenating(
            CGAffineTransform(translationX: (renderSize.width - sourceSize.width * scale) / 2,
                              y: (renderSize.height - sourceSize.height * scale) / 2)
        )
        let outputTransform = toDisplay.concatenating(fill)

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = Self.outputFrameDuration(source: sourceFrameDuration)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: sourceVideoTrack)
        layerInstruction.setTransform(outputTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]

        // With every HUD item hidden there is nothing to draw: skip the Core Animation pass.
        guard let items = hud.sublayers, !items.isEmpty else { return composition }

        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        parent.isGeometryFlipped = true

        let videoLayer = CALayer()
        videoLayer.frame = parent.bounds
        parent.addSublayer(videoLayer)

        parent.addSublayer(hud)
        composition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parent
        )
        return composition
    }

    // MARK: Depth HUD

    private struct TextSpec {
        var text: String
        var font: UIFont
        var color: UIColor
        var tracking: CGFloat = 0
        var glowOpacity: Float
        var glowRadius: CGFloat
        var live: ((DiveReading) -> String)? = nil
    }

    func makeHUDLayer(
        size: CGSize,
        samples: [DiveSample],
        maximumDepth: Double,
        videoDuration: Double,
        sync: TimelineSync,
        settings: DiveExportSettings
    ) -> CALayer {
        let hud = CALayer()
        hud.frame = CGRect(origin: .zero, size: size)
        hud.opacity = Float(settings.hudSettings.opacity)
        hud.masksToBounds = false
        let hudSettings = settings.hudSettings
        let unit = HUDMetrics.unit(for: size)
        let maximum = max(maximumDepth, samples.map(\.depthMeters).max() ?? 0)
        let interpolator = try? DiveDataInterpolator(samples: samples)

        // The recorded dive in video time; live values only show inside it (as in the preview).
        let diveStart = max(0, videoTime(forWatchTime: samples[0].elapsedSeconds, sync: sync))
        let diveEnd = min(videoDuration, videoTime(forWatchTime: samples[samples.count - 1].elapsedSeconds, sync: sync))
        let liveTimes = Self.sampleTimes(from: diveStart, to: diveEnd, step: 0.1)
        func reading(at videoTime: Double) -> DiveReading? {
            interpolator?.reading(at: sync.watchTime(forVideoTime: videoTime))
        }

        for item in HUDItemDefinition.all {
            guard hudSettings.visibility[item.id] ?? true else { continue }
            let layer: CALayer
            switch item.id {
            case "identityGroup":
                layer = HUDLayerFactory.identity(name: hudSettings.displayName, type: hudSettings.divingType,
                                                 countryID: hudSettings.country,
                                                 identityScale: hudSettings.identityScale, unit: unit)
                HUDLayerFactory.rasterize(layer)
            case "profileBlock":
                layer = depthProfileLayer(chartSize: CGSize(width: size.width * 0.91, height: size.height * 0.18),
                                          samples: samples, maximumDepth: maximum, unit: unit,
                                          videoDuration: videoDuration, sync: sync, interpolator: interpolator)
            default:
                guard let spec = textSpec(for: item.id, unit: unit, maximumDepth: maximum, deviceName: settings.deviceName) else { continue }
                let box = CGRect(x: 0, y: 0, width: max(unit * 0.9, 10), height: HUDLayerFactory.lineHeight(of: spec.font) * 1.2)
                let container = CALayer()
                container.contentsScale = 1
                container.bounds = box
                let text = HUDLayerFactory.text(spec.text, in: box, font: spec.font, color: spec.color,
                                                tracking: spec.tracking, glowOpacity: spec.glowOpacity,
                                                glowRadius: spec.glowRadius)
                container.addSublayer(text)
                if let live = spec.live {
                    HUDLayerFactory.addSampledText(to: text, times: liveTimes, duration: videoDuration,
                                                   key: "hud-text-\(item.id)") { time in
                        reading(at: time).map(live) ?? spec.text
                    }
                } else {
                    HUDLayerFactory.rasterize(container)
                }
                layer = container
            }
            if HUDItemDefinition.liveIDs.contains(item.id) {
                HUDLayerFactory.addVisibility(to: layer, start: diveStart, end: diveEnd,
                                              duration: videoDuration, key: "hud-visibility-\(item.id)")
            }
            let point = hudSettings.positions[item.id] ?? HUDPoint(x: 50, y: 50)
            let transform = hudSettings.transforms[item.id] ?? HUDTransform()
            let yPercent = min(100, max(0, point.y + hudSettings.verticalOffset))
            HUDLayerFactory.place(layer,
                                  center: CGPoint(x: size.width * CGFloat(point.x / 100), y: size.height * CGFloat(yPercent / 100)),
                                  scale: CGFloat(transform.scale * hudSettings.fontScale),
                                  rotationDegrees: transform.rotation)
            hud.addSublayer(layer)
        }
        return hud
    }

    /// Text items with the same font sizes, weights, colours and glow as DiveHUDOverlay.
    private func textSpec(for id: String, unit: CGFloat, maximumDepth: Double, deviceName: String) -> TextSpec? {
        let pt = HUDMetrics.point(unit: unit)
        let font = HUDLayerFactory.font
        let white = HUDLayerFactory.white, cyan = HUDLayerFactory.cyan, muted = HUDLayerFactory.muted
        func label(_ text: String) -> TextSpec {
            TextSpec(text: text, font: font(unit * 0.023, .bold, .rounded), color: muted,
                     tracking: 1.1 * pt, glowOpacity: 0.45, glowRadius: 4 * pt)
        }
        switch id {
        case "hudBrand":
            return TextSpec(text: "● FREEDIVE / MISSION 02", font: font(unit * 0.027, .bold, .rounded), color: muted,
                            tracking: 1.3 * pt, glowOpacity: 0.55, glowRadius: 5 * pt)
        case "hudClock":
            return TextSpec(text: "00:00", font: font(unit * 0.030, .semibold, .monospaced), color: white,
                            glowOpacity: 0.55, glowRadius: 6 * pt, live: { self.timeLabel($0.elapsedSeconds) })
        case "depthValue":
            return TextSpec(text: "--.-", font: font(unit * 0.14, .black, .rounded), color: white,
                            glowOpacity: 0.95, glowRadius: 13 * pt, live: { String(format: "%.1f", $0.depthMeters) })
        case "depthUnit":
            return TextSpec(text: "M", font: font(unit * 0.038, .heavy, .standard), color: cyan,
                            glowOpacity: 0.6, glowRadius: 6 * pt)
        case "elapsedValue":
            return TextSpec(text: "--:--", font: font(unit * 0.055, .heavy, .rounded), color: white,
                            glowOpacity: 0.5, glowRadius: 6 * pt, live: { self.timeLabel($0.elapsedSeconds) })
        case "elapsedLabel": return label("DIVE TIME")
        case "tempValue":
            return TextSpec(text: "--", font: font(unit * 0.055, .heavy, .rounded), color: white,
                            glowOpacity: 0.5, glowRadius: 6 * pt,
                            live: { $0.temperatureCelsius.map { String(format: "%.1f°", $0) } ?? "--" })
        case "tempLabel": return label("WATER TEMP")
        case "speedValue":
            return TextSpec(text: "0.0 m/s", font: font(unit * 0.050, .heavy, .rounded), color: white,
                            glowOpacity: 0.5, glowRadius: 6 * pt,
                            live: { String(format: "%.1f m/s", $0.verticalSpeedMetersPerSecond ?? 0) })
        case "speedLabel": return label("DEPTH / SEC")
        case "profileTitle":
            return TextSpec(text: "DEPTH PROFILE  /  0 M ↓ MAX DEPTH", font: font(unit * 0.025, .bold, .rounded),
                            color: muted, tracking: 1 * pt, glowOpacity: 0.5, glowRadius: 4 * pt)
        case "footerBrand":
            return TextSpec(text: deviceName.isEmpty ? "DEPTH STUDIO" : deviceName.uppercased(),
                            font: font(unit * 0.025, .bold, .rounded), color: muted,
                            tracking: 1 * pt, glowOpacity: 0.45, glowRadius: 4 * pt)
        case "maxDepth":
            return TextSpec(text: String(format: "MAX %.1f M", maximumDepth), font: font(unit * 0.025, .bold, .rounded),
                            color: muted, tracking: 1 * pt, glowOpacity: 0.45, glowRadius: 4 * pt)
        default:
            return nil
        }
    }

    /// The depth chart, drawn with DepthProfileGeometry exactly like the preview chart:
    /// dashed depth and time grid with labels, cyan curve, dashed playhead and marker dot.
    private func depthProfileLayer(chartSize: CGSize, samples: [DiveSample], maximumDepth: Double, unit: CGFloat,
                                   videoDuration: Double, sync: TimelineSync,
                                   interpolator: DiveDataInterpolator?) -> CALayer {
        let chart = DepthProfileGeometry(samples: samples, maximumDepth: maximumDepth, size: chartSize, unit: unit)
        let plot = chart.plot
        let pt = chart.point
        let layer = CALayer()
        layer.contentsScale = 1
        layer.bounds = CGRect(origin: .zero, size: chartSize)

        let background = CALayer()
        background.contentsScale = 1
        background.frame = layer.bounds
        let gridDash = [2 * pt, 3 * pt]
        let labelFont = HUDLayerFactory.font(size: chart.depthLabelFont, weight: .semibold, design: .standard)
        let timeFont = HUDLayerFactory.font(size: chart.timeLabelFont, weight: .semibold, design: .monospaced)
        for depth in chart.depthGrid {
            let y = chart.y(forDepth: depth)
            background.addSublayer(HUDLayerFactory.line([CGPoint(x: plot.minX, y: y), CGPoint(x: plot.maxX, y: y)],
                                                        color: HUDLayerFactory.grid, width: 0.7 * pt, dash: gridDash, cap: .butt))
            let width = chartSize.width * 0.12
            background.addSublayer(HUDLayerFactory.text("\(Int(depth))m",
                                                        in: CGRect(x: chartSize.width * 0.06 - width / 2, y: y - 1, width: width, height: 2),
                                                        font: labelFont, color: UIColor.white.withAlphaComponent(0.85)))
        }
        for part in 1...3 {
            let x = plot.minX + CGFloat(part) / 3 * plot.width
            background.addSublayer(HUDLayerFactory.line([CGPoint(x: x, y: plot.minY), CGPoint(x: x, y: plot.maxY)],
                                                        color: HUDLayerFactory.grid, width: 0.7 * pt, dash: gridDash, cap: .butt))
            let width = chartSize.width * 0.2
            background.addSublayer(HUDLayerFactory.text(chart.timeLabel(part: part),
                                                        in: CGRect(x: x - width / 2, y: chartSize.height * 0.91 - 1, width: width, height: 2),
                                                        font: timeFont, color: UIColor.white.withAlphaComponent(0.8)))
        }
        let curve = HUDLayerFactory.line(chart.curve, color: HUDLayerFactory.chartCyan, width: 2 * pt)
        curve.shadowColor = HUDLayerFactory.cyan.cgColor
        curve.shadowOpacity = 0.38
        curve.shadowRadius = 5 * pt
        curve.shadowOffset = .zero
        background.addSublayer(curve)
        HUDLayerFactory.rasterize(background)
        layer.addSublayer(background)

        // Playhead and marker follow the video time inside the recorded dive.
        let diveStart = max(0, videoTime(forWatchTime: chart.first, sync: sync))
        let diveEnd = min(videoDuration, videoTime(forWatchTime: chart.last, sync: sync))
        guard diveEnd > diveStart, let interpolator else { return layer }
        let times = Self.sampleTimes(from: diveStart, to: diveEnd, step: 0.1)

        let guide = HUDLayerFactory.line([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: plot.height)],
                                         color: HUDLayerFactory.chartCyan.withAlphaComponent(0.75),
                                         width: 1 * pt, dash: [3 * pt, 3 * pt], cap: .butt)
        guide.bounds = CGRect(x: 0, y: 0, width: max(1, pt), height: plot.height)
        layer.addSublayer(guide)
        HUDLayerFactory.addPositionAnimation(to: guide, times: times, duration: videoDuration, key: "depth-guide") { time in
            let watch = sync.watchTime(forVideoTime: time)
            return CGPoint(x: chart.x(forTime: watch), y: plot.midY)
        }
        HUDLayerFactory.addVisibility(to: guide, start: diveStart, end: diveEnd, duration: videoDuration, key: "depth-guide-visibility")

        let marker = HUDLayerFactory.dot(diameter: 8 * pt, fill: .white, stroke: HUDLayerFactory.chartCyan, strokeWidth: 1.5 * pt)
        layer.addSublayer(marker)
        HUDLayerFactory.addPositionAnimation(to: marker, times: times, duration: videoDuration, key: "depth-marker") { time in
            let watch = sync.watchTime(forVideoTime: time)
            let depth = interpolator.reading(at: watch)?.depthMeters ?? 0
            return CGPoint(x: chart.x(forTime: watch), y: chart.y(forDepth: depth))
        }
        HUDLayerFactory.addVisibility(to: marker, start: diveStart, end: diveEnd, duration: videoDuration, key: "depth-marker-visibility")
        return layer
    }

    /// start, start + step, … (computed by multiplication, so no rounding drift), then end.
    static func sampleTimes(from start: Double, to end: Double, step: Double) -> [Double] {
        guard end > start, step > 0 else { return [] }
        let count = Int(((end - start) / step).rounded(.up))
        var times = (0..<count).map { start + Double($0) * step }.filter { $0 < end }
        times.append(end)
        return times
    }

    /// Inverse of TimelineSync.watchTime(forVideoTime:).
    private func videoTime(forWatchTime watchTime: Double, sync: TimelineSync) -> Double {
        guard let second = sync.second else {
            return watchTime - sync.first.watchSeconds + sync.first.videoSeconds
        }
        let rate = (second.watchSeconds - sync.first.watchSeconds) / (second.videoSeconds - sync.first.videoSeconds)
        return sync.first.videoSeconds + (watchTime - sync.first.watchSeconds) / rate
    }

    private func timeLabel(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private func validateOutput(url: URL, expectedSize: CGSize, sourceHadAudio: Bool) async throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) > 1024 else { throw DiveExportError.invalidMP4("輸出檔案太小或為空。") }
        try validateMP4Container(url)
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = videoTracks.first else { throw DiveExportError.invalidMP4("找不到輸出影片軌。") }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let width = abs(rect.width), height = abs(rect.height)
        guard ExportSizing.isFourKClass(CGSize(width: width, height: height)) else { throw DiveExportError.outputResolutionTooSmall }
        guard abs(width - expectedSize.width) < 4 && abs(height - expectedSize.height) < 4 else {
            throw DiveExportError.invalidMP4("預期 \(Int(expectedSize.width))×\(Int(expectedSize.height))，實際 \(Int(width))×\(Int(height))。")
        }
        let packetCount = try countCompressedVideoSamples(asset: asset, track: track)
        guard packetCount >= 2 else {
            throw DiveExportError.videoPacketValidationFailed("有效影片封包少於兩個。")
        }
        try decodeFirstVideoFrame(asset: asset, track: track)

        if sourceHadAudio {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !audioTracks.isEmpty else { throw DiveExportError.audioTrackMissing }
        }
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0 else { throw DiveExportError.invalidMP4("輸出片長中繼資料無效。") }
    }

    /// Counts the compressed video samples without retaining the sample buffers in memory.
    private func countCompressedVideoSamples(asset: AVAsset, track: AVAssetTrack) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw DiveExportError.videoPacketValidationFailed("無法建立影片封包讀取器。")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw DiveExportError.videoPacketValidationFailed(reader.error?.localizedDescription ?? "無法開始讀取影片封包。")
        }
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            count += 1
            if count > 2_000_000 {
                reader.cancelReading()
                throw DiveExportError.videoPacketValidationFailed("影片封包數量超出安全上限。")
            }
            if count == 1, let description = CMSampleBufferGetFormatDescription(sample) {
                let codec = CMFormatDescriptionGetMediaSubType(description)
                let supported: Set<FourCharCode> = [0x61766331, 0x61766333, 0x68766331, 0x68657631, 0x6D703476]
                guard supported.contains(codec) else {
                    reader.cancelReading()
                    throw DiveExportError.videoPacketValidationFailed("輸出影片使用無法辨識的編碼格式。")
                }
            }
        }
        guard reader.status == .completed else {
            throw DiveExportError.videoPacketValidationFailed(reader.error?.localizedDescription ?? "影片封包讀取未完整完成。")
        }
        return count
    }

    /// Decodes the first output frame to verify that the encoded video is readable on-device.
    private func decodeFirstVideoFrame(asset: AVAsset, track: AVAssetTrack) throws {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw DiveExportError.videoFrameDecodeFailed }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferGetWidth(pixelBuffer) > 0,
              CVPixelBufferGetHeight(pixelBuffer) > 0 else {
            reader.cancelReading()
            throw DiveExportError.videoFrameDecodeFailed
        }
        reader.cancelReading()
    }

    private func validateMP4Container(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        var offset: UInt64 = 0
        var boxCount = 0
        var hasFtyp = false, hasMoov = false, hasMdat = false
        while offset < UInt64(fileSize) {
            boxCount += 1
            if boxCount > 10000 { throw DiveExportError.invalidMP4("區塊數量超出安全上限。") }
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else {
                throw DiveExportError.invalidMP4("區塊標頭不完整。")
            }
            let size32 = header[0..<4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let type = String(bytes: header[4..<8], encoding: .ascii) ?? "????"
            var boxSize = UInt64(size32)
            var headerSize: UInt64 = 8
            if size32 == 1 {
                guard header.count >= 16 else { throw DiveExportError.invalidMP4("64 位元區塊標頭不完整。") }
                boxSize = header[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                headerSize = 16
            } else if size32 == 0 {
                boxSize = UInt64(fileSize) - offset
            }
            guard boxSize >= headerSize, boxSize <= UInt64(fileSize) - offset else {
                throw DiveExportError.invalidMP4("\(type) 區塊邊界超出檔案。")
            }
            if boxCount == 1 && type != "ftyp" { throw DiveExportError.invalidMP4("第一個區塊不是 ftyp。") }
            if type == "ftyp" { hasFtyp = true }
            if type == "moov" { hasMoov = true }
            if type == "mdat" && boxSize > headerSize { hasMdat = true }
            offset += boxSize
        }
        guard offset == UInt64(fileSize), hasFtyp, hasMoov, hasMdat else {
            throw DiveExportError.invalidMP4("缺少 ftyp、moov 或有效 mdat 區塊。")
        }
    }
}
