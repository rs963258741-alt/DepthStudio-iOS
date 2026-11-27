#if DEBUG
import AVFoundation
import UIKit

/// Helpers for the UI tests, started with launch arguments. Debug builds only: the released
/// app (Release configuration) does not contain this file's code.
///
/// `-uitest-sample-video`: each mode starts with a generated 4 s portrait video, so the UI
/// tests can use the output-shape picker, the live floating preview and AI analysis.
enum UITestSupport {
    static var loadsSampleVideo: Bool {
        ProcessInfo.processInfo.arguments.contains("-uitest-sample-video")
    }

    static func sampleVideoURL() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-sample-v1.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try await makeVideo(url: url, size: CGSize(width: 720, height: 1280), duration: 4)
        return url
    }

    private enum Failure: Error { case writer(String) }

    private static func makeVideo(url: URL, size: CGSize, duration: Double, fps: Int32 = 30) async throws {
        let partial = url.deletingLastPathComponent().appendingPathComponent("uitest-sample-partial.mp4")
        try? FileManager.default.removeItem(at: partial)
        let writer = try AVAssetWriter(outputURL: partial, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height)
        ])
        guard writer.canAdd(input) else { throw Failure.writer("cannot add input") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "startWriting") }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<Int(duration * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.writer("no pixel buffer pool") }
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            guard let buffer = created else { throw Failure.writer("no pixel buffer") }
            draw(into: buffer, size: size, time: Double(index) / Double(fps))
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps)) else {
                throw Failure.writer(writer.error?.localizedDescription ?? "append")
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.writer(writer.error?.localizedDescription ?? "finish") }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
    }

    private static func draw(into buffer: CVPixelBuffer, size: CGSize, time: Double) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        context.setFillColor(UIColor(red: 0.06, green: 0.42, blue: 0.70, alpha: 1).cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        let spacing = size.height / 8
        let drift = CGFloat((time * 120).truncatingRemainder(dividingBy: Double(spacing)))
        context.setFillColor(UIColor(red: 0.12, green: 0.55, blue: 0.85, alpha: 1).cgColor)
        var y = -spacing + drift
        while y < size.height {
            context.fill(CGRect(x: 0, y: y, width: size.width, height: size.height * 0.012))
            y += spacing
        }
        let swimmerY = size.height * (0.45 + 0.15 * CGFloat(sin(time * 1.7)))
        context.setFillColor(UIColor(red: 0.95, green: 0.80, blue: 0.65, alpha: 1).cgColor)
        context.fill(CGRect(x: size.width * 0.40, y: swimmerY, width: size.width * 0.20, height: size.height * 0.12))
    }
}
#endif
