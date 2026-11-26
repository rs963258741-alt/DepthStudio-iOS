import Foundation

/// What a timeline point marks in a pool dynamic-apnea swim.
enum PoolNodeKind: String, Codable {
    case start       // 出發, always 0 m
    case turn        // 轉身, at each multiple of the pool length
    case checkpoint  // 校正點 the user added at any distance
    case finish      // 結束出水, at the final distance
}

/// One known (distance, video time) pair. Turns are generated from the pool length;
/// the time is nil until the user marks it against the video.
struct PoolNode: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var distance: Double
    var videoTime: Double?
    var kind: PoolNodeKind

    var title: String {
        switch kind {
        case .start: return "出發"
        case .turn: return "轉身"
        case .checkpoint: return "校正點"
        case .finish: return "結束出水"
        }
    }
}

/// The swim being edited: pool length, final distance and the timeline points.
/// Distances are in metres and times are seconds on the imported video's own clock
/// (pool mode has no watch, so there is no time offset to sync).
struct PoolSession: Codable, Equatable {
    static let poolLengths: [Double] = [25, 50]
    static let finalDistanceRange: ClosedRange<Double> = 1...1000

    private(set) var poolLength: Double
    private(set) var finalDistance: Double
    /// Always sorted by distance; first is the start (0 m) and last is the finish.
    private(set) var nodes: [PoolNode]

    init(poolLength: Double = 50, finalDistance: Double = 150) {
        self.poolLength = Self.poolLengths.contains(poolLength) ? poolLength : 50
        self.finalDistance = min(Self.finalDistanceRange.upperBound, max(Self.finalDistanceRange.lowerBound, finalDistance))
        self.nodes = []
        rebuildNodes()
    }

    /// The example from the design discussion: 50 m pool, 0 m at 00:02, turns at 00:50 and
    /// 01:40, surfacing at 150 m at 02:30 (150 m in 2:28, about 1.014 m/s).
    static var demo: PoolSession {
        var session = PoolSession(poolLength: 50, finalDistance: 150)
        let times: [Double: Double] = [0: 2, 50: 50, 100: 100, 150: 150]
        for node in session.nodes {
            if let time = times[node.distance] { session.setTime(time, for: node.id) }
        }
        return session
    }

    var hasAnyTime: Bool { nodes.contains { $0.videoTime != nil } }

    mutating func setPoolLength(_ length: Double) {
        guard Self.poolLengths.contains(length), length != poolLength else { return }
        poolLength = length
        rebuildNodes()
    }

    mutating func setFinalDistance(_ distance: Double) {
        guard distance.isFinite else { return }
        let clamped = min(Self.finalDistanceRange.upperBound, max(Self.finalDistanceRange.lowerBound, (distance * 10).rounded() / 10))
        guard clamped != finalDistance else { return }
        finalDistance = clamped
        rebuildNodes()
    }

    mutating func setTime(_ time: Double?, for id: UUID) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        if let time, time.isFinite {
            nodes[index].videoTime = max(0, (time * 100).rounded() / 100)
        } else {
            nodes[index].videoTime = nil
        }
    }

    mutating func clearAllTimes() {
        for index in nodes.indices { nodes[index].videoTime = nil }
    }

    /// Adds a checkpoint strictly between the start and the finish. Returns false if the
    /// distance is out of range or already has a point.
    @discardableResult
    mutating func addCheckpoint(distance: Double, videoTime: Double? = nil) -> Bool {
        let rounded = (distance * 10).rounded() / 10
        guard rounded > 0, rounded < finalDistance,
              !nodes.contains(where: { abs($0.distance - rounded) < 0.05 }) else { return false }
        nodes.append(PoolNode(distance: rounded, videoTime: videoTime, kind: .checkpoint))
        nodes.sort { $0.distance < $1.distance }
        return true
    }

    /// Only checkpoints can be removed; start, turns and finish follow the pool settings.
    mutating func removeNode(id: UUID) {
        nodes.removeAll { $0.id == id && $0.kind == .checkpoint }
    }

    /// Regenerates start, turns and finish for the current pool length and final distance,
    /// keeping times already marked at the same distance and keeping checkpoints that still fit.
    private mutating func rebuildNodes() {
        let previous = nodes
        func existing(at distance: Double) -> PoolNode? {
            previous.first { abs($0.distance - distance) < 0.05 && $0.kind != .checkpoint }
        }
        var rebuilt: [PoolNode] = []
        rebuilt.append(PoolNode(id: existing(at: 0)?.id ?? UUID(), distance: 0,
                                videoTime: existing(at: 0)?.videoTime, kind: .start))
        var turn = poolLength
        while turn < finalDistance - 0.05 {
            let old = existing(at: turn)
            rebuilt.append(PoolNode(id: old?.id ?? UUID(), distance: turn, videoTime: old?.videoTime, kind: .turn))
            turn += poolLength
        }
        // The finish keeps its time when only the final distance changes.
        let oldFinish = previous.first { $0.kind == .finish }
        rebuilt.append(PoolNode(id: oldFinish?.id ?? UUID(), distance: finalDistance,
                                videoTime: oldFinish?.videoTime, kind: .finish))
        for checkpoint in previous where checkpoint.kind == .checkpoint {
            if checkpoint.distance > 0, checkpoint.distance < finalDistance,
               !rebuilt.contains(where: { abs($0.distance - checkpoint.distance) < 0.05 }) {
                rebuilt.append(checkpoint)
            }
        }
        nodes = rebuilt.sorted { $0.distance < $1.distance }
    }
}

enum PoolTimelineError: LocalizedError, Equatable {
    case missingStart
    case missingFinish
    case timeNotIncreasing(distance: Double)

    var errorDescription: String? {
        switch self {
        case .missingStart: return "請先標記「0 m 出發」的影片時間。"
        case .missingFinish: return "請標記「結束出水」的影片時間。"
        case .timeNotIncreasing(let distance):
            return String(format: "%.1f m 的時間必須晚於前一個節點。", distance)
        }
    }
}

/// The HUD values at one moment of the video.
struct PoolReading: Equatable {
    enum Phase: Equatable { case beforeStart, swimming, finished }

    let videoTime: Double
    let phase: Phase
    /// Cumulative distance in metres.
    let distance: Double
    /// Seconds since the start point (breath-hold time), frozen after the finish.
    let elapsedSeconds: Double
    /// Average speed of the current segment in m/s; 0 before the start and after the finish.
    let speed: Double
    /// 1-based lap (pool length) currently being swum.
    let lap: Int
    let totalLaps: Int
}

/// Distance and speed over time, computed from the timed points.
/// Between two known points the distance changes linearly, so the speed in that
/// segment is its average speed (分段平均速率). AI tracking of speed changes within a
/// segment is a later stage.
struct PoolTimeline: Equatable {
    struct Point: Equatable {
        let time: Double
        let distance: Double
    }

    struct Segment: Equatable {
        let startTime: Double
        let endTime: Double
        let startDistance: Double
        let endDistance: Double
        var duration: Double { endTime - startTime }
        var distance: Double { endDistance - startDistance }
        var speed: Double { distance / duration }
    }

    let points: [Point]
    let poolLength: Double
    let finalDistance: Double

    init(session: PoolSession) throws {
        let timed = session.nodes.filter { $0.videoTime != nil }.sorted { $0.distance < $1.distance }
        guard let first = timed.first, first.kind == .start, let startTime = first.videoTime else {
            throw PoolTimelineError.missingStart
        }
        guard let last = timed.last, last.kind == .finish, last.videoTime != nil else {
            throw PoolTimelineError.missingFinish
        }
        var points: [Point] = [Point(time: startTime, distance: first.distance)]
        for node in timed.dropFirst() {
            guard let time = node.videoTime, time > points[points.count - 1].time else {
                throw PoolTimelineError.timeNotIncreasing(distance: node.distance)
            }
            points.append(Point(time: time, distance: node.distance))
        }
        self.points = points
        self.poolLength = session.poolLength
        self.finalDistance = session.finalDistance
    }

    var startTime: Double { points[0].time }
    var finishTime: Double { points[points.count - 1].time }
    var totalTime: Double { finishTime - startTime }
    var averageSpeed: Double { totalTime > 0 ? finalDistance / totalTime : 0 }
    var totalLaps: Int { max(1, Int((finalDistance / poolLength - 1e-9).rounded(.up))) }

    var segments: [Segment] {
        zip(points, points.dropFirst()).map {
            Segment(startTime: $0.time, endTime: $1.time, startDistance: $0.distance, endDistance: $1.distance)
        }
    }

    var maximumSegmentSpeed: Double { segments.map(\.speed).max() ?? 0 }

    func reading(atVideoTime time: Double) -> PoolReading {
        let t = time.isFinite ? time : 0
        if t < startTime {
            return PoolReading(videoTime: t, phase: .beforeStart, distance: 0, elapsedSeconds: 0,
                               speed: 0, lap: 1, totalLaps: totalLaps)
        }
        if t >= finishTime {
            return PoolReading(videoTime: t, phase: .finished, distance: finalDistance, elapsedSeconds: totalTime,
                               speed: 0, lap: totalLaps, totalLaps: totalLaps)
        }
        let current = self.segment(at: t)
        let fraction = (t - current.startTime) / current.duration
        let distance = current.startDistance + current.distance * fraction
        return PoolReading(videoTime: t, phase: .swimming, distance: distance, elapsedSeconds: t - startTime,
                           speed: current.speed, lap: lap(forDistance: distance), totalLaps: totalLaps)
    }

    func distance(atVideoTime time: Double) -> Double { reading(atVideoTime: time).distance }

    func lap(forDistance distance: Double) -> Int {
        if distance >= finalDistance { return totalLaps }
        return min(totalLaps, max(1, Int((distance / poolLength + 1e-9).rounded(.down)) + 1))
    }

    /// The segment containing `time`, for startTime <= time < finishTime.
    private func segment(at time: Double) -> Segment {
        var low = 0
        var high = points.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if points[mid].time <= time { low = mid } else { high = mid }
        }
        let a = points[low], b = points[low + 1]
        return Segment(startTime: a.time, endTime: b.time, startDistance: a.distance, endDistance: b.distance)
    }
}

enum PoolFormat {
    static func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    /// mm:ss.s, used for marking points precisely.
    static func preciseClock(_ seconds: Double) -> String {
        let tenths = max(0, Int((seconds * 10).rounded()))
        return String(format: "%02d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }

    static func distance(_ metres: Double) -> String { String(format: "%.1f", metres) }
    static func speed(_ metresPerSecond: Double) -> String { String(format: "%.2f", metresPerSecond) }
    static func lap(_ reading: PoolReading) -> String { String(format: "%02d / %02d", reading.lap, reading.totalLaps) }

    /// Parses "150", "2:30", "02:30.5" or "1:02:30" into seconds.
    static func parseTime(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "：", with: ":")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map { String($0) }
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total.isFinite ? total : nil
    }
}
