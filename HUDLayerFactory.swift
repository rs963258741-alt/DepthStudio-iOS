import UIKit
import QuartzCore
import AVFoundation

/// Core Animation building blocks for the HUD drawn into exported videos.
///
/// - The video composition renders in output pixels, so layers use `contentsScale = 1`
///   (screen scale would render 9× the pixels for nothing and slow the export down).
/// - Sizes follow `HUDMetrics` exactly like the SwiftUI preview: text from the frame's
///   short side, fixed point values (line widths, dashes, glow) via `HUDMetrics.point`.
/// - Text is vertically centred in its box, like SwiftUI centres a `Text`.
enum HUDLayerFactory {
    static let white = UIColor(red: 0.96, green: 0.99, blue: 1, alpha: 1)
    static let cyan = UIColor(red: 0.38, green: 0.91, blue: 1, alpha: 1)
    static let chartCyan = UIColor(red: 0.44, green: 0.93, blue: 1.0, alpha: 1)
    static let muted = UIColor(red: 0.75, green: 0.92, blue: 0.97, alpha: 1)
    static let yellow = UIColor(red: 1.0, green: 0.80, blue: 0.35, alpha: 1)
    static let grid = UIColor(red: 0.63, green: 0.88, blue: 0.94, alpha: 0.28)

    enum Design { case rounded, monospaced, standard }

    static func font(size: CGFloat, weight: UIFont.Weight, design: Design = .rounded) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let systemDesign: UIFontDescriptor.SystemDesign
        switch design {
        case .rounded: systemDesign = .rounded
        case .monospaced: systemDesign = .monospaced
        case .standard: return base
        }
        guard let descriptor = base.fontDescriptor.withDesign(systemDesign) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    static func lineHeight(of font: UIFont) -> CGFloat { ceil(font.lineHeight * 1.12) }

    /// A text layer vertically centred on `rect`'s middle, `rect.width` wide.
    static func text(_ string: String, in rect: CGRect, font: UIFont, color: UIColor,
                     tracking: CGFloat = 0, alignment: CATextLayerAlignmentMode = .center,
                     glowOpacity: Float = 0, glowRadius: CGFloat = 0) -> CATextLayer {
        let layer = CATextLayer()
        let height = lineHeight(of: font)
        layer.frame = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        layer.contentsScale = 1
        layer.alignmentMode = alignment
        layer.isWrapped = false
        layer.truncationMode = .none
        layer.font = font
        layer.fontSize = font.pointSize
        layer.foregroundColor = color.cgColor
        if tracking != 0 {
            layer.string = NSAttributedString(string: string, attributes: [
                .font: font, .foregroundColor: color, .kern: tracking
            ])
        } else {
            layer.string = string
        }
        if glowOpacity > 0, glowRadius > 0 {
            layer.shadowColor = cyan.cgColor
            layer.shadowOpacity = glowOpacity
            layer.shadowRadius = glowRadius
            layer.shadowOffset = .zero
        }
        return layer
    }

    static func line(_ points: [CGPoint], color: UIColor, width: CGFloat,
                     dash: [CGFloat]? = nil, cap: CAShapeLayerLineCap = .round) -> CAShapeLayer {
        let path = CGMutablePath()
        if let first = points.first {
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        let layer = CAShapeLayer()
        layer.contentsScale = 1
        layer.path = path
        layer.strokeColor = color.cgColor
        layer.fillColor = UIColor.clear.cgColor
        layer.lineWidth = width
        layer.lineCap = cap
        layer.lineJoin = .round
        if let dash { layer.lineDashPattern = dash.map { NSNumber(value: Double($0)) } }
        return layer
    }

    static func dot(diameter: CGFloat, fill: UIColor, stroke: UIColor, strokeWidth: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.contentsScale = 1
        layer.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        layer.cornerRadius = diameter / 2
        layer.backgroundColor = fill.cgColor
        layer.borderColor = stroke.cgColor
        layer.borderWidth = strokeWidth
        return layer
    }

    /// Places an item box at its HUD position with the user's size and rotation.
    static func place(_ layer: CALayer, center: CGPoint, scale: CGFloat, rotationDegrees: Double) {
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = center
        let angle = CGFloat(rotationDegrees * Double.pi / 180)
        layer.setAffineTransform(CGAffineTransform(rotationAngle: angle).scaledBy(x: scale, y: scale))
        layer.masksToBounds = false
    }

    /// Layer caching for static items. Off: the simulator cannot run the export compositor,
    /// so its effect on the device renderer is unverified.
    nonisolated(unsafe) static var allowsRasterization = false

    /// Test hook: when set, the animation helpers apply the value at this video time
    /// directly instead of adding animations, so an export HUD can be rendered as a still
    /// image (CALayer.render(in:) ignores animations) and compared with the preview.
    nonisolated(unsafe) static var stillTime: Double?

    /// Caches a layer that never changes, so it is not redrawn for every video frame.
    static func rasterize(_ layer: CALayer) {
        guard allowsRasterization else { return }
        layer.shouldRasterize = true
        layer.rasterizationScale = 1
    }

    // MARK: Animations against the video's time

    /// Discrete text changes: `values[i]` is shown from `starts[i]` (video seconds).
    /// Per Core Animation's discrete mode, keyTimes start at 0, end at 1 and have one
    /// more entry than values.
    static func addTextAnimation(to layer: CATextLayer, values: [String], starts: [Double],
                                 duration: Double, key: String) {
        guard let first = values.first else { return }
        layer.string = first
        if let time = stillTime, values.count == starts.count {
            if let index = starts.lastIndex(where: { $0 <= time }) { layer.string = values[index] }
            return
        }
        guard values.count > 1, values.count == starts.count else { return }
        let total = max(0.001, duration)
        var keyTimes: [NSNumber] = [NSNumber(value: 0.0)]
        for start in starts.dropFirst() { keyTimes.append(NSNumber(value: min(1, max(0, start / total)))) }
        keyTimes.append(NSNumber(value: 1.0))
        let animation = CAKeyframeAnimation(keyPath: "string")
        animation.values = values
        animation.keyTimes = keyTimes
        animation.calculationMode = .discrete
        animation.duration = total
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.add(animation, forKey: key)
    }

    /// Text values sampled at `times`; consecutive repeats are merged.
    static func addSampledText(to layer: CATextLayer, times: [Double], duration: Double, key: String,
                               value: (Double) -> String) {
        var values: [String] = []
        var starts: [Double] = []
        for time in times {
            let text = value(time)
            if text != values.last {
                values.append(text)
                starts.append(time)
            }
        }
        addTextAnimation(to: layer, values: values, starts: starts, duration: duration, key: key)
    }

    /// Linear position keyframes at the given video times (plus the start and end of the video).
    static func addPositionAnimation(to layer: CALayer, times: [Double], duration: Double, key: String,
                                     position: (Double) -> CGPoint) {
        let total = max(0.001, duration)
        if let time = stillTime {
            layer.position = position(min(total, max(0, time)))
            return
        }
        let clamped = Array(Set(([0, total] + times).map { min(total, max(0, $0)) })).sorted()
        layer.position = position(0)
        guard clamped.count > 1 else { return }
        let animation = CAKeyframeAnimation(keyPath: "position")
        animation.values = clamped.map { NSValue(cgPoint: position($0)) }
        animation.keyTimes = clamped.map { NSNumber(value: $0 / total) }
        animation.calculationMode = .linear
        animation.duration = total
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.add(animation, forKey: key)
    }

    /// Shows `layer` only from `start` to `end` (video seconds), like the preview hides
    /// live values outside the recorded dive.
    static func addVisibility(to layer: CALayer, start: Double, end: Double, duration: Double, key: String) {
        if let time = stillTime {
            layer.opacity = (time >= start && time <= end) ? 1 : 0
            return
        }
        let total = max(0.001, duration)
        let s = min(1, max(0, start / total))
        let e = min(1, max(s, end / total))
        var values: [NSNumber] = []
        var keyTimes: [NSNumber] = [NSNumber(value: 0.0)]
        if s > 0 {
            values.append(NSNumber(value: 0))
            keyTimes.append(NSNumber(value: s))
        }
        values.append(NSNumber(value: 1))
        if e < 1 {
            keyTimes.append(NSNumber(value: e))
            values.append(NSNumber(value: 0))
        }
        keyTimes.append(NSNumber(value: 1.0))
        layer.opacity = s > 0 ? 0 : 1
        guard values.count > 1 else { return }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = values
        animation.keyTimes = keyTimes
        animation.calculationMode = .discrete
        animation.duration = total
        animation.beginTime = AVCoreAnimationBeginTimeAtZero
        animation.isRemovedOnCompletion = false
        animation.fillMode = .both
        layer.add(animation, forKey: key)
    }

    // MARK: Shared items

    /// Flag + name + type (CWTB / DYNB …), matching the preview's HStack.
    static func identity(name: String, type: String, countryID: String, identityScale: Double, unit: CGFloat) -> CALayer {
        let pt = HUDMetrics.point(unit: unit)
        let scale = CGFloat(identityScale)
        let nameFont = font(size: max(11 * pt, unit * 0.036 * scale), weight: .heavy)
        let typeFont = font(size: max(10 * pt, unit * 0.034 * scale), weight: .black)
        let spacing = max(5 * pt, unit * 0.012)
        let flagHeight = max(12 * pt, unit * 0.040 * scale)
        let flagImage = HUDCountryOption.assetName(for: countryID).flatMap { UIImage(named: $0) }
        let flagWidth = flagImage.map { flagHeight * $0.size.width / max(1, $0.size.height) } ?? 0
        let displayName = name.isEmpty ? "name" : name
        let typeKern = 0.8 * pt
        let nameWidth = ceil((displayName as NSString).size(withAttributes: [.font: nameFont]).width) + 2
        let typeWidth = ceil((type as NSString).size(withAttributes: [.font: typeFont, .kern: typeKern]).width) + 2
        let typePad = 5 * pt
        let height = max(flagHeight, lineHeight(of: nameFont), lineHeight(of: typeFont))
        var width = nameWidth + spacing + typePad + typeWidth
        if flagWidth > 0 { width += flagWidth + spacing }

        let layer = CALayer()
        layer.contentsScale = 1
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var x: CGFloat = 0
        if let image = flagImage, let cgImage = image.cgImage {
            let flag = CALayer()
            flag.contents = cgImage
            flag.contentsGravity = .resizeAspect
            flag.contentsScale = 1
            flag.frame = CGRect(x: x, y: (height - flagHeight) / 2, width: flagWidth, height: flagHeight)
            flag.cornerRadius = pt
            flag.masksToBounds = true
            layer.addSublayer(flag)
            x += flagWidth + spacing
        }
        layer.addSublayer(text(displayName, in: CGRect(x: x, y: 0, width: nameWidth, height: height),
                               font: nameFont, color: white, alignment: .left,
                               glowOpacity: 0.6, glowRadius: 7 * pt))
        x += nameWidth + spacing
        layer.addSublayer(line([CGPoint(x: x, y: 2 * pt), CGPoint(x: x, y: height - 2 * pt)],
                               color: cyan.withAlphaComponent(0.55), width: max(1, pt), cap: .butt))
        layer.addSublayer(text(type, in: CGRect(x: x + typePad, y: 0, width: typeWidth, height: height),
                               font: typeFont, color: cyan, tracking: typeKern, alignment: .left,
                               glowOpacity: 0.6, glowRadius: 7 * pt))
        return layer
    }
}
