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
        case noFrames(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .invalidRange: return "請先標記出發與結束出水時間，再進行 AI 分析。"
            case .noFrames(let reason): return "無法分析影片影格（\(reason)）。"
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
        guard let signal = accumulator.signal() else { throw AnalysisError.noFrames(accumulator.failureReason) }
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
    private var imagesReceived = 0
    private var firstFailure: String?
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
            imagesReceived += 1
            if let previous, time > previous.time + 0.001 {
                switch FrameMotion.measure(from: previous.image, to: image) {
                case .success(let measurement):
                    analysedPairs += 1
                    if measurement.foundSwimmer { framesWithSwimmer += 1 }
                    let dt = time - previous.time
                    times.append((previous.time + time) / 2)
                    values.append(measurement.relativeMotion / dt)
                case .failure(let error):
                    if firstFailure == nil { firstFailure = error.message }
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

    var failureReason: String {
        lock.lock()
        defer { lock.unlock() }
        if imagesReceived < 2 { return "只讀到 \(imagesReceived) 個影格" }
        return firstFailure ?? "可分析的影格不足（\(times.count) 組）"
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

    struct Failure: Error {
        let message: String
    }

    static func measure(from first: CGImage, to second: CGImage) -> Result<Measurement, Failure> {
        // Optical flow is required; swimmer detection is optional and its errors are ignored.
        let flowRequest = VNGenerateOpticalFlowRequest(targetedCGImage: second, options: [:])
        flowRequest.computationAccuracy = .medium
        let flowHandler = VNImageRequestHandler(cgImage: first, options: [:])
        do {
            try flowHandler.perform([flowRequest])
        } catch {
            return .failure(Failure(message: "光流分析失敗：\(error.localizedDescription)"))
        }
        guard let flow = flowRequest.results?.first?.pixelBuffer else {
            return .failure(Failure(message: "光流分析沒有結果"))
        }

        // Swimmer box in normalised image coordinates (origin bottom-left).
        var box: CGRect?
        let humanRequest = VNDetectHumanRectanglesRequest()
        let saliencyRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
        let detectionHandler = VNImageRequestHandler(cgImage: first, options: [:])
        if (try? detectionHandler.perform([humanRequest])) != nil,
           let human = humanRequest.results?.max(by: { $0.boundingBox.area < $1.boundingBox.area }),
           human.confidence > 0.3 {
            box = human.boundingBox
        } else if (try? detectionHandler.perform([saliencyRequest])) != nil,
                  let salient = saliencyRequest.results?.first?.salientObjects?
                    .max(by: { $0.boundingBox.area < $1.boundingBox.area }),
                  salient.boundingBox.area < 0.6 {
            box = salient.boundingBox
        }
        guard let measurement = motion(in: flow, swimmerBox: box) else {
            let format = CVPixelBufferGetPixelFormatType(flow)
            return .failure(Failure(message: "無法讀取光流資料（格式 \(format)）"))
        }
        return .success(measurement)
    }

    /// Reads (dx, dy) at `x` of a flow row, for 32-bit or 16-bit float two-component buffers.
    private static func flowAt(_ row: UnsafeMutableRawPointer, x: Int, halfFloat: Bool) -> (Float, Float) {
        if halfFloat {
            #if arch(arm64)
            let values = row.assumingMemoryBound(to: UInt16.self)
            return (Float(Float16(bitPattern: values[x * 2])), Float(Float16(bitPattern: values[x * 2 + 1])))
            #else
            return (.nan, .nan)   // Float16 is unavailable on Intel; such samples are skipped.
            #endif
        }
        let values = row.assumingMemoryBound(to: Float32.self)
        return (values[x * 2], values[x * 2 + 1])
    }

    private static func motion(in buffer: CVPixelBuffer, swimmerBox: CGRect?) -> Measurement? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_TwoComponent32Float || format == kCVPixelFormatType_TwoComponent16Half,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let halfFloat = format == kCVPixelFormatType_TwoComponent16Half
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
            let row = base.advanced(by: y * rowBytes)
            // Vision boxes have their origin at the bottom-left; buffer rows start at the top.
            let normalizedY = 1 - (Double(y) + 0.5) / Double(height)
            for x in stride(from: 0, to: width, by: 3) {
                let (dx, dy) = flowAt(row, x: x, halfFloat: halfFloat)
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
