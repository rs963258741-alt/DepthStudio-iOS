import SwiftUI

/// Transparent, individually editable HUD matching the V8.18 web-preview items.
struct DiveHUDOverlay: View {
    let reading: DiveReading?
    let samples: [DiveSample]
    let maximumDepth: Double
    let deviceName: String
    @Binding var settings: HUDSettings
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

                ForEach(HUDItemDefinition.all) { definition in
                    let liveItems: Set<String> = ["hudClock", "depthValue", "depthUnit", "elapsedValue", "elapsedLabel", "tempValue", "tempLabel", "speedValue", "speedLabel"]
                    if (settings.visibility[definition.id] ?? true) && (!liveItems.contains(definition.id) || reading != nil) {
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
            Text("● FREEDIVE / MISSION 02")
                .font(.system(size: max(8, size.width * 0.027), weight: .bold, design: .rounded))
                .tracking(1.3).foregroundStyle(muted).shadow(color: cyan.opacity(0.55), radius: 5)
                .fixedSize()
        case "hudClock":
            Text(timeLabel(reading?.elapsedSeconds ?? 0))
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
                Text(settings.divingType)
                    .font(.system(size: max(10, size.width * 0.034 * settings.identityScale), weight: .black, design: .rounded))
                    .tracking(0.8).foregroundStyle(cyan)
                    .padding(.leading, 5)
                    .overlay(alignment: .leading) { Rectangle().fill(cyan.opacity(0.55)).frame(width: 1).padding(.vertical, 2) }
            }
            .shadow(color: cyan.opacity(0.6), radius: 7)
            .fixedSize()
        case "depthValue":
            Text(reading.map { String(format: "%.1f", $0.depthMeters) } ?? "--.-")
                .font(.system(size: max(30, size.width * 0.14), weight: .black, design: .rounded))
                .tracking(-1.7).foregroundStyle(.white)
                .shadow(color: cyan.opacity(0.95), radius: 13).shadow(color: .black.opacity(0.65), radius: 3, y: 2)
                .fixedSize()
        case "depthUnit":
            Text("M").font(.system(size: max(10, size.width * 0.038), weight: .heavy))
                .foregroundStyle(cyan).shadow(color: cyan.opacity(0.6), radius: 6).fixedSize()
        case "elapsedValue":
            Text(reading.map { timeLabel($0.elapsedSeconds) } ?? "--:--")
                .font(.system(size: max(13, size.width * 0.055), weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(.white).shadow(color: cyan.opacity(0.5), radius: 6).fixedSize()
        case "elapsedLabel":
            metricLabel("DIVE TIME", width: size.width)
        case "tempValue":
            Text(reading?.temperatureCelsius.map { String(format: "%.1f°", $0) } ?? "--")
                .font(.system(size: max(13, size.width * 0.055), weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(.white).shadow(color: cyan.opacity(0.5), radius: 6).fixedSize()
        case "tempLabel":
            metricLabel("WATER TEMP", width: size.width)
        case "speedValue":
            Text(String(format: "%.1f m/s", reading?.verticalSpeedMetersPerSecond ?? 0))
                .font(.system(size: max(12, size.width * 0.050), weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(.white).shadow(color: cyan.opacity(0.5), radius: 6).fixedSize()
        case "speedLabel":
            metricLabel("DEPTH / SEC", width: size.width)
        case "profileTitle":
            Text("DEPTH PROFILE  /  0 M ↓ MAX DEPTH")
                .font(.system(size: max(8, size.width * 0.025), weight: .bold, design: .rounded))
                .tracking(1).foregroundStyle(muted).shadow(color: cyan.opacity(0.5), radius: 4).fixedSize()
        case "profileBlock":
            DepthProfileChart(samples: samples, reading: reading, maximumDepth: maximumDepth)
                .frame(width: size.width * 0.91, height: size.height * 0.18)
                .shadow(color: cyan.opacity(0.38), radius: 5)
        case "footerBrand":
            Text(deviceName.isEmpty ? "DEPTH STUDIO" : deviceName.uppercased())
                .font(.system(size: max(8, size.width * 0.025), weight: .bold, design: .rounded))
                .tracking(1).foregroundStyle(muted).shadow(color: cyan.opacity(0.45), radius: 4).fixedSize()
        case "maxDepth":
            Text("MAX \(maximumDepth, specifier: "%.1f") M")
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
                // Match the web editor's centre-to-centre snapping threshold (2% of stage).
                for other in HUDItemDefinition.all where other.id != id && (settings.visibility[other.id] ?? true) {
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

    private func timeLabel(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

/// Depth profile using the web preview's scale: deeper readings move downwards,
/// the Y axis is labelled in metres and the X axis is split into three equal time spans.
private struct DepthProfileChart: View {
    let samples: [DiveSample]
    let reading: DiveReading?
    let maximumDepth: Double

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard samples.count >= 2 else { return }
                let sorted = samples.sorted { $0.elapsedSeconds < $1.elapsedSeconds }
                let first = sorted.first!.elapsedSeconds
                let last = max(sorted.last!.elapsedSeconds, first + 0.001)
                let depthLimit = max(10, ceil(maximumDepth / 10) * 10)
                let plot = CGRect(x: size.width * 0.135, y: size.height * 0.06,
                                  width: size.width * 0.84, height: size.height * 0.70)
                let gridColor = Color(red: 0.63, green: 0.88, blue: 0.94).opacity(0.28)

                for depth in stride(from: 10.0, through: depthLimit, by: 10.0) {
                    let y = plot.minY + CGFloat(depth / depthLimit) * plot.height
                    var line = Path(); line.move(to: CGPoint(x: plot.minX, y: y)); line.addLine(to: CGPoint(x: plot.maxX, y: y))
                    context.stroke(line, with: .color(gridColor), style: StrokeStyle(lineWidth: 0.7, dash: [2, 3]))
                    context.draw(Text("\(Int(depth))m").font(.system(size: max(7, size.width * 0.024), weight: .semibold)).foregroundColor(.white.opacity(0.85)),
                                 at: CGPoint(x: size.width * 0.06, y: y))
                }

                for part in 1...3 {
                    let fraction = CGFloat(part) / 3
                    let x = plot.minX + fraction * plot.width
                    var line = Path(); line.move(to: CGPoint(x: x, y: plot.minY)); line.addLine(to: CGPoint(x: x, y: plot.maxY))
                    context.stroke(line, with: .color(gridColor), style: StrokeStyle(lineWidth: 0.7, dash: [2, 3]))
                    let elapsed = (last - first) * Double(part) / 3
                    context.draw(Text(timeLabel(elapsed)).font(.system(size: max(6, size.width * 0.020), weight: .semibold, design: .monospaced)).foregroundColor(.white.opacity(0.8)),
                                 at: CGPoint(x: x, y: size.height * 0.91))
                }

                var curve = Path()
                for (index, sample) in sorted.enumerated() {
                    let x = plot.minX + CGFloat((sample.elapsedSeconds - first) / (last - first)) * plot.width
                    let y = plot.minY + CGFloat(max(0, sample.depthMeters) / depthLimit) * plot.height
                    if index == 0 { curve.move(to: CGPoint(x: x, y: y)) } else { curve.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(curve, with: .color(cyanColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                if let reading, reading.elapsedSeconds >= first, reading.elapsedSeconds <= last {
                    let fraction = CGFloat((reading.elapsedSeconds - first) / (last - first))
                    let x = plot.minX + fraction * plot.width
                    let y = plot.minY + CGFloat(max(0, reading.depthMeters) / depthLimit) * plot.height
                    var guide = Path(); guide.move(to: CGPoint(x: x, y: plot.minY)); guide.addLine(to: CGPoint(x: x, y: plot.maxY))
                    context.stroke(guide, with: .color(cyanColor.opacity(0.75)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    context.fill(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(.white))
                    context.stroke(Path(ellipseIn: CGRect(x: x - 4, y: y - 4, width: 8, height: 8)), with: .color(cyanColor), lineWidth: 1.5)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var cyanColor: Color { Color(red: 0.44, green: 0.93, blue: 1.0) }

    private func timeLabel(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
