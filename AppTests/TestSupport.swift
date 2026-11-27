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

    /// `size` is the encoded (natural) size; `transform` is the track's preferred transform
    /// (a rotated phone video has a landscape natural size and a 90° transform).
    static func makeVideo(url: URL, size: CGSize, duration: Double, fps: Int32 = 30,
                          transform: CGAffineTransform = .identity) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
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
        // An orange corner mark (first rows of the buffer, left), so a wrong rotation or flip shows.
        context.setFillColor(UIColor(red: 1.0, green: 0.55, blue: 0.05, alpha: 1).cgColor)
        context.fill(CGRect(x: size.width * 0.05, y: size.height * 0.80, width: size.width * 0.18, height: size.height * 0.12))
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

/// Pixel comparisons of rendered and exported frames.
enum PixelCompare {
    /// RGBA bytes of `image` drawn at `size` (sRGB, premultiplied).
    static func pixels(_ image: CGImage, size: CGSize) -> [UInt8] {
        let width = Int(size.width), height = Int(size.height)
        var data = [UInt8](repeating: 0, count: width * height * 4)
        data.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(origin: .zero, size: size))
        }
        return data
    }

    /// Mean absolute RGB difference (0...255) of two images at `size`, optionally only in
    /// `region` (normalised, origin top left).
    static func meanDifference(_ a: CGImage, _ b: CGImage, size: CGSize, region: CGRect? = nil) -> Double {
        let pa = pixels(a, size: size), pb = pixels(b, size: size)
        let width = Int(size.width), height = Int(size.height)
        let area = region ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let x0 = max(0, Int(area.minX * CGFloat(width))), x1 = min(width, Int(area.maxX * CGFloat(width)))
        // CGContext rows start at the bottom; the region's y is from the top.
        let y0 = max(0, Int(area.minY * CGFloat(height))), y1 = min(height, Int(area.maxY * CGFloat(height)))
        var total = 0.0, count = 0
        for row in y0..<max(y0, y1) {
            let bufferRow = height - 1 - row
            for column in x0..<max(x0, x1) {
                let index = (bufferRow * width + column) * 4
                total += Double(abs(Int(pa[index]) - Int(pb[index])))
                total += Double(abs(Int(pa[index + 1]) - Int(pb[index + 1])))
                total += Double(abs(Int(pa[index + 2]) - Int(pb[index + 2])))
                count += 3
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    /// Mean alpha (0...255) in `region` (normalised, origin top left).
    static func meanAlpha(_ image: CGImage, size: CGSize, region: CGRect) -> Double {
        let p = pixels(image, size: size)
        let width = Int(size.width), height = Int(size.height)
        let x0 = max(0, Int(region.minX * CGFloat(width))), x1 = min(width, Int(region.maxX * CGFloat(width)))
        let y0 = max(0, Int(region.minY * CGFloat(height))), y1 = min(height, Int(region.maxY * CGFloat(height)))
        var total = 0.0, count = 0
        for row in y0..<max(y0, y1) {
            for column in x0..<max(x0, x1) {
                total += Double(p[((height - 1 - row) * width + column) * 4 + 3])
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    /// A box around a HUD position given in % of the frame.
    static func region(around point: HUDPoint, halfWidth: CGFloat = 0.05, halfHeight: CGFloat = 0.03) -> CGRect {
        CGRect(x: CGFloat(point.x / 100) - halfWidth, y: CGFloat(point.y / 100) - halfHeight,
               width: halfWidth * 2, height: halfHeight * 2)
    }
}
