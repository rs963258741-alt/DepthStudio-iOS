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
    /// Every export has the pixel count of 4K UHD (3840 × 2160). That gives exactly
    /// 2160 × 3840 for 9:16 and 3840 × 2160 for 16:9, and keeps 1:1 (2880 × 2880) and
    /// 4:5 within what the H.264 encoder accepts.
    static let targetPixelCount: CGFloat = 3840 * 2160

    static func renderSize(aspect ratio: CGFloat) -> CGSize {
        let r = (ratio.isFinite && ratio > 0) ? ratio : 9.0 / 16.0
        let width = (targetPixelCount * r).squareRoot()
        let height = (targetPixelCount / r).squareRoot()
        return CGSize(width: multipleOf8(width), height: multipleOf8(height))
    }

    /// The exported frame is accepted as 4K-class if it has at least 97% of the target pixels.
    static func isFourKClass(_ size: CGSize) -> Bool {
        size.width * size.height >= targetPixelCount * 0.97
    }

    private static func multipleOf8(_ value: CGFloat) -> CGFloat {
        CGFloat(max(16, Int((value / 8).rounded()) * 8))
    }
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
            self.videoAspect = info.aspect
            if info.duration > 0 { self.duration = info.duration }
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

    nonisolated static func loadVideoInfo(url: URL) async -> (aspect: CGFloat, duration: Double)? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        guard abs(rect.width) > 0, abs(rect.height) > 0 else { return nil }
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        return (abs(rect.width) / abs(rect.height), seconds.isFinite ? seconds : 0)
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

/// A still frame of the video at (about) the given time, for the floating preview.
struct VideoStillView: View {
    let url: URL
    let time: Double
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .clipped()
        .task(id: "\(url.absoluteString)#\(Int((time * 4).rounded()))") {
            if let frame = await Self.frame(url: url, time: time) { image = frame }
        }
    }

    nonisolated static func frame(url: URL, time: Double) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        guard let result = try? await generator.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600)) else {
            return nil
        }
        return UIImage(cgImage: result.image)
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
struct FloatingPreviewPanel<Content: View>: View {
    let aspect: CGFloat
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    private var size: CGSize {
        if aspect >= 1 { return CGSize(width: 230, height: 230 / aspect) }
        return CGSize(width: 150, height: 150 / aspect)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content()
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

// MARK: - Layout presets (將目前排版設為預設)

/// Positions and per-item size/rotation of a HUD layout, saved as the user's own default.
struct HUDLayoutPreset: Codable, Equatable {
    var positions: [String: HUDPoint]
    var transforms: [String: HUDTransform]
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
