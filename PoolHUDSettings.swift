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

struct PoolHUDSettings: Codable, Equatable {
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
        return result
    }

    mutating func resetLayout() {
        let defaults = PoolHUDSettings()
        positions = defaults.positions
        transforms = defaults.transforms
    }

    mutating func setAllVisible(_ visible: Bool) {
        for item in PoolHUDItemDefinition.all { visibility[item.id] = visible }
    }
}
