import Foundation
import AVFoundation
import Vision
import CoreGraphics

/// On-device AI estimate of how the swimmer's speed varies (泳池平潛 V1.1).
///
/// Frames are sampled between the start and finish marks. For each pair of frames Apple's
/// Vision framework computes optical flow; the swimmer is located with human (or, failing
/// that, saliency) detection. The swimmer's motion relative to the pool background works
/// both for a fixed camera (background still, swimmer moves) and a following camera
/// (swimmer still in frame, background moves). Only the shape of the signal is used: each
/// segment is rescaled so its distance matches the marked points.
struct PoolMotionAnalyzer {
    let url: URL
    let startTime: Double
    let endTime: Double
    /// Frames analysed per second of video.
    var sampleRate: Double = 5

    enum AnalysisError: LocalizedError {
        case invalidRange
        case noFrames
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidRange: return "請先標記出發與結束出水時間，再進行 AI 分析。"
            case .noFrames: return "無法從影片讀取分析用的影格。"
            case .cancelled: return "AI 分析已取消。"
            }
        }
    }

    /// Runs the analysis off the main thread. `progress` receives 0...1.
    func analyze(progress: @escaping @Sendable (Double) -> Void) async throws -> PoolMotionSignal {
        guard endTime > startTime, startTime >= 0 else { throw AnalysisError.invalidRange }
        let count = max(2, Int(((endTime - startTime) * sampleRate).rounded(.up)) + 1)
        let step = (endTime - startTime) / Double(count - 1)
        let times = (0..<count).map { startTime + Double($0) * step }

        let accumulator = MotionAccumulator(expected: count, progress: progress)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        let tolerance = CMTime(seconds: step / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let requested = times.map { NSValue(time: CMTime(seconds: $0, preferredTimescale: 600)) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                accumulator.setOnFinish { continuation.resume() }
                generator.generateCGImagesAsynchronously(forTimes: requested) { requestedTime, image, actualTime, result, _ in
                    accumulator.add(image: result == .succeeded ? image : nil,
                                    time: actualTime.isValid ? actualTime.seconds : requestedTime.seconds)
                }
            }
        } onCancel: {
            generator.cancelAllCGImageGeneration()
            accumulator.cancel()
        }
        if Task.isCancelled { throw AnalysisError.cancelled }
        guard let signal = accumulator.signal() else { throw AnalysisError.noFrames }
        return signal
    }
}

/// Collects per-frame motion as images arrive from the generator (called serially).
private final class MotionAccumulator: @unchecked Sendable {
    private let expected: Int
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var received = 0
    private var finished = false
    private var previous: (image: CGImage, time: Double)?
    private var times: [Double] = []
    private var values: [Double] = []
    private var framesWithSwimmer = 0
    private var analysedPairs = 0
    private var onFinish: (() -> Void)?

    init(expected: Int, progress: @escaping @Sendable (Double) -> Void) {
        self.expected = expected
        self.progress = progress
    }

    /// Runs `callback` once when all frames have arrived or the analysis was cancelled,
    /// immediately if that already happened.
    func setOnFinish(_ callback: @escaping () -> Void) {
        lock.lock()
        if finished {
            lock.unlock()
            callback()
            return
        }
        onFinish = callback
        lock.unlock()
    }

    func add(image: CGImage?, time: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        received += 1
        if let image {
            if let previous, time > previous.time + 0.001 {
                if let measurement = FrameMotion.measure(from: previous.image, to: image) {
                    analysedPairs += 1
                    if measurement.foundSwimmer { framesWithSwimmer += 1 }
                    let dt = time - previous.time
                    times.append((previous.time + time) / 2)
                    values.append(measurement.relativeMotion / dt)
                }
            }
            previous = (image, time)
        }
        progress(min(1, Double(received) / Double(expected)))
        if received >= expected { finishLocked() }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        finishLocked()
    }

    private func finishLocked() {
        guard !finished else { return }
        finished = true
        let callback = onFinish
        onFinish = nil
        callback?()
    }

    /// Smoothed signal, or nil when too few frame pairs could be analysed.
    func signal() -> PoolMotionSignal? {
        lock.lock()
        defer { lock.unlock() }
        guard times.count >= 3 else { return nil }
        // Moving average over five samples (about one second) to remove frame noise.
        var smoothed: [Double] = []
        smoothed.reserveCapacity(values.count)
        for index in values.indices {
            let low = max(0, index - 2)
            let high = min(values.count - 1, index + 2)
            let window = values[low...high]
            smoothed.append(window.reduce(0, +) / Double(window.count))
        }
        let rate = analysedPairs > 0 ? Double(framesWithSwimmer) / Double(analysedPairs) : 0
        return PoolMotionSignal(times: times, values: smoothed, detectionRate: rate)
    }
}

/// Motion between two frames from Vision optical flow.
private enum FrameMotion {
    struct Measurement {
        /// Swimmer motion relative to the background, in flow pixels per frame pair.
        let relativeMotion: Double
        let foundSwimmer: Bool
    }

    static func measure(from first: CGImage, to second: CGImage) -> Measurement? {
        let flowRequest = VNGenerateOpticalFlowRequest(targetedCGImage: second, options: [:])
        flowRequest.computationAccuracy = .medium
        flowRequest.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        let humanRequest = VNDetectHumanRectanglesRequest()
        let saliencyRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: first, options: [:])
        do {
            try handler.perform([flowRequest, humanRequest, saliencyRequest])
        } catch {
            return nil
        }
        guard let flow = flowRequest.results?.first?.pixelBuffer else { return nil }

        // Swimmer box in normalised image coordinates (origin bottom-left).
        var box: CGRect?
        if let human = humanRequest.results?.max(by: { $0.boundingBox.area < $1.boundingBox.area }),
           human.confidence > 0.3 {
            box = human.boundingBox
        } else if let salient = saliencyRequest.results?.first?.salientObjects?
                    .max(by: { $0.boundingBox.area < $1.boundingBox.area }),
                  salient.boundingBox.area < 0.6 {
            box = salient.boundingBox
        }
        return motion(in: flow, swimmerBox: box)
    }

    private static func motion(in buffer: CVPixelBuffer, swimmerBox: CGRect?) -> Measurement? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_TwoComponent32Float,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 4, height > 4 else { return nil }

        var insideX = 0.0, insideY = 0.0, insideCount = 0.0
        var backgroundX: [Float] = []
        var backgroundY: [Float] = []
        backgroundX.reserveCapacity(width * height / 9)
        backgroundY.reserveCapacity(width * height / 9)

        for y in stride(from: 0, to: height, by: 3) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            // Vision boxes have their origin at the bottom-left; buffer rows start at the top.
            let normalizedY = 1 - (Double(y) + 0.5) / Double(height)
            for x in stride(from: 0, to: width, by: 3) {
                let dx = row[x * 2]
                let dy = row[x * 2 + 1]
                guard dx.isFinite, dy.isFinite else { continue }
                let normalizedX = (Double(x) + 0.5) / Double(width)
                if let box = swimmerBox, box.contains(CGPoint(x: normalizedX, y: normalizedY)) {
                    insideX += Double(dx)
                    insideY += Double(dy)
                    insideCount += 1
                } else {
                    backgroundX.append(dx)
                    backgroundY.append(dy)
                }
            }
        }
        guard backgroundX.count > 20 else { return nil }
        let backgroundDX = Double(median(&backgroundX))
        let backgroundDY = Double(median(&backgroundY))

        if insideCount > 10 {
            let swimmerDX = insideX / insideCount - backgroundDX
            let swimmerDY = insideY / insideCount - backgroundDY
            return Measurement(relativeMotion: (swimmerDX * swimmerDX + swimmerDY * swimmerDY).squareRoot(),
                               foundSwimmer: true)
        }
        // No swimmer found: with a camera following the swimmer, the background motion is
        // the best available measure of speed.
        return Measurement(relativeMotion: (backgroundDX * backgroundDX + backgroundDY * backgroundDY).squareRoot(),
                           foundSwimmer: false)
    }

    private static func median(_ values: inout [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let middle = values.count / 2
        values.sort()
        return values[middle]
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
