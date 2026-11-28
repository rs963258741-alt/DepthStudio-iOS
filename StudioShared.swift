import SwiftUI
import AVFoundation
import Observation
import UIKit

// MARK: - Output format (版型)

/// Shape of the exported video, chosen in the preview. The source video fills the frame
/// (centre crop), in the preview and in the export alike.
enum OutputAspect: String, CaseIterable, Identifiable, Codable {
    case original
    case square
    case portrait45
    case vertical916
    case landscape169

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "原始"
        case .square: return "1:1"
        case .portrait45: return "4:5"
        case .vertical916: return "9:16"
        case .landscape169: return "16:9"
        }
    }

    var icon: String {
        switch self {
        case .original: return "arrow.up.left.and.arrow.down.right"
        case .square, .portrait45: return "camera"
        case .vertical916: return "play.rectangle"
        case .landscape169: return "rectangle"
        }
    }

    /// Height of the picker tile, so each tile hints at its shape.
    var tileHeight: CGFloat {
        switch self {
        case .original, .square: return 58
        case .portrait45: return 64
        case .vertical916: return 74
        case .landscape169: return 46
        }
    }

    /// Width ÷ height of the output frame. `source` is the source video's display aspect.
    func ratio(source: CGFloat?) -> CGFloat {
        let ratio: CGFloat
        switch self {
        case .original:
            if let source, source.isFinite, source > 0 { ratio = source } else { ratio = 9.0 / 16.0 }
        case .square: ratio = 1
        case .portrait45: ratio = 4.0 / 5.0
        case .vertical916: ratio = 9.0 / 16.0
        case .landscape169: ratio = 16.0 / 9.0
        }
        return min(2.5, max(0.4, ratio))
    }
}

enum ExportSizing {
    /// The largest output: the pixel count of 4K UHD (3840 × 2160).
    static let maximumPixelCount: CGFloat = 3840 * 2160
    /// Used before the source video's size is known.
    static let fallbackPixelCount: CGFloat = 1920 * 1080

    /// Output frame for the chosen shape at the source video's quality: the frame has the
    /// source's pixel count (at most 4K UHD's). A 4K source gives 3840 × 2160 (16:9) or
    /// 2160 × 3840 (9:16), a 1080p source 1920 × 1080 or 1080 × 1920, and so on; other
    /// shapes keep the same pixel count (1:1 from 4K is 2880 × 2880).
    static func renderSize(aspect ratio: CGFloat, sourceSize: CGSize?) -> CGSize {
        let r = (ratio.isFinite && ratio > 0) ? ratio : 9.0 / 16.0
        let pixels = pixelCount(of: sourceSize)
        let width = (pixels * r).squareRoot()
        let height = (pixels / r).squareRoot()
        return CGSize(width: multipleOf8(width), height: multipleOf8(height))
    }

    static func pixelCount(of sourceSize: CGSize?) -> CGFloat {
        guard let size = sourceSize, size.width.isFinite, size.height.isFinite,
              size.width >= 16, size.height >= 16 else { return fallbackPixelCount }
        return min(maximumPixelCount, size.width * size.height)
    }

    /// 「4K」「1080P」…: the quality class of an output frame (by its pixel count, so every
    /// shape of the same source has the same label).
    static func qualityLabel(for size: CGSize) -> String {
        let pixels = size.width * size.height
        if pixels >= 3840 * 2160 * 0.97 { return "4K" }
        if pixels >= 2560 * 1440 * 0.97 { return "2K" }
        if pixels >= 1920 * 1080 * 0.97 { return "1080P" }
        if pixels >= 1280 * 720 * 0.97 { return "720P" }
        return "\(Int(min(size.width, size.height)))P"
    }

    private static func multipleOf8(_ value: CGFloat) -> CGFloat {
        CGFloat(max(16, Int((value / 8).rounded()) * 8))
    }
}

/// Centre snapping while dragging a HUD field (positions are % of the stage, so the
/// stage centre is 50 % in every output shape).
enum HUDSnapping {
    static let threshold = 2.0
    static let center = 50.0

    /// The field's new centre: the stage centre wins within the threshold, then the
    /// centres of the other visible fields. `verticalOffset` is the HUD's overall vertical
    /// offset, so the centre is where the field is shown.
    static func snap(x: Double, y: Double, verticalOffset: Double, others: [HUDPoint]) -> HUDPoint {
        var x = x
        var y = y
        var snappedX = false
        var snappedY = false
        if abs(x - center) < threshold { x = center; snappedX = true }
        if abs(y + verticalOffset - center) < threshold { y = center - verticalOffset; snappedY = true }
        for other in others {
            if !snappedX, abs(x - other.x) < threshold { x = other.x; snappedX = true }
            if !snappedY, abs(y - other.y) < threshold { y = other.y; snappedY = true }
        }
        return HUDPoint(x: min(99, max(1, x)), y: min(99, max(1, y)))
    }

    static func isCentered(_ value: Double) -> Bool { abs(value - center) < 0.001 }
}

enum HUDMetrics {
    /// HUD text, lines and markers scale with the frame's short side, so the HUD keeps its
    /// proportions in every output shape. For portrait frames this is the width.
    static func unit(for size: CGSize) -> CGFloat { max(1, min(size.width, size.height)) }

    /// One preview "point" at the reference stage width of 360 pt, for converting fixed
    /// point values (line widths, glow radii, tracking) into export pixels.
    static func point(unit: CGFloat) -> CGFloat { unit / 360 }
}

// MARK: - Playback

/// Owns the AVPlayer of the imported video and publishes its time. Views that show the
/// time read it from here, so only those views refresh during playback.
@MainActor
@Observable
final class PlaybackController {
    private(set) var player: AVPlayer?
    private(set) var url: URL?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    /// Display width ÷ height of the loaded video (after rotation), once it is known.
    private(set) var videoAspect: CGFloat?
    /// Display size in pixels of the loaded video (after rotation), once it is known.
    private(set) var videoSize: CGSize?
    /// Duration of one frame of the loaded video, once it is known (for frame stepping).
    private(set) var frameDuration: Double?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?

    var hasVideo: Bool { player != nil }

    func load(url: URL) {
        unload()
        let player = AVPlayer(url: url)
        self.player = player
        self.url = url
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 15),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                let seconds = time.seconds
                self.currentTime = seconds.isFinite ? max(0, seconds) : 0
                if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
            }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] observed, _ in
            let playing = observed.timeControlStatus == .playing
            Task { @MainActor in self?.isPlaying = playing }
        }
        Task { @MainActor [weak self] in
            guard let info = await Self.loadVideoInfo(url: url) else { return }
            guard let self, self.url == url else { return }
            self.videoAspect = info.size.width / info.size.height
            self.videoSize = info.size
            if info.duration > 0 { self.duration = info.duration }
            let frame = await Self.loadFrameDuration(url: url)
            if self.url == url { self.frameDuration = frame }
        }
    }

    func unload() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player = nil
        url = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        videoAspect = nil
        videoSize = nil
        frameDuration = nil
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let upper = duration > 0 ? duration : max(0, seconds)
        let safe = min(max(0, seconds), upper)
        player.seek(to: CMTime(seconds: safe, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = safe
    }

    func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            if duration > 0, currentTime >= duration - 0.05 { seek(to: 0) }
            player.play()
        }
    }

    func pause() { player?.pause() }

    func step(by delta: Double) {
        pause()
        seek(to: currentTime + delta)
    }

    /// The player's own current time (not the last periodic update), for capturing a
    /// video time exactly where the video is.
    var preciseTime: Double {
        guard let seconds = player?.currentTime().seconds, seconds.isFinite else { return currentTime }
        let upper = duration > 0 ? duration : seconds
        return min(max(0, seconds), upper)
    }

    /// Pauses and moves from the player's exact time (fine positioning: ±0.1 s).
    func stepPrecisely(by delta: Double) {
        pause()
        seek(to: preciseTime + delta)
    }

    /// Pauses and moves by whole frames (上一影格／下一影格); nil frame rate falls back to 1/30 s.
    func stepFrames(_ count: Int) {
        let frame = frameDuration ?? 1.0 / 30
        stepPrecisely(by: Double(count) * frame)
    }

    nonisolated static func loadFrameDuration(url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
        if let minimum = try? await track.load(.minFrameDuration), minimum.seconds.isFinite, minimum.seconds > 0 {
            return minimum.seconds
        }
        if let rate = try? await track.load(.nominalFrameRate), rate > 0 { return 1 / Double(rate) }
        return nil
    }

    nonisolated static func loadVideoInfo(url: URL) async -> (size: CGSize, duration: Double)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        guard abs(rect.width) > 0, abs(rect.height) > 0 else { return nil }
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        return (CGSize(width: abs(rect.width), height: abs(rect.height)), seconds.isFinite ? seconds : 0)
    }
}

/// Shows the player's video filling its frame (centre crop), matching the export.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }

    final class PlayerContainerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Play / scrub / frame-step controls under the preview.
struct PlaybackControls: View {
    let playback: PlaybackController

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { playback.togglePlayback() } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.headline).frame(width: 40, height: 40)
                }
                .buttonStyle(.bordered)
                .tint(Color.cyan)
                .accessibilityIdentifier("playback.toggle")

                Slider(value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }),
                       in: 0...max(playback.duration, 0.1))
                    .tint(Color.cyan)

                Text("\(StudioFormat.clock(playback.currentTime)) / \(StudioFormat.clock(playback.duration))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            HStack(spacing: 8) {
                ForEach([-0.5, -0.033, 0.033, 0.5], id: \.self) { step in
                    Button(step > 0 ? String(format: "+%.2gs", step) : String(format: "%.2gs", step)) {
                        playback.step(by: step)
                    }
                    .font(.caption.monospacedDigit())
                    .buttonStyle(.bordered)
                    .tint(DepthStudioColors.muted)
                }
            }
        }
    }
}

// MARK: - Pickers and panels

/// 版型 picker: 原始 / 1:1 / 4:5 / 9:16 / 16:9.
struct OutputAspectPicker: View {
    @Binding var selection: OutputAspect

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(OutputAspect.allCases) { aspect in
                Button { selection = aspect } label: {
                    VStack(spacing: 5) {
                        Image(systemName: aspect.icon).font(.system(size: 14, weight: .semibold))
                        Text(aspect.title).font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: aspect.tileHeight)
                    .foregroundStyle(selection == aspect ? Color.black : Color.white)
                    .background(selection == aspect ? Color.white : Color.white.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("輸出版型 \(aspect.title)")
                .accessibilityIdentifier("aspect.\(aspect.rawValue)")
            }
        }
    }
}

/// Semi-transparent floating preview shown while adjusting settings further down the page.
/// Its content is the live video with the HUD drawn at the same proportions as the stage
/// and the export, so every change shows immediately.
struct FloatingPreviewPanel<Content: View>: View {
    let aspect: CGFloat
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    private var size: CGSize {
        if aspect >= 1 { return CGSize(width: 250, height: 250 / aspect) }
        return CGSize(width: min(170, 300 * aspect), height: min(170, 300 * aspect) / aspect)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content()
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("floatingPreview.stage")
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(DepthStudioColors.cyan.opacity(0.7), lineWidth: 1))
                .opacity(0.88)
                .allowsHitTesting(false)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Color.black.opacity(0.65))
            }
            .padding(4)
            .accessibilityLabel("關閉預覽影像")
            .accessibilityIdentifier("floatingPreview.close")
        }
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("floatingPreview")
    }
}

/// Small 「預覽影像」 button placed in each settings section.
struct FloatingPreviewButton: View {
    @Binding var isShowing: Bool

    var body: some View {
        Button { isShowing.toggle() } label: {
            Label(isShowing ? "關閉預覽" : "預覽影像", systemImage: isShowing ? "eye.slash" : "eye")
                .font(.caption.weight(.bold))
                .foregroundStyle(isShowing ? Color.black : DepthStudioColors.cyan)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(isShowing ? DepthStudioColors.cyan : DepthStudioColors.background, in: Capsule())
                .overlay(Capsule().stroke(DepthStudioColors.cyan.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("floatingPreview.toggle")
    }
}

// MARK: - Formatting

enum StudioFormat {
    static func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    /// "45 秒" / "2 分 05 秒".
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total) 秒" }
        return String(format: "%d 分 %02d 秒", total / 60, total % 60)
    }
}

/// Progress text with a time-remaining estimate for an export.
struct ExportProgressClock {
    let startedAt: Date

    init(startedAt: Date = Date()) { self.startedAt = startedAt }

    func label(progress: Double, now: Date = Date()) -> String {
        let p = min(1, max(0, progress))
        let percent = Int((p * 100).rounded(.down))
        if p >= 0.995 { return "輸出進度 \(percent)%，正在檢查輸出影片…" }
        let elapsed = now.timeIntervalSince(startedAt)
        guard p >= 0.02, elapsed >= 2 else { return "輸出進度 \(percent)%，正在估算剩餘時間…" }
        let remaining = elapsed * (1 - p) / p
        return "輸出進度 \(percent)%，預估剩餘 \(StudioFormat.duration(remaining))"
    }
}

// MARK: - Layout presets (將目前排版設為預設1／預設2)

/// A saved HUD layout and look: positions and per-item size/rotation, plus (since 1.3)
/// shown fields, 字體顏色／陰影／對比 and the overall HUD size, opacity and offset.
/// Presets saved by 1.2 only have positions and transforms; the rest is then kept as is.
struct HUDLayoutPreset: Codable, Equatable {
    var positions: [String: HUDPoint]
    var transforms: [String: HUDTransform]
    var visibility: [String: Bool]?
    var styles: [String: HUDItemStyle]?
    var opacity: Double?
    var fontScale: Double?
    var verticalOffset: Double?
    var identityScale: Double?
}

enum HUDLayoutPresetStore {
    static func load(key: String, from defaults: UserDefaults = .standard) -> HUDLayoutPreset? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HUDLayoutPreset.self, from: data)
    }

    static func save(_ preset: HUDLayoutPreset, key: String, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(preset) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(key: String, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

/// The parts of the depth and pool HUD settings that presets save and restore.
protocol HUDPresetSettings {
    var positions: [String: HUDPoint] { get set }
    var transforms: [String: HUDTransform] { get set }
    var visibility: [String: Bool] { get set }
    var styles: [String: HUDItemStyle] { get set }
    var opacity: Double { get set }
    var fontScale: Double { get set }
    var verticalOffset: Double { get set }
    var identityScale: Double { get set }
    static var builtIn: Self { get }
    static var presetKeys: [Int: String] { get }
    func mergingDefaults() -> Self
}

extension HUDPresetSettings {
    static func preset(_ slot: Int, in store: UserDefaults = .standard) -> HUDLayoutPreset? {
        guard let key = presetKeys[slot] else { return nil }
        return HUDLayoutPresetStore.load(key: key, from: store)
    }

    static func savedPresetSlots(in store: UserDefaults = .standard) -> Set<Int> {
        Set(presetKeys.keys.filter { preset($0, in: store) != nil })
    }

    /// 「將目前排版設為預設1／2」: saves the current layout and look, kept across restarts.
    func savePreset(_ slot: Int, in store: UserDefaults = .standard) {
        guard let key = Self.presetKeys[slot] else { return }
        let preset = HUDLayoutPreset(positions: positions, transforms: transforms, visibility: visibility,
                                     styles: styles, opacity: opacity, fontScale: fontScale,
                                     verticalOffset: verticalOffset, identityScale: identityScale)
        HUDLayoutPresetStore.save(preset, key: key, to: store)
    }

    static func clearPreset(_ slot: Int, in store: UserDefaults = .standard) {
        guard let key = presetKeys[slot] else { return }
        HUDLayoutPresetStore.clear(key: key, in: store)
    }

    /// 「預設1／預設2」: applies a saved preset. Returns false if the slot is empty.
    @discardableResult
    mutating func applyPreset(_ slot: Int, using store: UserDefaults = .standard) -> Bool {
        guard let preset = Self.preset(slot, in: store) else { return false }
        let builtIn = Self.builtIn
        positions = builtIn.positions.merging(preset.positions) { _, saved in saved }
        transforms = builtIn.transforms.merging(preset.transforms) { _, saved in saved }
        if let saved = preset.visibility { visibility = builtIn.visibility.merging(saved) { _, value in value } }
        if let saved = preset.styles { styles = saved }
        if let saved = preset.opacity { opacity = saved }
        if let saved = preset.fontScale { fontScale = saved }
        if let saved = preset.verticalOffset { verticalOffset = saved }
        if let saved = preset.identityScale { identityScale = saved }
        self = mergingDefaults()
        return true
    }

    /// 「恢復預設位置」: positions and per-item size/rotation of preset 1, or the built-in layout.
    mutating func restoreDefaultPositions(using store: UserDefaults = .standard) {
        let builtIn = Self.builtIn
        if let preset = Self.preset(1, in: store) {
            positions = builtIn.positions.merging(preset.positions) { _, custom in custom }
            transforms = builtIn.transforms.merging(preset.transforms) { _, custom in custom }
        } else {
            positions = builtIn.positions
            transforms = builtIn.transforms
        }
    }
}
