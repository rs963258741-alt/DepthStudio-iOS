import XCTest
import AVFoundation
import SwiftUI
import UIKit
@testable import DepthStudio

/// Where tests save images for review: <repo>/build/test-artifacts (the simulator can
/// write to the Mac's file system), collected as CI artifacts by scripts/ci_test.sh.
enum TestArtifacts {
    static var directory: URL {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = repo.appendingPathComponent("build/test-artifacts", isDirectory: true)
        if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil {
            return url
        }
        let fallback = FileManager.default.temporaryDirectory.appendingPathComponent("test-artifacts", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static func save(_ image: UIImage, name: String) {
        guard let data = image.pngData() else { return }
        try? data.write(to: directory.appendingPathComponent(name))
    }

    /// Preview (left) and exported frame (right) side by side, both scaled to `height`.
    static func sideBySide(_ left: UIImage, _ right: UIImage, height: CGFloat = 960) -> UIImage {
        let leftWidth = left.size.width * height / max(1, left.size.height)
        let rightWidth = right.size.width * height / max(1, right.size.height)
        let size = CGSize(width: leftWidth + rightWidth + 24, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            left.draw(in: CGRect(x: 0, y: 0, width: leftWidth, height: height))
            right.draw(in: CGRect(x: leftWidth + 24, y: 0, width: rightWidth, height: height))
        }
    }
}

/// Generates small H.264 test videos: a pool-blue frame with lane lines that slide
/// (camera motion) and a light "swimmer" block whose speed varies.
enum TestVideoFactory {
    enum Failure: Error { case writer(String) }

    static func makeVideo(url: URL, size: CGSize, duration: Double, fps: Int32 = 30) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
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

        let frameCount = Int(duration * Double(fps))
        for index in 0..<frameCount {
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
        // Floor tiles / lane lines drifting downwards (a camera following the swimmer).
        let spacing = size.height / 8
        let drift = CGFloat((time * 120).truncatingRemainder(dividingBy: Double(spacing)))
        context.setFillColor(UIColor(red: 0.12, green: 0.55, blue: 0.85, alpha: 1).cgColor)
        var y = -spacing + drift
        while y < size.height {
            context.fill(CGRect(x: 0, y: y, width: size.width, height: size.height * 0.012))
            y += spacing
        }
        context.setFillColor(UIColor(red: 0.02, green: 0.15, blue: 0.30, alpha: 1).cgColor)
        context.fill(CGRect(x: size.width * 0.48, y: 0, width: size.width * 0.04, height: size.height))
        // Swimmer: moves up and down the frame with a kick-like varying speed.
        let swimmerY = size.height * (0.45 + 0.15 * CGFloat(sin(time * 1.7)))
        context.setFillColor(UIColor(red: 0.95, green: 0.80, blue: 0.65, alpha: 1).cgColor)
        context.fill(CGRect(x: size.width * 0.40, y: swimmerY, width: size.width * 0.20, height: size.height * 0.12))
    }

    static func frame(of url: URL, at seconds: Double, maximumSize: CGSize = CGSize(width: 1080, height: 1080)) async throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return UIImage(cgImage: result.image)
    }

    static func videoSize(of url: URL) async throws -> CGSize {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return .zero }
        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        return CGSize(width: abs(rect.width), height: abs(rect.height))
    }
}

/// Runs an export and records every progress value it reports.
final class ExportRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var progressValues: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        progressValues.append(value)
        lock.unlock()
    }

    func run(_ start: (@escaping (Double) -> Void, @escaping (Result<URL, Error>) -> Void) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            start({ [weak self] value in self?.record(value) }, { result in continuation.resume(with: result) })
        }
    }
}

@MainActor
enum PreviewRenderer {
    /// Renders a SwiftUI view at the given size (points) and scale, like the on-screen preview.
    static func image<Content: View>(_ content: Content, size: CGSize, scale: CGFloat = 3) -> UIImage? {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = scale
        return renderer.uiImage
    }
}
