import Foundation

/// HUD fields for 泳池平潛 mode. Same editing model as the depth HUD (position,
/// scale, rotation, visibility), with depth fields replaced by distance, lap and speed.
struct PoolHUDItemDefinition: Identifiable, Hashable {
    let id: String
    let title: String

    static let all: [PoolHUDItemDefinition] = [
        .init(id: "hudBrand", title: "品牌文字"),
        .init(id: "hudClock", title: "影片時間"),
        .init(id: "identityGroup", title: "姓名、國旗與項目"),
        .init(id: "distanceValue", title: "累積距離數值"),
        .init(id: "distanceUnit", title: "距離單位"),
        .init(id: "elapsedValue", title: "閉氣時間數值"),
        .init(id: "elapsedLabel", title: "閉氣時間標籤"),
        .init(id: "lapValue", title: "目前趟次數值"),
        .init(id: "lapLabel", title: "目前趟次標籤"),
        .init(id: "speedValue", title: "估算速率數值"),
        .init(id: "speedLabel", title: "估算速率標籤"),
        .init(id: "profileTitle", title: "距離／速率曲線標題"),
        .init(id: "profileBlock", title: "距離／速率雙曲線圖"),
        .init(id: "footerBrand", title: "蕉流自潛設計"),
        .init(id: "totalDistance", title: "總距離"),
        .init(id: "averageSpeed", title: "平均速率")
    ]

    /// Fields whose text changes with the video time.
    static let liveIDs: Set<String> = ["hudClock", "distanceValue", "elapsedValue", "lapValue", "speedValue"]
}

struct PoolHUDSettings: Codable, Equatable, HUDPresetSettings {
    static let storageKey = "depthstudio.native.pool-hud-settings.v1"
    /// Pool freediving disciplines: dynamic with fins, with bi-fins, and no fins.
    static let disciplines = ["DYN", "DYNB", "DNF"]
    static let footerText = "蕉流自潛設計"

    var positions: [String: HUDPoint]
    var transforms: [String: HUDTransform]
    var visibility: [String: Bool]
    var opacity: Double
    var fontScale: Double
    var verticalOffset: Double
    var displayName: String
    var country: String
    var identityScale: Double
    var discipline: String
    /// 字體顏色、陰影、對比 of each field; fields without an entry keep their original look.
    var styles: [String: HUDItemStyle]

    init() {
        positions = [
            "hudBrand": HUDPoint(x: 18, y: 3),
            "hudClock": HUDPoint(x: 88, y: 3),
            "identityGroup": HUDPoint(x: 27, y: 76),
            "distanceValue": HUDPoint(x: 21, y: 18),
            "distanceUnit": HUDPoint(x: 43, y: 24),
            "elapsedValue": HUDPoint(x: 62, y: 21),
            "elapsedLabel": HUDPoint(x: 62, y: 15),
            "lapValue": HUDPoint(x: 85, y: 21),
            "lapLabel": HUDPoint(x: 85, y: 15),
            "speedValue": HUDPoint(x: 82, y: 71),
            "speedLabel": HUDPoint(x: 82, y: 66),
            "profileTitle": HUDPoint(x: 30, y: 82),
            "profileBlock": HUDPoint(x: 50, y: 89),
            "footerBrand": HUDPoint(x: 17, y: 96),
            "totalDistance": HUDPoint(x: 83, y: 96),
            "averageSpeed": HUDPoint(x: 82, y: 60)
        ]
        transforms = Dictionary(uniqueKeysWithValues: PoolHUDItemDefinition.all.map { ($0.id, HUDTransform()) })
        visibility = [
            "hudBrand": false, "hudClock": false, "identityGroup": true,
            "distanceValue": true, "distanceUnit": true, "elapsedValue": true,
            "elapsedLabel": true, "lapValue": true, "lapLabel": true,
            "speedValue": true, "speedLabel": true, "profileTitle": false,
            "profileBlock": true, "footerBrand": true, "totalDistance": false,
            "averageSpeed": false
        ]
        opacity = 0.90
        fontScale = 0.90
        verticalOffset = 0
        displayName = "name"
        country = "chinesetaipei"
        identityScale = 0.80
        discipline = "DYNB"
        styles = [:]
    }

    /// Settings saved by older versions have no `styles`: missing values fall back to the
    /// defaults instead of discarding the whole settings.
    init(from decoder: Decoder) throws {
        let defaults = PoolHUDSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        positions = try c.decodeIfPresent([String: HUDPoint].self, forKey: .positions) ?? defaults.positions
        transforms = try c.decodeIfPresent([String: HUDTransform].self, forKey: .transforms) ?? defaults.transforms
        visibility = try c.decodeIfPresent([String: Bool].self, forKey: .visibility) ?? defaults.visibility
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? defaults.opacity
        fontScale = try c.decodeIfPresent(Double.self, forKey: .fontScale) ?? defaults.fontScale
        verticalOffset = try c.decodeIfPresent(Double.self, forKey: .verticalOffset) ?? defaults.verticalOffset
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? defaults.displayName
        country = try c.decodeIfPresent(String.self, forKey: .country) ?? defaults.country
        identityScale = try c.decodeIfPresent(Double.self, forKey: .identityScale) ?? defaults.identityScale
        discipline = try c.decodeIfPresent(String.self, forKey: .discipline) ?? defaults.discipline
        styles = (try? c.decodeIfPresent([String: HUDItemStyle].self, forKey: .styles)) ?? [:]
    }

    /// Loads saved pool settings. On first use the athlete name and flag are taken
    /// from the depth-mode settings so they do not have to be entered twice.
    static func load() -> PoolHUDSettings {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(PoolHUDSettings.self, from: data) {
            return decoded.mergingDefaults()
        }
        var settings = PoolHUDSettings()
        let depth = HUDSettings.load()
        settings.displayName = depth.displayName
        settings.country = depth.country
        settings.identityScale = depth.identityScale
        return settings.mergingDefaults()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    func mergingDefaults() -> PoolHUDSettings {
        var result = self
        let defaults = PoolHUDSettings()
        for item in PoolHUDItemDefinition.all {
            if result.positions[item.id] == nil { result.positions[item.id] = defaults.positions[item.id] }
            if result.transforms[item.id] == nil { result.transforms[item.id] = HUDTransform() }
            if result.visibility[item.id] == nil { result.visibility[item.id] = defaults.visibility[item.id] ?? true }
        }
        result.opacity = min(1, max(0.2, result.opacity))
        result.fontScale = min(1.4, max(0.7, result.fontScale))
        result.verticalOffset = min(25, max(-15, result.verticalOffset))
        result.identityScale = min(1.8, max(0.6, result.identityScale))
        if result.displayName.count > 30 { result.displayName = String(result.displayName.prefix(30)) }
        if !Self.disciplines.contains(result.discipline) { result.discipline = "DYNB" }
        if HUDCountryOption.assetName(for: result.country) == nil { result.country = "chinesetaipei" }
        result.styles = result.styles.mapValues(\.sanitized).filter { !$0.value.isDefault }
        return result
    }

    static var builtIn: PoolHUDSettings { PoolHUDSettings() }

    /// Key of preset 1 (「將目前排版設為預設1」), which 「恢復預設位置」 restores. It is the
    /// key the single 「將目前排版設為預設」 of version 1.2 used, so that layout becomes preset 1.
    static let customDefaultLayoutKey = "depthstudio.native.pool-hud-default-layout.v1"
    static let presetKeys = [1: customDefaultLayoutKey, 2: "depthstudio.native.pool-hud-layout-preset2.v1"]

    static func customDefaultLayout(in store: UserDefaults = .standard) -> HUDLayoutPreset? {
        preset(1, in: store)
    }

    func saveLayoutAsDefault(in store: UserDefaults = .standard) {
        savePreset(1, in: store)
    }

    static func clearCustomDefaultLayout(in store: UserDefaults = .standard) {
        clearPreset(1, in: store)
    }

    /// Restores the positions and per-item size/rotation of preset 1 if it is saved,
    /// otherwise the built-in layout.
    mutating func resetLayout(using store: UserDefaults = .standard) {
        restoreDefaultPositions(using: store)
    }

    mutating func setAllVisible(_ visible: Bool) {
        for item in PoolHUDItemDefinition.all { visibility[item.id] = visible }
    }

    func style(for id: String) -> HUDItemStyle { styles[id] ?? HUDItemStyle() }

    mutating func setStyle(_ style: HUDItemStyle, for id: String) {
        styles[id] = style.isDefault ? nil : style.sanitized
    }

    /// The colour a field's 「原色」 refers to.
    static func originalColor(for id: String) -> HUDColor {
        switch id {
        case "distanceUnit": return .cyan
        case "hudBrand", "elapsedLabel", "lapLabel", "speedLabel", "profileTitle", "footerBrand",
             "totalDistance", "averageSpeed": return .muted
        default: return .white
        }
    }
}
