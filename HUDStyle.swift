import SwiftUI
import UIKit
import CoreText

// MARK: - Colours

/// An RGBA colour (0...1) that can be stored in the HUD settings.
struct HUDColor: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let white = HUDColor(red: 1, green: 1, blue: 1)
    static let cyan = HUDColor(red: 0.38, green: 0.91, blue: 1.0)
    static let chartCyan = HUDColor(red: 0.44, green: 0.93, blue: 1.0)
    static let muted = HUDColor(red: 0.75, green: 0.92, blue: 0.97)
    static let yellow = HUDColor(red: 1.0, green: 0.80, blue: 0.35)
    static let gridLine = HUDColor(red: 0.63, green: 0.88, blue: 0.94, alpha: 0.28)
    static let black = HUDColor(red: 0, green: 0, blue: 0)

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// The colour picked in a SwiftUI ColorPicker.
    init(_ color: Color) {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        if !UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) {
            var white: CGFloat = 1
            if UIColor(color).getWhite(&white, alpha: &a) { r = white; g = white; b = white }
        }
        self.init(red: Self.unit(Double(r)), green: Self.unit(Double(g)), blue: Self.unit(Double(b)), alpha: Self.unit(Double(a)))
    }

    func opacity(_ value: Double) -> HUDColor {
        var copy = self
        copy.alpha = Self.unit(alpha * value)
        return copy
    }

    var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: alpha) }
    var cgColor: CGColor { uiColor.cgColor }

    static func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 1 }
}

// MARK: - Per-field style (字體顏色、陰影、對比)

/// The user's look for one HUD field. The default (no colour, no shadow, contrast 100%)
/// is the field's original look.
struct HUDItemStyle: Codable, Equatable {
    /// 字體顏色: replaces the field's text colour and tints its glow. Nil keeps the original colours.
    var color: HUDColor?
    /// 陰影: a dark drop shadow under the field, 0 (none) ... 1 (strong).
    var shadow: Double = 0
    /// 對比: 0.5 ... 1.5. Pushes the field's colours away from (or towards) mid grey and
    /// strengthens (or softens) its glow.
    var contrast: Double = 1

    static let shadowRange: ClosedRange<Double> = 0...1
    static let contrastRange: ClosedRange<Double> = 0.5...1.5

    init(color: HUDColor? = nil, shadow: Double = 0, contrast: Double = 1) {
        self.color = color
        self.shadow = shadow
        self.contrast = contrast
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        color = try container.decodeIfPresent(HUDColor.self, forKey: .color)
        shadow = try container.decodeIfPresent(Double.self, forKey: .shadow) ?? 0
        contrast = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
        self = sanitized
    }

    var isDefault: Bool { self == HUDItemStyle() }

    var sanitized: HUDItemStyle {
        var copy = self
        copy.shadow = shadow.isFinite ? min(Self.shadowRange.upperBound, max(Self.shadowRange.lowerBound, shadow)) : 0
        copy.contrast = contrast.isFinite ? min(Self.contrastRange.upperBound, max(Self.contrastRange.lowerBound, contrast)) : 1
        return copy
    }

    /// Colour of the field's text: the chosen colour (keeping the field's own transparency)
    /// or the original colour, with the contrast applied.
    func text(_ base: HUDColor) -> HUDColor {
        guard let color else { return adjusted(base) }
        var chosen = color
        chosen.alpha = HUDColor.unit(base.alpha * color.alpha)
        return adjusted(chosen)
    }

    /// Glow colour: follows the chosen text colour, otherwise the original glow colour.
    func glow(_ base: HUDColor) -> HUDColor { adjusted(color.map { var c = $0; c.alpha = 1; return c } ?? base) }

    /// Strength of the glow with the contrast applied.
    func glowOpacity(_ base: Double) -> Double { HUDColor.unit(base * contrast) }

    /// Other colours of the field (chart lines, markers): only the contrast applies.
    func accent(_ base: HUDColor) -> HUDColor { adjusted(base) }

    func adjusted(_ color: HUDColor) -> HUDColor {
        guard contrast != 1 else { return color }
        func channel(_ value: Double) -> Double { HUDColor.unit((value - 0.5) * contrast + 0.5) }
        return HUDColor(red: channel(color.red), green: channel(color.green), blue: channel(color.blue), alpha: color.alpha)
    }

    /// The drop shadow in reference points (one point = HUDMetrics.point), or nil for none.
    var dropShadow: (opacity: Double, radius: CGFloat, offsetY: CGFloat)? {
        guard shadow > 0.001 else { return nil }
        return (0.85 * shadow, CGFloat(1.5 + 4.5 * shadow), CGFloat(1 + 3 * shadow))
    }
}

// MARK: - Text looks shared by the preview and the export

enum HUDFontWeight: Equatable {
    case semibold, bold, heavy, black

    var swiftUI: Font.Weight {
        switch self {
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }

    var uiKit: UIFont.Weight {
        switch self {
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
}

enum HUDFontDesign: Equatable {
    case rounded, monospaced, standard

    var swiftUI: Font.Design {
        switch self {
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        case .standard: return .default
        }
    }
}

/// Font, colour and glow of one HUD text. Sizes are fractions of the frame's short side
/// (`HUDMetrics.unit`) and the fixed values are in reference points
/// (`HUDMetrics.point`), so the preview, the floating preview and the export all have
/// the same proportions.
struct HUDTextLook: Equatable {
    var size: CGFloat
    var minimum: CGFloat
    var weight: HUDFontWeight
    var design: HUDFontDesign
    var monospacedDigits = false
    var tracking: CGFloat = 0
    var color: HUDColor
    var glow: Double
    var glowRadius: CGFloat
    /// The big numbers have a dark shadow under their glow.
    var darkShadow = false

    func fontSize(unit: CGFloat) -> CGFloat { max(minimum * HUDMetrics.point(unit: unit), unit * size) }

    func swiftUIFont(unit: CGFloat) -> Font {
        let font = Font.system(size: fontSize(unit: unit), weight: weight.swiftUI, design: design.swiftUI)
        return monospacedDigits ? font.monospacedDigit() : font
    }

    func uiFont(unit: CGFloat) -> UIFont {
        HUDLayerFactory.font(size: fontSize(unit: unit), weight: weight.uiKit, design: design,
                             monospacedDigits: monospacedDigits)
    }

    static let brand = HUDTextLook(size: 0.027, minimum: 8, weight: .bold, design: .rounded, tracking: 1.3,
                                   color: .muted, glow: 0.55, glowRadius: 5)
    static let clock = HUDTextLook(size: 0.030, minimum: 9, weight: .semibold, design: .monospaced,
                                   color: .white, glow: 0.55, glowRadius: 6)
    static let depthValue = HUDTextLook(size: 0.14, minimum: 30, weight: .black, design: .rounded, tracking: -1.7,
                                        color: .white, glow: 0.95, glowRadius: 13, darkShadow: true)
    static let distanceValue = HUDTextLook(size: 0.13, minimum: 28, weight: .black, design: .rounded,
                                           monospacedDigits: true, tracking: -1.5,
                                           color: .white, glow: 0.95, glowRadius: 13, darkShadow: true)
    static let unitLetter = HUDTextLook(size: 0.038, minimum: 10, weight: .heavy, design: .standard,
                                        color: .cyan, glow: 0.6, glowRadius: 6)
    static let value = HUDTextLook(size: 0.055, minimum: 13, weight: .heavy, design: .rounded, monospacedDigits: true,
                                   color: .white, glow: 0.5, glowRadius: 6)
    static let speed = HUDTextLook(size: 0.050, minimum: 12, weight: .heavy, design: .rounded, monospacedDigits: true,
                                   color: .white, glow: 0.5, glowRadius: 6)
    static let label = HUDTextLook(size: 0.023, minimum: 7, weight: .bold, design: .rounded, tracking: 1.1,
                                   color: .muted, glow: 0.45, glowRadius: 4)
    static let small = HUDTextLook(size: 0.025, minimum: 8, weight: .bold, design: .rounded, tracking: 1,
                                   color: .muted, glow: 0.45, glowRadius: 4)
    static let title = HUDTextLook(size: 0.025, minimum: 8, weight: .bold, design: .rounded, tracking: 1,
                                   color: .muted, glow: 0.5, glowRadius: 4)
}

/// Sizes of the flag + name + type group, shared by the preview and the export.
struct HUDIdentityMetrics {
    let unit: CGFloat
    let identityScale: Double

    var point: CGFloat { HUDMetrics.point(unit: unit) }
    var scale: CGFloat { CGFloat(identityScale) }
    var nameSize: CGFloat { max(11 * point, unit * 0.036 * scale) }
    var typeSize: CGFloat { max(10 * point, unit * 0.034 * scale) }
    var spacing: CGFloat { max(5 * point, unit * 0.012) }
    var flagHeight: CGFloat { max(12 * point, unit * 0.040 * scale) }
    var typeTracking: CGFloat { 0.8 * point }
    var typePadding: CGFloat { 5 * point }
    var separatorWidth: CGFloat { max(0.5, point) }
    static let glow = 0.6
    static let glowRadius: CGFloat = 7
}

/// Colour of the chart's text labels (「字體顏色」 of a chart changes its labels).
enum HUDChartColors {
    static let depthLabel = HUDColor.white.opacity(0.85)
    static let timeLabel = HUDColor.white.opacity(0.8)
    static let glow = 0.38
    static let glowRadius: CGFloat = 5
}

// MARK: - SwiftUI pieces

extension View {
    /// The field's 「陰影」 drop shadow, scaled like every other HUD size.
    @ViewBuilder
    func hudDropShadow(_ style: HUDItemStyle, point: CGFloat) -> some View {
        if let shadow = style.dropShadow {
            self.shadow(color: Color.black.opacity(shadow.opacity), radius: shadow.radius * point,
                        x: 0, y: shadow.offsetY * point)
        } else {
            self
        }
    }

    /// The big numbers' built-in dark shadow.
    @ViewBuilder
    func hudDarkShadow(_ enabled: Bool, point: CGFloat) -> some View {
        if enabled {
            self.shadow(color: Color.black.opacity(0.65), radius: 3 * point, x: 0, y: 2 * point)
        } else {
            self
        }
    }
}

/// One HUD text with its look and the user's style, as shown in the preview.
///
/// With `unitLabel` (the live depth / distance value) the unit is part of the same field:
/// on the value's baseline right after it, i.e. at its bottom right, and it cannot be moved
/// on its own. Like the export (HUDValueUnitLine), the value and the unit each draw the
/// whole line with the other part transparent, so each keeps its own colour and glow.
struct HUDTextView: View {
    let text: String
    let look: HUDTextLook
    let style: HUDItemStyle
    let unit: CGFloat
    var unitLabel: String? = nil
    var unitLook: HUDTextLook = .unitLetter

    var body: some View {
        let point = HUDMetrics.point(unit: unit)
        Group {
            if let unitLabel {
                ZStack {
                    line(unitLabel, showing: .value, point: point)
                        .shadow(color: style.glow(.cyan).swiftUI.opacity(style.glowOpacity(look.glow)), radius: look.glowRadius * point)
                    line(unitLabel, showing: .unit, point: point)
                        .shadow(color: style.glow(.cyan).swiftUI.opacity(style.glowOpacity(unitLook.glow)), radius: unitLook.glowRadius * point)
                }
            } else {
                Text(text)
                    .font(look.swiftUIFont(unit: unit))
                    .tracking(look.tracking * point)
                    .foregroundStyle(style.text(look.color).swiftUI)
                    .shadow(color: style.glow(.cyan).swiftUI.opacity(style.glowOpacity(look.glow)), radius: look.glowRadius * point)
            }
        }
        .hudDarkShadow(look.darkShadow, point: point)
        .fixedSize()
        .hudDropShadow(style, point: point)
    }

    /// "value unit" in one line (fonts on a shared baseline), showing only one part.
    private func line(_ unitLabel: String, showing part: HUDValueUnitLine.Part, point: CGFloat) -> Text {
        let value = Text(text)
            .font(look.swiftUIFont(unit: unit))
            .tracking(look.tracking * point)
            .foregroundStyle(part == .value ? style.text(look.color).swiftUI : Color.clear)
        let gap = Text(HUDValueUnitLine.gap).font(unitLook.swiftUIFont(unit: unit)).foregroundStyle(Color.clear)
        let unitText = Text(unitLabel)
            .font(unitLook.swiftUIFont(unit: unit))
            .tracking(unitLook.tracking * point)
            .foregroundStyle(part == .unit ? style.text(unitLook.color).swiftUI : Color.clear)
        return value + gap + unitText
    }
}

/// Flag + name + type (CWTB / DYNB …) as one group.
struct HUDIdentityView: View {
    let name: String
    let type: String
    let countryID: String
    let identityScale: Double
    let style: HUDItemStyle
    let unit: CGFloat

    var body: some View {
        let metrics = HUDIdentityMetrics(unit: unit, identityScale: identityScale)
        let typeColor = style.text(.cyan)
        HStack(spacing: metrics.spacing) {
            if let flagName = HUDCountryOption.assetName(for: countryID) {
                Image(flagName)
                    .resizable().scaledToFit()
                    .frame(height: metrics.flagHeight)
                    .clipShape(RoundedRectangle(cornerRadius: metrics.point))
            }
            Text(name.isEmpty ? "name" : name)
                .font(.system(size: metrics.nameSize, weight: .heavy, design: .rounded))
                .foregroundStyle(style.text(.white).swiftUI)
            Text(type)
                .font(.system(size: metrics.typeSize, weight: .black, design: .rounded))
                .tracking(metrics.typeTracking)
                .foregroundStyle(typeColor.swiftUI)
                .padding(.leading, metrics.typePadding)
                .overlay(alignment: .leading) {
                    Rectangle().fill(typeColor.opacity(0.55).swiftUI)
                        .frame(width: metrics.separatorWidth)
                        .padding(.vertical, 2 * metrics.point)
                }
        }
        .shadow(color: style.glow(.cyan).swiftUI.opacity(style.glowOpacity(HUDIdentityMetrics.glow)),
                radius: HUDIdentityMetrics.glowRadius * metrics.point)
        .fixedSize()
        .hudDropShadow(style, point: metrics.point)
    }
}

// MARK: - Editors

/// 字體顏色（調色盤）、陰影、對比 for the field being edited.
struct HUDStyleEditor: View {
    let itemTitle: String
    @Binding var style: HUDItemStyle
    let originalColor: HUDColor
    let onApplyToAll: () -> Void

    private var colorBinding: Binding<Color> {
        Binding(get: { (style.color ?? originalColor).swiftUI },
                set: { style.color = HUDColor($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("「\(itemTitle)」的字體顏色、陰影與對比")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DepthStudioColors.muted)
            HStack(spacing: 10) {
                ColorPicker(selection: colorBinding, supportsOpacity: false) {
                    Label("字體顏色", systemImage: "paintpalette").font(.caption)
                }
                .accessibilityIdentifier("style.color")
                Button("原色") { style.color = nil }
                    .font(.caption)
                    .buttonStyle(.bordered).tint(DepthStudioColors.muted)
                    .disabled(style.color == nil)
                    .accessibilityIdentifier("style.originalColor")
            }
            styleSlider("陰影", value: $style.shadow, range: HUDItemStyle.shadowRange, id: "style.shadow")
            styleSlider("對比", value: $style.contrast, range: HUDItemStyle.contrastRange, id: "style.contrast")
            HStack(spacing: 8) {
                Button("套用到所有欄位", action: onApplyToAll)
                    .accessibilityIdentifier("style.applyAll")
                Button("重設此欄位樣式") { style = HUDItemStyle() }
                    .disabled(style.isDefault)
                    .accessibilityIdentifier("style.reset")
            }
            .font(.caption)
            .buttonStyle(.bordered).tint(DepthStudioColors.muted)
        }
    }

    private func styleSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(DepthStudioColors.cyan)
                    .accessibilityIdentifier("\(id).value")
            }
            Slider(value: value, in: range)
                .tint(DepthStudioColors.cyan)
                .accessibilityIdentifier(id)
        }
    }
}

/// 「將目前排版設為預設1／2」 and the 「預設1／預設2」 buttons that apply them.
struct HUDPresetButtons: View {
    let savedSlots: Set<Int>
    let onSave: (Int) -> Void
    let onApply: (Int) -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(HUDPresetSlot.all, id: \.self) { slot in
                    Button { onSave(slot) } label: {
                        Label("將目前排版設為預設\(slot)", systemImage: "pin")
                            .font(.caption.weight(.bold))
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(DepthStudioColors.cyan)
                            .padding(.horizontal, 8).padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(DepthStudioColors.background, in: Capsule())
                            .overlay(Capsule().stroke(DepthStudioColors.cyan.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("layout.savePreset\(slot)")
                }
            }
            HStack(spacing: 8) {
                ForEach(HUDPresetSlot.all, id: \.self) { slot in
                    let saved = savedSlots.contains(slot)
                    Button { onApply(slot) } label: {
                        Label(saved ? "預設\(slot)" : "預設\(slot)（未設定）",
                              systemImage: saved ? "square.stack.3d.up.fill" : "square.stack.3d.up")
                            .font(.caption.weight(.bold))
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .foregroundStyle(saved ? Color.black : DepthStudioColors.muted)
                            .padding(.horizontal, 8).padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(saved ? DepthStudioColors.cyan : DepthStudioColors.background, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!saved)
                    .accessibilityIdentifier("layout.applyPreset\(slot)")
                }
            }
        }
    }
}

enum HUDPresetSlot {
    static let all = [1, 2]
}
