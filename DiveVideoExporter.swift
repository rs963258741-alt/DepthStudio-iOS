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
        case .outputResolutionTooSmall: return "輸出影片長邊未達 3840 像素，未符合至少 4K 的要求。"
        case .audioTrackMissing: return "來源影片含有音訊，但輸出影片沒有保留音訊軌。"
        case .videoPacketValidationFailed(let message): return "輸出影片封包驗證失敗：\(message)"
        case .videoFrameDecodeFailed: return "輸出影片無法解碼首個影格。"
        }
    }
}

/// Native iOS counterpart of the V8.18 web canvas exporter.
/// The editable HUD model is shared with the preview; the same positions,
/// transforms, visibility, identity, global style and sync offset are rendered
/// into the final MP4 using Core Animation.
final class DiveVideoExporter {
    /// 深度潛水 export: the depth HUD over the source video.
    func export(
        videoURL: URL,
        samples: [DiveSample],
        maximumDepth: Double,
        sync: TimelineSync,
        settings: DiveExportSettings,
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
            progress: progress,
            completion: completion,
            makeHUD: { renderSize, videoDuration in
                self.makeHUDLayer(size: renderSize, samples: sorted, maximumDepth: maximumDepth,
                                  videoDuration: videoDuration, sync: sync, settings: settings)
            }
        )
    }

    /// Shared export path for every mode: renders the source video at a long edge of at
    /// least 3840 px, composites the HUD layer from `makeHUD(renderSize, videoDuration)`,
    /// keeps the audio and validates the resulting MP4.
    func exportVideo(
        videoURL: URL,
        outputURL: URL,
        outputFileType: AVFileType = .mp4,
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
                let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
                let sourceDisplayWidth = abs(transformedRect.width)
                let sourceDisplayHeight = abs(transformedRect.height)
                guard sourceDisplayWidth > 0, sourceDisplayHeight > 0 else { throw DiveExportError.invalidDuration }

                // Keep the source's aspect ratio and ensure the long edge is at least 3840 px.
                let longEdge = max(sourceDisplayWidth, sourceDisplayHeight)
                let factor = longEdge >= 3840 ? 1.0 : 3840.0 / longEdge
                let targetWidth = evenPixel(sourceDisplayWidth * factor)
                let targetHeight = evenPixel(sourceDisplayHeight * factor)
                let renderSize = CGSize(width: targetWidth, height: targetHeight)

                let composition = try await makeVideoComposition(
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
                session.shouldOptimizeForNetworkUse = true

                let progressTask = Task.detached(priority: .utility) {
                    while !Task.isCancelled {
                        let value = Double(session.progress)
                        await MainActor.run { progress?(value) }
                        if session.status != .exporting { break }
                        try? await Task.sleep(nanoseconds: 300_000_000)
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

    private func evenPixel(_ value: CGFloat) -> CGFloat {
        let rounded = max(2, Int(value.rounded()))
        return CGFloat(rounded.isMultiple(of: 2) ? rounded : rounded + 1)
    }

    private func makeVideoComposition(
        sourceVideoTrack: AVAssetTrack,
        duration: CMTime,
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        sourceFrameDuration: CMTime,
        renderSize: CGSize,
        hud: CALayer
    ) async throws -> AVMutableVideoComposition {
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let normalizedTransform = preferredTransform.concatenating(
            CGAffineTransform(translationX: -transformedRect.minX, y: -transformedRect.minY)
        )
        let scaleX = renderSize.width / max(1, abs(transformedRect.width))
        let scaleY = renderSize.height / max(1, abs(transformedRect.height))
        let outputTransform = normalizedTransform.scaledBy(x: scaleX, y: scaleY)

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderSize
        composition.frameDuration = sourceFrameDuration.isValid && sourceFrameDuration.seconds > 0
            ? sourceFrameDuration : CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: sourceVideoTrack)
        layerInstruction.setTransform(outputTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        composition.instructions = [instruction]

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

    private func makeHUDLayer(
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
        let sorted = samples.sorted { $0.elapsedSeconds < $1.elapsedSeconds }
        let maximum = max(maximumDepth, sorted.map(\.depthMeters).max() ?? 0)

        for item in HUDItemDefinition.all {
            guard settings.hudSettings.visibility[item.id] ?? true else { continue }
            let point = settings.hudSettings.positions[item.id] ?? HUDPoint(x: 50, y: 50)
            let transform = settings.hudSettings.transforms[item.id] ?? HUDTransform()
            let yPercent = min(100, max(0, point.y + settings.hudSettings.verticalOffset))
            let position = CGPoint(x: size.width * CGFloat(point.x / 100), y: size.height * CGFloat(yPercent / 100))
            let itemLayer = CALayer()
            let itemSize = itemBounds(for: item.id, size: size)
            itemLayer.bounds = CGRect(origin: .zero, size: itemSize)
            itemLayer.position = position
            itemLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            let scale = CGFloat(transform.scale * settings.hudSettings.fontScale)
            itemLayer.setAffineTransform(CGAffineTransform(rotationAngle: transform.rotation * .pi / 180).scaledBy(x: scale, y: scale))
            itemLayer.masksToBounds = false
            addItemContent(item.id, to: itemLayer, itemSize: itemSize, canvasSize: size,
                           samples: sorted, maximumDepth: maximum, videoDuration: videoDuration,
                           sync: sync, settings: settings)
            hud.addSublayer(itemLayer)
        }
        return hud
    }

    private func itemBounds(for id: String, size: CGSize) -> CGSize {
        let w = size.width
        let h = size.height
        switch id {
        case "depthValue": return CGSize(width: w * 0.32, height: h * 0.17)
        case "depthUnit": return CGSize(width: w * 0.12, height: h * 0.08)
        case "elapsedValue", "tempValue", "speedValue": return CGSize(width: w * 0.31, height: h * 0.075)
        case "elapsedLabel", "tempLabel", "speedLabel", "profileTitle", "hudBrand", "footerBrand", "maxDepth":
            return CGSize(width: w * 0.44, height: h * 0.045)
        case "hudClock": return CGSize(width: w * 0.23, height: h * 0.055)
        case "identityGroup": return CGSize(width: w * 0.78, height: h * 0.10)
        case "profileBlock": return CGSize(width: w * 0.91, height: h * 0.18)
        default: return CGSize(width: w * 0.3, height: h * 0.06)
        }
    }

    private func addItemContent(
        _ id: String,
        to container: CALayer,
        itemSize: CGSize,
        canvasSize: CGSize,
        samples: [DiveSample],
        maximumDepth: Double,
        videoDuration: Double,
        sync: TimelineSync,
        settings: DiveExportSettings
    ) {
        let white = UIColor(red: 0.94, green: 0.99, blue: 1, alpha: 1)
        let cyan = UIColor(red: 0.38, green: 0.91, blue: 1, alpha: 1)
        let muted = UIColor(red: 0.74, green: 0.93, blue: 0.98, alpha: 1)

        if id == "profileBlock" {
            addProfile(to: container, size: itemSize, samples: samples, maximumDepth: maximumDepth,
                       videoDuration: videoDuration, sync: sync, cyan: cyan)
            return
        }
        if id == "identityGroup" {
            addIdentity(to: container, size: itemSize,
                        settings: settings.hudSettings, white: white, cyan: cyan)
            return
        }

        let fontSize: CGFloat
        let color: UIColor
        let weight: UIFont.Weight
        let staticText: String
        let dynamic: (DiveReading) -> String
        switch id {
        case "hudBrand": fontSize = canvasSize.width * 0.027; color = muted; weight = .bold; staticText = "● FREEDIVE / MISSION 02"; dynamic = { _ in "FREEDIVE / MISSION 02" }
        case "hudClock": fontSize = canvasSize.width * 0.030; color = white; weight = .semibold; staticText = "00:00"; dynamic = { self.timeLabel($0.elapsedSeconds) }
        case "depthValue": fontSize = canvasSize.width * 0.14; color = white; weight = .heavy; staticText = "--.-"; dynamic = { String(format: "%.1f", $0.depthMeters) }
        case "depthUnit": fontSize = canvasSize.width * 0.038; color = cyan; weight = .heavy; staticText = "M"; dynamic = { _ in "M" }
        case "elapsedValue": fontSize = canvasSize.width * 0.055; color = white; weight = .heavy; staticText = "--:--"; dynamic = { self.timeLabel($0.elapsedSeconds) }
        case "elapsedLabel": fontSize = canvasSize.width * 0.023; color = muted; weight = .bold; staticText = "DIVE TIME"; dynamic = { _ in "DIVE TIME" }
        case "tempValue": fontSize = canvasSize.width * 0.055; color = white; weight = .heavy; staticText = "--"; dynamic = { $0.temperatureCelsius.map { String(format: "%.1f°", $0) } ?? "--" }
        case "tempLabel": fontSize = canvasSize.width * 0.023; color = muted; weight = .bold; staticText = "WATER TEMP"; dynamic = { _ in "WATER TEMP" }
        case "speedValue": fontSize = canvasSize.width * 0.050; color = white; weight = .heavy; staticText = "0.0 m/s"; dynamic = { String(format: "%.1f m/s", $0.verticalSpeedMetersPerSecond ?? 0) }
        case "speedLabel": fontSize = canvasSize.width * 0.023; color = muted; weight = .bold; staticText = "DEPTH / SEC"; dynamic = { _ in "DEPTH / SEC" }
        case "profileTitle": fontSize = canvasSize.width * 0.025; color = muted; weight = .bold; staticText = "DEPTH PROFILE / 0 M ↓ MAX DEPTH"; dynamic = { _ in "DEPTH PROFILE / 0 M ↓ MAX DEPTH" }
        case "footerBrand": fontSize = canvasSize.width * 0.025; color = muted; weight = .bold; staticText = settings.deviceName.uppercased(); dynamic = { _ in settings.deviceName.uppercased() }
        case "maxDepth": fontSize = canvasSize.width * 0.025; color = muted; weight = .bold; staticText = String(format: "MAX %.1f M", maximumDepth); dynamic = { _ in String(format: "MAX %.1f M", maximumDepth) }
        default: fontSize = 14; color = white; weight = .bold; staticText = ""; dynamic = { _ in "" }
        }

        let text = makeTextLayer(text: staticText, frame: CGRect(origin: .zero, size: itemSize),
                                 fontSize: max(7, fontSize), weight: weight, color: color,
                                 tracking: id == "hudBrand" || id == "footerBrand" || id == "profileTitle" || id == "maxDepth" ? 1.2 : 0)
        container.addSublayer(text)
        if ["hudClock", "depthValue", "elapsedValue", "tempValue", "speedValue"].contains(id) {
            addDynamicTextAnimation(to: text, id: id, samples: samples, maximumDepth: maximumDepth,
                                    videoDuration: videoDuration, sync: sync, textProvider: dynamic)
        }
    }

    private func addIdentity(to container: CALayer, size: CGSize,
                             settings: HUDSettings, white: UIColor, cyan: UIColor) {
        let fontSize = max(12, size.width * 0.047 * CGFloat(settings.identityScale))
        let name = settings.displayName.isEmpty ? "name" : settings.displayName
        let nameFont = UIFont.systemFont(ofSize: fontSize, weight: .heavy)
        let typeFont = UIFont.systemFont(ofSize: fontSize * 0.96, weight: .black)
        let nameWidth = (name as NSString).size(withAttributes: [.font: nameFont]).width
        let typeWidth = (settings.divingType as NSString).size(withAttributes: [.font: typeFont]).width
        let flagImage = HUDCountryOption.assetName(for: settings.country).flatMap { UIImage(named: $0) }
        let flagHeight = fontSize * 1.28
        let flagWidth = flagImage.map { flagHeight * $0.size.width / max(1, $0.size.height) } ?? 0
        let flagGap = flagWidth > 0 ? fontSize * 0.42 : 0
        let typeGap = fontSize * 0.9
        let totalWidth = flagWidth + flagGap + nameWidth + typeGap + typeWidth
        var x = (size.width - totalWidth) / 2

        if let image = flagImage, let cgImage = image.cgImage {
            let flag = CALayer()
            flag.contents = cgImage
            flag.contentsGravity = .resizeAspect
            flag.contentsScale = UIScreen.main.scale
            flag.frame = CGRect(x: x, y: (size.height - flagHeight) / 2, width: flagWidth, height: flagHeight)
            flag.cornerRadius = 1
            flag.masksToBounds = true
            container.addSublayer(flag)
            x += flagWidth + flagGap
        }
        let nameLayer = makeTextLayer(text: name, frame: CGRect(x: x, y: 0, width: nameWidth + 2, height: size.height),
                                      fontSize: fontSize, weight: .heavy, color: white)
        nameLayer.alignmentMode = .left
        container.addSublayer(nameLayer)
        x += nameWidth + typeGap
        let typeLayer = makeTextLayer(text: settings.divingType,
                                      frame: CGRect(x: x, y: 0, width: typeWidth + 2, height: size.height),
                                      fontSize: fontSize * 0.96, weight: .black, color: cyan)
        typeLayer.alignmentMode = .left
        container.addSublayer(typeLayer)
    }

    func makeTextLayer(text: String, frame: CGRect, fontSize: CGFloat, weight: UIFont.Weight,
                               color: UIColor, tracking: CGFloat = 0) -> CATextLayer {
        let layer = CATextLayer()
        layer.string = text
        layer.alignmentMode = .center
        layer.isWrapped = false
        layer.truncationMode = .none
        layer.contentsScale = UIScreen.main.scale
        layer.font = UIFont.systemFont(ofSize: fontSize, weight: weight)
        layer.fontSize = fontSize
        layer.foregroundColor = color.cgColor
        layer.frame = frame
        layer.shadowColor = UIColor(red: 0.20, green: 0.82, blue: 1, alpha: 1).cgColor
        layer.shadowOpacity = 0.48
        layer.shadowRadius = max(2, fontSize * 0.12)
        layer.shadowOffset = CGSize(width: 0, height: 1)
        if tracking > 0 {
            layer.string = NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: weight),
                .foregroundColor: color,
                .kern: tracking
            ])
        }
        return layer
    }

    private func addDynamicTextAnimation(to layer: CATextLayer, id: String, samples: [DiveSample],
                                         maximumDepth: Double, videoDuration: Double, sync: TimelineSync,
                                         textProvider: (DiveReading) -> String) {
        guard let interpolator = try? DiveDataInterpolator(samples: samples) else {
            layer.opacity = 0
            return
        }
        let frames = animationFrames(samples: samples, videoDuration: videoDuration, sync: sync)
        var values: [String] = []
        var times: [NSNumber] = []
        for frame in frames {
            guard let reading = interpolator.reading(at: frame.watchTime) else { continue }
            values.append(textProvider(reading))
            times.append(NSNumber(value: min(1, max(0, frame.videoTime / max(0.001, videoDuration)))) )
        }
        guard let first = values.first, let firstTime = times.first?.doubleValue,
              let lastTime = times.last?.doubleValue else {
            layer.opacity = 0
            return
        }
        layer.string = first
        if values.count > 1 {
            let animation = CAKeyframeAnimation(keyPath: "string")
            animation.values = values
            animation.keyTimes = times
            animation.duration = videoDuration
            animation.beginTime = AVCoreAnimationBeginTimeAtZero
            animation.calculationMode = .discrete
            animation.isRemovedOnCompletion = false
            animation.fillMode = .both
            layer.add(animation, forKey: "hud-text-\(id)")
        }
        // The web preview hides live telemetry outside the valid dive interval.
        addDataVisibilityAnimation(to: layer, start: firstTime, end: lastTime,
                                   duration: videoDuration, key: "hud-visibility-\(id)")
    }

    private func addDataVisibilityAnimation(to layer: CALayer, start: Double, end: Double,
                                            duration: Double, key: String) {
        let safeStart = min(1, max(0, start))
        let safeEnd = min(1, max(safeStart, end))
        var values: [NSNumber] = []
        var keyTimes: [NSNumber] = []
        if safeStart > 0 {
            values.append(NSNumber(value: 0))
            keyTimes.append(NSNumber(value: 0))
        }
        values.append(NSNumber(value: 1))
        keyTimes.append(NSNumber(value: safeStart))
        if safeEnd < 1 {
            if safeEnd > safeStart {
                values.append(NSNumber(value: 1))
                keyTimes.append(NSNumber(value: safeEnd))
            }
            values.append(NSNumber(value: 0))
            keyTimes.append(NSNumber(value: 1))
        }
        layer.opacity = safeStart == 0 ? 1 : 0
        guard values.count > 1 else { return }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = values
        animation.keyTimes = keyTimes
        animation.duration = duration
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.calculationMode = .linear
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.add(animation, forKey: key)
    }

    private func addProfile(to container: CALayer, size: CGSize, samples: [DiveSample], maximumDepth: Double,
                            videoDuration: Double, sync: TimelineSync, cyan: UIColor) {
        guard samples.count >= 2 else { return }
        let chart = CALayer()
        chart.frame = CGRect(origin: .zero, size: size)
        container.addSublayer(chart)
        let plot = CGRect(x: size.width * 0.135, y: size.height * 0.06,
                          width: size.width * 0.84, height: size.height * 0.70)
        let depthLimit = max(10, ceil(maximumDepth / 10) * 10)
        let axisColor = UIColor(red: 0.67, green: 0.89, blue: 0.95, alpha: 0.50)

        for depth in stride(from: 10.0, through: depthLimit, by: 10.0) {
            let y = plot.minY + CGFloat(depth / depthLimit) * plot.height
            let path = UIBezierPath(); path.move(to: CGPoint(x: plot.minX, y: y)); path.addLine(to: CGPoint(x: plot.maxX, y: y))
            let grid = CAShapeLayer(); grid.path = path.cgPath; grid.strokeColor = axisColor.cgColor
            grid.fillColor = UIColor.clear.cgColor; grid.lineWidth = 1; grid.lineDashPattern = [2, 3]
            chart.addSublayer(grid)
            let tick = makeTextLayer(text: "\(Int(depth))m", frame: CGRect(x: 0, y: y - 7, width: plot.minX - 3, height: 14),
                                     fontSize: max(8, size.width * 0.025), weight: .semibold, color: axisColor)
            tick.alignmentMode = .right
            chart.addSublayer(tick)
        }

        let first = samples.first!.elapsedSeconds
        let last = max(samples.last!.elapsedSeconds, first + 0.001)
        for part in 1...3 {
            let fraction = CGFloat(part) / 3
            let x = plot.minX + fraction * plot.width
            let path = UIBezierPath(); path.move(to: CGPoint(x: x, y: plot.minY)); path.addLine(to: CGPoint(x: x, y: plot.maxY))
            let grid = CAShapeLayer(); grid.path = path.cgPath; grid.strokeColor = axisColor.withAlphaComponent(0.45).cgColor
            grid.fillColor = UIColor.clear.cgColor; grid.lineWidth = 1; grid.lineDashPattern = [2, 3]
            chart.addSublayer(grid)
            let label = makeTextLayer(text: timeLabel((last - first) * Double(part) / 3),
                                      frame: CGRect(x: x - 30, y: size.height * 0.82, width: 60, height: 15),
                                      fontSize: max(8, size.width * 0.024), weight: .semibold, color: axisColor)
            chart.addSublayer(label)
        }

        let curve = UIBezierPath()
        for (index, sample) in samples.enumerated() {
            let x = plot.minX + CGFloat((sample.elapsedSeconds - first) / (last - first)) * plot.width
            let y = plot.minY + CGFloat(max(0, sample.depthMeters) / depthLimit) * plot.height
            if index == 0 { curve.move(to: CGPoint(x: x, y: y)) } else { curve.addLine(to: CGPoint(x: x, y: y)) }
        }
        let glow = CAShapeLayer(); glow.path = curve.cgPath; glow.strokeColor = cyan.withAlphaComponent(0.38).cgColor
        glow.fillColor = UIColor.clear.cgColor; glow.lineWidth = max(3, size.width * 0.012); glow.lineCap = .round
        glow.shadowColor = cyan.cgColor; glow.shadowOpacity = 0.8; glow.shadowRadius = 6
        chart.addSublayer(glow)
        let line = CAShapeLayer(); line.path = curve.cgPath; line.strokeColor = UIColor.white.cgColor
        line.fillColor = UIColor.clear.cgColor; line.lineWidth = max(1.5, size.width * 0.006); line.lineCap = .round; line.lineJoin = .round
        chart.addSublayer(line)

        let playhead = CALayer()
        playhead.bounds = CGRect(x: 0, y: 0, width: max(2, size.width * 0.003), height: plot.height)
        playhead.backgroundColor = cyan.withAlphaComponent(0.75).cgColor
        let frames = animationFrames(samples: samples, videoDuration: videoDuration, sync: sync)
        let positions = frames.map { frame -> NSValue in
            let fraction = min(1, max(0, (frame.watchTime - first) / (last - first)))
            let x = plot.minX + CGFloat(fraction) * plot.width
            return NSValue(cgPoint: CGPoint(x: x, y: plot.midY))
        }
        if let firstPosition = positions.first { playhead.position = firstPosition.cgPointValue }
        if let firstFrame = frames.first, let lastFrame = frames.last {
            addDataVisibilityAnimation(to: playhead,
                                       start: firstFrame.videoTime / max(0.001, videoDuration),
                                       end: lastFrame.videoTime / max(0.001, videoDuration),
                                       duration: videoDuration, key: "profile-playhead-visibility")
        } else {
            playhead.opacity = 0
        }
        if positions.count > 1 {
            let move = CAKeyframeAnimation(keyPath: "position")
            move.values = positions
            move.keyTimes = frames.map { NSNumber(value: min(1, max(0, $0.videoTime / max(0.001, videoDuration)))) }
            move.duration = videoDuration; move.beginTime = AVCoreAnimationBeginTimeAtZero
            move.isRemovedOnCompletion = false; move.fillMode = .both
            playhead.add(move, forKey: "depth-profile-playhead")
        }
        chart.addSublayer(playhead)
    }

    private func animationFrames(samples: [DiveSample], videoDuration: Double,
                                 sync: TimelineSync) -> [(videoTime: Double, watchTime: Double)] {
        samples.compactMap { sample in
            let videoTime = sample.elapsedSeconds - sync.first.watchSeconds + sync.first.videoSeconds
            guard videoTime >= 0, videoTime <= videoDuration else { return nil }
            return (videoTime, sample.elapsedSeconds)
        }.sorted { $0.videoTime < $1.videoTime }
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
        guard max(width, height) >= 3840 else { throw DiveExportError.outputResolutionTooSmall }
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
