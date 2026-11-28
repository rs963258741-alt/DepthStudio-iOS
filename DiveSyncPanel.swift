import SwiftUI
import AVFoundation

/// 潛水紀錄摘要與時間同步: the sync mode picker and the chosen mode's settings
/// (智慧同步、進階同步、手動同步), with the mode's 適用對象說明 at the bottom.
///
/// Every change goes through `DiveSyncState`, the one sync calculation the stage, the
/// floating and docked previews and the export use.
struct DiveSyncPanel: View {
    @Binding var state: DiveSyncState
    let landmarks: DiveLogLandmarks?
    let samples: [DiveSample]
    /// Not observed here: only the small views that show the playback time read it.
    let playback: PlaybackController
    let videoURL: URL?

    private enum Entry: Identifiable, Equatable {
        case video(SyncPoint)
        case watchPoint
        var id: String {
            switch self {
            case .video(let anchor): return "video.\(anchor.rawValue)"
            case .watchPoint: return "watchPoint"
            }
        }
    }

    @State private var entry: Entry?
    @State private var entryText = ""
    @State private var delayText = ""
    @State private var message: String?
    @State private var messageIsError = false
    @State private var pickingWatchPoint = false
    @State private var thumbnails: [CGImage] = []
    @FocusState private var delayFieldFocused: Bool

    private struct Nudge {
        let id: String
        let step: Double
        let label: String
    }

    /// 數據偏移 −1、−0.1、+0.1、+1 秒.
    private static let nudges = [Nudge(id: "minus1", step: -1, label: "−1 秒"), Nudge(id: "minus01", step: -0.1, label: "−0.1 秒"),
                                 Nudge(id: "plus01", step: 0.1, label: "+0.1 秒"), Nudge(id: "plus1", step: 1, label: "+1 秒")]

    private var hasVideo: Bool { playback.hasVideo }
    private var videoDuration: Double? { playback.duration > 0 ? playback.duration : nil }
    private var sortedSamples: [DiveSample] { samples.sorted { $0.elapsedSeconds < $1.elapsedSeconds } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            modePicker
            resultBanner
            availabilityNotes
            switch state.mode {
            case .smart: smartContent
            case .advanced: advancedContent
            case .manual: manualContent
            }
            if hasVideo { videoPositionControls }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(messageIsError ? Color.red : DepthStudioColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sync.message")
            }
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(DepthStudioColors.cyan)
                Text(state.mode.audience)
                    .font(.caption2).foregroundStyle(DepthStudioColors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sync.audience")
            }
            Button(role: .destructive) {
                state.reset()
                delayText = ""
                pickingWatchPoint = false
                show("已重設同步：清除所有定位時間，偏移回到 0 秒。")
            } label: {
                Label("重設同步", systemImage: "arrow.counterclockwise")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("sync.reset")
        }
        .alert(entryTitle, isPresented: entryPresented, presenting: entry) { target in
            TextField("例如 00:42.3", text: $entryText)
                .keyboardType(.numbersAndPunctuation)
                .accessibilityIdentifier("sync.entryField")
            Button("確定") { applyEntry(target) }
            Button("取消", role: .cancel) { entry = nil }
        } message: { target in
            Text(entryHint(target))
        }
        .task(id: thumbnailKey) { await loadThumbnails() }
    }

    // MARK: Mode and result

    private var modePicker: some View {
        HStack(spacing: 10) {
            Text("同步模式").font(.subheadline.weight(.bold))
            Spacer(minLength: 4)
            Picker("同步模式", selection: Binding(get: { state.mode }, set: { mode in
                state.select(mode)
                pickingWatchPoint = false
                message = nil
            })) {
                ForEach(DiveSyncMode.allCases) { mode in
                    Text("\(mode.title) \(mode.englishTitle)").tag(mode)
                }
            }
            .pickerStyle(.menu)
            .tint(DepthStudioColors.cyan)
            .accessibilityIdentifier("sync.mode")
        }
    }

    /// The applied offset for VoiceOver and the UI tests. (The visible 「目前同步」 block was
    /// removed in 1.5.1 to keep the section compact; the offset still shows in the message
    /// after setting a time and in 手動同步's 數據時間偏移.)
    private var resultBanner: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityAddTraits(.isStaticText)
            .accessibilityLabel("偏移 \(DiveSyncState.signedSeconds(state.delay))")
            .accessibilityValue(DiveSyncState.describe(state.delay))
            .accessibilityIdentifier("sync.delay")
    }

    @ViewBuilder
    private var availabilityNotes: some View {
        if !hasVideo {
            note("請先匯入影片：擷取影片時間、跳回時間點與雙時間軸需要影片。", systemImage: "video.slash")
        }
        if landmarks == nil {
            note("請先匯入潛水紀錄（FIT／UDDF）：需要手錶的深度數據才能同步。", systemImage: "waveform.slash")
        }
    }

    private func note(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 智慧同步

    private var smartContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            watchMaximumInfo
            anchorRow(.maximum, title: "影片抵達最大深度時間", required: true)
            pendingNotice
            if state.videoMaximum == nil, landmarks != nil {
                Text("播放到抵達最大深度的畫面，按「擷取時間」或輸入時間，即可自動計算偏移。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .disabled(landmarks == nil)
    }

    // MARK: 進階同步

    private var advancedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            watchMaximumInfo
            anchorRow(.descentStart, title: "開始下潛時間", required: false)
            anchorRow(.maximum, title: "抵達最大深度時間", required: true)
            anchorRow(.surface, title: "回到水面時間", required: false)
            pendingNotice
            checksTable
        }
        .disabled(landmarks == nil)
    }

    private var checksTable: some View {
        let checks = state.checks(landmarks)
        return VStack(alignment: .leading, spacing: 6) {
            Text("同步誤差驗證（以最大深度為基準）").font(.caption.weight(.bold))
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("時間點"); Text("手錶"); Text("影片"); Text("時間差")
                }
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(checks) { check in
                    GridRow {
                        Text(shortTitle(check.anchor))
                        Text(check.watchTime.map(DiveSyncState.clock) ?? "—")
                        Text(check.videoTime.map(DiveSyncState.clock) ?? "—")
                        Text(check.difference.map(DiveSyncState.signedSeconds) ?? "—")
                    }
                    .font(.caption.monospacedDigit())
                    if check.anchor != .maximum {
                        GridRow {
                            checkLevelText(check)
                                .gridCellColumns(4)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sync.checks")
            if checks.contains(where: { $0.level == .recheck }) {
                Text("誤差超過 3 秒：影片可能經過剪輯或變速，單一時間偏移無法讓整段同步。建議使用未經剪接及變速的原始影片；App 不會修改手錶數據來強制對齊。")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("誤差判定（0–1 秒良好、1–3 秒建議微調、3 秒以上建議重新確認）為初步建議，會受手錶取樣頻率、開始記錄的深度與數據品質影響。開始下潛／回到水面只在手錶確實記錄到水面時才能驗證。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(DepthStudioColors.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private func checkLevelText(_ check: SyncCheck) -> some View {
        let color: Color
        switch check.level {
        case .good: color = .green
        case .adjust: color = .yellow
        case .recheck: color = .orange
        case .notSet, .noData: color = .secondary
        }
        let errorText = check.error.map { "誤差 \(DiveSyncState.signedSeconds($0))：" } ?? ""
        return Text("　\(errorText)\(check.level.text)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .accessibilityIdentifier("sync.check.\(check.anchor.rawValue)")
    }

    private func shortTitle(_ anchor: SyncPoint) -> String {
        switch anchor {
        case .descentStart: return "開始下潛"
        case .maximum: return "最大深度"
        case .surface: return "回到水面"
        case .point: return "定位點"
        }
    }

    // MARK: 手動同步

    private var manualContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            anchorRow(.maximum, title: "影片抵達最大深度時間", required: false)
            if let landmarks, let duration = videoDuration, hasVideo {
                DiveSyncTimelineView(samples: sortedSamples, landmarks: landmarks, maximumEvent: state.maximumEvent,
                                     videoDuration: duration, delay: state.delay, videoMaximum: state.videoMaximum,
                                     pointVideoTime: state.pointVideoTime, pointWatchTime: state.pointWatchTime,
                                     thumbnails: thumbnails, playback: playback, pickingWatchPoint: pickingWatchPoint,
                                     onDelayChange: { state.setDelay($0) },
                                     onPickWatchTime: { time in
                                         state.setPointWatchTime(time)
                                         pickingWatchPoint = false
                                         show("已選取手錶時間點 \(DiveSyncState.clock(time))。")
                                     })
            } else {
                Text("匯入影片與潛水紀錄後，這裡會顯示影片時間軸與手錶深度曲線。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            offsetControls
            arbitraryPoint
        }
    }

    private var offsetControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("數據時間偏移").font(.caption.weight(.bold))
                Spacer()
                Text(DiveSyncState.signedSeconds(state.delay))
                    .font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(DepthStudioColors.cyan)
            }
            Slider(value: Binding(get: { min(DiveSyncState.sliderRange.upperBound, max(DiveSyncState.sliderRange.lowerBound, state.delay)) },
                                  set: { state.setDelay(($0 * 10).rounded() / 10) }),
                   in: DiveSyncState.sliderRange, step: 0.1)
                .tint(DepthStudioColors.cyan)
                .accessibilityIdentifier("sync.delaySlider")
            HStack(spacing: 6) {
                ForEach(Self.nudges, id: \.id) { nudge in
                    Button(nudge.label) { state.nudge(by: nudge.step) }
                        .font(.caption.monospacedDigit())
                        .buttonStyle(.bordered).tint(DepthStudioColors.cyan)
                        .accessibilityIdentifier("sync.nudge.\(nudge.id)")
                }
            }
            HStack(spacing: 8) {
                TextField("輸入偏移秒數，例如 +7.3", text: $delayText)
                    .keyboardType(.numbersAndPunctuation)
                    .submitLabel(.done)
                    .focused($delayFieldFocused)
                    .onSubmit { applyTypedDelay() }
                    .font(.caption)
                    .padding(8)
                    .background(DepthStudioColors.background, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("sync.delayField")
                Button("套用") { applyTypedDelay() }
                    .buttonStyle(.bordered).tint(DepthStudioColors.cyan)
                    .accessibilityIdentifier("sync.delayApply")
            }
            HStack(spacing: 8) {
                Button("自動對齊最大深度點") {
                    if state.applyCalculation(landmarks) {
                        show("已自動對齊：偏移 \(DiveSyncState.signedSeconds(state.delay))。")
                    }
                }
                .disabled(state.computedDelay(landmarks) == nil)
                .accessibilityIdentifier("sync.alignMaximum")
                Button("重設偏移") { state.setDelay(0) }
                    .accessibilityIdentifier("sync.resetDelay")
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered).tint(DepthStudioColors.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text("數據顯示太快：將數據延後（＋）。")
                Text("數據顯示太慢：將數據提前（−）。")
            }
            .font(.caption2).foregroundStyle(DepthStudioColors.muted)
            Text("滑桿範圍 −120 至 +120 秒，可直接輸入超出範圍的秒數；精度 0.1 秒。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(DepthStudioColors.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private var arbitraryPoint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("任意時間點定位").font(.caption.weight(.bold))
            Text("影片沒有拍到最大深度時：選擇影片中的一個時間點，再在手錶深度曲線上選擇代表同一事件的時間點，系統依兩點計算偏移，之後可再微調。請自行確認兩點確實是同一事件，這不代表精確同步。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            anchorRow(.point, title: "影片時間點", required: false)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("手錶時間點").font(.caption.weight(.semibold))
                    Text(state.pointWatchTime.map(DiveSyncState.clock) ?? "未設定")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(state.pointWatchTime == nil ? Color.secondary : Color.green)
                        .accessibilityIdentifier("sync.pointWatch.time")
                }
                Spacer(minLength: 4)
                Button(pickingWatchPoint ? "點選曲線中…" : "在曲線上點選") { pickingWatchPoint.toggle() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered).tint(pickingWatchPoint ? .green : DepthStudioColors.cyan)
                    .disabled(landmarks == nil || !hasVideo)
                    .accessibilityIdentifier("sync.pointWatch.pick")
                Menu {
                    Button("輸入手錶時間…") { beginEntry(.watchPoint, current: state.pointWatchTime) }
                    if state.pointWatchTime != nil {
                        Button("清除", role: .destructive) { state.setPointWatchTime(nil) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(DepthStudioColors.muted)
                }
                .disabled(landmarks == nil)
                .accessibilityLabel("手錶時間點選項")
                .accessibilityIdentifier("sync.pointWatch.menu")
            }
            Button("以兩點計算偏移") {
                if state.applyPoint() {
                    show("已依兩個定位點計算偏移 \(DiveSyncState.signedSeconds(state.delay))；請確認兩點是同一事件後再微調。")
                }
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderedProminent).tint(DepthStudioColors.cyan)
            .disabled(state.pointVideoTime == nil || state.pointWatchTime == nil)
            .accessibilityIdentifier("sync.applyPoint")
        }
        .padding(10)
        .background(DepthStudioColors.background, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Shared pieces

    @ViewBuilder
    private var watchMaximumInfo: some View {
        if let landmarks {
            VStack(alignment: .leading, spacing: 6) {
                Text("手錶最大深度 \(String(format: "%.1f m", landmarks.maximumDepth))｜手錶時間 \(DiveSyncState.clock(landmarks.maximumTime(for: state.maximumEvent)))")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .accessibilityIdentifier("sync.watchMaximum")
                if landmarks.holdDuration > 0.05 {
                    Text("最大深度停留 \(String(format: "%.0f", landmarks.holdDuration)) 秒（\(DiveSyncState.clock(landmarks.firstMaximumTime))–\(DiveSyncState.clock(landmarks.lastMaximumTime))）。影片時間請標記同一個事件：")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker("手錶基準點", selection: Binding(get: { state.maximumEvent },
                                                         set: { state.setMaximumEvent($0, landmarks: landmarks) })) {
                        ForEach(MaximumDepthEvent.allCases) { event in Text(event.title).tag(event) }
                    }
                    .pickerStyle(.menu)
                    .tint(DepthStudioColors.cyan)
                    .accessibilityIdentifier("sync.maximumEvent")
                }
            }
        }
    }

    @ViewBuilder
    private var pendingNotice: some View {
        if let pending = state.pendingCalculation(landmarks) {
            VStack(alignment: .leading, spacing: 6) {
                Text("目前套用的偏移為 \(DiveSyncState.signedSeconds(state.delay))（手動調整），依最大深度計算為 \(DiveSyncState.signedSeconds(pending))。")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("套用計算結果") {
                    state.applyCalculation(landmarks)
                    show("已套用最大深度計算的偏移 \(DiveSyncState.signedSeconds(state.delay))。")
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered).tint(DepthStudioColors.cyan)
                .accessibilityIdentifier("sync.applyCalculation")
            }
        } else if state.videoMaximum == nil, abs(state.delay) > 0.004 {
            Text("尚未設定影片抵達最大深度時間；目前沿用偏移 \(DiveSyncState.signedSeconds(state.delay))。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// One time point: its time (tap to jump there), 擷取時間 / 重新擷取, and a menu to type or clear it.
    private func anchorRow(_ anchor: SyncPoint, title: String, required: Bool) -> some View {
        let time = state.videoTime(of: anchor)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold)).lineLimit(2)
                Text(required ? "必填" : "選填").font(.caption2)
                    .foregroundStyle(required ? DepthStudioColors.cyan : .secondary)
            }
            Spacer(minLength: 4)
            Button {
                guard let time else { return }
                playback.pause()
                playback.seek(to: time)
            } label: {
                Text(time.map(DiveSyncState.clock) ?? "未設定")
                    .font(.system(.footnote, design: .monospaced).weight(.semibold))
                    .foregroundStyle(time == nil ? DepthStudioColors.muted : (anchor == .maximum ? Color.orange : Color.white))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .overlay(Capsule().stroke(DepthStudioColors.cyan.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(time == nil || !hasVideo)
            .accessibilityLabel("跳到\(title)")
            .accessibilityValue(time.map(DiveSyncState.clock) ?? "未設定")
            .accessibilityIdentifier("sync.\(anchor.rawValue).time")

            Button(time == nil ? "擷取時間" : "重新擷取") { capture(anchor) }
                .font(.caption.weight(.bold))
                .buttonStyle(.borderedProminent)
                .tint(DepthStudioColors.cyan)
                .foregroundStyle(.black)
                .disabled(!hasVideo)
                .accessibilityIdentifier("sync.\(anchor.rawValue).capture")

            Menu {
                Button("輸入時間…") { beginEntry(.video(anchor), current: time) }
                if time != nil {
                    Button("清除", role: .destructive) {
                        state.set(anchor, to: nil, landmarks: landmarks)
                        show("已清除「\(anchor.title)」。")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3).foregroundStyle(DepthStudioColors.muted)
            }
            .accessibilityLabel("\(title)選項")
            .accessibilityIdentifier("sync.\(anchor.rawValue).menu")
        }
    }

    /// Fine positioning of the video (not of the data offset).
    private var videoPositionControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("影片位置微調（只移動影片，不改變數據偏移）").font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                PlaybackTimeReadout(playback: playback)
            }
            HStack(spacing: 6) {
                videoStep("上一影格", systemImage: "backward.frame", id: "video.previousFrame") { playback.stepFrames(-1) }
                videoStep("後退 0.1 秒", systemImage: "gobackward", id: "video.back") { playback.stepPrecisely(by: -0.1) }
                videoStep("前進 0.1 秒", systemImage: "goforward", id: "video.forward") { playback.stepPrecisely(by: 0.1) }
                videoStep("下一影格", systemImage: "forward.frame", id: "video.nextFrame") { playback.stepFrames(1) }
            }
        }
        .padding(10)
        .background(DepthStudioColors.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private func videoStep(_ title: String, systemImage: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.caption.weight(.semibold))
                Text(title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).tint(DepthStudioColors.muted)
        .accessibilityLabel(title)
        .accessibilityIdentifier(id)
    }

    // MARK: Actions

    private func capture(_ anchor: SyncPoint) {
        playback.pause()
        apply(playback.preciseTime, to: anchor)
    }

    private func apply(_ time: Double, to anchor: SyncPoint) {
        if let problem = state.problem(setting: time, for: anchor, videoDuration: videoDuration) {
            show(problem + "未套用。", isError: true)
            return
        }
        state.set(anchor, to: time, landmarks: landmarks)
        var text = "已將「\(anchor.title)」設為 \(DiveSyncState.clock(time))。"
        if anchor == .maximum, state.mode != .manual, state.computedDelay(landmarks) != nil {
            text += "已套用偏移 \(DiveSyncState.signedSeconds(state.delay))（\(DiveSyncState.describe(state.delay))）。"
        }
        show(text)
    }

    private func applyTypedDelay() {
        delayFieldFocused = false
        guard let value = DiveSyncState.parseDelay(delayText) else {
            show("無法辨識「\(delayText)」，請輸入秒數，例如 +7.3 或 -12（範圍 ±3600 秒）。", isError: true)
            return
        }
        state.setDelay(value)
        delayText = ""
        show("已套用偏移 \(DiveSyncState.signedSeconds(state.delay))。")
    }

    private func beginEntry(_ target: Entry, current: Double?) {
        entryText = current.map(DiveSyncState.clock) ?? ""
        entry = target
    }

    private var entryPresented: Binding<Bool> {
        Binding(get: { entry != nil }, set: { if !$0 { entry = nil } })
    }

    private var entryTitle: String {
        if case .watchPoint = entry { return "輸入手錶時間" }
        return "輸入影片時間"
    }

    private func entryHint(_ target: Entry) -> String {
        let format = "格式為 分:秒 或 分:秒.小數（例如 00:42.3），也可以直接輸入秒數。"
        switch target {
        case .video:
            return videoDuration.map { format + "影片長度 \(DiveSyncState.clock($0))。" } ?? format
        case .watchPoint:
            return landmarks.map { format + "手錶紀錄 \(DiveSyncState.clock($0.firstSampleTime))–\(DiveSyncState.clock($0.lastSampleTime))。" } ?? format
        }
    }

    private func applyEntry(_ target: Entry) {
        entry = nil
        switch target {
        case .video(let anchor):
            guard let seconds = PoolFormat.parseTime(entryText, videoDuration: videoDuration) else {
                show("無法辨識時間「\(entryText)」，請輸入例如 00:42.3（分:秒.小數）或 42.3（秒）。", isError: true)
                return
            }
            apply(seconds, to: anchor)
        case .watchPoint:
            let logEnd = landmarks?.lastSampleTime
            guard let seconds = PoolFormat.parseTime(entryText, videoDuration: logEnd) else {
                show("無法辨識時間「\(entryText)」。", isError: true)
                return
            }
            if let landmarks, seconds < landmarks.firstSampleTime - 0.05 || seconds > landmarks.lastSampleTime + 0.05 {
                show("手錶時間 \(DiveSyncState.clock(seconds)) 不在手錶紀錄範圍內（\(DiveSyncState.clock(landmarks.firstSampleTime))–\(DiveSyncState.clock(landmarks.lastSampleTime))），未套用。", isError: true)
                return
            }
            state.setPointWatchTime(seconds)
            show("已設定手錶時間點 \(DiveSyncState.clock(seconds))。")
        }
    }

    private func show(_ text: String, isError: Bool = false) {
        message = text
        messageIsError = isError
    }

    // MARK: Thumbnails (影片時間軸縮圖)

    private var thumbnailKey: String { "\(videoURL?.absoluteString ?? "")|\(state.mode == .manual)" }

    private func loadThumbnails() async {
        guard state.mode == .manual, let videoURL else { return }
        let asset = AVURLAsset(url: videoURL)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        let count = 8
        var images: [CGImage] = []
        for index in 0..<count {
            if Task.isCancelled { return }
            let time = CMTime(seconds: duration * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image { images.append(image) }
        }
        if images.count == count { thumbnails = images }
    }
}

/// The current video time, refreshed on its own during playback.
struct PlaybackTimeReadout: View {
    let playback: PlaybackController

    var body: some View {
        Text(DiveSyncState.clock(playback.currentTime))
            .font(.system(.caption, design: .monospaced).weight(.bold))
            .foregroundStyle(DepthStudioColors.cyan)
            .accessibilityIdentifier("video.currentTime")
    }
}

// MARK: - 雙時間軸

/// The video timeline (fixed) above the watch's depth curve drawn on the same time scale.
/// The curve and its blue maximum marker move with the offset; the orange marker is the
/// video's maximum-depth time. Parts of the log outside the video are clipped and noted
/// (the log itself is unchanged).
struct DiveSyncTimelineView: View {
    let samples: [DiveSample]
    let landmarks: DiveLogLandmarks
    let maximumEvent: MaximumDepthEvent
    let videoDuration: Double
    let delay: Double
    let videoMaximum: Double?
    let pointVideoTime: Double?
    let pointWatchTime: Double?
    let thumbnails: [CGImage]
    let playback: PlaybackController
    let pickingWatchPoint: Bool
    let onDelayChange: (Double) -> Void
    let onPickWatchTime: (Double) -> Void

    @State private var dragStartDelay: Double?

    static let orange = Color(red: 1.0, green: 0.58, blue: 0.15)
    static let blue = Color(red: 0.30, green: 0.62, blue: 1.0)

    private var watchMaximumTime: Double { landmarks.maximumTime(for: maximumEvent) }

    private func x(forVideoTime time: Double, width: CGFloat) -> CGFloat {
        CGFloat(time / max(videoDuration, 0.001)) * width
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("影片時間軸（固定）").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let videoMaximum {
                    Text("● 影片最大深度 \(DiveSyncState.clock(videoMaximum))")
                        .font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(Self.orange)
                }
            }
            videoTrack
            HStack {
                Text("手錶深度曲線（隨偏移移動）").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("● \(String(format: "%.1f m", landmarks.maximumDepth)) @ 手錶 \(DiveSyncState.clock(watchMaximumTime))")
                    .font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(Self.blue)
            }
            watchTrack
            HStack {
                Text("00:00.0")
                Spacer()
                Text(DiveSyncState.clock(videoDuration / 2))
                Spacer()
                Text(DiveSyncState.clock(videoDuration))
            }
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            statusLine
            Text(pickingWatchPoint ? "點選手錶曲線上的時間點。" : "左右拖曳手錶曲線可調整偏移。")
                .font(.caption2).foregroundStyle(pickingWatchPoint ? .green : .secondary)
        }
        .padding(10)
        .background(DepthStudioColors.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private var videoTrack: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                if thumbnails.isEmpty {
                    RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.08, green: 0.20, blue: 0.27))
                } else {
                    HStack(spacing: 0) {
                        ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                            Image(decorative: image, scale: 1)
                                .resizable().scaledToFill()
                                .frame(width: width / CGFloat(thumbnails.count), height: proxy.size.height)
                                .clipped()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .opacity(0.75)
                }
                if let videoMaximum {
                    marker(x: x(forVideoTime: videoMaximum, width: width), height: proxy.size.height, color: Self.orange)
                }
                if let pointVideoTime {
                    marker(x: x(forVideoTime: pointVideoTime, width: width), height: proxy.size.height, color: .green)
                }
                TimelinePlayhead(playback: playback, duration: videoDuration)
            }
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("影片時間軸")
        .accessibilityValue(videoMaximum.map { "最大深度 \(DiveSyncState.clock($0))" } ?? "未設定最大深度")
        .accessibilityIdentifier("sync.timeline.video")
    }

    private var watchTrack: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let maximum = max(landmarks.maximumDepth, 1)
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 6),
                                 with: .color(Color(red: 0.04, green: 0.10, blue: 0.16)))
                    let top: CGFloat = 6, bottom = size.height - 6
                    func y(_ depth: Double) -> CGFloat { top + CGFloat(max(0, depth) / maximum) * (bottom - top) }
                    var curve = Path()
                    for (index, sample) in samples.enumerated() {
                        let point = CGPoint(x: x(forVideoTime: sample.elapsedSeconds + delay, width: size.width),
                                            y: y(sample.depthMeters))
                        if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
                    }
                    context.stroke(curve, with: .color(DepthStudioColors.cyan), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                    // Blue: the log's maximum (moves with the offset).
                    let blueX = x(forVideoTime: watchMaximumTime + delay, width: size.width)
                    var blueLine = Path(); blueLine.move(to: CGPoint(x: blueX, y: 0)); blueLine.addLine(to: CGPoint(x: blueX, y: size.height))
                    context.stroke(blueLine, with: .color(Self.blue), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    let dot = CGRect(x: blueX - 4, y: y(landmarks.maximumDepth) - 4, width: 8, height: 8)
                    context.fill(Path(ellipseIn: dot), with: .color(Self.blue))
                    // Orange: the video's maximum, continued from the video timeline.
                    if let videoMaximum {
                        let orangeX = x(forVideoTime: videoMaximum, width: size.width)
                        var line = Path(); line.move(to: CGPoint(x: orangeX, y: 0)); line.addLine(to: CGPoint(x: orangeX, y: size.height))
                        context.stroke(line, with: .color(Self.orange), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    }
                    if let pointWatchTime {
                        let greenX = x(forVideoTime: pointWatchTime + delay, width: size.width)
                        let mark = CGRect(x: greenX - 4, y: size.height / 2 - 4, width: 8, height: 8)
                        context.fill(Path(ellipseIn: mark), with: .color(.green))
                    }
                }
                TimelinePlayhead(playback: playback, duration: videoDuration)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard !pickingWatchPoint, size.width > 0 else { return }
                    if dragStartDelay == nil { dragStartDelay = delay }
                    let shift = Double(value.translation.width / size.width) * videoDuration
                    onDelayChange((((dragStartDelay ?? delay) + shift) * 10).rounded() / 10)
                }
                .onEnded { value in
                    defer { dragStartDelay = nil }
                    guard pickingWatchPoint, size.width > 0 else { return }
                    let videoTime = Double(value.location.x / size.width) * videoDuration
                    let watch = min(landmarks.lastSampleTime, max(landmarks.firstSampleTime, videoTime - delay))
                    onPickWatchTime((watch * 10).rounded() / 10)
                })
        }
        .frame(height: 84)
        .accessibilityElement()
        .accessibilityLabel("手錶深度曲線")
        .accessibilityValue("偏移 \(DiveSyncState.signedSeconds(delay))")
        .accessibilityIdentifier("sync.timeline.watch")
    }

    private func marker(x: CGFloat, height: CGFloat, color: Color) -> some View {
        Path { path in
            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: height))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
    }

    @ViewBuilder
    private var statusLine: some View {
        let start = landmarks.firstSampleTime + delay, end = landmarks.lastSampleTime + delay
        VStack(alignment: .leading, spacing: 2) {
            if let videoMaximum {
                let residual = DiveSyncState.rounded(videoMaximum - watchMaximumTime - delay)
                if abs(residual) < 0.05 {
                    Text("✓ 已對齊：橘色與藍色最大深度標記一致。").foregroundStyle(.green)
                } else {
                    Text("剩餘同步誤差 \(DiveSyncState.signedSeconds(residual))（橘色與藍色標記相距）。").foregroundStyle(Self.orange)
                }
            } else {
                Text("未設定影片最大深度時間：可拖曳曲線或使用下方的偏移控制手動對齊。").foregroundStyle(.secondary)
            }
            if start < -0.05 {
                Text("◀ 手錶紀錄前段 \(String(format: "%.1f", -start)) 秒在影片開始之前（不顯示，原始數據保留）。").foregroundStyle(.secondary)
            }
            if end > videoDuration + 0.05 {
                Text("手錶紀錄後段 \(String(format: "%.1f", end - videoDuration)) 秒在影片結束之後（不顯示，原始數據保留）▶").foregroundStyle(.secondary)
            }
            if end < 0 || start > videoDuration {
                Text("手錶紀錄完全不在影片範圍內，請確認偏移。").foregroundStyle(.orange)
            }
        }
        .font(.caption2)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sync.timeline.status")
    }
}

/// The playback position on a timeline; only this view refreshes during playback.
struct TimelinePlayhead: View {
    let playback: PlaybackController
    let duration: Double

    var body: some View {
        GeometryReader { proxy in
            let x = CGFloat(min(1, max(0, playback.currentTime / max(duration, 0.001)))) * proxy.size.width
            Rectangle().fill(.white).frame(width: 2, height: proxy.size.height)
                .position(x: x, y: proxy.size.height / 2)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - 固定影片預覽

/// While the sync settings are on screen and the main preview has scrolled away, a compact
/// copy of the preview (the same player, live HUD) and the playback controls stay at the
/// top. The video keeps its shape (fit, not cropped or stretched); it is not editable.
struct DockedPreviewPanel<Video: View>: View {
    let aspect: CGFloat
    let playback: PlaybackController
    @ViewBuilder let video: () -> Video

    var body: some View {
        VStack(spacing: 6) {
            video()
                .aspectRatio(aspect, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 200)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            PlaybackControls(playback: playback)
        }
        .padding(10)
        .background(DepthStudioColors.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(DepthStudioColors.cyan.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dockedPreview")
    }
}
