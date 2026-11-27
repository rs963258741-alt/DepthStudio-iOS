import SwiftUI
import UIKit
import QuartzCore

/// 垂直深度指示計: a dark panel titled METERS with a light-to-deep gradient bar, a depth
/// scale (ticks and labels), a cyan badge pointing at the current depth and a white badge
/// at the dive's maximum depth.
///
/// The geometry is shared by the preview (DepthGaugeView) and the export
/// (DepthGaugeLayerBuilder). Every size is a design value (a 170 × 400 box) scaled from the
/// frame's short side, like the other HUD fields, so the stage, the floating preview and
/// the exported video have the same proportions.
struct DepthGaugeGeometry {
    static let designWidth: CGFloat = 170
    static let designHeight: CGFloat = 400
    /// Height of the gauge as a fraction of the frame's short side (before the field's size).
    static let heightFraction: CGFloat = 0.56

    let unit: CGFloat
    let maximumDepth: Double

    /// Output points per design unit.
    var factor: CGFloat { unit * Self.heightFraction / Self.designHeight }
    func d(_ value: CGFloat) -> CGFloat { value * factor }

    var size: CGSize { CGSize(width: d(Self.designWidth), height: d(Self.designHeight)) }

    // Panel and title
    var panel: CGRect { CGRect(x: d(52), y: d(1), width: d(100), height: d(398)) }
    var panelCorner: CGFloat { d(14) }
    var panelBorderWidth: CGFloat { d(1.5) }
    var titleX: CGFloat { d(64) }
    var titleCenterY: CGFloat { d(18) }
    var titleFontSize: CGFloat { d(10) }
    var titleTracking: CGFloat { d(1.3) }

    // Bar and scale
    var bar: CGRect { CGRect(x: d(64), y: d(34), width: d(18), height: d(348)) }
    var barCorner: CGFloat { bar.width / 2 }
    var barBorderWidth: CGFloat { d(1) }
    var scaleTop: CGFloat { d(44) }
    var scaleBottom: CGFloat { d(372) }
    var tickStart: CGFloat { d(87) }
    var majorTickEnd: CGFloat { d(99) }
    var minorTickEnd: CGFloat { d(94) }
    var majorTickWidth: CGFloat { d(1.6) }
    var minorTickWidth: CGFloat { d(1) }
    var labelX: CGFloat { d(104) }
    var labelWidth: CGFloat { d(46) }
    var labelFontSize: CGFloat { d(23) }

    // Badges (current depth and maximum depth)
    var badgeHeight: CGFloat { d(30) }
    var badgeBodyWidth: CGFloat { d(50) }
    var badgeTipLength: CGFloat { d(12) }
    var badgeCorner: CGFloat { d(6) }
    var badgeStrokeWidth: CGFloat { d(1.5) }
    var badgeFontSize: CGFloat { d(22) }
    /// x of the badge's point, just over the bar's left edge.
    var badgeTipX: CGFloat { bar.minX + d(3) }
    var badgeWidth: CGFloat { badgeBodyWidth + badgeTipLength }
    var badgeCenterX: CGFloat { badgeTipX - badgeWidth / 2 }

    var scale: (limit: Double, step: Double) { Self.scale(for: maximumDepth) }

    /// The scale's end and label step: the smallest listed end that holds the maximum depth
    /// (87 m → 0…100 m labelled every 10 m).
    static func scale(for maximumDepth: Double) -> (limit: Double, step: Double) {
        let depth = maximumDepth.isFinite ? max(0, maximumDepth) : 0
        let table: [(limit: Double, step: Double)] = [
            (10, 1), (20, 2), (30, 5), (40, 5), (50, 5), (60, 10), (80, 10), (100, 10),
            (120, 20), (150, 25), (200, 20), (300, 50)
        ]
        if let entry = table.first(where: { depth <= $0.limit + 1e-9 }) { return entry }
        let limit = (depth / 50).rounded(.up) * 50
        return (limit, max(50, (limit / 100).rounded(.up) * 10))
    }

    func y(forDepth depth: Double) -> CGFloat {
        let fraction = CGFloat(min(1, max(0, (depth.isFinite ? depth : 0) / scale.limit)))
        return scaleTop + fraction * (scaleBottom - scaleTop)
    }

    var majorDepths: [Double] {
        let (limit, step) = scale
        return (0...Int((limit / step).rounded())).map { Double($0) * step }
    }

    var minorDepths: [Double] {
        let (limit, step) = scale
        return majorDepths.map { $0 + step / 2 }.filter { $0 < limit }
    }

    static func depthLabel(_ depth: Double) -> String { "\(Int(depth.rounded()))" }

    /// The badges show whole metres.
    func badgeText(_ depth: Double) -> String { "\(Int((depth.isFinite ? max(0, depth) : 0).rounded()))" }
    var maximumText: String { badgeText(maximumDepth) }

    /// Badge outline in its own box (0…badgeWidth × 0…badgeHeight): a rounded body with a
    /// point on the right.
    var badgeLocalPath: CGPath {
        let h = badgeHeight, body = badgeBodyWidth, r = min(badgeCorner, h / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r, y: 0))
        path.addLine(to: CGPoint(x: body, y: 0))
        path.addLine(to: CGPoint(x: body + badgeTipLength, y: h / 2))
        path.addLine(to: CGPoint(x: body, y: h))
        path.addLine(to: CGPoint(x: r, y: h))
        path.addArc(tangent1End: CGPoint(x: 0, y: h), tangent2End: CGPoint(x: 0, y: h - r), radius: r)
        path.addLine(to: CGPoint(x: 0, y: r))
        path.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: r, y: 0), radius: r)
        path.closeSubpath()
        return path
    }

    /// The badge's box in gauge coordinates, centred on `centerY`.
    func badgeFrame(centerY: CGFloat) -> CGRect {
        CGRect(x: badgeTipX - badgeWidth, y: centerY - badgeHeight / 2, width: badgeWidth, height: badgeHeight)
    }

    /// Centre of the badge's text in the badge's own box.
    var badgeTextCenter: CGPoint { CGPoint(x: badgeBodyWidth / 2 + d(1), y: badgeHeight / 2) }

    // Fonts (the same font objects for the preview and the export)

    static func numberFont(size: CGFloat) -> UIFont {
        UIFont(name: "DINCondensed-Bold", size: size)
            ?? UIFont.systemFont(ofSize: size, weight: .bold, width: .condensed)
    }

    static func titleFont(size: CGFloat) -> UIFont {
        HUDLayerFactory.font(size: size, weight: .heavy, design: .standard)
    }

    /// How far a line box centred on y must move so the digits (cap height) are centred on y.
    static func capCenterShift(_ font: UIFont) -> CGFloat {
        let lineCenter = font.lineHeight / 2
        let capCenter = font.ascender - font.capHeight / 2
        return lineCenter - capCenter
    }
}

/// Colours of the gauge. The field's 「字體顏色」 changes the scale labels and the title;
/// 「對比」 applies to everything.
enum DepthGaugeColors {
    static let panelFill = HUDColor(red: 0.03, green: 0.09, blue: 0.17, alpha: 0.80)
    static let panelBorder = HUDColor(red: 0.50, green: 0.74, blue: 0.96, alpha: 0.60)
    static let title = HUDColor.white.opacity(0.88)
    static let label = HUDColor.white
    static let tick = HUDColor.white.opacity(0.85)
    static let barStops: [(location: CGFloat, color: HUDColor)] = [
        (0, HUDColor(red: 0.95, green: 0.98, blue: 1.0)),
        (0.4, HUDColor(red: 0.55, green: 0.80, blue: 0.94)),
        (1, HUDColor(red: 0.10, green: 0.27, blue: 0.42))
    ]
    static let barBorder = HUDColor.white.opacity(0.30)
    static let currentFill = HUDColor(red: 0.42, green: 0.86, blue: 0.98)
    static let currentStroke = HUDColor(red: 0.04, green: 0.22, blue: 0.38)
    static let maximumFill = HUDColor(red: 0.97, green: 0.98, blue: 1.0)
    static let maximumStroke = HUDColor(red: 0.45, green: 0.58, blue: 0.72)
    static let badgeText = HUDColor(red: 0.02, green: 0.09, blue: 0.18)
}

// MARK: - Preview

/// The gauge as drawn on the stage and in the floating preview. `depth` is the current
/// depth inside the recorded dive (nil hides the cyan badge, like the export).
struct DepthGaugeView: View {
    let geometry: DepthGaugeGeometry
    let depth: Double?
    let style: HUDItemStyle

    var body: some View {
        let g = geometry
        Canvas { context, _ in
            let panel = Path(roundedRect: g.panel, cornerRadius: g.panelCorner)
            context.fill(panel, with: .color(style.accent(DepthGaugeColors.panelFill).swiftUI))
            context.stroke(panel, with: .color(style.accent(DepthGaugeColors.panelBorder).swiftUI), lineWidth: g.panelBorderWidth)

            let titleFont = DepthGaugeGeometry.titleFont(size: g.titleFontSize)
            context.draw(Text("METERS").font(Font(titleFont as CTFont)).tracking(g.titleTracking)
                            .foregroundColor(style.text(DepthGaugeColors.title).swiftUI),
                         at: CGPoint(x: g.titleX, y: g.titleCenterY + DepthGaugeGeometry.capCenterShift(titleFont)),
                         anchor: .leading)

            let bar = Path(roundedRect: g.bar, cornerRadius: g.barCorner)
            let gradient = Gradient(stops: DepthGaugeColors.barStops.map {
                Gradient.Stop(color: style.accent($0.color).swiftUI, location: $0.location)
            })
            context.fill(bar, with: .linearGradient(gradient, startPoint: CGPoint(x: g.bar.midX, y: g.bar.minY),
                                                    endPoint: CGPoint(x: g.bar.midX, y: g.bar.maxY)))
            context.stroke(bar, with: .color(style.accent(DepthGaugeColors.barBorder).swiftUI), lineWidth: g.barBorderWidth)

            let tickColor = style.accent(DepthGaugeColors.tick).swiftUI
            var major = Path()
            for depth in g.majorDepths {
                let y = g.y(forDepth: depth)
                major.move(to: CGPoint(x: g.tickStart, y: y)); major.addLine(to: CGPoint(x: g.majorTickEnd, y: y))
            }
            context.stroke(major, with: .color(tickColor), lineWidth: g.majorTickWidth)
            var minor = Path()
            for depth in g.minorDepths {
                let y = g.y(forDepth: depth)
                minor.move(to: CGPoint(x: g.tickStart, y: y)); minor.addLine(to: CGPoint(x: g.minorTickEnd, y: y))
            }
            context.stroke(minor, with: .color(tickColor), lineWidth: g.minorTickWidth)

            let labelFont = DepthGaugeGeometry.numberFont(size: g.labelFontSize)
            let labelShift = DepthGaugeGeometry.capCenterShift(labelFont)
            for depth in g.majorDepths {
                context.draw(Text(DepthGaugeGeometry.depthLabel(depth)).font(Font(labelFont as CTFont))
                                .foregroundColor(style.text(DepthGaugeColors.label).swiftUI),
                             at: CGPoint(x: g.labelX, y: g.y(forDepth: depth) + labelShift), anchor: .leading)
            }

            drawBadge(in: context, text: g.maximumText, centerY: g.y(forDepth: g.maximumDepth),
                      fill: DepthGaugeColors.maximumFill, stroke: DepthGaugeColors.maximumStroke)
            if let depth {
                drawBadge(in: context, text: g.badgeText(depth), centerY: g.y(forDepth: depth),
                          fill: DepthGaugeColors.currentFill, stroke: DepthGaugeColors.currentStroke)
            }
        }
        .frame(width: g.size.width, height: g.size.height)
        .hudDropShadow(style, point: HUDMetrics.point(unit: g.unit))
    }

    private func drawBadge(in context: GraphicsContext, text: String, centerY: CGFloat, fill: HUDColor, stroke: HUDColor) {
        let g = geometry
        let frame = g.badgeFrame(centerY: centerY)
        var local = context
        local.translateBy(x: frame.minX, y: frame.minY)
        let path = Path(g.badgeLocalPath)
        local.fill(path, with: .color(style.accent(fill).swiftUI))
        local.stroke(path, with: .color(style.accent(stroke).swiftUI), lineWidth: g.badgeStrokeWidth)
        let font = DepthGaugeGeometry.numberFont(size: g.badgeFontSize)
        let center = g.badgeTextCenter
        local.draw(Text(text).font(Font(font as CTFont)).foregroundColor(style.accent(DepthGaugeColors.badgeText).swiftUI),
                   at: CGPoint(x: center.x, y: center.y + DepthGaugeGeometry.capCenterShift(font)), anchor: .center)
    }
}

// MARK: - Export

/// The gauge's layers for the exported video, drawn with the same geometry as the preview.
/// The cyan badge moves with the depth and shows it, only inside the recorded dive.
struct DepthGaugeLayerBuilder {
    let geometry: DepthGaugeGeometry
    let style: HUDItemStyle

    func makeLayer(liveTimes: [Double], diveStart: Double, diveEnd: Double, videoDuration: Double,
                   depth: @escaping (Double) -> Double?) -> CALayer {
        let g = geometry
        let bounds = CGRect(origin: .zero, size: g.size)
        let pt = HUDMetrics.point(unit: g.unit)

        let content = CALayer()
        content.contentsScale = 1
        content.frame = bounds

        let panel = shape(CGPath(roundedRect: g.panel, cornerWidth: g.panelCorner, cornerHeight: g.panelCorner, transform: nil),
                          fill: style.accent(DepthGaugeColors.panelFill), stroke: style.accent(DepthGaugeColors.panelBorder),
                          lineWidth: g.panelBorderWidth)
        content.addSublayer(panel)

        content.addSublayer(text("METERS", font: DepthGaugeGeometry.titleFont(size: g.titleFontSize),
                                 x: g.titleX, width: g.panel.maxX - g.titleX, centerY: g.titleCenterY,
                                 color: style.text(DepthGaugeColors.title), tracking: g.titleTracking, alignment: .left))

        let bar = CALayer()
        bar.contentsScale = 1
        bar.frame = g.bar
        bar.contents = barImage()
        bar.contentsGravity = .resize
        content.addSublayer(bar)
        content.addSublayer(shape(CGPath(roundedRect: g.bar, cornerWidth: g.barCorner, cornerHeight: g.barCorner, transform: nil),
                                  fill: nil, stroke: style.accent(DepthGaugeColors.barBorder), lineWidth: g.barBorderWidth))

        let tickColor = style.accent(DepthGaugeColors.tick)
        let major = CGMutablePath()
        for depth in g.majorDepths {
            let y = g.y(forDepth: depth)
            major.move(to: CGPoint(x: g.tickStart, y: y)); major.addLine(to: CGPoint(x: g.majorTickEnd, y: y))
        }
        content.addSublayer(shape(major, fill: nil, stroke: tickColor, lineWidth: g.majorTickWidth))
        let minor = CGMutablePath()
        for depth in g.minorDepths {
            let y = g.y(forDepth: depth)
            minor.move(to: CGPoint(x: g.tickStart, y: y)); minor.addLine(to: CGPoint(x: g.minorTickEnd, y: y))
        }
        content.addSublayer(shape(minor, fill: nil, stroke: tickColor, lineWidth: g.minorTickWidth))

        let labelFont = DepthGaugeGeometry.numberFont(size: g.labelFontSize)
        for depth in g.majorDepths {
            content.addSublayer(text(DepthGaugeGeometry.depthLabel(depth), font: labelFont, x: g.labelX, width: g.labelWidth,
                                     centerY: g.y(forDepth: depth), color: style.text(DepthGaugeColors.label), alignment: .left))
        }

        let maximum = badge(text: g.maximumText, fill: DepthGaugeColors.maximumFill, stroke: DepthGaugeColors.maximumStroke)
        maximum.layer.position = CGPoint(x: g.badgeCenterX, y: g.y(forDepth: g.maximumDepth))
        content.addSublayer(maximum.layer)

        let styled = HUDLayerFactory.applyDropShadow(style, to: content, bounds: bounds, point: pt)
        styled.frame = bounds

        let item = CALayer()
        item.contentsScale = 1
        item.bounds = bounds
        item.addSublayer(styled)

        // The current-depth badge: moves and shows the depth of each moment of the dive.
        if diveEnd > diveStart {
            let current = badge(text: "0", fill: DepthGaugeColors.currentFill, stroke: DepthGaugeColors.currentStroke)
            if let shadow = style.dropShadow {
                HUDLayerFactory.setShadow(on: current.layer, color: .black, opacity: Float(shadow.opacity),
                                          radius: shadow.radius * pt, offsetY: shadow.offsetY * pt)
            }
            item.addSublayer(current.layer)
            HUDLayerFactory.addPositionAnimation(to: current.layer, times: liveTimes, duration: videoDuration,
                                                 key: "depth-gauge-badge") { time in
                CGPoint(x: g.badgeCenterX, y: g.y(forDepth: depth(time) ?? 0))
            }
            HUDLayerFactory.addSampledText(to: current.text, times: liveTimes, duration: videoDuration,
                                           key: "depth-gauge-badge-text") { time in
                g.badgeText(depth(time) ?? 0)
            }
            HUDLayerFactory.addVisibility(to: current.layer, start: diveStart, end: diveEnd,
                                          duration: videoDuration, key: "depth-gauge-badge-visibility")
        }
        return item
    }

    private func badge(text value: String, fill: HUDColor, stroke: HUDColor) -> (layer: CALayer, text: CATextLayer) {
        let g = geometry
        let layer = CALayer()
        layer.contentsScale = 1
        layer.bounds = CGRect(x: 0, y: 0, width: g.badgeWidth, height: g.badgeHeight)
        layer.addSublayer(shape(g.badgeLocalPath, fill: style.accent(fill), stroke: style.accent(stroke),
                                lineWidth: g.badgeStrokeWidth))
        let center = g.badgeTextCenter
        let label = text(value, font: DepthGaugeGeometry.numberFont(size: g.badgeFontSize),
                         x: center.x - g.badgeBodyWidth / 2, width: g.badgeBodyWidth, centerY: center.y,
                         color: style.accent(DepthGaugeColors.badgeText), alignment: .center)
        layer.addSublayer(label)
        return (layer, label)
    }

    private func shape(_ path: CGPath, fill: HUDColor?, stroke: HUDColor?, lineWidth: CGFloat) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.contentsScale = 1
        layer.path = path
        layer.fillColor = fill?.cgColor ?? UIColor.clear.cgColor
        layer.strokeColor = stroke?.cgColor
        layer.lineWidth = stroke == nil ? 0 : lineWidth
        layer.lineCap = .butt
        layer.lineJoin = .round
        return layer
    }

    /// A one-line text layer whose digits (cap height) are centred on `centerY`, placed like
    /// the preview's Canvas text.
    private func text(_ string: String, font: UIFont, x: CGFloat, width: CGFloat, centerY: CGFloat,
                      color: HUDColor, tracking: CGFloat = 0, alignment: CATextLayerAlignmentMode) -> CATextLayer {
        let layer = CATextLayer()
        let height = font.lineHeight
        let middle = centerY + DepthGaugeGeometry.capCenterShift(font)
        layer.frame = CGRect(x: x, y: middle - height / 2, width: width, height: ceil(height) + 1)
        layer.contentsScale = 1
        layer.alignmentMode = alignment
        layer.isWrapped = false
        layer.truncationMode = .none
        layer.string = NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color.uiColor, .kern: tracking
        ])
        return layer
    }

    private func barImage() -> CGImage? {
        let g = geometry
        let size = CGSize(width: max(1, g.bar.width), height: max(1, g.bar.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let colors = DepthGaugeColors.barStops.map { style.accent($0.color).cgColor } as CFArray
        let locations = DepthGaugeColors.barStops.map(\.location)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            cg.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: g.barCorner,
                              cornerHeight: g.barCorner, transform: nil))
            cg.clip()
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                            locations: locations) else { return }
            cg.drawLinearGradient(gradient, start: CGPoint(x: size.width / 2, y: 0),
                                  end: CGPoint(x: size.width / 2, y: size.height), options: [])
        }.cgImage
    }
}
