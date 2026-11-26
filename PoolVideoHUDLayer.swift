import Foundation
import AVFoundation
import UIKit
import QuartzCore

extension DiveVideoExporter {
    /// 泳池平潛 export: the pool HUD over the source video, through the same 4K / audio /
    /// MP4-validation path as the depth export.
    func exportPool(
        videoURL: URL,
        timeline: PoolTimeline,
        settings: PoolHUDSettings,
        outputURL: URL,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        exportVideo(
            videoURL: videoURL,
            outputURL: outputURL,
            progress: progress,
            completion: completion,
            makeHUD: { renderSize, videoDuration in
                PoolHUDLayerBuilder(exporter: self, timeline: timeline, settings: settings,
                                    videoDuration: videoDuration)
                    .makeLayer(size: renderSize)
            }
        )
    }
}

/// Builds the Core Animation HUD for an exported pool video. Positions, transforms,
/// visibility and style come from the same PoolHUDSettings as the on-screen preview;
/// live values are keyframed against the video's own time.
struct PoolHUDLayerBuilder {
    let exporter: DiveVideoExporter
    let timeline: PoolTimeline
    let settings: PoolHUDSettings
    let videoDuration: Double

    private static let white = UIColor(red: 0.94, green: 0.99, blue: 1, alpha: 1)
    private static let cyan = UIColor(red: 0.38, green: 0.91, blue: 1, alpha: 1)
    private static let muted = UIColor(red: 0.74, green: 0.93, blue: 0.98, alpha: 1)
    private static let yellow = UIColor(red: 1.0, green: 0.80, blue: 0.35, alpha: 1)

    func makeLayer(size: CGSize) -> CALayer {
        let hud = CALayer()
        hud.frame = CGRect(origin: .zero, size: size)
        hud.opacity = Float(settings.opacity)
        hud.masksToBounds = false

        for item in PoolHUDItemDefinition.all {
            guard settings.visibility[item.id] ?? true else { continue }
            let point = settings.positions[item.id] ?? HUDPoint(x: 50, y: 50)
            let transform = settings.transforms[item.id] ?? HUDTransform()
            let yPercent = min(100, max(0, point.y + settings.verticalOffset))
            let itemSize = itemBounds(for: item.id, size: size)
            let itemLayer = CALayer()
            itemLayer.bounds = CGRect(origin: .zero, size: itemSize)
            itemLayer.position = CGPoint(x: size.width * CGFloat(point.x / 100), y: size.height * CGFloat(yPercent / 100))
            itemLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            let scale = CGFloat(transform.scale * settings.fontScale)
            let angle = CGFloat(transform.rotation * Double.pi / 180)
            itemLayer.setAffineTransform(CGAffineTransform(rotationAngle: angle).scaledBy(x: scale, y: scale))
            itemLayer.masksToBounds = false
            addContent(item.id, to: itemLayer, itemSize: itemSize, canvasSize: size)
            hud.addSublayer(itemLayer)
        }
        return hud
    }

    private func itemBounds(for id: String, size: CGSize) -> CGSize {
        let w = size.width
        let h = size.height
        switch id {
        case "distanceValue": return CGSize(width: w * 0.46, height: h * 0.15)
        case "distanceUnit": return CGSize(width: w * 0.12, height: h * 0.08)
        case "elapsedValue", "lapValue", "speedValue": return CGSize(width: w * 0.34, height: h * 0.075)
        case "elapsedLabel", "lapLabel", "speedLabel", "profileTitle", "hudBrand", "footerBrand",
             "totalDistance", "averageSpeed":
            return CGSize(width: w * 0.48, height: h * 0.045)
        case "hudClock": return CGSize(width: w * 0.23, height: h * 0.055)
        case "identityGroup": return CGSize(width: w * 0.78, height: h * 0.10)
        case "profileBlock": return CGSize(width: w * 0.91, height: h * 0.18)
        default: return CGSize(width: w * 0.3, height: h * 0.06)
        }
    }

    private func addContent(_ id: String, to container: CALayer, itemSize: CGSize, canvasSize: CGSize) {
        if id == "profileBlock" {
            addProfile(to: container, size: itemSize)
            return
        }
        if id == "identityGroup" {
            addIdentity(to: container, size: itemSize)
            return
        }

        let w = canvasSize.width
        let fontSize: CGFloat
        let color: UIColor
        let weight: UIFont.Weight
        let text: String
        var live: ((PoolReading) -> String)? = nil
        switch id {
        case "hudBrand":
            fontSize = w * 0.027; color = Self.muted; weight = .bold; text = "● FREEDIVE / POOL DYNAMIC"
        case "hudClock":
            fontSize = w * 0.030; color = Self.white; weight = .semibold; text = "00:00"
            live = { PoolFormat.clock($0.videoTime) }
        case "distanceValue":
            fontSize = w * 0.13; color = Self.white; weight = .heavy; text = "0.0"
            live = { PoolFormat.distance($0.distance) }
        case "distanceUnit":
            fontSize = w * 0.038; color = Self.cyan; weight = .heavy; text = "M"
        case "elapsedValue":
            fontSize = w * 0.055; color = Self.white; weight = .heavy; text = "00:00"
            live = { PoolFormat.clock($0.elapsedSeconds) }
        case "elapsedLabel":
            fontSize = w * 0.023; color = Self.muted; weight = .bold; text = "DIVE TIME"
        case "lapValue":
            fontSize = w * 0.055; color = Self.white; weight = .heavy; text = "01 / 01"
            live = { PoolFormat.lap($0) }
        case "lapLabel":
            fontSize = w * 0.023; color = Self.muted; weight = .bold; text = "LAP"
        case "speedValue":
            fontSize = w * 0.050; color = Self.white; weight = .heavy; text = "0.00 m/s"
            live = { "\(PoolFormat.speed($0.speed)) m/s" }
        case "speedLabel":
            fontSize = w * 0.023; color = Self.muted; weight = .bold; text = "SPEED"
        case "profileTitle":
            fontSize = w * 0.025; color = Self.muted; weight = .bold; text = "DISTANCE / SPEED PROFILE"
        case "footerBrand":
            fontSize = w * 0.025; color = Self.muted; weight = .bold; text = PoolHUDSettings.footerText
        case "totalDistance":
            fontSize = w * 0.025; color = Self.muted; weight = .bold
            text = "TOTAL \(PoolFormat.distance(timeline.finalDistance)) M"
        case "averageSpeed":
            fontSize = w * 0.025; color = Self.muted; weight = .bold
            text = "AVG \(PoolFormat.speed(timeline.averageSpeed)) M/S"
        default:
            fontSize = 14; color = Self.white; weight = .bold; text = ""
        }

        let tracked = ["hudBrand", "footerBrand", "profileTitle", "totalDistance", "averageSpeed"].contains(id)
        let layer = exporter.makeTextLayer(text: text, frame: CGRect(origin: .zero, size: itemSize),
                                           fontSize: max(7, fontSize), weight: weight, color: color,
                                           tracking: tracked ? 1.2 : 0)
        container.addSublayer(layer)
        if let live {
            addLiveText(to: layer, id: id, times: id == "hudClock" ? clockTimes() : swimTimes(), text: live)
        }
    }

    // MARK: Live values

    /// Every 0.1 s across the swim, plus the video start and each timed point.
    private func swimTimes() -> [Double] {
        var times: [Double] = [0]
        let start = max(0, timeline.startTime)
        let end = min(videoDuration, timeline.finishTime)
        if end > start {
            var t = start
            while t < end {
                times.append(t)
                t += 0.1
            }
        }
        for point in timeline.points where point.time >= 0 && point.time <= videoDuration {
            times.append(point.time)
        }
        return Array(Set(times)).sorted()
    }

    private func clockTimes() -> [Double] {
        Array(stride(from: 0.0, to: max(0.001, videoDuration), by: 0.5))
    }

    /// Discrete text keyframes. Consecutive identical values are merged; per Core Animation's
    /// discrete mode, keyTimes start at 0, end at 1 and have one more entry than values.
    private func addLiveText(to layer: CATextLayer, id: String, times: [Double], text: (PoolReading) -> String) {
        var values: [String] = []
        var starts: [Double] = []
        for time in times {
            let value = text(timeline.reading(atVideoTime: time))
            if value != values.last {
                values.append(value)
                starts.append(time)
            }
        }
        guard let first = values.first else { return }
        layer.string = first
        guard values.count > 1 else { return }
        let duration = max(0.001, videoDuration)
        var keyTimes: [NSNumber] = [NSNumber(value: 0.0)]
        for start in starts.dropFirst() {
            keyTimes.append(NSNumber(value: min(1, max(0, start / duration))))
        }
        keyTimes.append(NSNumber(value: 1.0))

        let animation = CAKeyframeAnimation(keyPath: "string")
        animation.values = values
        animation.keyTimes = keyTimes
        animation.duration = duration
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.calculationMode = .discrete
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.add(animation, forKey: "pool-text-\(id)")
    }

    // MARK: Identity

    private func addIdentity(to container: CALayer, size: CGSize) {
        let fontSize = max(12, size.width * 0.047 * CGFloat(settings.identityScale))
        let name = settings.displayName.isEmpty ? "name" : settings.displayName
        let discipline = settings.discipline
        let nameFont = UIFont.systemFont(ofSize: fontSize, weight: .heavy)
        let typeFont = UIFont.systemFont(ofSize: fontSize * 0.96, weight: .black)
        let nameWidth = (name as NSString).size(withAttributes: [.font: nameFont]).width
        let typeWidth = (discipline as NSString).size(withAttributes: [.font: typeFont]).width
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
        let nameLayer = exporter.makeTextLayer(text: name, frame: CGRect(x: x, y: 0, width: nameWidth + 2, height: size.height),
                                               fontSize: fontSize, weight: .heavy, color: Self.white)
        nameLayer.alignmentMode = .left
        container.addSublayer(nameLayer)
        x += nameWidth + typeGap
        let typeLayer = exporter.makeTextLayer(text: discipline,
                                               frame: CGRect(x: x, y: 0, width: typeWidth + 2, height: size.height),
                                               fontSize: fontSize * 0.96, weight: .black, color: Self.cyan)
        typeLayer.alignmentMode = .left
        container.addSublayer(typeLayer)
    }

    // MARK: Distance / speed chart

    private func addProfile(to container: CALayer, size: CGSize) {
        let chart = PoolProfileGeometry(timeline: timeline, size: size)
        let plot = chart.plot
        let layer = CALayer()
        layer.frame = CGRect(origin: .zero, size: size)
        container.addSublayer(layer)

        let gridColor = UIColor(red: 0.67, green: 0.89, blue: 0.95, alpha: 0.45)
        let labelSize = max(8, size.width * 0.024)

        for fraction in PoolProfileGeometry.gridFractions {
            let y = plot.maxY - CGFloat(fraction) * plot.height
            layer.addSublayer(dashedLine(from: CGPoint(x: plot.minX, y: y), to: CGPoint(x: plot.maxX, y: y), color: gridColor))
            let distanceLabel = exporter.makeTextLayer(
                text: "\(Int((chart.distanceLimit * fraction).rounded()))m",
                frame: CGRect(x: 0, y: y - labelSize * 0.7, width: plot.minX - 4, height: labelSize * 1.4),
                fontSize: labelSize, weight: .semibold, color: Self.cyan)
            distanceLabel.alignmentMode = .right
            layer.addSublayer(distanceLabel)
            let speedLabel = exporter.makeTextLayer(
                text: String(format: "%.1f", chart.speedLimit * fraction),
                frame: CGRect(x: plot.maxX + 4, y: y - labelSize * 0.7, width: size.width - plot.maxX - 4, height: labelSize * 1.4),
                fontSize: labelSize, weight: .semibold, color: Self.yellow)
            speedLabel.alignmentMode = .left
            layer.addSublayer(speedLabel)
        }

        for part in 1...3 {
            let x = plot.minX + CGFloat(part) / 3 * plot.width
            layer.addSublayer(dashedLine(from: CGPoint(x: x, y: plot.minY), to: CGPoint(x: x, y: plot.maxY),
                                         color: gridColor.withAlphaComponent(0.3)))
            let label = exporter.makeTextLayer(
                text: PoolFormat.clock(timeline.totalTime * Double(part) / 3),
                frame: CGRect(x: x - 40, y: size.height * 0.80, width: 80, height: labelSize * 1.4),
                fontSize: labelSize, weight: .semibold, color: gridColor)
            layer.addSublayer(label)
        }

        let speedLine = CAShapeLayer()
        speedLine.path = polyline(chart.speedPoints).cgPath
        speedLine.strokeColor = Self.yellow.cgColor
        speedLine.fillColor = UIColor.clear.cgColor
        speedLine.lineWidth = max(1.5, size.width * 0.005)
        speedLine.lineJoin = .round
        layer.addSublayer(speedLine)

        let distancePath = polyline(chart.distancePoints).cgPath
        let glow = CAShapeLayer()
        glow.path = distancePath
        glow.strokeColor = Self.cyan.withAlphaComponent(0.38).cgColor
        glow.fillColor = UIColor.clear.cgColor
        glow.lineWidth = max(3, size.width * 0.012)
        glow.lineCap = .round
        glow.shadowColor = Self.cyan.cgColor
        glow.shadowOpacity = 0.8
        glow.shadowRadius = 6
        layer.addSublayer(glow)
        let distanceLine = CAShapeLayer()
        distanceLine.path = distancePath
        distanceLine.strokeColor = Self.cyan.cgColor
        distanceLine.fillColor = UIColor.clear.cgColor
        distanceLine.lineWidth = max(1.8, size.width * 0.006)
        distanceLine.lineCap = .round
        distanceLine.lineJoin = .round
        layer.addSublayer(distanceLine)

        // Playhead guide and the two markers follow the video time.
        let guide = CALayer()
        guide.bounds = CGRect(x: 0, y: 0, width: max(2, size.width * 0.003), height: plot.height)
        guide.backgroundColor = UIColor.white.withAlphaComponent(0.55).cgColor
        layer.addSublayer(guide)
        addPositionAnimation(to: guide, key: "pool-guide", times: [timeline.startTime, timeline.finishTime]) { time in
            CGPoint(x: chart.x(forTime: time), y: plot.midY)
        }

        let pointTimes = timeline.points.map(\.time)
        let distanceDot = dot(color: Self.cyan, diameter: max(8, size.width * 0.022))
        layer.addSublayer(distanceDot)
        addPositionAnimation(to: distanceDot, key: "pool-distance-dot", times: pointTimes) { time in
            CGPoint(x: chart.x(forTime: time), y: chart.y(forDistance: timeline.reading(atVideoTime: time).distance))
        }

        // The speed is a step function, so each change gets a keyframe just before and at the point.
        let stepTimes = pointTimes.flatMap { [$0 - 0.001, $0] }
        let speedDot = dot(color: Self.yellow, diameter: max(8, size.width * 0.022))
        layer.addSublayer(speedDot)
        addPositionAnimation(to: speedDot, key: "pool-speed-dot", times: stepTimes) { time in
            CGPoint(x: chart.x(forTime: time), y: chart.y(forSpeed: timeline.reading(atVideoTime: time).speed))
        }
    }

    private func dashedLine(from start: CGPoint, to end: CGPoint, color: UIColor) -> CAShapeLayer {
        let path = UIBezierPath()
        path.move(to: start)
        path.addLine(to: end)
        let line = CAShapeLayer()
        line.path = path.cgPath
        line.strokeColor = color.cgColor
        line.fillColor = UIColor.clear.cgColor
        line.lineWidth = 1
        line.lineDashPattern = [2, 3]
        return line
    }

    private func polyline(_ points: [CGPoint]) -> UIBezierPath {
        let path = UIBezierPath()
        for (index, point) in points.enumerated() {
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    private func dot(color: UIColor, diameter: CGFloat) -> CALayer {
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        dot.cornerRadius = diameter / 2
        dot.backgroundColor = color.cgColor
        dot.borderColor = UIColor.white.cgColor
        dot.borderWidth = max(1, diameter * 0.15)
        return dot
    }

    /// Linear position keyframes at the given video times (plus the start and end of the video).
    private func addPositionAnimation(to layer: CALayer, key: String, times: [Double],
                                      position: (Double) -> CGPoint) {
        let duration = max(0.001, videoDuration)
        let clamped = Array(Set(([0, duration] + times).map { min(duration, max(0, $0)) })).sorted()
        layer.position = position(0)
        guard clamped.count > 1 else { return }
        let animation = CAKeyframeAnimation(keyPath: "position")
        animation.values = clamped.map { NSValue(cgPoint: position($0)) }
        animation.keyTimes = clamped.map { NSNumber(value: $0 / duration) }
        animation.calculationMode = .linear
        animation.duration = duration
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.add(animation, forKey: key)
    }
}
