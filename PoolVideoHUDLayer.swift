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

/// Builds the HUD layer tree for an exported pool video with the same settings, looks and
/// sizing rules (HUDMetrics, HUDTextLook, PoolProfileGeometry) as the on-screen PoolHUDOverlay.
struct PoolHUDLayerBuilder {
    let timeline: PoolTimeline
    let settings: PoolHUDSettings
    let videoDuration: Double

    struct TextSpec {
        var text: String
        var look: HUDTextLook
        var live: ((PoolReading) -> String)? = nil
    }

    func makeLayer(size: CGSize) -> CALayer {
        let hud = CALayer()
        hud.frame = CGRect(origin: .zero, size: size)
        hud.opacity = Float(settings.opacity)
        hud.masksToBounds = false
        let unit = HUDMetrics.unit(for: size)
        let swimTimes = self.swimTimes()
        let clockTimes = DiveVideoExporter.sampleTimes(from: 0, to: max(0.001, videoDuration), step: 0.5)

        for item in PoolHUDItemDefinition.all {
            guard settings.visibility[item.id] ?? true else { continue }
            let style = settings.style(for: item.id)
            let layer: CALayer
            switch item.id {
            case "identityGroup":
                layer = HUDLayerFactory.identity(name: settings.displayName, type: settings.discipline,
                                                 countryID: settings.country,
                                                 identityScale: settings.identityScale, style: style, unit: unit)
            case "profileBlock":
                layer = profileLayer(chartSize: CGSize(width: size.width * 0.91, height: size.height * 0.18),
                                     unit: unit, style: style)
            default:
                guard let spec = textSpec(for: item.id) else { continue }
                let made = HUDLayerFactory.textItem(spec.text, look: spec.look, style: style, unit: unit,
                                                    width: spec.live == nil ? nil : max(unit * 0.9, 10))
                if let live = spec.live {
                    HUDLayerFactory.addSampledText(to: made.text, times: item.id == "hudClock" ? clockTimes : swimTimes,
                                                   duration: videoDuration, key: "pool-text-\(item.id)") { time in
                        live(timeline.reading(atVideoTime: time))
                    }
                }
                layer = made.item
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

    /// Text of a pool HUD field, with the look the preview uses.
    func textSpec(for id: String) -> TextSpec? {
        switch id {
        case "hudBrand": return TextSpec(text: "● FREEDIVE / POOL DYNAMIC", look: .brand)
        case "hudClock": return TextSpec(text: "00:00", look: .clock, live: { PoolFormat.clock($0.videoTime) })
        case "distanceValue": return TextSpec(text: "0.0", look: .distanceValue, live: { PoolFormat.distance($0.distance) })
        case "distanceUnit": return TextSpec(text: "M", look: .unitLetter)
        case "elapsedValue": return TextSpec(text: "00:00", look: .value, live: { PoolFormat.clock($0.elapsedSeconds) })
        case "elapsedLabel": return TextSpec(text: "DIVE TIME", look: .label)
        case "lapValue": return TextSpec(text: "01 / 01", look: .value, live: { PoolFormat.lap($0) })
        case "lapLabel": return TextSpec(text: "LAP", look: .label)
        case "speedValue": return TextSpec(text: "0.00 m/s", look: .speed, live: { "\(PoolFormat.speed($0.speed)) m/s" })
        case "speedLabel": return TextSpec(text: "SPEED", look: .label)
        case "profileTitle": return TextSpec(text: "DISTANCE  /  SPEED PROFILE", look: .title)
        case "footerBrand": return TextSpec(text: PoolHUDSettings.footerText, look: .small)
        case "totalDistance": return TextSpec(text: "TOTAL \(PoolFormat.distance(timeline.finalDistance)) M", look: .small)
        case "averageSpeed": return TextSpec(text: "AVG \(PoolFormat.speed(timeline.averageSpeed)) M/S", look: .small)
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
    private func profileLayer(chartSize: CGSize, unit: CGFloat, style: HUDItemStyle) -> CALayer {
        let chart = PoolProfileGeometry(timeline: timeline, size: chartSize, unit: unit)
        let plot = chart.plot
        let pt = chart.point
        let bounds = CGRect(origin: .zero, size: chartSize)
        let cyan = style.accent(.chartCyan).uiColor
        let yellow = style.accent(.yellow).uiColor
        let gridColor = style.accent(.gridLine).uiColor

        let background = CALayer()
        background.contentsScale = 1
        background.frame = bounds
        let gridDash = [2 * pt, 3 * pt]
        let labelFont = HUDLayerFactory.font(size: chart.labelFont, weight: .semibold, design: .standard)
        let timeFont = HUDLayerFactory.font(size: chart.labelFont, weight: .semibold, design: .monospaced)
        for fraction in PoolProfileGeometry.gridFractions {
            let y = plot.maxY - CGFloat(fraction) * plot.height
            background.addSublayer(HUDLayerFactory.line([CGPoint(x: plot.minX, y: y), CGPoint(x: plot.maxX, y: y)],
                                                        color: gridColor, width: 0.7 * pt, dash: gridDash, cap: .butt))
            let leftWidth = plot.minX * 1.6
            background.addSublayer(HUDLayerFactory.text("\(Int((chart.distanceLimit * fraction).rounded()))m",
                                                        in: CGRect(x: plot.minX * 0.5 - leftWidth / 2, y: y - 1, width: leftWidth, height: 2),
                                                        font: labelFont, color: style.text(PoolChartColors.distanceLabel).uiColor))
            let rightCenter = plot.maxX + (chartSize.width - plot.maxX) * 0.5
            let rightWidth = (chartSize.width - plot.maxX) * 1.6
            background.addSublayer(HUDLayerFactory.text(String(format: "%.1f", chart.speedLimit * fraction),
                                                        in: CGRect(x: rightCenter - rightWidth / 2, y: y - 1, width: rightWidth, height: 2),
                                                        font: labelFont, color: style.text(PoolChartColors.speedLabel).uiColor))
        }
        for part in 1...3 {
            let x = plot.minX + CGFloat(part) / 3 * plot.width
            background.addSublayer(HUDLayerFactory.line([CGPoint(x: x, y: plot.minY), CGPoint(x: x, y: plot.maxY)],
                                                        color: gridColor, width: 0.7 * pt, dash: gridDash, cap: .butt))
            let width = chartSize.width * 0.2
            background.addSublayer(HUDLayerFactory.text(PoolFormat.clock(timeline.totalTime * Double(part) / 3),
                                                        in: CGRect(x: x - width / 2, y: chartSize.height * 0.88 - 1, width: width, height: 2),
                                                        font: timeFont, color: style.text(HUDChartColors.timeLabel).uiColor))
        }
        background.addSublayer(HUDLayerFactory.line(chart.speedPoints, color: yellow, width: 1.6 * pt))
        background.addSublayer(HUDLayerFactory.line(chart.distancePoints, color: cyan, width: 2 * pt))

        // The whole chart casts the cyan glow, like the preview's .shadow on the chart.
        let glowColor = style.accent(.cyan).uiColor
        let glowOpacity = style.glowOpacity(HUDChartColors.glow)
        let glowRadius = HUDChartColors.glowRadius * pt
        let content = CALayer()
        content.contentsScale = 1
        content.frame = bounds
        content.addSublayer(HUDLayerFactory.shadowGroup(background, bounds: bounds, color: glowColor,
                                                        opacity: glowOpacity, radius: glowRadius))

        // Playhead and the two markers follow the video time (0.1 s steps, the profile's resolution).
        let times = swimTimes() + [timeline.finishTime]
        let guide = HUDLayerFactory.line([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: plot.height)],
                                         color: style.accent(.white).uiColor.withAlphaComponent(0.55),
                                         width: 1 * pt, dash: [3 * pt, 3 * pt], cap: .butt)
        guide.bounds = CGRect(x: 0, y: 0, width: max(1, pt), height: plot.height)
        HUDLayerFactory.setShadow(on: guide, color: glowColor, opacity: Float(glowOpacity), radius: glowRadius)
        content.addSublayer(guide)
        HUDLayerFactory.addPositionAnimation(to: guide, times: [timeline.startTime, timeline.finishTime],
                                             duration: videoDuration, key: "pool-guide") { time in
            CGPoint(x: chart.x(forTime: time), y: plot.midY)
        }

        let distanceDot = HUDLayerFactory.dot(diameter: 8 * pt, fill: cyan, stroke: .white, strokeWidth: 1.2 * pt)
        HUDLayerFactory.setShadow(on: distanceDot, color: glowColor, opacity: Float(glowOpacity), radius: glowRadius)
        content.addSublayer(distanceDot)
        HUDLayerFactory.addPositionAnimation(to: distanceDot, times: times, duration: videoDuration, key: "pool-distance-dot") { time in
            CGPoint(x: chart.x(forTime: time), y: chart.y(forDistance: timeline.reading(atVideoTime: time).distance))
        }

        // Speed changes in steps, so each change gets a keyframe just before it as well.
        let stepTimes = times.flatMap { [$0 - 0.001, $0] }
        let speedDot = HUDLayerFactory.dot(diameter: 8 * pt, fill: yellow, stroke: .white, strokeWidth: 1.2 * pt)
        HUDLayerFactory.setShadow(on: speedDot, color: glowColor, opacity: Float(glowOpacity), radius: glowRadius)
        content.addSublayer(speedDot)
        HUDLayerFactory.addPositionAnimation(to: speedDot, times: stepTimes, duration: videoDuration, key: "pool-speed-dot") { time in
            CGPoint(x: chart.x(forTime: time), y: chart.y(forSpeed: timeline.reading(atVideoTime: time).speed))
        }

        let layer = CALayer()
        layer.contentsScale = 1
        layer.bounds = bounds
        let styled = HUDLayerFactory.applyDropShadow(style, to: content, bounds: bounds, point: pt)
        styled.frame = bounds
        layer.addSublayer(styled)
        return layer
    }
}

/// Label colours of the pool chart (「字體顏色」 of the chart changes these).
enum PoolChartColors {
    static let distanceLabel = HUDColor.chartCyan.opacity(0.9)
    static let speedLabel = HUDColor.yellow.opacity(0.9)
}
