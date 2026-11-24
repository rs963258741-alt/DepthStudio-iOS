import Foundation

struct DiveReading: Equatable {
    let elapsedSeconds: Double
    let depthMeters: Double
    let temperatureCelsius: Double?
    /// Positive means descending (depth increasing); negative means ascending.
    let verticalSpeedMetersPerSecond: Double?
}

enum DiveInterpolationError: Error { case emptySamples, invalidSamples }

struct DiveDataInterpolator {
    let samples: [DiveSample]

    init(samples: [DiveSample]) throws {
        guard !samples.isEmpty else { throw DiveInterpolationError.emptySamples }
        let sorted = samples.sorted { $0.elapsedSeconds < $1.elapsedSeconds }
        guard sorted.allSatisfy({ $0.elapsedSeconds.isFinite && $0.depthMeters.isFinite && $0.depthMeters >= 0 }),
              zip(sorted, sorted.dropFirst()).allSatisfy({ $0.elapsedSeconds < $1.elapsedSeconds }) else {
            throw DiveInterpolationError.invalidSamples
        }
        self.samples = sorted
    }

    /// Linear interpolation between recorded samples. Returns nil outside the recorded interval.
    func reading(at seconds: Double) -> DiveReading? {
        guard seconds.isFinite,
              let first = samples.first, let last = samples.last,
              seconds >= first.elapsedSeconds, seconds <= last.elapsedSeconds else { return nil }

        if seconds == last.elapsedSeconds {
            return DiveReading(elapsedSeconds: seconds, depthMeters: last.depthMeters,
                               temperatureCelsius: last.temperatureCelsius,
                               verticalSpeedMetersPerSecond: speed(for: samples.count - 2))
        }

        var low = 0
        var high = samples.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if samples[mid].elapsedSeconds <= seconds { low = mid } else { high = mid }
        }
        let a = samples[low]
        let b = samples[min(low + 1, samples.count - 1)]
        let fraction = (seconds - a.elapsedSeconds) / (b.elapsedSeconds - a.elapsedSeconds)
        let depth = a.depthMeters + (b.depthMeters - a.depthMeters) * fraction
        let temp: Double?
        if let ta = a.temperatureCelsius, let tb = b.temperatureCelsius {
            temp = ta + (tb - ta) * fraction
        } else { temp = a.temperatureCelsius ?? b.temperatureCelsius }
        let verticalSpeed = (b.depthMeters - a.depthMeters) / (b.elapsedSeconds - a.elapsedSeconds)
        return DiveReading(elapsedSeconds: seconds, depthMeters: depth,
                           temperatureCelsius: temp,
                           verticalSpeedMetersPerSecond: verticalSpeed)
    }

    private func speed(for index: Int) -> Double? {
        guard samples.count >= 2, index >= 0, index + 1 < samples.count else { return nil }
        let a = samples[index], b = samples[index + 1]
        return (b.depthMeters - a.depthMeters) / (b.elapsedSeconds - a.elapsedSeconds)
    }
}
