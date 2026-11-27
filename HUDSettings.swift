import Foundation

struct HUDPoint: Codable, Equatable {
    var x: Double
    var y: Double
}

struct HUDTransform: Codable, Equatable {
    var scale: Double = 1.0
    var rotation: Double = 0.0
}

struct HUDItemDefinition: Identifiable, Hashable {
    let id: String
    let title: String

    static let all: [HUDItemDefinition] = [
        .init(id: "hudBrand", title: "品牌文字"),
        .init(id: "hudClock", title: "影片時間"),
        .init(id: "identityGroup", title: "姓名、國旗與潛水種類"),
        .init(id: "depthValue", title: "即時深度數值與單位"),
        .init(id: "elapsedValue", title: "潛水時間數值"),
        .init(id: "elapsedLabel", title: "潛水時間標籤"),
        .init(id: "tempValue", title: "水溫數值"),
        .init(id: "tempLabel", title: "水溫標籤"),
        .init(id: "speedValue", title: "深度變化速度數值"),
        .init(id: "speedLabel", title: "深度變化速度標籤"),
        .init(id: "profileTitle", title: "深度曲線標題"),
        .init(id: "profileBlock", title: "深度曲線圖"),
        .init(id: "depthGauge", title: "垂直深度指示計"),
        .init(id: "footerBrand", title: "裝置名稱"),
        .init(id: "maxDepth", title: "最大深度")
    ]

    /// Items shown only while the recorded dive covers the current video time. (The depth
    /// unit is part of the depth value since 1.4, fixed at its bottom right.)
    static let liveIDs: Set<String> = ["hudClock", "depthValue", "elapsedValue", "elapsedLabel",
                                       "tempValue", "tempLabel", "speedValue", "speedLabel"]
}

struct HUDCountryOption: Identifiable, Hashable {
    let id: String
    let title: String
    let assetName: String

    static let all: [HUDCountryOption] = [
        .init(id: "roc", title: "中華民國 Republic of China", assetName: "FlagROC"),
        .init(id: "hongkong", title: "香港 Hong Kong", assetName: "FlagHongKong"),
        .init(id: "china", title: "中國 China", assetName: "FlagChina"),
        .init(id: "southkorea", title: "韓國 South Korea", assetName: "FlagSouthKorea"),
        .init(id: "malaysia", title: "馬來西亞 Malaysia", assetName: "FlagMalaysia"),
        .init(id: "japan", title: "日本 Japan", assetName: "FlagJapan"),
        .init(id: "chinesetaipei", title: "中華台北 Chinese Taipei", assetName: "FlagChineseTaipei")
    ]

    static func assetName(for id: String) -> String? {
        all.first(where: { $0.id == id })?.assetName
    }
}

struct HUDSettings: Codable, Equatable, HUDPresetSettings {
    static let storageKey = "depthstudio.native.hud-settings.v1"
    static let diveTypes = ["CWTB", "CNF", "CWT", "FIM", "VWT", "DPV"]

    var positions: [String: HUDPoint]
    var transforms: [String: HUDTransform]
    var visibility: [String: Bool]
    var opacity: Double
    var fontScale: Double
    var verticalOffset: Double
    var syncOffset: Double
    var displayName: String
    var country: String
    var identityScale: Double
    var divingType: String
    /// 字體顏色、陰影、對比 of each field; fields without an entry keep their original look.
    var styles: [String: HUDItemStyle]

    init() {
        positions = [
            "hudBrand": HUDPoint(x: 16, y: 3),
            "hudClock": HUDPoint(x: 88, y: 3),
            "identityGroup": HUDPoint(x: 25, y: 76),
            "depthValue": HUDPoint(x: 20, y: 18),
            "elapsedValue": HUDPoint(x: 55, y: 21),
            "elapsedLabel": HUDPoint(x: 55, y: 15),
            "tempValue": HUDPoint(x: 82, y: 21),
            "tempLabel": HUDPoint(x: 82, y: 15),
            "speedValue": HUDPoint(x: 82, y: 71),
            "speedLabel": HUDPoint(x: 82, y: 78),
            "profileTitle": HUDPoint(x: 30, y: 82),
            "profileBlock": HUDPoint(x: 50, y: 89),
            "depthGauge": HUDPoint(x: 86, y: 46),
            "footerBrand": HUDPoint(x: 17, y: 96),
            "maxDepth": HUDPoint(x: 83, y: 96)
        ]
        transforms = Dictionary(uniqueKeysWithValues: HUDItemDefinition.all.map { ($0.id, HUDTransform()) })
        visibility = [
            "hudBrand": false, "hudClock": false, "identityGroup": true,
            "depthValue": true, "elapsedValue": true,
            "elapsedLabel": true, "tempValue": true, "tempLabel": true,
            "speedValue": true, "speedLabel": true, "profileTitle": false,
            "profileBlock": true, "depthGauge": true, "footerBrand": false, "maxDepth": false
        ]
        opacity = 0.90
        fontScale = 0.90
        verticalOffset = 0
        syncOffset = 0
        displayName = "name"
        country = "chinesetaipei"
        identityScale = 0.80
        divingType = "CWTB"
        styles = [:]
    }

    /// Settings saved by older versions have no `styles` (and could lack other keys):
    /// missing values fall back to the defaults instead of discarding the whole settings.
    init(from decoder: Decoder) throws {
        let defaults = HUDSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        positions = try c.decodeIfPresent([String: HUDPoint].self, forKey: .positions) ?? defaults.positions
        transforms = try c.decodeIfPresent([String: HUDTransform].self, forKey: .transforms) ?? defaults.transforms
        visibility = try c.decodeIfPresent([String: Bool].self, forKey: .visibility) ?? defaults.visibility
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? defaults.opacity
        fontScale = try c.decodeIfPresent(Double.self, forKey: .fontScale) ?? defaults.fontScale
        verticalOffset = try c.decodeIfPresent(Double.self, forKey: .verticalOffset) ?? defaults.verticalOffset
        syncOffset = try c.decodeIfPresent(Double.self, forKey: .syncOffset) ?? defaults.syncOffset
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? defaults.displayName
        country = try c.decodeIfPresent(String.self, forKey: .country) ?? defaults.country
        identityScale = try c.decodeIfPresent(Double.self, forKey: .identityScale) ?? defaults.identityScale
        divingType = try c.decodeIfPresent(String.self, forKey: .divingType) ?? defaults.divingType
        styles = (try? c.decodeIfPresent([String: HUDItemStyle].self, forKey: .styles)) ?? [:]
    }

    static func load() -> HUDSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(HUDSettings.self, from: data) else {
            return HUDSettings()
        }
        return decoded.mergingDefaults()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    func mergingDefaults() -> HUDSettings {
        var result = self
        let defaults = HUDSettings()
        // Fields that no longer exist (the separate 深度單位 of 1.3) are dropped.
        let known = Set(HUDItemDefinition.all.map(\.id))
        result.positions = result.positions.filter { known.contains($0.key) }
        result.transforms = result.transforms.filter { known.contains($0.key) }
        result.visibility = result.visibility.filter { known.contains($0.key) }
        result.styles = result.styles.filter { known.contains($0.key) }
        for item in HUDItemDefinition.all {
            if result.positions[item.id] == nil { result.positions[item.id] = defaults.positions[item.id] }
            if result.transforms[item.id] == nil { result.transforms[item.id] = HUDTransform() }
            if result.visibility[item.id] == nil { result.visibility[item.id] = defaults.visibility[item.id] ?? true }
        }
        result.opacity = min(1, max(0.2, result.opacity))
        result.fontScale = min(1.4, max(0.7, result.fontScale))
        result.verticalOffset = min(25, max(-15, result.verticalOffset))
        result.syncOffset = min(120, max(-120, result.syncOffset))
        result.identityScale = min(1.8, max(0.6, result.identityScale))
        if !Self.diveTypes.contains(result.divingType) { result.divingType = "CWTB" }
        if HUDCountryOption.assetName(for: result.country) == nil { result.country = "chinesetaipei" }
        result.styles = result.styles.mapValues(\.sanitized).filter { !$0.value.isDefault }
        return result
    }

    static var builtIn: HUDSettings { HUDSettings() }

    /// Key of preset 1 (「將目前排版設為預設1」), which 「恢復預設位置」 restores. It is the
    /// key the single 「將目前排版設為預設」 of version 1.2 used, so that layout becomes preset 1.
    static let customDefaultLayoutKey = "depthstudio.native.hud-default-layout.v1"
    static let presetKeys = [1: customDefaultLayoutKey, 2: "depthstudio.native.hud-layout-preset2.v1"]

    /// The user's saved default layout (preset 1), if they have set one.
    static func customDefaultLayout(in store: UserDefaults = .standard) -> HUDLayoutPreset? {
        preset(1, in: store)
    }

    /// Saves the current layout and look as preset 1, the default that 「恢復預設位置」
    /// restores, including after the app restarts.
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
        for item in HUDItemDefinition.all { visibility[item.id] = visible }
    }

    func style(for id: String) -> HUDItemStyle { styles[id] ?? HUDItemStyle() }

    mutating func setStyle(_ style: HUDItemStyle, for id: String) {
        styles[id] = style.isDefault ? nil : style.sanitized
    }

    /// The colour a field's 「原色」 refers to.
    static func originalColor(for id: String) -> HUDColor {
        switch id {
        case "hudBrand", "elapsedLabel", "tempLabel", "speedLabel", "profileTitle", "footerBrand", "maxDepth": return .muted
        default: return .white
        }
    }
}
