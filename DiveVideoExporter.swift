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
        case .outputResolutionTooSmall: return "輸出影片尺寸與預期不符。"
        case .audioTrackMissing: return "來源影片含有音訊，但輸出影片沒有保留音訊軌。"
        case .videoPacketValidationFailed(let message): return "輸出影片封包驗證失敗：\(message)"
        case .videoFrameDecodeFailed: return "輸出影片無法解碼首個影格。"
        }
    }
}

/// Native iOS counterpart of the V8.18 web canvas exporter.
///
/// The output frame has the shape chosen in the preview (版型) and the source video's
/// quality (its pixel count, at most 4K UHD's: a 4K source exports 4K, a 1080p source
/// 1080p); the source video fills it with a centre crop, like the preview. Each frame is
/// composed by HUDVideoCompositor: the video plus the HUD of that frame's time, drawn
/// from the same settings and sizing rules (HUDMetrics, HUDTextLook) as the preview.
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
    /// shape at the source's quality, draws the HUD layer from `makeHUD(renderSize, videoDuration)`
    /// on every frame, keeps the audio and validates the resulting MP4. `progress` receives
    /// 0...1 on the main actor.
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

                let renderSize = ExportSizing.renderSize(aspect: aspect.ratio(source: sourceSize.width / sourceSize.height),
                                                         sourceSize: sourceSize)
                let composition = makeVideoComposition(
                    sourceVideoTrack: sourceVideoTrack,
                    duration: duration,
                    naturalSize: naturalSize,
                    preferredTransform: preferredTransform,
                    sourceFrameDuration: sourceFrameDuration,
                    renderSize: renderSize,
                    hud: Self.committedHUD { makeHUD(renderSize, duration.seconds) }
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

    /// Builds the HUD layers in their own transaction and commits it, so their state is
    /// visible on the compositor's thread.
    static func committedHUD(_ build: () -> CALayer) -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let hud = build()
        CATransaction.commit()
        CATransaction.flush()
        return hud
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
        composition.customVideoCompositorClass = HUDVideoCompositor.self
        composition.renderSize = renderSize
        composition.frameDuration = Self.outputFrameDuration(source: sourceFrameDuration)
        // Frames reach the compositor as standard-range Rec. 709 (HDR sources are converted).
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        let overlay = HUDOverlayRenderer(root: hud)
        composition.instructions = [HUDCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: duration),
            sourceTrackID: sourceVideoTrack.trackID,
            renderSize: renderSize,
            transform: outputTransform,
            overlay: overlay.isEmpty ? nil : overlay
        )]
        return composition
    }

    // MARK: Depth HUD

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
            let style = hudSettings.style(for: item.id)
            let layer: CALayer
            switch item.id {
            case "identityGroup":
                layer = HUDLayerFactory.identity(name: hudSettings.displayName, type: hudSettings.divingType,
                                                 countryID: hudSettings.country,
                                                 identityScale: hudSettings.identityScale, style: style, unit: unit)
            case "profileBlock":
                layer = depthProfileLayer(chartSize: CGSize(width: size.width * 0.91, height: size.height * 0.18),
                                          samples: samples, maximumDepth: maximum, unit: unit,
                                          videoDuration: videoDuration, sync: sync, interpolator: interpolator, style: style)
            case "depthGauge":
                layer = DepthGaugeLayerBuilder(geometry: DepthGaugeGeometry(unit: unit, maximumDepth: maximum), style: style)
                    .makeLayer(liveTimes: liveTimes, diveStart: diveStart, diveEnd: diveEnd, videoDuration: videoDuration) { time in
                        reading(at: time)?.depthMeters
                    }
            default:
                guard let spec = Self.textSpec(for: item.id, maximumDepth: maximum, deviceName: settings.deviceName) else { continue }
                let made = HUDLayerFactory.textItem(spec.text, look: spec.look, style: style, unit: unit,
                                                    width: spec.live == nil ? nil : max(unit * 0.9, 10),
                                                    unitLabel: spec.unit)
                if let live = spec.live {
                    HUDLayerFactory.addSampledText(to: made.texts, times: liveTimes, duration: videoDuration,
                                                   key: "hud-text-\(item.id)") { time in
                        reading(at: time).map(live) ?? spec.text
                    }
                }
                layer = made.item
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

    /// Text of a depth HUD field: the static text (or placeholder) and, for live values,
    /// how to read it from the dive data. The look is the one the preview uses. `unit` is
    /// drawn at the value's bottom right as part of the same field (the depth value's "M").
    struct DepthTextSpec {
        var text: String
        var look: HUDTextLook
        var live: ((DiveReading) -> String)?
        var unit: String?
    }

    static func textSpec(for id: String, maximumDepth: Double, deviceName: String) -> DepthTextSpec? {
        switch id {
        case "hudBrand": return DepthTextSpec(text: "● FREEDIVE / MISSION 02", look: .brand)
        case "hudClock": return DepthTextSpec(text: "00:00", look: .clock, live: { DiveVideoExporter.timeLabel($0.elapsedSeconds) })
        case "depthValue":
            return DepthTextSpec(text: "--.-", look: .depthValue, live: { String(format: "%.1f", $0.depthMeters) }, unit: "M")
        case "elapsedValue": return DepthTextSpec(text: "--:--", look: .value, live: { DiveVideoExporter.timeLabel($0.elapsedSeconds) })
        case "elapsedLabel": return DepthTextSpec(text: "DIVE TIME", look: .label)
        case "tempValue":
            return DepthTextSpec(text: "--", look: .value, live: { $0.temperatureCelsius.map { String(format: "%.1f°", $0) } ?? "--" })
        case "tempLabel": return DepthTextSpec(text: "WATER TEMP", look: .label)
        case "speedValue":
            return DepthTextSpec(text: "0.0 m/s", look: .speed, live: { String(format: "%.1f m/s", $0.verticalSpeedMetersPerSecond ?? 0) })
        case "speedLabel": return DepthTextSpec(text: "DEPTH / SEC", look: .label)
        case "profileTitle": return DepthTextSpec(text: "DEPTH PROFILE  /  0 M ↓ MAX DEPTH", look: .title)
        case "footerBrand": return DepthTextSpec(text: deviceName.isEmpty ? "DEPTH STUDIO" : deviceName.uppercased(), look: .small)
        case "maxDepth": return DepthTextSpec(text: String(format: "MAX %.1f M", maximumDepth), look: .small)
        default: return nil
        }
    }

    /// The depth chart, drawn with DepthProfileGeometry exactly like the preview chart:
    /// dashed depth and time grid with labels, cyan curve, dashed playhead and marker dot.
    private func depthProfileLayer(chartSize: CGSize, samples: [DiveSample], maximumDepth: Double, unit: CGFloat,
                                   videoDuration: Double, sync: TimelineSync,
                                   interpolator: DiveDataInterpolator?, style: HUDItemStyle) -> CALayer {
        let chart = DepthProfileGeometry(samples: samples, maximumDepth: maximumDepth, size: chartSize, unit: unit)
        let plot = chart.plot
        let pt = chart.point
        let bounds = CGRect(origin: .zero, size: chartSize)
        let curveColor = style.accent(.chartCyan).uiColor
        let gridColor = style.accent(.gridLine).uiColor

        let background = CALayer()
        background.contentsScale = 1
        background.frame = bounds
        let gridDash = [2 * pt, 3 * pt]
        let labelFont = HUDLayerFactory.font(size: chart.depthLabelFont, weight: .semibold, design: .standard)
        let timeFont = HUDLayerFactory.font(size: chart.timeLabelFont, weight: .semibold, design: .monospaced)
        for depth in chart.depthGrid {
            let y = chart.y(forDepth: depth)
            background.addSublayer(HUDLayerFactory.line([CGPoint(x: plot.minX, y: y), CGPoint(x: plot.maxX, y: y)],
                                                        color: gridColor, width: 0.7 * pt, dash: gridDash, cap: .butt))
            let width = chartSize.width * 0.12
            background.addSublayer(HUDLayerFactory.text("\(Int(depth))m",
                                                        in: CGRect(x: chartSize.width * 0.06 - width / 2, y: y - 1, width: width, height: 2),
                                                        font: labelFont, color: style.text(HUDChartColors.depthLabel).uiColor))
        }
        for part in 1...3 {
            let x = plot.minX + CGFloat(part) / 3 * plot.width
            background.addSublayer(HUDLayerFactory.line([CGPoint(x: x, y: plot.minY), CGPoint(x: x, y: plot.maxY)],
                                                        color: gridColor, width: 0.7 * pt, dash: gridDash, cap: .butt))
            let width = chartSize.width * 0.2
            background.addSublayer(HUDLayerFactory.text(chart.timeLabel(part: part),
                                                        in: CGRect(x: x - width / 2, y: chartSize.height * 0.91 - 1, width: width, height: 2),
                                                        font: timeFont, color: style.text(HUDChartColors.timeLabel).uiColor))
        }
        background.addSublayer(HUDLayerFactory.line(chart.curve, color: curveColor, width: 2 * pt))

        // The whole chart casts the cyan glow, like the preview's .shadow on the chart.
        let glowColor = style.accent(.cyan).uiColor
        let glowOpacity = style.glowOpacity(HUDChartColors.glow)
        let content = CALayer()
        content.contentsScale = 1
        content.frame = bounds
        content.addSublayer(HUDLayerFactory.shadowGroup(background, bounds: bounds, color: glowColor,
                                                        opacity: glowOpacity, radius: HUDChartColors.glowRadius * pt))

        // Playhead and marker follow the video time inside the recorded dive.
        let diveStart = max(0, videoTime(forWatchTime: chart.first, sync: sync))
        let diveEnd = min(videoDuration, videoTime(forWatchTime: chart.last, sync: sync))
        if diveEnd > diveStart, let interpolator {
            let times = Self.sampleTimes(from: diveStart, to: diveEnd, step: 0.1)
            let guide = HUDLayerFactory.line([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: plot.height)],
                                             color: curveColor.withAlphaComponent(0.75),
                                             width: 1 * pt, dash: [3 * pt, 3 * pt], cap: .butt)
            guide.bounds = CGRect(x: 0, y: 0, width: max(1, pt), height: plot.height)
            HUDLayerFactory.setShadow(on: guide, color: glowColor, opacity: Float(glowOpacity), radius: HUDChartColors.glowRadius * pt)
            content.addSublayer(guide)
            HUDLayerFactory.addPositionAnimation(to: guide, times: times, duration: videoDuration, key: "depth-guide") { time in
                let watch = sync.watchTime(forVideoTime: time)
                return CGPoint(x: chart.x(forTime: watch), y: plot.midY)
            }
            HUDLayerFactory.addVisibility(to: guide, start: diveStart, end: diveEnd, duration: videoDuration, key: "depth-guide-visibility")

            let marker = HUDLayerFactory.dot(diameter: 8 * pt, fill: .white, stroke: curveColor, strokeWidth: 1.5 * pt)
            HUDLayerFactory.setShadow(on: marker, color: glowColor, opacity: Float(glowOpacity), radius: HUDChartColors.glowRadius * pt)
            content.addSublayer(marker)
            HUDLayerFactory.addPositionAnimation(to: marker, times: times, duration: videoDuration, key: "depth-marker") { time in
                let watch = sync.watchTime(forVideoTime: time)
                let depth = interpolator.reading(at: watch)?.depthMeters ?? 0
                return CGPoint(x: chart.x(forTime: watch), y: chart.y(forDepth: depth))
            }
            HUDLayerFactory.addVisibility(to: marker, start: diveStart, end: diveEnd, duration: videoDuration, key: "depth-marker-visibility")
        }

        let layer = CALayer()
        layer.contentsScale = 1
        layer.bounds = bounds
        let styled = HUDLayerFactory.applyDropShadow(style, to: content, bounds: bounds, point: pt)
        styled.frame = bounds
        layer.addSublayer(styled)
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

    static func timeLabel(_ seconds: Double) -> String {
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
