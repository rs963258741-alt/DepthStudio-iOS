import SwiftUI

/// Transparent, individually editable HUD for 泳池平潛 mode.
/// Mirrors DiveHUDOverlay: same drag, 2% centre snapping, scale, rotation and visibility.
struct PoolHUDOverlay: View {
    let reading: PoolReading?
    let timeline: PoolTimeline?
    @Binding var settings: PoolHUDSettings
    @Binding var selectedItem: String
    let isEditing: Bool

    @State private var dragOrigins: [String: HUDPoint] = [:]

    private let cyan = Color(red: 0.38, green: 0.91, blue: 1.0)
    private let muted = Color(red: 0.75, green: 0.92, blue: 0.97)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                if isEditing, let selected = settings.positions[selectedItem] {
                    snapGuides(size: size, point: selected)
                }

                ForEach(PoolHUDItemDefinition.all) { definition in
                    if (settings.visibility[definition.id] ?? true)
                        && (!PoolHUDItemDefinition.liveIDs.contains(definition.id) || reading != nil) {
                        let point = settings.positions[definition.id] ?? HUDPoint(x: 50, y: 50)
                        let transform = settings.transforms[definition.id] ?? HUDTransform()
                        hudItem(definition.id, size: size)
                            .opacity(settings.opacity)
                            .scaleEffect(settings.fontScale * transform.scale)
                            .rotationEffect(.degrees(transform.rotation))
                            .position(
                                x: size.width * CGFloat(point.x / 100),
                                y: size.height * CGFloat(min(100, max(0, point.y + settings.verticalOffset)) / 100)
                            )
                            .overlay {
                                if isEditing && selectedItem == definition.id {
                                    RoundedRectangle(cornerRadius: 5)
                                        .stroke(cyan.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                        .padding(-5)
                                        .allowsHitTesting(false)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if isEditing { selectedItem = definition.id }
                            }
                            .gesture(dragGesture(id: definition.id, size: size))
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func hudItem(_ id: String, size: CGSize) -> some View {
        switch id {
        case "hudBrand":
            Text("● FREEDIVE / POOL DYNAMIC")
                .font(.system(size: max(8, size.width * 0.027), weight: .bold, design: .rounded))
                .tracking(1.3).foregroundStyle(muted).shadow(color: cyan.opacity(0.55), radius: 5)
                .fixedSize()
        case "hudClock":
            Text(PoolFormat.clock(reading?.videoTime ?? 0))
                .font(.system(size: max(9, size.width * 0.030), weight: .semibold, design: .monospaced))
                .foregroundStyle(.white).shadow(color: cyan.opacity(0.55), radius: 6).fixedSize()
        case "identityGroup":
            HStack(spacing: max(5, size.width * 0.012)) {
                if let flagName = HUDCountryOption.assetName(for: settings.country) {
                    Image(flagName)
                        .resizable().scaledToFit()
                        .frame(height: max(12, size.width * 0.040 * settings.identityScale))
                        .clipShape(RoundedRectangle(cornerRadius: 1))
                }
                Text(settings.displayName.isEmpty ? "name" : settings.displayName)
                    .font(.system(size: max(11, size.width * 0.036 * settings.identityScale), weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text(settings.discipline)
                    .font(.system(size: max(10, size.width * 0.034 * settings.identityScale), weight: .black, design: .rounded))
                    .tracking(0.8).foregroundStyle(cyan)
                    .padding(.leading, 5)
                    .overlay(alignment: .leading) { Rectangle().fill(cyan.opacity(0.55)).frame(width: 1).padding(.vertical, 2) }
            }
            .shadow(color: cyan.opacity(0.6), radius: 7)
            .fixedSize()
        case "distanceValue":
            Text(reading.map { PoolFormat.distance($0.distance) } ?? "--.-")
                .font(.system(size: max(28, size.width * 0.13), weight: .black, design: .rounded).monospacedDigit())
                .tracking(-1.5).foregroundStyle(.white)
                .shadow(color: cyan.opacity(0.95), radius: 13).shadow(color: .black.opacity(0.65), radius: 3, y: 2)
                .fixedSize()
        case "distanceUnit":
            Text("M").font(.system(size: max(10, size.width * 0.038), weight: .heavy))
                .foregroundStyle(cyan).shadow(color: cyan.opacity(0.6), radius: 6).fixedSize()
        case "elapsedValue":
            Text(reading.map { PoolFormat.clock($0.elapsedSeconds) } ?? "--:--")
                .font(.system(size: max(13, size.width * 0.055), weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(.white).shadow(color: cyan.opacity(0.5), radius: 6).fixedSize()
        case "elapsedLabel":
            metricLabel("DIVE TIME", width: size.width)
        case "lapValue":
            Text(reading.map(PoolFormat.lap) ?? "-- / --")
                .font(.system(size: max(13, size.width * 0.055), weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(.white).shadow(color: cyan.opacity(0.5), radius: 6).fixedSize()
        case "lapLabel":
            metricLabel("LAP", width: size.width)
        case "speedValue":
            Text("\(PoolFormat.speed(reading?.speed ?? 0)) m/s")
                .font(.system(size: max(12, size.width * 0.050), weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(.white).shadow(color: cyan.opacity(0.5), radius: 6).fixedSize()
        case "speedLabel":
            metricLabel("SPEED", width: size.width)
        case "profileTitle":
            Text("DISTANCE  /  SPEED PROFILE")
                .font(.system(size: max(8, size.width * 0.025), weight: .bold, design: .rounded))
                .tracking(1).foregroundStyle(muted).shadow(color: cyan.opacity(0.5), radius: 4).fixedSize()
        case "profileBlock":
            PoolProfileChart(timeline: timeline, reading: reading)
                .frame(width: size.width * 0.91, height: size.height * 0.18)
                .shadow(color: cyan.opacity(0.38), radius: 5)
        case "footerBrand":
            Text(PoolHUDSettings.footerText)
                .font(.system(size: max(8, size.width * 0.025), weight: .bold, design: .rounded))
                .tracking(1).foregroundStyle(muted).shadow(color: cyan.opacity(0.45), radius: 4).fixedSize()
        case "totalDistance":
            Text("TOTAL \(PoolFormat.distance(timeline?.finalDistance ?? 0)) M")
                .font(.system(size: max(8, size.width * 0.025), weight: .bold, design: .rounded))
                .tracking(1).foregroundStyle(muted).shadow(color: cyan.opacity(0.45), radius: 4).fixedSize()
        case "averageSpeed":
            Text("AVG \(PoolFormat.speed(timeline?.averageSpeed ?? 0)) M/S")
                .font(.system(size: max(8, size.width * 0.025), weight: .bold, design: .rounded))
                .tracking(1).foregroundStyle(muted).shadow(color: cyan.opacity(0.45), radius: 4).fixedSize()
        default:
            EmptyView()
        }
    }

    private func metricLabel(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: max(7, width * 0.023), weight: .bold, design: .rounded))
            .tracking(1.1).foregroundStyle(muted).shadow(color: cyan.opacity(0.45), radius: 4).fixedSize()
    }

    private func dragGesture(id: String, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard isEditing, size.width > 0, size.height > 0 else { return }
                selectedItem = id
                if dragOrigins[id] == nil {
                    dragOrigins[id] = settings.positions[id] ?? HUDPoint(x: 50, y: 50)
                }
                guard let origin = dragOrigins[id] else { return }
                var x = origin.x + Double(value.translation.width / size.width * 100)
                var y = origin.y + Double(value.translation.height / size.height * 100)
                // Same centre-to-centre snapping threshold as the depth HUD (2% of stage).
                for other in PoolHUDItemDefinition.all where other.id != id && (settings.visibility[other.id] ?? true) {
                    guard let otherPoint = settings.positions[other.id] else { continue }
                    if abs(x - otherPoint.x) < 2 { x = otherPoint.x }
                    if abs(y - otherPoint.y) < 2 { y = otherPoint.y }
                }
                settings.positions[id] = HUDPoint(x: min(99, max(1, x)), y: min(99, max(1, y)))
            }
            .onEnded { _ in dragOrigins[id] = nil }
    }

    @ViewBuilder
    private func snapGuides(size: CGSize, point: HUDPoint) -> some View {
        Path { path in
            let x = size.width * CGFloat(point.x / 100)
            let y = size.height * CGFloat(min(100, max(0, point.y + settings.verticalOffset)) / 100)
            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
        }
        .stroke(cyan.opacity(0.20), style: StrokeStyle(lineWidth: 0.7, dash: [3, 5]))
        .allowsHitTesting(false)
    }
}

/// Shared geometry for the two-curve chart, so the preview and the exported video match.
/// Left axis: cumulative distance (cyan). Right axis: segment speed (yellow). Shared time axis
/// from the start point to the finish point.
struct PoolProfileGeometry {
    let timeline: PoolTimeline
    let size: CGSize

    var plot: CGRect {
        CGRect(x: size.width * 0.12, y: size.height * 0.08, width: size.width * 0.76, height: size.height * 0.66)
    }

    /// Distance axis top: the final distance rounded up to a whole pool length.
    var distanceLimit: Double {
        max(timeline.poolLength, (timeline.finalDistance / timeline.poolLength - 1e-9).rounded(.up) * timeline.poolLength)
    }

    /// Speed axis top, in 0.5 m/s steps with some headroom.
    var speedLimit: Double {
        max(0.5, ((timeline.maximumSegmentSpeed * 1.25) * 2).rounded(.up) / 2)
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

    var distancePoints: [CGPoint] {
        timeline.points.map { CGPoint(x: x(forTime: $0.time), y: y(forDistance: $0.distance)) }
    }

    /// Step line: each segment's average speed held flat across the segment.
    var speedPoints: [CGPoint] {
        var result: [CGPoint] = []
        for segment in timeline.segments {
            let level = self.y(forSpeed: segment.speed)
            result.append(CGPoint(x: self.x(forTime: segment.startTime), y: level))
            result.append(CGPoint(x: self.x(forTime: segment.endTime), y: level))
        }
        return result
    }

    static let gridFractions: [Double] = [0.25, 0.5, 0.75, 1.0]
}

private struct PoolProfileChart: View {
    let timeline: PoolTimeline?
    let reading: PoolReading?

    private let cyan = Color(red: 0.44, green: 0.93, blue: 1.0)
    private let yellow = Color(red: 1.0, green: 0.80, blue: 0.35)

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard let timeline else { return }
                let chart = PoolProfileGeometry(timeline: timeline, size: size)
                let plot = chart.plot
                let gridColor = Color(red: 0.63, green: 0.88, blue: 0.94).opacity(0.28)
                let labelSize = max(6, size.width * 0.022)

                for fraction in PoolProfileGeometry.gridFractions {
                    let y = plot.maxY - CGFloat(fraction) * plot.height
                    var line = Path(); line.move(to: CGPoint(x: plot.minX, y: y)); line.addLine(to: CGPoint(x: plot.maxX, y: y))
                    context.stroke(line, with: .color(gridColor), style: StrokeStyle(lineWidth: 0.7, dash: [2, 3]))
                    context.draw(Text("\(Int((chart.distanceLimit * fraction).rounded()))m")
                                    .font(.system(size: labelSize, weight: .semibold)).foregroundColor(cyan.opacity(0.9)),
                                 at: CGPoint(x: plot.minX * 0.5, y: y))
                    context.draw(Text(String(format: "%.1f", chart.speedLimit * fraction))
                                    .font(.system(size: labelSize, weight: .semibold)).foregroundColor(yellow.opacity(0.9)),
                                 at: CGPoint(x: plot.maxX + (size.width - plot.maxX) * 0.5, y: y))
                }

                for part in 1...3 {
                    let x = plot.minX + CGFloat(part) / 3 * plot.width
                    var line = Path(); line.move(to: CGPoint(x: x, y: plot.minY)); line.addLine(to: CGPoint(x: x, y: plot.maxY))
                    context.stroke(line, with: .color(gridColor), style: StrokeStyle(lineWidth: 0.7, dash: [2, 3]))
                    context.draw(Text(PoolFormat.clock(timeline.totalTime * Double(part) / 3))
                                    .font(.system(size: labelSize, weight: .semibold, design: .monospaced)).foregroundColor(.white.opacity(0.8)),
                                 at: CGPoint(x: x, y: size.height * 0.88))
                }

                var speedPath = Path()
                for (index, point) in chart.speedPoints.enumerated() {
                    if index == 0 { speedPath.move(to: point) } else { speedPath.addLine(to: point) }
                }
                context.stroke(speedPath, with: .color(yellow), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

                var distancePath = Path()
                for (index, point) in chart.distancePoints.enumerated() {
                    if index == 0 { distancePath.move(to: point) } else { distancePath.addLine(to: point) }
                }
                context.stroke(distancePath, with: .color(cyan), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                if let reading {
                    let x = chart.x(forTime: reading.videoTime)
                    var guide = Path(); guide.move(to: CGPoint(x: x, y: plot.minY)); guide.addLine(to: CGPoint(x: x, y: plot.maxY))
                    context.stroke(guide, with: .color(.white.opacity(0.55)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    let distanceDot = CGRect(x: x - 4, y: chart.y(forDistance: reading.distance) - 4, width: 8, height: 8)
                    context.fill(Path(ellipseIn: distanceDot), with: .color(cyan))
                    context.stroke(Path(ellipseIn: distanceDot), with: .color(.white), lineWidth: 1.2)
                    let speedDot = CGRect(x: x - 4, y: chart.y(forSpeed: reading.speed) - 4, width: 8, height: 8)
                    context.fill(Path(ellipseIn: speedDot), with: .color(yellow))
                    context.stroke(Path(ellipseIn: speedDot), with: .color(.white), lineWidth: 1.2)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}
