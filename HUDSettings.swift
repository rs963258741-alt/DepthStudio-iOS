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
        .init(id: "depthValue", title: "即時深度數值"),
        .init(id: "depthUnit", title: "深度單位"),
        .init(id: "elapsedValue", title: "潛水時間數值"),
        .init(id: "elapsedLabel", title: "潛水時間標籤"),
        .init(id: "tempValue", title: "水溫數值"),
        .init(id: "tempLabel", title: "水溫標籤"),
        .init(id: "speedValue", title: "深度變化速度數值"),
        .init(id: "speedLabel", title: "深度變化速度標籤"),
        .init(id: "profileTitle", title: "深度曲線標題"),
        .init(id: "profileBlock", title: "深度曲線圖"),
        .init(id: "footerBrand", title: "裝置名稱"),
        .init(id: "maxDepth", title: "最大深度")
    ]
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

struct HUDSettings: Codable, Equatable {
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

    init() {
        positions = [
            "hudBrand": HUDPoint(x: 16, y: 3),
            "hudClock": HUDPoint(x: 88, y: 3),
            "identityGroup": HUDPoint(x: 25, y: 76),
            "depthValue": HUDPoint(x: 17, y: 18),
            "depthUnit": HUDPoint(x: 34, y: 24),
            "elapsedValue": HUDPoint(x: 55, y: 21),
            "elapsedLabel": HUDPoint(x: 55, y: 15),
            "tempValue": HUDPoint(x: 82, y: 21),
            "tempLabel": HUDPoint(x: 82, y: 15),
            "speedValue": HUDPoint(x: 82, y: 71),
            "speedLabel": HUDPoint(x: 82, y: 78),
            "profileTitle": HUDPoint(x: 30, y: 82),
            "profileBlock": HUDPoint(x: 50, y: 89),
            "footerBrand": HUDPoint(x: 17, y: 96),
            "maxDepth": HUDPoint(x: 83, y: 96)
        ]
        transforms = Dictionary(uniqueKeysWithValues: HUDItemDefinition.all.map { ($0.id, HUDTransform()) })
        visibility = [
            "hudBrand": false, "hudClock": false, "identityGroup": true,
            "depthValue": true, "depthUnit": true, "elapsedValue": true,
            "elapsedLabel": true, "tempValue": true, "tempLabel": true,
            "speedValue": true, "speedLabel": true, "profileTitle": false,
            "profileBlock": true, "footerBrand": false, "maxDepth": false
        ]
        opacity = 0.90
        fontScale = 0.90
        verticalOffset = 0
        syncOffset = 0
        displayName = "name"
        country = "chinesetaipei"
        identityScale = 0.80
        divingType = "CWTB"
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
        return result
    }

    mutating func resetLayout() {
        let defaults = HUDSettings()
        positions = defaults.positions
        transforms = defaults.transforms
    }

    mutating func setAllVisible(_ visible: Bool) {
        for item in HUDItemDefinition.all { visibility[item.id] = visible }
    }
}
