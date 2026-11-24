import SwiftUI
import AVKit
import Combine

/// Connects AVPlayer playback time to the watch timeline and the HUD.
/// Requires DiveSample, DiveDataInterpolator, TimelineSync and DiveHUDOverlay.
@MainActor
final class DivePlayerClock: ObservableObject {
    @Published private(set) var currentVideoTime: Double = 0
    @Published private(set) var duration: Double = 0

    private let player: AVPlayer
    private var observer: Any?

    init(player: AVPlayer) {
        self.player = player
        self.duration = player.currentItem?.duration.seconds.isFinite == true
            ? max(0, player.currentItem!.duration.seconds) : 0

        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1.0 / 15.0, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.currentVideoTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                if let item = self.player.currentItem {
                    let seconds = item.duration.seconds
                    self.duration = seconds.isFinite ? max(0, seconds) : 0
                }
            }
        }
    }

    func seek(to seconds: Double) {
        let safe = min(max(0, seconds), max(duration, 0))
        player.seek(to: CMTime(seconds: safe, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero)
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
    }
}

struct DiveVideoPreview: View {
    let player: AVPlayer
    let samples: [DiveSample]
    let sync: TimelineSync
    let maximumDepth: Double

    @StateObject private var clock: DivePlayerClock
    @State private var hudOpacity = 0.88
    @State private var hudScale = 1.0
    @State private var hudOffset = CGSize.zero
    @State private var dragOrigin = CGSize.zero

    private var interpolator: DiveDataInterpolator? {
        try? DiveDataInterpolator(samples: samples)
    }

    private var watchTime: Double {
        sync.watchTime(forVideoTime: clock.currentVideoTime)
    }

    private var currentReading: DiveReading? {
        interpolator?.reading(at: watchTime)
    }

    init(player: AVPlayer, samples: [DiveSample],
         sync: TimelineSync, maximumDepth: Double) {
        self.player = player
        self.samples = samples
        self.sync = sync
        self.maximumDepth = maximumDepth
        _clock = StateObject(wrappedValue: DivePlayerClock(player: player))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                VideoPlayer(player: player)
                    .background(.black)

                GeometryReader { geometry in
                    DiveHUDOverlay(
                        reading: currentReading,
                        samples: samples,
                        videoTime: clock.currentVideoTime,
                        totalVideoDuration: clock.duration,
                        maximumDepth: maximumDepth
                    )
                    .opacity(hudOpacity)
                    .scaleEffect(hudScale)
                    .frame(maxWidth: min(geometry.size.width * 0.96, 900))
                    .fixedSize(horizontal: false, vertical: true)
                    .position(
                        x: geometry.size.width / 2 + hudOffset.width,
                        y: geometry.size.height * 0.78 + hudOffset.height
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                hudOffset = CGSize(
                                    width: dragOrigin.width + value.translation.width,
                                    height: dragOrigin.height + value.translation.height
                                )
                            }
                            .onEnded { _ in dragOrigin = hudOffset }
                    )
                }
                .allowsHitTesting(true)
            }
            .aspectRatio(contentMode: .fit)
            .clipped()

            VStack(spacing: 10) {
                HStack(spacing: 14) {
                    Button {
                        if player.timeControlStatus == .playing {
                            player.pause()
                        } else {
                            player.play()
                        }
                    } label: {
                        Image(systemName: player.timeControlStatus == .playing
                              ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.bordered)

                    Slider(
                        value: Binding(
                            get: { clock.currentVideoTime },
                            set: { clock.seek(to: $0) }
                        ),
                        in: 0...max(clock.duration, 0.1)
                    )

                    Text("\(timeLabel(clock.currentVideoTime)) / \(timeLabel(clock.duration))")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }

                HStack {
                    Label("HUD 透明度", systemImage: "circle.lefthalf.filled")
                    Slider(value: $hudOpacity, in: 0.25...1.0)
                    Text("\(Int(hudOpacity * 100))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }

                HStack {
                    Label("HUD 大小", systemImage: "arrow.up.left.and.arrow.down.right")
                    Slider(value: $hudScale, in: 0.65...1.35)
                    Text("\(Int(hudScale * 100))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
        }
        .background(.black)
    }

    private func timeLabel(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
