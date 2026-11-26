import SwiftUI
import AVKit

/// Depth-mode stage: the imported video filling the chosen output shape (the same centre
/// crop as the export) with the editable depth HUD on top. Reads the playback time from
/// PlaybackController, so only this view refreshes while the video plays.
struct DiveStageView: View {
    let playback: PlaybackController
    let samples: [DiveSample]
    let sync: TimelineSync
    let maximumDepth: Double
    let deviceName: String
    @Binding var settings: HUDSettings
    @Binding var selectedHUDItem: String
    let isEditing: Bool

    var body: some View {
        ZStack {
            Color.black
            PlayerLayerView(player: playback.player)
            DiveHUDOverlay(
                reading: DiveStageView.reading(samples: samples, sync: sync, videoTime: playback.currentTime),
                samples: samples,
                maximumDepth: maximumDepth,
                deviceName: deviceName,
                settings: $settings,
                selectedItem: $selectedHUDItem,
                isEditing: isEditing
            )
        }
    }

    static func reading(samples: [DiveSample], sync: TimelineSync, videoTime: Double) -> DiveReading? {
        guard let interpolator = try? DiveDataInterpolator(samples: samples) else { return nil }
        return interpolator.reading(at: sync.watchTime(forVideoTime: videoTime))
    }
}

/// Floating 「預覽影像」 content for depth mode: a still of the current frame (or the empty
/// stage) with the HUD, not editable.
struct DiveFloatingPreview: View {
    let playback: PlaybackController
    let samples: [DiveSample]
    let sync: TimelineSync?
    let demoReading: DiveReading?
    let maximumDepth: Double
    let deviceName: String
    let settings: HUDSettings

    var body: some View {
        ZStack {
            if let url = playback.url {
                VideoStillView(url: url, time: playback.currentTime)
            } else {
                LinearGradient(colors: [Color(red: 0.04, green: 0.20, blue: 0.28), Color(red: 0.015, green: 0.055, blue: 0.085)],
                               startPoint: .top, endPoint: .bottom)
            }
            DiveHUDOverlay(
                reading: playback.hasVideo
                    ? sync.flatMap { DiveStageView.reading(samples: samples, sync: $0, videoTime: playback.currentTime) }
                    : demoReading,
                samples: samples,
                maximumDepth: maximumDepth,
                deviceName: deviceName,
                settings: .constant(settings),
                selectedItem: .constant(""),
                isEditing: false
            )
        }
    }
}
