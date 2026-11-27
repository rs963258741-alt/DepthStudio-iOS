import AVFoundation
import CoreImage
import QuartzCore
import UIKit

/// Draws an export HUD (the CALayer tree built by the depth or pool builder) at any video
/// time, as a Core Image overlay.
///
/// Every top-level HUD item is rendered into its own image, and only again when what it
/// shows changes (a new text value). Moving parts (the chart's playhead and markers, the
/// depth gauge's badge) are rendered once and then only moved; a moving part with text
/// (the badge's depth) is rendered again only when its text changes. Visibility, text and
/// positions come from the `HUDLayerTracks` recorded on the layers, so each frame shows
/// exactly the values of its video time.
final class HUDOverlayRenderer {
    let size: CGSize
    private let root: CALayer
    private let itemOpacity: CGFloat
    private var items: [Item] = []

    private final class Sprite {
        let layer: CALayer
        let tracks: HUDLayerTracks
        var texts: [(layer: CATextLayer, tracks: HUDLayerTracks)] = []
        var key: String?
        var image: CIImage?
        var reference = CGPoint.zero
        var hasReference = false
        init(layer: CALayer, tracks: HUDLayerTracks) { self.layer = layer; self.tracks = tracks }
    }

    private final class Item {
        let layer: CALayer
        let visibility: HUDLayerTracks?
        var texts: [(layer: CATextLayer, tracks: HUDLayerTracks)] = []
        var toggles: [(layer: CALayer, tracks: HUDLayerTracks)] = []
        var sprites: [Sprite] = []
        var key: String?
        var image: CIImage?
        init(layer: CALayer) {
            self.layer = layer
            visibility = HUDLayerTracks.existing(on: layer)
        }
    }

    /// `root` is the HUD layer (its bounds are the output frame); its opacity is applied
    /// to each item, like the preview's per-item opacity.
    init(root: CALayer) {
        self.root = root
        size = root.bounds.size
        itemOpacity = CGFloat(root.opacity)
        for layer in root.sublayers ?? [] {
            let item = Item(layer: layer)
            collect(layer, into: item, isRoot: true)
            items.append(item)
        }
        // The layers are usually built on a background thread. Draw every text layer and
        // commit, so they render on the compositor's thread too (uncommitted text layers
        // came out blank in the export while the values that were set later did show).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        Self.drawText(in: root)
        CATransaction.commit()
        CATransaction.flush()
    }

    private static func drawText(in layer: CALayer) {
        if let text = layer as? CATextLayer {
            text.setNeedsDisplay()
            text.displayIfNeeded()
        }
        for sublayer in layer.sublayers ?? [] { drawText(in: sublayer) }
    }

    var isEmpty: Bool { items.isEmpty }

    /// Number of items shown at `time`.
    func visibleItemCount(at time: Double) -> Int {
        items.filter { $0.visibility?.isVisible(at: time) ?? true }.count
    }

    private func collect(_ layer: CALayer, into item: Item, isRoot: Bool) {
        if !isRoot, let tracks = HUDLayerTracks.existing(on: layer) {
            if tracks.hasPosition {
                let sprite = Sprite(layer: layer, tracks: tracks)
                Self.collectTexts(in: layer, into: sprite)
                item.sprites.append(sprite)
                return
            }
            if let text = layer as? CATextLayer, tracks.hasText { item.texts.append((text, tracks)) }
            if tracks.visibleRange != nil { item.toggles.append((layer, tracks)) }
        }
        for sublayer in layer.sublayers ?? [] { collect(sublayer, into: item, isRoot: false) }
    }

    private static func collectTexts(in layer: CALayer, into sprite: Sprite) {
        for sublayer in layer.sublayers ?? [] {
            if let text = sublayer as? CATextLayer, let tracks = HUDLayerTracks.existing(on: text), tracks.hasText {
                sprite.texts.append((text, tracks))
            }
            collectTexts(in: sublayer, into: sprite)
        }
    }

    /// The HUD at `time` over a transparent background, in Core Image coordinates (origin
    /// at the bottom left, within 0...width × 0...height).
    func overlay(at time: Double) -> CIImage {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
            CATransaction.flush()
        }
        var result = CIImage.empty()
        for item in items {
            guard item.visibility?.isVisible(at: time) ?? true else { continue }
            if let image = staticImage(of: item, at: time) { result = image.composited(over: result) }
            for sprite in item.sprites {
                guard sprite.tracks.isVisible(at: time), let image = spriteImage(sprite, at: time) else { continue }
                result = image.composited(over: result)
            }
        }
        return result
    }

    /// The item without its moving parts; re-rendered only when its text or visibility changes.
    private func staticImage(of item: Item, at time: Double) -> CIImage? {
        var parts: [String] = []
        for entry in item.texts {
            let value = entry.tracks.text(at: time) ?? ""
            entry.tracks.show(value, on: entry.layer)
            entry.layer.displayIfNeeded()
            parts.append(value)
        }
        for entry in item.toggles {
            let visible = entry.tracks.isVisible(at: time)
            entry.layer.isHidden = !visible
            parts.append(visible ? "1" : "0")
        }
        let key = parts.joined(separator: "\u{1F}")
        if key == item.key { return item.image }
        for sprite in item.sprites { sprite.layer.isHidden = true }
        item.image = render(item.layer)
        for sprite in item.sprites { sprite.layer.isHidden = false }
        item.key = key
        return item.image
    }

    private func spriteImage(_ sprite: Sprite, at time: Double) -> CIImage? {
        guard let parent = sprite.layer.superlayer else { return nil }
        if !sprite.hasReference {
            // The layer itself never moves; each frame's image is shifted from here.
            sprite.reference = root.convert(sprite.layer.position, from: parent)
            sprite.hasReference = true
        }
        var parts: [String] = []
        for entry in sprite.texts {
            let value = entry.tracks.text(at: time) ?? ""
            entry.tracks.show(value, on: entry.layer)
            entry.layer.displayIfNeeded()
            parts.append(value)
        }
        let key = parts.joined(separator: "\u{1F}")
        if sprite.image == nil || key != sprite.key {
            sprite.image = render(sprite.layer)
            sprite.key = key
        }
        guard let image = sprite.image else { return nil }
        guard let position = sprite.tracks.position(at: time) else { return image }
        let now = root.convert(position, from: parent)
        // Core Image's y axis points up.
        return image.transformed(by: CGAffineTransform(translationX: now.x - sprite.reference.x,
                                                       y: -(now.y - sprite.reference.y)))
    }

    /// Renders `layer` (with its position, size and rotation in the HUD) into an image placed
    /// at the right spot of the output frame.
    private func render(_ layer: CALayer) -> CIImage? {
        let unit = HUDMetrics.unit(for: size)
        // Room for glows and shadows around what is drawn.
        let padding = unit * 0.08
        let frame = CGRect(origin: .zero, size: size)
        let drawn = Self.drawnBounds(of: layer)
        guard !drawn.isNull else { return nil }
        var rect = root.convert(drawn, from: layer).insetBy(dx: -padding, dy: -padding).integral
        rect = rect.intersection(frame.insetBy(dx: -size.width * 0.5, dy: -size.height * 0.5))
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        let transform = Self.transform(from: layer, to: root)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: -rect.minX, y: -rect.minY)
            cg.concatenate(transform)
            layer.render(in: cg)
        }
        guard let cgImage = image.cgImage else { return nil }
        var output = CIImage(cgImage: cgImage, options: [.colorSpace: NSNull()])
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: size.height - rect.maxY))
        if itemOpacity < 0.999 {
            output = output.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: itemOpacity)
            ])
        }
        return output
    }

    /// The part of `layer` (in its own coordinates) that actually has something drawn:
    /// the text's width rather than its wide box, a shape's path, and the union over the
    /// visible sublayers. Rendering only this area keeps the per-change cost low at 4K.
    static func drawnBounds(of layer: CALayer) -> CGRect {
        if layer.isHidden { return .null }
        var rect = CGRect.null
        if let text = layer as? CATextLayer {
            rect = textBounds(of: text)
        } else if let shape = layer as? CAShapeLayer, let path = shape.path {
            rect = path.boundingBoxOfPath.insetBy(dx: -shape.lineWidth, dy: -shape.lineWidth)
        } else if layer.contents != nil || layer.backgroundColor != nil || layer.borderWidth > 0 {
            rect = layer.bounds
        }
        for sublayer in layer.sublayers ?? [] {
            let inner = drawnBounds(of: sublayer)
            if !inner.isNull { rect = rect.union(layer.convert(inner, from: sublayer)) }
        }
        return rect
    }

    private static func textBounds(of layer: CATextLayer) -> CGRect {
        let bounds = layer.bounds
        let width: CGFloat
        if let attributed = layer.string as? NSAttributedString {
            width = ceil(attributed.size().width)
        } else if let string = layer.string as? String, let font = layer.font.flatMap({ $0 as? UIFont }) {
            width = ceil((string as NSString).size(withAttributes: [.font: font]).width)
        } else {
            return bounds
        }
        let drawnWidth = min(bounds.width, width + 4)
        let x: CGFloat
        switch layer.alignmentMode {
        case .left, .natural: x = bounds.minX
        case .right: x = bounds.maxX - drawnWidth
        default: x = bounds.midX - drawnWidth / 2
        }
        return CGRect(x: x, y: bounds.minY, width: drawnWidth, height: bounds.height)
    }

    /// The affine transform from `layer`'s coordinates to `ancestor`'s.
    static func transform(from layer: CALayer, to ancestor: CALayer) -> CGAffineTransform {
        let origin = ancestor.convert(CGPoint.zero, from: layer)
        let xAxis = ancestor.convert(CGPoint(x: 1, y: 0), from: layer)
        let yAxis = ancestor.convert(CGPoint(x: 0, y: 1), from: layer)
        return CGAffineTransform(a: xAxis.x - origin.x, b: xAxis.y - origin.y,
                                 c: yAxis.x - origin.x, d: yAxis.y - origin.y,
                                 tx: origin.x, ty: origin.y)
    }

    // MARK: Stills (tests and checks)

    private static let stillContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// The HUD at `time` over `background` (or transparent), as a bitmap of the output size.
    /// Like the export, no colour conversion is made; `colorSpace` only tags the result.
    func still(at time: Double, background: CIImage? = nil,
               colorSpace: CGColorSpace? = CGColorSpace(name: CGColorSpace.sRGB)) -> CGImage? {
        let frame = CGRect(origin: .zero, size: size)
        var image = overlay(at: time)
        if let background { image = image.composited(over: background) }
        return Self.stillContext.createCGImage(image.cropped(to: frame), from: frame, format: .RGBA8, colorSpace: colorSpace)
    }
}

// MARK: - Video composition

/// The one instruction of an export: the source track, its placement in the output frame
/// (rotation + centre-crop fill) and the HUD to draw on top.
final class HUDCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let sourceTrackID: CMPersistentTrackID
    let renderSize: CGSize
    /// Source pixels (top-left origin) → output pixels (top-left origin).
    let transform: CGAffineTransform
    let overlay: HUDOverlayRenderer?

    init(timeRange: CMTimeRange, sourceTrackID: CMPersistentTrackID, renderSize: CGSize,
         transform: CGAffineTransform, overlay: HUDOverlayRenderer?) {
        self.timeRange = timeRange
        self.sourceTrackID = sourceTrackID
        self.requiredSourceTrackIDs = [NSNumber(value: sourceTrackID)]
        self.renderSize = renderSize
        self.transform = transform
        self.overlay = overlay
        super.init()
    }

    /// One output frame: the source frame placed in the output, black where it does not
    /// reach, and the HUD of this time on top.
    func frame(from source: CVPixelBuffer, at time: Double) -> CIImage {
        let canvas = CGRect(origin: .zero, size: renderSize)
        let sourceHeight = CGFloat(CVPixelBufferGetHeight(source))
        // Core Image has its origin at the bottom left; the transform works top-left.
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: sourceHeight)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: renderSize.height)
        let video = CIImage(cvPixelBuffer: source, options: [.colorSpace: NSNull()])
            .transformed(by: flipIn.concatenating(transform).concatenating(flipOut))
        var image = video.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvas))
        if let overlay { image = overlay.overlay(at: time).composited(over: image) }
        return image.cropped(to: canvas)
    }
}

/// Custom video compositor for exports: places each source frame and draws the HUD of its
/// time with Core Image. Frames are processed in order on one queue.
final class HUDVideoCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.bananaflow.depthstudio.hud-compositor", qos: .userInitiated)
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                              .cacheIntermediates: false])
    private let lock = NSLock()
    private var generation = 0

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock()
        let requestGeneration = generation
        lock.unlock()
        queue.async { [self] in
            autoreleasepool {
                lock.lock()
                let cancelled = requestGeneration != generation
                lock.unlock()
                if cancelled {
                    request.finishCancelledRequest()
                    return
                }
                render(request)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? HUDCompositionInstruction else {
            request.finish(with: HUDCompositorError.unexpectedInstruction)
            return
        }
        guard let source = request.sourceFrame(byTrackID: instruction.sourceTrackID) else {
            request.finish(with: HUDCompositorError.missingSourceFrame)
            return
        }
        guard let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: HUDCompositorError.noOutputBuffer)
            return
        }
        let image = instruction.frame(from: source, at: request.compositionTime.seconds)
        context.render(image, to: output, bounds: CGRect(origin: .zero, size: instruction.renderSize), colorSpace: nil)
        request.finish(withComposedVideoFrame: output)
    }
}

enum HUDCompositorError: LocalizedError {
    case unexpectedInstruction
    case missingSourceFrame
    case noOutputBuffer

    var errorDescription: String? {
        switch self {
        case .unexpectedInstruction: return "影片合成設定錯誤。"
        case .missingSourceFrame: return "無法讀取來源影片的影格。"
        case .noOutputBuffer: return "無法建立輸出影格。"
        }
    }
}
