import SwiftUI
import AVKit
import Combine

@MainActor
final class DivePlayerClock: ObservableObject {
    @Published private(set) var currentVideoTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false

    private let player: AVPlayer
    private var observer: Any?
    private var statusObserver: AnyCancellable?

    init(player: AVPlayer) {
        self.player = player
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
                self.isPlaying = self.player.timeControlStatus == .playing
            }
        }
        statusObserver = player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                Task { @MainActor in self?.isPlaying = status == .playing }
            }
    }

    func seek(to seconds: Double) {
        let safe = min(max(0, seconds), max(duration, 0))
        player.seek(to: CMTime(seconds: safe, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlayback() {
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    deinit {
        if let observer { player.removeTimeObserver(observer) }
        statusObserver?.cancel()
    }
}

struct DiveVideoPreview: View {
    let player: AVPlayer
    let samples: [DiveSample]
    let sync: TimelineSync
    let maximumDepth: Double
    let deviceName: String
    @Binding var settings: HUDSettings
    @Binding var selectedHUDItem: String
    let isEditing: Bool

    @StateObject private var clock: DivePlayerClock

    private var reading: DiveReading? {
        guard let interpolator = try? DiveDataInterpolator(samples: samples) else { return nil }
        return interpolator.reading(at: sync.watchTime(forVideoTime: clock.currentVideoTime))
    }

    init(player: AVPlayer, samples: [DiveSample], sync: TimelineSync,
         maximumDepth: Double, deviceName: String,
         settings: Binding<HUDSettings>, selectedHUDItem: Binding<String>, isEditing: Bool) {
        self.player = player
        self.samples = samples
        self.sync = sync
        self.maximumDepth = maximumDepth
        self.deviceName = deviceName
        self._settings = settings
        self._selectedHUDItem = selectedHUDItem
        self.isEditing = isEditing
        _clock = StateObject(wrappedValue: DivePlayerClock(player: player))
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.black
                VideoPlayer(player: player)
                    .background(Color.black)
                DiveHUDOverlay(
                    reading: reading,
                    samples: samples,
                    maximumDepth: maximumDepth,
                    deviceName: deviceName,
                    settings: $settings,
                    selectedItem: $selectedHUDItem,
                    isEditing: isEditing
                )
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.cyan.opacity(0.25), lineWidth: 1))

            HStack(spacing: 12) {
                Button { clock.togglePlayback() } label: {
                    Image(systemName: clock.isPlaying ? "pause.fill" : "play.fill")
                        .font(.headline).frame(width: 40, height: 40)
                }
                .buttonStyle(.bordered)
                .tint(Color.cyan)

                Slider(value: Binding(get: { clock.currentVideoTime }, set: { clock.seek(to: $0) }),
                       in: 0...max(clock.duration, 0.1))
                    .tint(Color.cyan)

                Text("\(timeLabel(clock.currentVideoTime)) / \(timeLabel(clock.duration))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}
