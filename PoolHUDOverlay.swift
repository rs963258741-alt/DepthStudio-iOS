import SwiftUI

/// Transparent, individually editable HUD for 泳池平潛 mode.
/// Same rules as DiveHUDOverlay: every size follows the stage's short side (so the stage,
/// the floating preview and the export have the same proportions), each item takes
/// touches only inside its own frame and only while layout editing is on.
struct PoolHUDOverlay: View {
    let reading: PoolReading?
    let timeline: PoolTimeline?
    @Binding var settings: PoolHUDSettings
    @Binding var selectedItem: String
    let isEditing: Bool

    @State private var dragOrigins: [String: HUDPoint] = [:]

    private let cyan = HUDColor.cyan.swiftUI

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let unit = HUDMetrics.unit(for: size)
            ZStack(alignment: .topLeading) {
                if isEditing, let selected = settings.positions[selectedItem] {
                    HUDSnapGuides(size: size, point: selected, verticalOffset: settings.verticalOffset)
                }

                ForEach(PoolHUDItemDefinition.all) { definition in
                    if (settings.visibility[definition.id] ?? true)
                        && (!PoolHUDItemDefinition.liveIDs.contains(definition.id) || reading != nil) {
                        let point = settings.positions[definition.id] ?? HUDPoint(x: 50, y: 50)
                        let transform = settings.transforms[definition.id] ?? HUDTransform()
                        hudItem(definition.id, size: size, unit: unit)
                            .overlay {
                                if isEditing && selectedItem == definition.id {
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(cyan.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                        .padding(-5)
                                        .allowsHitTesting(false)
                                }
                            }
                            .contentShape(Rectangle())
                            .scaleEffect(settings.fontScale * transform.scale)
                            .rotationEffect(.degrees(transform.rotation))
                            .opacity(settings.opacity)
                            .highPriorityGesture(dragGesture(id: definition.id, size: size))
                            .allowsHitTesting(isEditing)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(definition.title)
                            .accessibilityIdentifier("hud.\(definition.id)")
                            .position(
                                x: size.width * CGFloat(point.x / 100),
                                y: size.height * CGFloat(min(100, max(0, point.y + settings.verticalOffset)) / 100)
                            )
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func hudItem(_ id: String, size: CGSize, unit: CGFloat) -> some View {
        let style = settings.style(for: id)
        switch id {
        case "identityGroup":
            HUDIdentityView(name: settings.displayName, type: settings.discipline, countryID: settings.country,
                            identityScale: settings.identityScale, style: style, unit: unit)
        case "profileBlock":
            PoolProfileChart(timeline: timeline, reading: reading, unit: unit, style: style)
                .frame(width: size.width * 0.91, height: size.height * 0.18)
                .shadow(color: style.accent(.cyan).swiftUI.opacity(style.glowOpacity(HUDChartColors.glow)),
                        radius: HUDChartColors.glowRadius * HUDMetrics.point(unit: unit))
                .hudDropShadow(style, point: HUDMetrics.point(unit: unit))
        default:
            if let spec = textSpec(for: id) {
                HUDTextView(text: reading.flatMap { spec.live?($0) } ?? placeholder(for: id, spec: spec),
                            look: spec.look, style: style, unit: unit)
            }
        }
    }

    /// The export's text specs, so the preview and the video use the same texts and looks.
    private func textSpec(for id: String) -> PoolHUDLayerBuilder.TextSpec? {
        guard let timeline else { return Self.placeholderSpec(for: id) }
        return PoolHUDLayerBuilder(timeline: timeline, settings: settings, videoDuration: timeline.finishTime).textSpec(for: id)
    }

    /// Texts without a timeline (no start/finish marked yet).
    private static func placeholderSpec(for id: String) -> PoolHUDLayerBuilder.TextSpec? {
        switch id {
        case "hudBrand": return .init(text: "● FREEDIVE / POOL DYNAMIC", look: .brand)
        case "distanceUnit": return .init(text: "M", look: .unitLetter)
        case "elapsedLabel": return .init(text: "DIVE TIME", look: .label)
        case "lapLabel": return .init(text: "LAP", look: .label)
        case "speedLabel": return .init(text: "SPEED", look: .label)
        case "profileTitle": return .init(text: "DISTANCE  /  SPEED PROFILE", look: .title)
        case "footerBrand": return .init(text: PoolHUDSettings.footerText, look: .small)
        case "totalDistance": return .init(text: "TOTAL 0.0 M", look: .small)
        case "averageSpeed": return .init(text: "AVG 0.00 M/S", look: .small)
        default: return nil
        }
    }

    private func placeholder(for id: String, spec: PoolHUDLayerBuilder.TextSpec) -> String {
        switch id {
        case "distanceValue": return "--.-"
        case "elapsedValue": return "--:--"
        case "lapValue": return "-- / --"
        default: return spec.text
        }
    }

    /// One gesture for select and move: touching an item selects it, moving it drags it.
    /// (A separate tap gesture competed with the drag, so short drags were taken as taps.)
    /// High priority so it wins over the page's scrolling; screen coordinates so scaled or
    /// rotated items follow the finger; the end event applies the final translation too,
    /// because a quick flick can arrive as a single end event.
    private func dragGesture(id: String, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in moveItem(id, by: value.translation, size: size) }
            .onEnded { value in
                moveItem(id, by: value.translation, size: size)
                dragOrigins[id] = nil
            }
    }

    private func moveItem(_ id: String, by translation: CGSize, size: CGSize) {
        guard isEditing, size.width > 0, size.height > 0 else { return }
        selectedItem = id
        // A touch without movement only selects (no snapping jump).
        guard abs(translation.width) >= 0.5 || abs(translation.height) >= 0.5 else { return }
        if dragOrigins[id] == nil {
            dragOrigins[id] = settings.positions[id] ?? HUDPoint(x: 50, y: 50)
        }
        guard let origin = dragOrigins[id] else { return }
        // Snaps to the stage centre first (threshold 2% of stage), then to other fields' centres.
        let others = PoolHUDItemDefinition.all
            .filter { $0.id != id && (settings.visibility[$0.id] ?? true) }
            .compactMap { settings.positions[$0.id] }
        settings.positions[id] = HUDSnapping.snap(x: origin.x + Double(translation.width / size.width * 100),
                                                  y: origin.y + Double(translation.height / size.height * 100),
                                                  verticalOffset: settings.verticalOffset, others: others)
    }
}

/// Shared geometry for the two-curve chart, so the preview and the exported video match.
/// Left axis: cumulative distance (cyan). Right axis: speed (yellow). Shared time axis
/// from the start point to the finish point.
struct PoolProfileGeometry {
    let timeline: PoolTimeline
    let size: CGSize   // chart size
    let unit: CGFloat  // HUDMetrics.unit of the whole frame

    var plot: CGRect {
        CGRect(x: size.width * 0.12, y: size.height * 0.08, width: size.width * 0.76, height: size.height * 0.66)
    }

    var labelFont: CGFloat { max(6 * point, unit * 0.020) }
    var point: CGFloat { HUDMetrics.point(unit: unit) }

    /// Distance axis top: the final distance rounded up to a whole pool length.
    var distanceLimit: Double {
        max(timeline.poolLength, (timeline.finalDistance / timeline.poolLength - 1e-9).rounded(.up) * timeline.poolLength)
    }

    /// Speed axis top, in 0.5 m/s steps with some headroom.
    var speedLimit: Double {
        max(0.5, ((timeline.maximumSpeed * 1.2) * 2).rounded(.up) / 2)
    }

    func x(forTime time: Double) -> CGFloat {
        let span = max(0.001, timeline.totalTime)
        let fraction = min(1, max(0, (time - timeline.startTime) / span))
        return plot.minX + CGFloat(fraction) * plot.width
    }

    func y(forDistance distance: Double) -> CGFloat {
        plot.maxY - CGFloat(min(1, max(0, distance / distanceLimit))) * plot.height
    }

    func y(forSpeed speed: Double) -> CGFloat {
        plot.maxY - CGFloat(min(1, max(0, speed / speedLimit))) * plot.height
    }

    /// At most about 400 points per curve; enough for a smooth line.
    private static func thinned<T>(_ items: [T], limit: Int = 400) -> [T] {
        guard items.count > limit, let last = items.last else { return items }
        let stride = Int((Double(items.count) / Double(limit)).rounded(.up))
        var result = Swift.stride(from: 0, to: items.count, by: stride).map { items[$0] }
        result.append(last)
        return result
    }

    var distancePoints: [CGPoint] {
        Self.thinned(timeline.distanceSeries).map { CGPoint(x: self.x(forTime: $0.time), y: self.y(forDistance: $0.distance)) }
    }

    var speedPoints: [CGPoint] {
        Self.thinned(timeline.speedSeries).map { CGPoint(x: self.x(forTime: $0.time), y: self.y(forSpeed: $0.speed)) }
    }

    static let gridFractions: [Double] = [0.25, 0.5, 0.75, 1.0]
}

private struct PoolProfileChart: View {
    let timeline: PoolTimeline?
    let reading: PoolReading?
    let unit: CGFloat
    let style: HUDItemStyle

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard let timeline else { return }
                let chart = PoolProfileGeometry(timeline: timeline, size: size, unit: unit)
                let plot = chart.plot
                let pt = chart.point
                let cyan = style.accent(.chartCyan).swiftUI
                let yellow = style.accent(.yellow).swiftUI
                let gridColor = style.accent(.gridLine).swiftUI
                let gridStyle = StrokeStyle(lineWidth: 0.7 * pt, dash: [2 * pt, 3 * pt])

                for fraction in PoolProfileGeometry.gridFractions {
                    let y = plot.maxY - CGFloat(fraction) * plot.height
                    var line = Path(); line.move(to: CGPoint(x: plot.minX, y: y)); line.addLine(to: CGPoint(x: plot.maxX, y: y))
                    context.stroke(line, with: .color(gridColor), style: gridStyle)
                    context.draw(Text("\(Int((chart.distanceLimit * fraction).rounded()))m")
                                    .font(.system(size: chart.labelFont, weight: .semibold))
                                    .foregroundColor(style.text(PoolChartColors.distanceLabel).swiftUI),
                                 at: CGPoint(x: plot.minX * 0.5, y: y))
                    context.draw(Text(String(format: "%.1f", chart.speedLimit * fraction))
                                    .font(.system(size: chart.labelFont, weight: .semibold))
                                    .foregroundColor(style.text(PoolChartColors.speedLabel).swiftUI),
                                 at: CGPoint(x: plot.maxX + (size.width - plot.maxX) * 0.5, y: y))
                }

                for part in 1...3 {
                    let x = plot.minX + CGFloat(part) / 3 * plot.width
                    var line = Path(); line.move(to: CGPoint(x: x, y: plot.minY)); line.addLine(to: CGPoint(x: x, y: plot.maxY))
                    context.stroke(line, with: .color(gridColor), style: gridStyle)
                    context.draw(Text(PoolFormat.clock(timeline.totalTime * Double(part) / 3))
                                    .font(.system(size: chart.labelFont, weight: .semibold, design: .monospaced))
                                    .foregroundColor(style.text(HUDChartColors.timeLabel).swiftUI),
                                 at: CGPoint(x: x, y: size.height * 0.88))
                }

                var speedPath = Path()
                for (index, point) in chart.speedPoints.enumerated() {
                    if index == 0 { speedPath.move(to: point) } else { speedPath.addLine(to: point) }
                }
                context.stroke(speedPath, with: .color(yellow), style: StrokeStyle(lineWidth: 1.6 * pt, lineCap: .round, lineJoin: .round))

                var distancePath = Path()
                for (index, point) in chart.distancePoints.enumerated() {
                    if index == 0 { distancePath.move(to: point) } else { distancePath.addLine(to: point) }
                }
                context.stroke(distancePath, with: .color(cyan), style: StrokeStyle(lineWidth: 2 * pt, lineCap: .round, lineJoin: .round))

                if let reading {
                    let x = chart.x(forTime: reading.videoTime)
                    var guide = Path(); guide.move(to: CGPoint(x: x, y: plot.minY)); guide.addLine(to: CGPoint(x: x, y: plot.maxY))
                    context.stroke(guide, with: .color(style.accent(.white).swiftUI.opacity(0.55)),
                                   style: StrokeStyle(lineWidth: 1 * pt, dash: [3 * pt, 3 * pt]))
                    let r = 4 * pt
                    let distanceDot = CGRect(x: x - r, y: chart.y(forDistance: reading.distance) - r, width: 2 * r, height: 2 * r)
                    context.fill(Path(ellipseIn: distanceDot), with: .color(cyan))
                    context.stroke(Path(ellipseIn: distanceDot), with: .color(.white), lineWidth: 1.2 * pt)
                    let speedDot = CGRect(x: x - r, y: chart.y(forSpeed: reading.speed) - r, width: 2 * r, height: 2 * r)
                    context.fill(Path(ellipseIn: speedDot), with: .color(yellow))
                    context.stroke(Path(ellipseIn: speedDot), with: .color(.white), lineWidth: 1.2 * pt)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
