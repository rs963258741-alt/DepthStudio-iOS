import Foundation

// MARK: - Smart Sync core
//
// One calculation for all three sync modes (智慧同步、進階同步、手動同步):
//
//     data time (watch log) = video time − delay
//
// `delay` > 0 shows the dive data later, < 0 earlier. The stage, the floating preview,
// the docked preview and the export all use `DiveSyncState.timelineSync`, so the preview
// and the exported video always show the same moment of the log, and the offset is applied
// exactly once. The dive log itself is never changed (no stretching or resampling).

/// 同步模式.
enum DiveSyncMode: String, CaseIterable, Identifiable, Codable {
    case smart, advanced, manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smart: return "智慧同步"
        case .advanced: return "進階同步"
        case .manual: return "手動同步"
        }
    }

    var englishTitle: String {
        switch self {
        case .smart: return "Smart Sync"
        case .advanced: return "Advanced Sync"
        case .manual: return "Manual Sync"
        }
    }

    /// 適用對象說明, shown at the bottom of the mode's settings.
    var audience: String {
        switch self {
        case .smart:
            return "適合一般使用者，擁有完整下潛至上升過程的影片，只需設定抵達最大深度的時間，即可快速完成影片與潛水數據同步。"
        case .advanced:
            return "適合擁有完整下潛至上升影片，並希望更精確呈現潛水數據的使用者，可透過多個時間點驗證同步結果。"
        case .manual:
            return "適合不完整的潛水影片，例如下潛途中開始錄影、出水前停止錄影，或需要手動微調影片與潛水數據的使用者。"
        }
    }
}

/// Which moment of the log stands for "reached the maximum depth". The video time must
/// mark the same event.
enum MaximumDepthEvent: String, CaseIterable, Identifiable, Codable {
    /// 首次抵達最大深度 (default).
    case firstArrival
    /// 開始上升: the last sample of the stay at the maximum depth.
    case ascentStart

    var id: String { rawValue }

    var title: String {
        switch self {
        case .firstArrival: return "首次抵達最大深度"
        case .ascentStart: return "開始上升（最大深度停留結束）"
        }
    }
}

/// Moments of a dive log, read from the samples as recorded. Nothing is invented: the
/// descent start and the return to the surface are only known when the log really
/// recorded the surface before and after the dive.
struct DiveLogLandmarks: Equatable {
    /// Samples within this of the maximum count as "at the maximum depth" (sensor noise).
    static let depthTolerance = 0.05
    /// A sample at or above this depth counts as at the surface.
    static let surfaceDepth = 0.5

    let maximumDepth: Double
    /// First sample at the maximum depth.
    let firstMaximumTime: Double
    /// Last sample of the first continuous stay at the maximum depth (equal to
    /// `firstMaximumTime` when the diver did not stay).
    let lastMaximumTime: Double
    /// Last surface sample before the descent; nil if the log starts below the surface.
    let descentStartTime: Double?
    /// First surface sample after the maximum; nil if the log ends below the surface.
    let surfaceTime: Double?
    let firstSampleTime: Double
    let lastSampleTime: Double

    init?(samples unsorted: [DiveSample]) {
        let samples = unsorted.filter { $0.elapsedSeconds.isFinite && $0.depthMeters.isFinite }
            .sorted { $0.elapsedSeconds < $1.elapsedSeconds }
        guard samples.count >= 2, let maximum = samples.map(\.depthMeters).max(), maximum > Self.surfaceDepth else {
            return nil
        }
        let atMaximum: (DiveSample) -> Bool = { $0.depthMeters >= maximum - Self.depthTolerance }
        guard let firstIndex = samples.firstIndex(where: atMaximum) else { return nil }
        var lastIndex = firstIndex
        while lastIndex + 1 < samples.count, atMaximum(samples[lastIndex + 1]) { lastIndex += 1 }

        maximumDepth = maximum
        firstMaximumTime = samples[firstIndex].elapsedSeconds
        lastMaximumTime = samples[lastIndex].elapsedSeconds
        firstSampleTime = samples[0].elapsedSeconds
        lastSampleTime = samples[samples.count - 1].elapsedSeconds

        if let firstDeep = samples.firstIndex(where: { $0.depthMeters > Self.surfaceDepth }), firstDeep > 0 {
            descentStartTime = samples[firstDeep - 1].elapsedSeconds
        } else {
            descentStartTime = nil
        }
        surfaceTime = samples[(lastIndex + 1)...].first { $0.depthMeters <= Self.surfaceDepth }?.elapsedSeconds
    }

    /// How long the log stays at the maximum depth.
    var holdDuration: Double { lastMaximumTime - firstMaximumTime }

    func maximumTime(for event: MaximumDepthEvent) -> Double {
        event == .firstArrival ? firstMaximumTime : lastMaximumTime
    }
}

/// Video times the user marks for syncing.
enum SyncAnchor: String, CaseIterable, Identifiable {
    case descentStart, maximum, surface, point

    var id: String { rawValue }

    var title: String {
        switch self {
        case .descentStart: return "開始下潛時間"
        case .maximum: return "抵達最大深度時間"
        case .surface: return "回到水面時間"
        case .point: return "影片時間點"
        }
    }
}

/// Result of checking one extra time point against the applied offset (進階同步).
struct SyncCheck: Equatable, Identifiable {
    enum Level: Equatable {
        /// 0–1 s
        case good
        /// more than 1 s and up to 3 s
        case adjust
        /// more than 3 s
        case recheck
        /// the user did not set the video time
        case notSet
        /// the log did not record this moment
        case noData

        var text: String {
            switch self {
            case .good: return "同步良好"
            case .adjust: return "建議微調"
            case .recheck: return "建議重新確認定位時間，或影片是否經過剪輯、變速"
            case .notSet: return "未設定（選填）"
            case .noData: return "手錶資料不足，無法驗證"
            }
        }
    }

    let anchor: SyncAnchor
    let watchTime: Double?
    let videoTime: Double?
    /// video − watch for this point.
    let difference: Double?
    /// `difference` − the applied offset (how far this point is from the sync result).
    let error: Double?
    let level: Level

    var id: SyncAnchor { anchor }

    static func level(forError error: Double) -> Level {
        let size = abs(error)
        if size <= 1.0 + 1e-9 { return .good }
        if size <= 3.0 + 1e-9 { return .adjust }
        return .recheck
    }
}

/// The sync settings of the current video and dive log, shared by the three modes.
struct DiveSyncState: Equatable {
    /// Slider range of 手動同步 (typed values may go beyond it, up to `inputLimit`).
    static let sliderRange: ClosedRange<Double> = -120...120
    static let inputLimit = 3600.0

    var mode: DiveSyncMode = .smart
    var maximumEvent: MaximumDepthEvent = .firstArrival
    private(set) var videoDescentStart: Double?
    private(set) var videoMaximum: Double?
    private(set) var videoSurface: Double?
    /// 任意時間點定位: a video time and the log time of the same event.
    private(set) var pointVideoTime: Double?
    private(set) var pointWatchTime: Double?
    /// The applied offset in seconds: data time = video time − delay.
    private(set) var delay: Double = 0

    init(mode: DiveSyncMode = .smart) {
        self.mode = mode
    }

    /// The video-to-log mapping used by the preview and the export.
    var timelineSync: TimelineSync { Self.timelineSync(delay: delay) }

    static func timelineSync(delay: Double) -> TimelineSync {
        // TimelineSync maps video time v to log time v + offset, so offset = −delay.
        (try? TimelineSync(offsetSeconds: -delay)) ?? Self.identity
    }

    private static let identity: TimelineSync = {
        guard let sync = try? TimelineSync(offsetSeconds: 0) else { preconditionFailure("zero offset is valid") }
        return sync
    }()

    func watchTime(forVideoTime time: Double) -> Double { time - delay }
    func videoTime(forWatchTime time: Double) -> Double { time + delay }

    func videoTime(of anchor: SyncAnchor) -> Double? {
        switch anchor {
        case .descentStart: return videoDescentStart
        case .maximum: return videoMaximum
        case .surface: return videoSurface
        case .point: return pointVideoTime
        }
    }

    // MARK: Offset from the maximum depth

    /// Offset that puts the log's maximum-depth event at the marked video time.
    func computedDelay(_ landmarks: DiveLogLandmarks?) -> Double? {
        guard let videoMaximum, let landmarks else { return nil }
        return Self.rounded(videoMaximum - landmarks.maximumTime(for: maximumEvent))
    }

    /// In 智慧／進階同步: the maximum-depth calculation when it differs from the applied
    /// offset (after manual changes); shown instead of silently replacing the offset.
    func pendingCalculation(_ landmarks: DiveLogLandmarks?) -> Double? {
        guard let computed = computedDelay(landmarks), abs(computed - delay) > 0.004 else { return nil }
        return computed
    }

    /// 剩餘同步誤差 between the video's maximum (orange) and the log's (blue) marker.
    func residual(_ landmarks: DiveLogLandmarks?) -> Double? {
        computedDelay(landmarks).map { Self.rounded($0 - delay) }
    }

    // MARK: Changes

    /// Checks a video time for an anchor: inside the video and in the dive's order
    /// (descent < maximum < surface). Returns a message when it is not allowed.
    func problem(setting time: Double, for anchor: SyncAnchor, videoDuration: Double?) -> String? {
        guard time.isFinite, time >= 0 else { return "時間格式不正確。" }
        if let videoDuration, videoDuration > 0, time > videoDuration + 0.05 {
            return "時間 \(Self.clock(time)) 超過影片長度 \(Self.clock(videoDuration))。"
        }
        switch anchor {
        case .descentStart:
            if let videoMaximum, time >= videoMaximum { return "開始下潛時間必須早於抵達最大深度時間（\(Self.clock(videoMaximum))）。" }
            if let videoSurface, time >= videoSurface { return "開始下潛時間必須早於回到水面時間。" }
        case .maximum:
            if let videoDescentStart, time <= videoDescentStart { return "抵達最大深度時間必須晚於開始下潛時間（\(Self.clock(videoDescentStart))）。" }
            if let videoSurface, time >= videoSurface { return "抵達最大深度時間必須早於回到水面時間（\(Self.clock(videoSurface))）。" }
        case .surface:
            if let videoMaximum, time <= videoMaximum { return "回到水面時間必須晚於抵達最大深度時間（\(Self.clock(videoMaximum))）。" }
            if let videoDescentStart, time <= videoDescentStart { return "回到水面時間必須晚於開始下潛時間。" }
        case .point:
            break
        }
        return nil
    }

    /// Sets (or clears) an anchor. Setting the maximum-depth time in 智慧／進階同步 applies
    /// the calculated offset; in 手動同步 it only places the orange marker.
    mutating func set(_ anchor: SyncAnchor, to time: Double?, landmarks: DiveLogLandmarks?) {
        let value = time.map { Self.rounded(max(0, $0)) }
        switch anchor {
        case .descentStart: videoDescentStart = value
        case .maximum:
            videoMaximum = value
            if mode != .manual {
                // Without the maximum-depth time there is nothing to sync on: no offset.
                if let computed = computedDelay(landmarks) { delay = computed } else if value == nil { delay = 0 }
            }
        case .surface: videoSurface = value
        case .point: pointVideoTime = value
        }
    }

    mutating func setPointWatchTime(_ time: Double?) {
        pointWatchTime = time.map { Self.rounded(max(0, $0)) }
    }

    mutating func setMaximumEvent(_ event: MaximumDepthEvent, landmarks: DiveLogLandmarks?) {
        maximumEvent = event
        if mode != .manual, let computed = computedDelay(landmarks) { delay = computed }
    }

    /// Switching modes keeps every time and the applied offset.
    mutating func select(_ mode: DiveSyncMode) { self.mode = mode }

    mutating func setDelay(_ value: Double) {
        guard value.isFinite else { return }
        delay = Self.rounded(min(Self.inputLimit, max(-Self.inputLimit, value)))
    }

    mutating func nudge(by step: Double) { setDelay(delay + step) }

    /// Applies the maximum-depth calculation (自動對齊最大深度點, 套用計算結果).
    @discardableResult
    mutating func applyCalculation(_ landmarks: DiveLogLandmarks?) -> Bool {
        guard let computed = computedDelay(landmarks) else { return false }
        delay = computed
        return true
    }

    /// 任意時間點定位: offset from a video time and the log time of the same event.
    @discardableResult
    mutating func applyPoint() -> Bool {
        guard let pointVideoTime, let pointWatchTime else { return false }
        setDelay(pointVideoTime - pointWatchTime)
        return true
    }

    /// 重設同步: clears the times and the offset; keeps the mode.
    mutating func reset() { self = DiveSyncState(mode: mode) }

    // MARK: Checks (進階同步)

    /// The maximum (the reference) and the optional descent and surface checks.
    func checks(_ landmarks: DiveLogLandmarks?) -> [SyncCheck] {
        func check(_ anchor: SyncAnchor, watch: Double?, video: Double?) -> SyncCheck {
            guard let video else {
                return SyncCheck(anchor: anchor, watchTime: watch, videoTime: nil, difference: nil, error: nil, level: .notSet)
            }
            guard let watch else {
                return SyncCheck(anchor: anchor, watchTime: nil, videoTime: video, difference: nil, error: nil, level: .noData)
            }
            let difference = Self.rounded(video - watch)
            let error = Self.rounded(difference - delay)
            return SyncCheck(anchor: anchor, watchTime: watch, videoTime: video, difference: difference, error: error,
                             level: SyncCheck.level(forError: error))
        }
        return [
            check(.descentStart, watch: landmarks?.descentStartTime, video: videoDescentStart),
            check(.maximum, watch: landmarks.map { $0.maximumTime(for: maximumEvent) }, video: videoMaximum),
            check(.surface, watch: landmarks?.surfaceTime, video: videoSurface)
        ]
    }

    // MARK: Formatting

    static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    /// mm:ss.s (negative times get a leading −).
    static func clock(_ seconds: Double) -> String {
        let sign = seconds < -0.049 ? "−" : ""
        return sign + PoolFormat.preciseClock(abs(seconds))
    }

    /// "+7.3 秒" / "−2.0 秒".
    static func signedSeconds(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if abs(rounded) < 0.05 { return "0.0 秒" }
        return (rounded > 0 ? "+" : "−") + String(format: "%.1f 秒", abs(rounded))
    }

    /// Plain-language meaning of the offset.
    static func describe(_ delay: Double) -> String {
        let rounded = (delay * 10).rounded() / 10
        if abs(rounded) < 0.05 { return "數據與影片同時開始（未偏移）" }
        return rounded > 0
            ? String(format: "數據延後 %.1f 秒顯示", rounded)
            : String(format: "數據提前 %.1f 秒顯示", -rounded)
    }

    /// Parses a typed offset: "+7.3", "-12", "7.3秒", "－2".
    static func parseDelay(_ text: String) -> Double? {
        var cleaned = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        for remove in ["秒", "s", "S", " "] { cleaned = cleaned.replacingOccurrences(of: remove, with: "") }
        cleaned = cleaned.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: ",", with: ".")
        guard let value = Double(cleaned), value.isFinite, abs(value) <= inputLimit else { return nil }
        return value
    }
}
