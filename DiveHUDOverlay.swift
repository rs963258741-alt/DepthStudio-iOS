import SwiftUI

/// Transparent, individually editable HUD matching the V8.18 web-preview items.
///
/// Every size follows the stage's short side (`HUDMetrics.unit`, fixed values in
/// `HUDMetrics.point`), the same rule the export uses, so the stage, the floating preview
/// and the exported video all have the same proportions in every output shape. Each item
/// only takes touches inside its own frame, and only while layout editing is on.
struct DiveHUDOverlay: View {
    let reading: DiveReading?
    let samples: [DiveSample]
    let maximumDepth: Double
    let deviceName: String
    @Binding var settings: HUDSettings
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

                ForEach(HUDItemDefinition.all) { definition in
                    if (settings.visibility[definition.id] ?? true)
                        && (!HUDItemDefinition.liveIDs.contains(definition.id) || reading != nil) {
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
            HUDIdentityView(name: settings.displayName, type: settings.divingType, countryID: settings.country,
                            identityScale: settings.identityScale, style: style, unit: unit)
        case "profileBlock":
            DepthProfileChart(samples: samples, reading: reading, maximumDepth: maximumDepth, unit: unit, style: style)
                .frame(width: size.width * 0.91, height: size.height * 0.18)
                .shadow(color: style.accent(.cyan).swiftUI.opacity(style.glowOpacity(HUDChartColors.glow)),
                        radius: HUDChartColors.glowRadius * HUDMetrics.point(unit: unit))
                .hudDropShadow(style, point: HUDMetrics.point(unit: unit))
        default:
            if let spec = DiveVideoExporter.textSpec(for: id, maximumDepth: maximumDepth, deviceName: deviceName) {
                HUDTextView(text: reading.flatMap { spec.live?($0) } ?? previewText(id, spec: spec),
                            look: spec.look, style: style, unit: unit)
            }
        }
    }

    /// Text shown without a reading (outside the dive); live fields are hidden then anyway.
    private func previewText(_ id: String, spec: DiveVideoExporter.DepthTextSpec) -> String {
        id == "speedValue" ? "0.0 m/s" : spec.text
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
        let others = HUDItemDefinition.all
            .filter { $0.id != id && (settings.visibility[$0.id] ?? true) }
            .compactMap { settings.positions[$0.id] }
        settings.positions[id] = HUDSnapping.snap(x: origin.x + Double(translation.width / size.width * 100),
                                                  y: origin.y + Double(translation.height / size.height * 100),
                                                  verticalOffset: settings.verticalOffset, others: others)
    }
}

/// Guide lines through the selected field's centre; the stage's centre lines light up
/// when the field is centred on them.
struct HUDSnapGuides: View {
    let size: CGSize
    let point: HUDPoint
    let verticalOffset: Double

    var body: some View {
        let cyan = HUDColor.cyan.swiftUI
        let shownY = min(100, max(0, point.y + verticalOffset))
        let x = size.width * CGFloat(point.x / 100)
        let y = size.height * CGFloat(shownY / 100)
        ZStack {
            Path { path in
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
            }
            .stroke(cyan.opacity(0.20), style: StrokeStyle(lineWidth: 0.7, dash: [3, 5]))
            if HUDSnapping.isCentered(point.x) {
                Path { path in
                    path.move(to: CGPoint(x: size.width / 2, y: 0)); path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                }
                .stroke(cyan.opacity(0.85), lineWidth: 1)
                .accessibilityElement()
                .accessibilityLabel("水平置中參考線")
                .accessibilityIdentifier("snap.centerX")
            }
            if HUDSnapping.isCentered(shownY) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height / 2)); path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                }
                .stroke(cyan.opacity(0.85), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Geometry of the depth profile, shared by the preview chart and the exported video so
/// both draw the same grid, labels, curve and marker.
struct DepthProfileGeometry {
    let samples: [DiveSample]   // sorted by time, at least two
    let maximumDepth: Double
    let size: CGSize            // chart size
    let unit: CGFloat           // HUDMetrics.unit of the whole frame

    var plot: CGRect {
        CGRect(x: size.width * 0.135, y: size.height * 0.06, width: size.width * 0.84, height: size.height * 0.70)
    }
    var first: Double { samples.first?.elapsedSeconds ?? 0 }
    var last: Double { max(samples.last?.elapsedSeconds ?? 0, first + 0.001) }
    var depthLimit: Double { max(10, (maximumDepth / 10).rounded(.up) * 10) }
    var depthGrid: [Double] { Array(stride(from: 10.0, through: depthLimit, by: 10.0)) }

    var depthLabelFont: CGFloat { max(7 * point, unit * 0.0218) }
    var timeLabelFont: CGFloat { max(6 * point, unit * 0.0182) }
    var point: CGFloat { HUDMetrics.point(unit: unit) }

    func x(forTime time: Double) -> CGFloat {
        plot.minX + CGFloat(min(1, max(0, (time - first) / (last - first)))) * plot.width
    }

    func y(forDepth depth: Double) -> CGFloat {
        plot.minY + CGFloat(max(0, depth) / depthLimit) * plot.height
    }

    var curve: [CGPoint] { samples.map { CGPoint(x: x(forTime: $0.elapsedSeconds), y: y(forDepth: $0.depthMeters)) } }

    func timeLabel(part: Int) -> String {
        let value = max(0, Int(((last - first) * Double(part) / 3).rounded(.down)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

/// Depth profile using the web preview's scale: deeper readings move downwards,
/// the Y axis is labelled in metres and the X axis is split into three equal time spans.
private struct DepthProfileChart: View {
    let samples: [DiveSample]
    let reading: DiveReading?
    let maximumDepth: Double
    let unit: CGFloat
    let style: HUDItemStyle

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard samples.count >= 2 else { return }
                let chart = DepthProfileGeometry(samples: samples.sorted { $0.elapsedSeconds < $1.elapsedSeconds },
                                                 maximumDepth: maximumDepth, size: size, unit: unit)
                let plot = chart.plot
                let pt = chart.point
                let curveColor = style.accent(.chartCyan).swiftUI
                let gridColor = style.accent(.gridLine).swiftUI
                let depthLabelColor = style.text(HUDChartColors.depthLabel).swiftUI
                let timeLabelColor = style.text(HUDChartColors.timeLabel).swiftUI
                let gridStyle = StrokeStyle(lineWidth: 0.7 * pt, dash: [2 * pt, 3 * pt])

                for depth in chart.depthGrid {
                    let y = chart.y(forDepth: depth)
                    var line = Path(); line.move(to: CGPoint(x: plot.minX, y: y)); line.addLine(to: CGPoint(x: plot.maxX, y: y))
                    context.stroke(line, with: .color(gridColor), style: gridStyle)
                    context.draw(Text("\(Int(depth))m").font(.system(size: chart.depthLabelFont, weight: .semibold)).foregroundColor(depthLabelColor),
                                 at: CGPoint(x: size.width * 0.06, y: y))
                }

                for part in 1...3 {
                    let x = plot.minX + CGFloat(part) / 3 * plot.width
                    var line = Path(); line.move(to: CGPoint(x: x, y: plot.minY)); line.addLine(to: CGPoint(x: x, y: plot.maxY))
                    context.stroke(line, with: .color(gridColor), style: gridStyle)
                    context.draw(Text(chart.timeLabel(part: part)).font(.system(size: chart.timeLabelFont, weight: .semibold, design: .monospaced)).foregroundColor(timeLabelColor),
                                 at: CGPoint(x: x, y: size.height * 0.91))
                }

                var curve = Path()
                for (index, point) in chart.curve.enumerated() {
                    if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                }
                context.stroke(curve, with: .color(curveColor), style: StrokeStyle(lineWidth: 2 * pt, lineCap: .round, lineJoin: .round))

                if let reading, reading.elapsedSeconds >= chart.first, reading.elapsedSeconds <= chart.last {
                    let x = chart.x(forTime: reading.elapsedSeconds)
                    let y = chart.y(forDepth: reading.depthMeters)
                    var guide = Path(); guide.move(to: CGPoint(x: x, y: plot.minY)); guide.addLine(to: CGPoint(x: x, y: plot.maxY))
                    context.stroke(guide, with: .color(curveColor.opacity(0.75)), style: StrokeStyle(lineWidth: 1 * pt, dash: [3 * pt, 3 * pt]))
                    let r = 4 * pt
                    let dot = CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)
                    context.fill(Path(ellipseIn: dot), with: .color(.white))
                    context.stroke(Path(ellipseIn: dot), with: .color(curveColor), lineWidth: 1.5 * pt)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
