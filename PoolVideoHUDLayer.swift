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
        aspect: OutputAspect = .original,
        outputURL: URL,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        exportVideo(
            videoURL: videoURL,
            outputURL: outputURL,
            aspect: aspect,
            progress: progress,
            completion: completion,
            makeHUD: { renderSize, videoDuration in
                PoolHUDLayerBuilder(timeline: timeline, settings: settings, videoDuration: videoDuration)
                    .makeLayer(size: renderSize)
            }
        )
    }
}

/// Builds the Core Animation HUD for an exported pool video with the same settings and
/// sizing rules (HUDMetrics, PoolProfileGeometry) as the on-screen PoolHUDOverlay.
struct PoolHUDLayerBuilder {
    let timeline: PoolTimeline
    let settings: PoolHUDSettings
    let videoDuration: Double

    private struct TextSpec {
        var text: String
        var font: UIFont
        var color: UIColor
        var tracking: CGFloat = 0
        var glowOpacity: Float
        var glowRadius: CGFloat
        var live: ((PoolReading) -> String)? = nil
    }

    func makeLayer(size: CGSize) -> CALayer {
        let hud = CALayer()
        hud.frame = CGRect(origin: .zero, size: size)
        hud.opacity = Float(settings.opacity)
        hud.masksToBounds = false
        let unit = HUDMetrics.unit(for: size)
        let swimTimes = self.swimTimes()
        let clockTimes = Array(stride(from: 0.0, to: max(0.001, videoDuration), by: 0.5))

        for item in PoolHUDItemDefinition.all {
            guard settings.visibility[item.id] ?? true else { continue }
            let layer: CALayer
            switch item.id {
            case "identityGroup":
                layer = HUDLayerFactory.identity(name: settings.displayName, type: settings.discipline,
                                                 countryID: settings.country,
                                                 identityScale: settings.identityScale, unit: unit)
                HUDLayerFactory.rasterize(layer)
            case "profileBlock":
                layer = profileLayer(chartSize: CGSize(width: size.width * 0.91, height: size.height * 0.18), unit: unit)
            default:
                guard let spec = textSpec(for: item.id, unit: unit) else { continue }
                let box = CGRect(x: 0, y: 0, width: max(unit * 0.9, 10), height: HUDLayerFactory.lineHeight(of: spec.font) * 1.2)
                let container = CALayer()
                container.contentsScale = 1
                container.bounds = box
                let text = HUDLayerFactory.text(spec.text, in: box, font: spec.font, color: spec.color,
                                                tracking: spec.tracking, glowOpacity: spec.glowOpacity,
                                                glowRadius: spec.glowRadius)
                container.addSublayer(text)
                if let live = spec.live {
                    HUDLayerFactory.addSampledText(to: text, times: item.id == "hudClock" ? clockTimes : swimTimes,
                                                   duration: videoDuration, key: "pool-text-\(item.id)") { time in
                        live(timeline.reading(atVideoTime: time))
                    }
                } else {
                    HUDLayerFactory.rasterize(container)
                }
                layer = container
            }
            let point = settings.positions[item.id] ?? HUDPoint(x: 50, y: 50)
            let transform = settings.transforms[item.id] ?? HUDTransform()
            let yPercent = min(100, max(0, point.y + settings.verticalOffset))
            HUDLayerFactory.place(layer,
                                  center: CGPoint(x: size.width * CGFloat(point.x / 100), y: size.height * CGFloat(yPercent / 100)),
                                  scale: CGFloat(transform.scale * settings.fontScale),
                                  rotationDegrees: transform.rotation)
            hud.addSublayer(layer)
        }
        return hud
    }

    /// Text items with the same font sizes, weights, colours and glow as PoolHUDOverlay.
    private func textSpec(for id: String, unit: CGFloat) -> TextSpec? {
        let pt = HUDMetrics.point(unit: unit)
        let font = HUDLayerFactory.font
        let white = HUDLayerFactory.white, cyan = HUDLayerFactory.cyan, muted = HUDLayerFactory.muted
        func label(_ text: String) -> TextSpec {
            TextSpec(text: text, font: font(unit * 0.023, .bold, .rounded), color: muted,
                     tracking: 1.1 * pt, glowOpacity: 0.45, glowRadius: 4 * pt)
        }
        func small(_ text: String) -> TextSpec {
            TextSpec(text: text, font: font(unit * 0.025, .bold, .rounded), color: muted,
                     tracking: 1 * pt, glowOpacity: 0.45, glowRadius: 4 * pt)
        }
        switch id {
        case "hudBrand":
            return TextSpec(text: "● FREEDIVE / POOL DYNAMIC", font: font(unit * 0.027, .bold, .rounded), color: muted,
                            tracking: 1.3 * pt, glowOpacity: 0.55, glowRadius: 5 * pt)
        case "hudClock":
            return TextSpec(text: "00:00", font: font(unit * 0.030, .semibold, .monospaced), color: white,
                            glowOpacity: 0.55, glowRadius: 6 * pt, live: { PoolFormat.clock($0.videoTime) })
        case "distanceValue":
            return TextSpec(text: "0.0", font: font(unit * 0.13, .black, .rounded), color: white,
                            glowOpacity: 0.95, glowRadius: 13 * pt, live: { PoolFormat.distance($0.distance) })
        case "distanceUnit":
            return TextSpec(text: "M", font: font(unit * 0.038, .heavy, .standard), color: cyan,
                            glowOpacity: 0.6, glowRadius: 6 * pt)
        case "elapsedValue":
            return TextSpec(text: "00:00", font: font(unit * 0.055, .heavy, .rounded), color: white,
                            glowOpacity: 0.5, glowRadius: 6 * pt, live: { PoolFormat.clock($0.elapsedSeconds) })
        case "elapsedLabel": return label("DIVE TIME")
        case "lapValue":
            return TextSpec(text: "01 / 01", font: font(unit * 0.055, .heavy, .rounded), color: white,
                            glowOpacity: 0.5, glowRadius: 6 * pt, live: { PoolFormat.lap($0) })
        case "lapLabel": return label("LAP")
        case "speedValue":
            return TextSpec(text: "0.00 m/s", font: font(unit * 0.050, .heavy, .rounded), color: white,
                            glowOpacity: 0.5, glowRadius: 6 * pt, live: { "\(PoolFormat.speed($0.speed)) m/s" })
        case "speedLabel": return label("SPEED")
        case "profileTitle": return small("DISTANCE  /  SPEED PROFILE")
        case "footerBrand": return small(PoolHUDSettings.footerText)
        case "totalDistance": return small("TOTAL \(PoolFormat.distance(timeline.finalDistance)) M")
        case "averageSpeed": return small("AVG \(PoolFormat.speed(timeline.averageSpeed)) M/S")
        default: return nil
        }
    }

    /// Every 0.1 s across the swim (the speed profile's resolution), plus the video start
    /// and each marked point.
    private func swimTimes() -> [Double] {
        var times: [Double] = [0]
        let start = max(0, timeline.startTime)
        let end = min(videoDuration, timeline.finishTime)
        times += DiveVideoExporter.sampleTimes(from: start, to: end, step: PoolTimeline.stepDuration)
        for point in timeline.points where point.time >= 0 && point.time <= videoDuration {
            times.append(point.time)
        }
        return Array(Set(times)).sorted()
    }

    /// Two-curve chart drawn with PoolProfileGeometry, like the preview.
    private func profileLayer(chartSize: CGSize, unit: CGFloat) -> CALayer {
        let chart = PoolProfileGeometry(timeline: timeline, size: chartSize, unit: unit)
        let plot = chart.plot
        let pt = chart.point
        let layer = CALayer()
        layer.contentsScale = 1
        layer.bounds = CGRect(origin: .zero, size: chartSize)

        let background = CALayer()
        background.contentsScale = 1
        background.frame = layer.bounds
        let gridDash = [2 * pt, 3 * pt]
        let labelFont = HUDLayerFactory.font(size: chart.labelFont, weight: .semibold, design: .standard)
        let timeFont = HUDLayerFactory.font(size: chart.labelFont, weight: .semibold, design: .monospaced)
        for fraction in PoolProfileGeometry.gridFractions {
            let y = plot.maxY - CGFloat(fraction) * plot.height
            background.addSublayer(HUDLayerFactory.line([CGPoint(x: plot.minX, y: y), CGPoint(x: plot.maxX, y: y)],
                                                        color: HUDLayerFactory.grid, width: 0.7 * pt, dash: gridDash, cap: .butt))
            let leftWidth = plot.minX * 1.6
            background.addSublayer(HUDLayerFactory.text("\(Int((chart.distanceLimit * fraction).rounded()))m",
                                                        in: CGRect(x: plot.minX * 0.5 - leftWidth / 2, y: y - 1, width: leftWidth, height: 2),
                                                        font: labelFont, color: HUDLayerFactory.chartCyan.withAlphaComponent(0.9)))
            let rightCenter = plot.maxX + (chartSize.width - plot.maxX) * 0.5
            let rightWidth = (chartSize.width - plot.maxX) * 1.6
            background.addSublayer(HUDLayerFactory.text(String(format: "%.1f", chart.speedLimit * fraction),
                                                        in: CGRect(x: rightCenter - rightWidth / 2, y: y - 1, width: rightWidth, height: 2),
                                                        font: labelFont, color: HUDLayerFactory.yellow.withAlphaComponent(0.9)))
        }
        for part in 1...3 {
            let x = plot.minX + CGFloat(part) / 3 * plot.width
            background.addSublayer(HUDLayerFactory.line([CGPoint(x: x, y: plot.minY), CGPoint(x: x, y: plot.maxY)],
                                                        color: HUDLayerFactory.grid, width: 0.7 * pt, dash: gridDash, cap: .butt))
            let width = chartSize.width * 0.2
            background.addSublayer(HUDLayerFactory.text(PoolFormat.clock(timeline.totalTime * Double(part) / 3),
                                                        in: CGRect(x: x - width / 2, y: chartSize.height * 0.88 - 1, width: width, height: 2),
                                                        font: timeFont, color: UIColor.white.withAlphaComponent(0.8)))
        }
        background.addSublayer(HUDLayerFactory.line(chart.speedPoints, color: HUDLayerFactory.yellow, width: 1.6 * pt))
        let distance = HUDLayerFactory.line(chart.distancePoints, color: HUDLayerFactory.chartCyan, width: 2 * pt)
        distance.shadowColor = HUDLayerFactory.cyan.cgColor
        distance.shadowOpacity = 0.38
        distance.shadowRadius = 5 * pt
        distance.shadowOffset = .zero
        background.addSublayer(distance)
        HUDLayerFactory.rasterize(background)
        layer.addSublayer(background)

        // Playhead and the two markers follow the video time (0.1 s keyframes, the profile's resolution).
        let times = swimTimes() + [timeline.finishTime]
        let guide = HUDLayerFactory.line([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: plot.height)],
                                         color: UIColor.white.withAlphaComponent(0.55),
                                         width: 1 * pt, dash: [3 * pt, 3 * pt], cap: .butt)
        guide.bounds = CGRect(x: 0, y: 0, width: max(1, pt), height: plot.height)
        layer.addSublayer(guide)
        HUDLayerFactory.addPositionAnimation(to: guide, times: [timeline.startTime, timeline.finishTime],
                                             duration: videoDuration, key: "pool-guide") { time in
            CGPoint(x: chart.x(forTime: time), y: plot.midY)
        }

        let distanceDot = HUDLayerFactory.dot(diameter: 8 * pt, fill: HUDLayerFactory.chartCyan, stroke: .white, strokeWidth: 1.2 * pt)
        layer.addSublayer(distanceDot)
        HUDLayerFactory.addPositionAnimation(to: distanceDot, times: times, duration: videoDuration, key: "pool-distance-dot") { time in
            CGPoint(x: chart.x(forTime: time), y: chart.y(forDistance: timeline.reading(atVideoTime: time).distance))
        }

        // Speed changes in steps, so each change gets a keyframe just before it as well.
        let stepTimes = times.flatMap { [$0 - 0.001, $0] }
        let speedDot = HUDLayerFactory.dot(diameter: 8 * pt, fill: HUDLayerFactory.yellow, stroke: .white, strokeWidth: 1.2 * pt)
        layer.addSublayer(speedDot)
        HUDLayerFactory.addPositionAnimation(to: speedDot, times: stepTimes, duration: videoDuration, key: "pool-speed-dot") { time in
            CGPoint(x: chart.x(forTime: time), y: chart.y(forSpeed: timeline.reading(atVideoTime: time).speed))
        }
        return layer
    }
}
