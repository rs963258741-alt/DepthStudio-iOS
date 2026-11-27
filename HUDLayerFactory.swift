import UIKit
import QuartzCore
import CoreText

/// Building blocks for the HUD drawn into exported videos.
///
/// - The HUD is a CALayer tree in output pixels (`contentsScale = 1`), sized with
///   `HUDMetrics` exactly like the SwiftUI preview: text from the frame's short side, fixed
///   values (line widths, dashes, glow, shadows) via `HUDMetrics.point`.
/// - What changes with the video time (text values, marker positions, visibility) is
///   recorded on the layers as `HUDLayerTracks`. `HUDOverlayRenderer` evaluates them for
///   every exported frame and draws the layers itself, so the export does not depend on
///   Core Animation timing (in 1.2 the device ignored those animations: values stayed
///   still and fields that start hidden never appeared).
/// - Text is vertically centred in its box, like SwiftUI centres a `Text`.
enum HUDLayerFactory {
    static func font(size: CGFloat, weight: UIFont.Weight, design: HUDFontDesign = .rounded,
                     monospacedDigits: Bool = false) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        var descriptor = base.fontDescriptor
        switch design {
        case .rounded: descriptor = descriptor.withDesign(.rounded) ?? descriptor
        case .monospaced: descriptor = descriptor.withDesign(.monospaced) ?? descriptor
        case .standard: break
        }
        if monospacedDigits {
            descriptor = descriptor.addingAttributes([
                .featureSettings: [[UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                                    UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector]]
            ])
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    static func lineHeight(of font: UIFont) -> CGFloat { ceil(font.lineHeight * 1.12) }

    static func textWidth(_ string: String, font: UIFont, tracking: CGFloat = 0) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font, .kern: tracking]).width)
    }

    /// A text layer vertically centred on `rect`'s middle, `rect.width` wide.
    static func text(_ string: String, in rect: CGRect, font: UIFont, color: UIColor,
                     tracking: CGFloat = 0, alignment: CATextLayerAlignmentMode = .center,
                     glowColor: UIColor = HUDColor.cyan.uiColor,
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
            setShadow(on: layer, color: glowColor, opacity: glowOpacity, radius: glowRadius)
        }
        return layer
    }

    static func setShadow(on layer: CALayer, color: UIColor, opacity: Float, radius: CGFloat, offsetY: CGFloat = 0) {
        layer.shadowColor = color.cgColor
        layer.shadowOpacity = opacity
        layer.shadowRadius = radius
        layer.shadowOffset = CGSize(width: 0, height: offsetY)
    }

    /// A layer the size of `bounds` holding `content`, with a shadow cast by everything inside it.
    static func shadowGroup(_ content: CALayer, bounds: CGRect, color: UIColor, opacity: Double,
                            radius: CGFloat, offsetY: CGFloat = 0) -> CALayer {
        let group = CALayer()
        group.contentsScale = 1
        group.frame = bounds
        group.addSublayer(content)
        setShadow(on: group, color: color, opacity: Float(opacity), radius: radius, offsetY: offsetY)
        return group
    }

    /// Wraps an item's content in the user's 「陰影」, if any.
    static func applyDropShadow(_ style: HUDItemStyle, to content: CALayer, bounds: CGRect, point: CGFloat) -> CALayer {
        guard let shadow = style.dropShadow else { return content }
        return shadowGroup(content, bounds: bounds, color: .black, opacity: shadow.opacity,
                           radius: shadow.radius * point, offsetY: shadow.offsetY * point)
    }

    /// One HUD text item with its look and the user's style, the export twin of HUDTextView.
    /// `width` is the box width (the text is centred in it); live values need room for
    /// their longest text.
    static func textItem(_ string: String, look: HUDTextLook, style: HUDItemStyle, unit: CGFloat,
                         width: CGFloat? = nil) -> (item: CALayer, text: CATextLayer) {
        let pt = HUDMetrics.point(unit: unit)
        let font = look.uiFont(unit: unit)
        let tracking = look.tracking * pt
        let boxWidth = width ?? (textWidth(string, font: font, tracking: tracking) + 12 * pt)
        let box = CGRect(x: 0, y: 0, width: max(10, boxWidth), height: lineHeight(of: font) * 1.2)
        let text = self.text(string, in: box, font: font, color: style.text(look.color).uiColor,
                             tracking: tracking, glowColor: style.glow(.cyan).uiColor,
                             glowOpacity: Float(style.glowOpacity(look.glow)), glowRadius: look.glowRadius * pt)
        var content: CALayer = text
        if look.darkShadow {
            content = shadowGroup(content, bounds: box, color: .black, opacity: 0.65, radius: 3 * pt, offsetY: 2 * pt)
        }
        content = applyDropShadow(style, to: content, bounds: box, point: pt)
        // `content` is the text layer itself (already centred in the box) or a shadow
        // group with the box's frame.
        let item = CALayer()
        item.contentsScale = 1
        item.bounds = box
        item.addSublayer(content)
        return (item, text)
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

    // MARK: Changes over the video's time

    /// Text that changes at the given video times: `values[i]` is shown from `starts[i]`.
    static func addTextAnimation(to layer: CATextLayer, values: [String], starts: [Double],
                                 duration: Double, key: String) {
        guard let first = values.first, values.count == starts.count else { return }
        HUDLayerTracks.setString(first, on: layer)
        guard values.count > 1 else { return }
        let tracks = HUDLayerTracks.of(layer)
        tracks.textValues = values
        tracks.textStarts = starts
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

    /// Position (in the superlayer) at the given video times, linear in between, held
    /// before the first and after the last time. The start and end of the video are included.
    static func addPositionAnimation(to layer: CALayer, times: [Double], duration: Double, key: String,
                                     position: (Double) -> CGPoint) {
        let total = max(0.001, duration)
        let clamped = Array(Set(([0, total] + times).map { min(total, max(0, $0)) })).sorted()
        layer.position = position(0)
        guard clamped.count > 1 else { return }
        let tracks = HUDLayerTracks.of(layer)
        tracks.positionTimes = clamped
        tracks.positions = clamped.map(position)
    }

    /// Shows `layer` only from `start` to `end` (video seconds), like the preview hides
    /// live values outside the recorded dive.
    static func addVisibility(to layer: CALayer, start: Double, end: Double, duration: Double, key: String) {
        HUDLayerTracks.of(layer).visibleRange = start...max(start, end)
    }

    // MARK: Shared items

    /// Flag + name + type (CWTB / DYNB …), the export twin of HUDIdentityView.
    static func identity(name: String, type: String, countryID: String, identityScale: Double,
                         style: HUDItemStyle, unit: CGFloat) -> CALayer {
        let metrics = HUDIdentityMetrics(unit: unit, identityScale: identityScale)
        let pt = metrics.point
        let nameFont = font(size: metrics.nameSize, weight: .heavy)
        let typeFont = font(size: metrics.typeSize, weight: .black)
        let flagImage = HUDCountryOption.assetName(for: countryID).flatMap { UIImage(named: $0) }
        let flagWidth = flagImage.map { metrics.flagHeight * $0.size.width / max(1, $0.size.height) } ?? 0
        let displayName = name.isEmpty ? "name" : name
        let nameWidth = textWidth(displayName, font: nameFont) + 2
        let typeWidth = textWidth(type, font: typeFont, tracking: metrics.typeTracking) + 2
        let height = max(metrics.flagHeight, lineHeight(of: nameFont), lineHeight(of: typeFont))
        var width = nameWidth + metrics.spacing + metrics.typePadding + typeWidth
        if flagWidth > 0 { width += flagWidth + metrics.spacing }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let typeColor = style.text(.cyan).uiColor

        let row = CALayer()
        row.contentsScale = 1
        row.frame = bounds
        var x: CGFloat = 0
        if let image = flagImage, let cgImage = image.cgImage {
            let flag = CALayer()
            flag.contents = cgImage
            flag.contentsGravity = .resizeAspect
            flag.contentsScale = 1
            flag.frame = CGRect(x: x, y: (height - metrics.flagHeight) / 2, width: flagWidth, height: metrics.flagHeight)
            flag.cornerRadius = pt
            flag.masksToBounds = true
            row.addSublayer(flag)
            x += flagWidth + metrics.spacing
        }
        row.addSublayer(text(displayName, in: CGRect(x: x, y: 0, width: nameWidth, height: height),
                             font: nameFont, color: style.text(.white).uiColor, alignment: .left))
        x += nameWidth + metrics.spacing
        row.addSublayer(line([CGPoint(x: x, y: 2 * pt), CGPoint(x: x, y: height - 2 * pt)],
                             color: typeColor.withAlphaComponent(0.55 * typeColor.cgColor.alpha),
                             width: metrics.separatorWidth, cap: .butt))
        row.addSublayer(text(type, in: CGRect(x: x + metrics.typePadding, y: 0, width: typeWidth, height: height),
                             font: typeFont, color: typeColor, tracking: metrics.typeTracking, alignment: .left))

        // The glow is cast by the whole group, like the preview's HStack shadow.
        var content = shadowGroup(row, bounds: bounds, color: style.glow(.cyan).uiColor,
                                  opacity: style.glowOpacity(HUDIdentityMetrics.glow),
                                  radius: HUDIdentityMetrics.glowRadius * pt)
        content = applyDropShadow(style, to: content, bounds: bounds, point: pt)
        let item = CALayer()
        item.contentsScale = 1
        item.bounds = bounds
        content.frame = bounds
        item.addSublayer(content)
        return item
    }
}

/// What a HUD layer shows over the video's time (text values, position, visibility).
/// Recorded by HUDLayerFactory and evaluated by HUDOverlayRenderer for each frame.
final class HUDLayerTracks: NSObject {
    static let key = "depthstudio.hudTracks"

    /// `textValues[i]` is shown from `textStarts[i]` (video seconds, ascending).
    var textValues: [String] = []
    var textStarts: [Double] = []
    /// Position in the superlayer at `positionTimes` (ascending), linear in between.
    var positionTimes: [Double] = []
    var positions: [CGPoint] = []
    /// Shown only inside this range (video seconds); nil = always.
    var visibleRange: ClosedRange<Double>?

    /// The tracks of `layer`, created if needed.
    static func of(_ layer: CALayer) -> HUDLayerTracks {
        if let existing = existing(on: layer) { return existing }
        let tracks = HUDLayerTracks()
        layer.setValue(tracks, forKey: key)
        return tracks
    }

    static func existing(on layer: CALayer) -> HUDLayerTracks? {
        layer.value(forKey: key) as? HUDLayerTracks
    }

    var hasText: Bool { !textValues.isEmpty }
    var hasPosition: Bool { !positions.isEmpty }

    func text(at time: Double) -> String? {
        guard let first = textValues.first else { return nil }
        guard let index = lastIndex(in: textStarts, notAfter: time) else { return first }
        return textValues[index]
    }

    func position(at time: Double) -> CGPoint? {
        guard let first = positions.first, let firstTime = positionTimes.first else { return nil }
        if time <= firstTime || positions.count == 1 { return first }
        guard let index = lastIndex(in: positionTimes, notAfter: time) else { return first }
        guard index + 1 < positions.count else { return positions[positions.count - 1] }
        let t0 = positionTimes[index], t1 = positionTimes[index + 1]
        let fraction = t1 > t0 ? CGFloat((time - t0) / (t1 - t0)) : 1
        let a = positions[index], b = positions[index + 1]
        return CGPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
    }

    func isVisible(at time: Double) -> Bool { visibleRange?.contains(time) ?? true }

    /// Index of the last value ≤ `time` in an ascending array (nil if all are later).
    private func lastIndex(in values: [Double], notAfter time: Double) -> Int? {
        var low = 0, high = values.count - 1, found: Int?
        while low <= high {
            let middle = (low + high) / 2
            if values[middle] <= time { found = middle; low = middle + 1 } else { high = middle - 1 }
        }
        return found
    }

    /// Sets a text layer's string, keeping the font, colour and tracking of an attributed string.
    static func setString(_ value: String, on layer: CATextLayer) {
        if let attributed = layer.string as? NSAttributedString, attributed.length > 0 {
            if attributed.string == value { return }
            layer.string = NSAttributedString(string: value, attributes: attributed.attributes(at: 0, effectiveRange: nil))
        } else if (layer.string as? String) != value {
            layer.string = value
        }
    }
}
