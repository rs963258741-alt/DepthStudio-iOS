import SwiftUI

/// Semi-transparent underwater telemetry overlay.
/// Uses the existing DiveSample and DiveReading models from the core modules.
struct DiveHUDOverlay: View {
    let reading: DiveReading?
    let samples: [DiveSample]
    let videoTime: Double
    let totalVideoDuration: Double
    let maximumDepth: Double

    private let cyan = Color(red: 0.28, green: 0.91, blue: 0.97)
    private let panel = Color(red: 0.015, green: 0.075, blue: 0.12)

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 520
            HStack(alignment: .center, spacing: compact ? 9 : 16) {
                metricsColumn(compact: compact)
                    .frame(width: proxy.size.width * (compact ? 0.31 : 0.29))
                profileChart(compact: compact)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(compact ? 9 : 16)
            .background {
                RoundedRectangle(cornerRadius: compact ? 15 : 22, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .overlay {
                        RoundedRectangle(cornerRadius: compact ? 15 : 22, style: .continuous)
                            .fill(panel.opacity(0.58))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: compact ? 15 : 22, style: .continuous)
                            .stroke(cyan.opacity(0.32), lineWidth: 1)
                    }
                    .shadow(color: cyan.opacity(0.12), radius: 18, y: 0)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func metricsColumn(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 12) {
            metric(
                symbol: "water.waves",
                label: "DEPTH",
                value: reading.map { String(format: "%.1f", $0.depthMeters) } ?? "—",
                unit: "m",
                compact: compact
            )
            separator
            metric(
                symbol: "clock",
                label: "DIVE TIME",
                value: reading.map { clockString($0.elapsedSeconds) } ?? "--:--",
                unit: "",
                compact: compact
            )
            separator
            metric(
                symbol: "speedometer",
                label: "RATE",
                value: reading?.verticalSpeedMetersPerSecond.map {
                    String(format: "%.2f", abs($0))
                } ?? "—",
                unit: "m/s",
                compact: compact,
                detail: rateLabel
            )
            if let temperature = reading?.temperatureCelsius {
                separator
                metric(
                    symbol: "thermometer",
                    label: "TEMP",
                    value: String(format: "%.1f", temperature),
                    unit: "°C",
                    compact: compact
                )
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private var rateLabel: String {
        guard let speed = reading?.verticalSpeedMetersPerSecond else { return " " }
        if speed > 0.03 { return "DESCENT" }
        if speed < -0.03 { return "ASCENT" }
        return "NEUTRAL"
    }

    private var separator: some View {
        Rectangle()
            .fill(cyan.opacity(0.22))
            .frame(height: 1)
    }

    private func metric(
        symbol: String,
        label: String,
        value: String,
        unit: String,
        compact: Bool,
        detail: String? = nil
    ) -> some View {
        HStack(alignment: .center, spacing: compact ? 6 : 10) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 17 : 25, weight: .medium))
                .foregroundStyle(cyan)
                .shadow(color: cyan.opacity(0.85), radius: 7)
                .frame(width: compact ? 22 : 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: compact ? 8 : 10, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(cyan.opacity(0.9))
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value)
                        .font(.system(size: compact ? 19 : 27, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(color: .white.opacity(0.25), radius: 5)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    if !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: compact ? 9 : 12, weight: .semibold))
                            .foregroundStyle(cyan)
                    }
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: compact ? 7 : 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(cyan.opacity(0.75))
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func profileChart(compact: Bool) -> some View {
        GeometryReader { geo in
            let chartWidth = geo.size.width
            let chartHeight = max(geo.size.height - (compact ? 17 : 24), 20)
            let depthLimit = max(5, ceil(maximumDepth / 5) * 5)

            ZStack(alignment: .topLeading) {
                // Depth grid: zero metres at top, greater depth lower down.
                ForEach(stride(from: 0.0, through: depthLimit, by: 5.0).map { $0 }, id: \.self) { depth in
                    let y = chartHeight * CGFloat(depth / depthLimit)
                    Path { path in
                        path.move(to: CGPoint(x: compact ? 27 : 38, y: y))
                        path.addLine(to: CGPoint(x: chartWidth, y: y))
                    }
                    .stroke(cyan.opacity(depth == 0 ? 0.38 : 0.16),
                            style: StrokeStyle(lineWidth: 0.7, dash: [2, 3]))
                    Text("\(Int(depth))m")
                        .font(.system(size: compact ? 8 : 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(cyan.opacity(0.9))
                        .position(x: compact ? 13 : 19, y: min(max(y, 6), chartHeight - 6))
                }

                profilePath(width: chartWidth, height: chartHeight, depthLimit: depthLimit,
                            leftInset: compact ? 27 : 38)
                    .stroke(cyan.opacity(0.22), lineWidth: compact ? 5 : 8)
                    .blur(radius: 6)

                profilePath(width: chartWidth, height: chartHeight, depthLimit: depthLimit,
                            leftInset: compact ? 27 : 38)
                    .stroke(
                        LinearGradient(colors: [.white, cyan, cyan.opacity(0.7)],
                                       startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: compact ? 1.8 : 2.5,
                                           lineCap: .round, lineJoin: .round)
                    )
                    .shadow(color: cyan.opacity(0.75), radius: 5)

                if let point = currentPoint(width: chartWidth, height: chartHeight,
                                            depthLimit: depthLimit,
                                            leftInset: compact ? 27 : 38) {
                    Path { path in
                        path.move(to: CGPoint(x: point.x, y: 0))
                        path.addLine(to: CGPoint(x: point.x, y: chartHeight))
                    }
                    .stroke(cyan.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Circle()
                        .fill(.white)
                        .frame(width: compact ? 5 : 8, height: compact ? 5 : 8)
                        .overlay(Circle().stroke(cyan, lineWidth: 1.5))
                        .shadow(color: cyan, radius: 6)
                        .position(point)
                }
            }
            .frame(width: chartWidth, height: chartHeight, alignment: .topLeading)
            .overlay(alignment: .bottom) {
                HStack {
                    Text(samples.first.map { clockString($0.elapsedSeconds) } ?? "00:00")
                    Spacer()
                    Text(reading.map { clockString($0.elapsedSeconds) } ?? "--:--")
                    Spacer()
                    Text(samples.last.map { clockString($0.elapsedSeconds) } ?? "--:--")
                }
                .font(.system(size: compact ? 7 : 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(cyan.opacity(0.85))
                .offset(y: compact ? 15 : 20)
            }
        }
    }

    private func profilePath(width: CGFloat, height: CGFloat, depthLimit: Double,
                             leftInset: CGFloat) -> Path {
        let points = samples
        return Path { path in
            guard points.count > 1 else { return }
            let firstTime = points.first!.elapsedSeconds
            let lastTime = max(points.last!.elapsedSeconds, firstTime + 0.001)
            for (index, sample) in points.enumerated() {
                let x = leftInset + CGFloat((sample.elapsedSeconds - firstTime) /
                                            (lastTime - firstTime)) * (width - leftInset)
                let y = CGFloat(sample.depthMeters / depthLimit) * height
                let p = CGPoint(x: x, y: y)
                if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
        }
    }

    private func currentPoint(width: CGFloat, height: CGFloat, depthLimit: Double,
                              leftInset: CGFloat) -> CGPoint? {
        guard let reading, let first = samples.first, let last = samples.last else { return nil }
        let range = max(last.elapsedSeconds - first.elapsedSeconds, 0.001)
        let x = leftInset + CGFloat((reading.elapsedSeconds - first.elapsedSeconds) / range) *
            (width - leftInset)
        let y = CGFloat(reading.depthMeters / depthLimit) * height
        return CGPoint(x: x, y: y)
    }

    private func clockString(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
