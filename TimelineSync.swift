import Foundation

struct SyncAnchor: Codable, Equatable {
    let videoSeconds: Double
    let watchSeconds: Double
}

enum SyncError: Error, Equatable {
    case invalidAnchor
    case unreasonableDrift(Double)
}

struct TimelineSync: Codable, Equatable {
    let first: SyncAnchor
    let second: SyncAnchor?

    init(offsetSeconds: Double) throws {
        guard offsetSeconds.isFinite else { throw SyncError.invalidAnchor }
        self.first = SyncAnchor(videoSeconds: 0, watchSeconds: offsetSeconds)
        self.second = nil
    }

    init(first: SyncAnchor, second: SyncAnchor?) throws {
        guard first.videoSeconds.isFinite, first.watchSeconds.isFinite else {
            throw SyncError.invalidAnchor
        }
        if let b = second {
            guard b.videoSeconds.isFinite, b.watchSeconds.isFinite,
                  b.videoSeconds > first.videoSeconds,
                  b.watchSeconds > first.watchSeconds else { throw SyncError.invalidAnchor }
            let rate = (b.watchSeconds - first.watchSeconds) / (b.videoSeconds - first.videoSeconds)
            guard (0.90...1.10).contains(rate) else { throw SyncError.unreasonableDrift(rate) }
        }
        self.first = first
        self.second = second
    }

    /// Returns watch-log elapsed seconds for a video playback position.
    func watchTime(forVideoTime videoSeconds: Double) -> Double {
        guard let b = second else {
            return videoSeconds + first.watchSeconds - first.videoSeconds
        }
        let rate = (b.watchSeconds - first.watchSeconds) / (b.videoSeconds - first.videoSeconds)
        return first.watchSeconds + (videoSeconds - first.videoSeconds) * rate
    }
}
