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

/// Relative swimming motion measured from the video by PoolMotionAnalyzer (AI).
/// Only its shape matters: each segment is rescaled so its distance matches the marks.
struct PoolMotionSignal: Equatable {
    /// Ascending video times in seconds.
    let times: [Double]
    /// Motion magnitude at each time (arbitrary units, >= 0), already smoothed.
    let values: [Double]
    /// Share of analysed frames (0...1) in which a swimmer was found.
    let detectionRate: Double

    /// Linear interpolation; nil outside the analysed range.
    func value(at time: Double) -> Double? {
        guard times.count == values.count, let first = times.first, let last = times.last,
              time >= first - 0.25, time <= last + 0.25 else { return nil }
        if time <= first { return values.first }
        if time >= last { return values.last }
        var low = 0
        var high = times.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if times[mid] <= time { low = mid } else { high = mid }
        }
        let span = times[high] - times[low]
        guard span > 0 else { return values[low] }
        let fraction = (time - times[low]) / span
        return values[low] + (values[high] - values[low]) * fraction
    }
}

/// Where a segment's speed variation comes from.
enum PoolSpeedSource: Equatable {
    /// Shaped by the AI motion analysis of the video.
    case ai
    /// No usable AI data: a smooth fluctuation of up to about ±0.22 m/s around the segment average.
    case simulated
}

/// Distance and speed over time, computed from the timed points.
///
/// Between two marked points the total distance is fixed by the marks; within that
/// segment the speed follows a 0.1 s profile (AI-shaped or simulated) whose average is
/// the segment's average speed, so the distance at every marked point is exact.
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

    /// One 0.1 s step of the speed profile; the speed is constant within the step.
    struct ProfileStep: Equatable {
        let startTime: Double
        let endTime: Double
        let startDistance: Double
        let speed: Double
    }

    static let stepDuration = 0.1

    let points: [Point]
    let poolLength: Double
    let finalDistance: Double
    let steps: [ProfileStep]
    let segmentSources: [PoolSpeedSource]

    init(session: PoolSession, motion: PoolMotionSignal? = nil) throws {
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
        var steps: [ProfileStep] = []
        var sources: [PoolSpeedSource] = []
        for (index, pair) in zip(points, points.dropFirst()).enumerated() {
            let segment = Segment(startTime: pair.0.time, endTime: pair.1.time,
                                  startDistance: pair.0.distance, endDistance: pair.1.distance)
            let profile = Self.profile(for: segment, index: index, motion: motion)
            steps.append(contentsOf: profile.steps)
            sources.append(profile.source)
        }
        self.points = points
        self.poolLength = session.poolLength
        self.finalDistance = session.finalDistance
        self.steps = steps
        self.segmentSources = sources
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

    var maximumSpeed: Double { steps.map(\.speed).max() ?? 0 }
    var aiSegmentCount: Int { segmentSources.filter { $0 == .ai }.count }

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
        let current = self.step(at: t)
        let distance = current.startDistance + current.speed * (t - current.startTime)
        return PoolReading(videoTime: t, phase: .swimming, distance: distance, elapsedSeconds: t - startTime,
                           speed: current.speed, lap: lap(forDistance: distance), totalLaps: totalLaps)
    }

    func distance(atVideoTime time: Double) -> Double { reading(atVideoTime: time).distance }

    func lap(forDistance distance: Double) -> Int {
        if distance >= finalDistance { return totalLaps }
        return min(totalLaps, max(1, Int((distance / poolLength + 1e-9).rounded(.down)) + 1))
    }

    /// Profile points for drawing: (time, distance) at every step boundary.
    var distanceSeries: [Point] {
        var series = steps.map { Point(time: $0.startTime, distance: $0.startDistance) }
        series.append(Point(time: finishTime, distance: finalDistance))
        return series
    }

    /// Profile points for drawing: (time, speed) at the middle of every step.
    var speedSeries: [(time: Double, speed: Double)] {
        steps.map { (time: ($0.startTime + $0.endTime) / 2, speed: $0.speed) }
    }

    /// The profile step containing `time`, for startTime <= time < finishTime.
    private func step(at time: Double) -> ProfileStep {
        var low = 0
        var high = steps.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if steps[mid].startTime <= time { low = mid } else { high = mid - 1 }
        }
        return steps[low]
    }

    // MARK: Profile construction

    private static func profile(for segment: Segment, index: Int,
                                motion: PoolMotionSignal?) -> (steps: [ProfileStep], source: PoolSpeedSource) {
        let count = max(1, Int((segment.duration / stepDuration - 1e-9).rounded(.up)))
        let dt = segment.duration / Double(count)
        let mids = (0..<count).map { segment.startTime + (Double($0) + 0.5) * dt }
        let average = segment.speed

        var source = PoolSpeedSource.simulated
        var weights: [Double]
        if let ai = aiWeights(times: mids, motion: motion) {
            source = .ai
            // A nearly flat AI result still gets a little natural variation.
            if standardDeviation(ai) < 0.03 {
                let wiggle = simulatedWeights(times: mids, average: average, index: index)
                weights = zip(ai, wiggle).map { $0 * $1 }
            } else {
                weights = ai
            }
        } else {
            weights = simulatedWeights(times: mids, average: average, index: index)
        }
        var mean = weights.reduce(0, +) / Double(weights.count)
        if !(mean > 0) || !mean.isFinite {
            weights = Array(repeating: 1, count: count)
            mean = 1
        }

        var steps: [ProfileStep] = []
        steps.reserveCapacity(count)
        var distance = segment.startDistance
        for k in 0..<count {
            let speed = average * weights[k] / mean
            let start = segment.startTime + Double(k) * dt
            let end = k == count - 1 ? segment.endTime : start + dt
            steps.append(ProfileStep(startTime: start, endTime: end, startDistance: distance, speed: speed))
            distance += speed * dt
        }
        return (steps, source)
    }

    /// Relative speed shape from the AI motion signal, or nil when it does not cover the segment.
    private static func aiWeights(times: [Double], motion: PoolMotionSignal?) -> [Double]? {
        guard let motion, !times.isEmpty else { return nil }
        var values: [Double] = []
        values.reserveCapacity(times.count)
        for time in times {
            guard let value = motion.value(at: time), value.isFinite, value >= 0 else { return nil }
            values.append(value)
        }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean > 1e-6 else { return nil }
        // Keep the AI shape within a plausible range around the segment average.
        return values.map { min(1.6, max(0.5, $0 / mean)) }
    }

    /// Smooth fluctuation (kick rhythm about 1.4 s plus a slower 3.3 s swell) of up to
    /// ±0.22 m/s around the average, deterministic so the preview and the export match.
    private static func simulatedWeights(times: [Double], average: Double, index: Int) -> [Double] {
        let safeAverage = max(average, 0.01)
        let amplitude = min(0.22, max(0.05, average * 0.12), safeAverage * 0.5)
        let phase1 = Double(index) * 1.7 + 0.4
        let phase2 = Double(index) * 0.9 + 1.3
        return times.map { t in
            let wave = 0.6 * sin(2 * Double.pi * t / 1.4 + phase1) + 0.4 * sin(2 * Double.pi * t / 3.3 + phase2)
            return max(0.05, 1 + amplitude * wave / safeAverage)
        }
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
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
