import SwiftUI
import AVKit
import PhotosUI
import Photos
import UniformTypeIdentifiers

/// 泳池平潛 mode (V1 basic analysis): import a pool dynamic-apnea video, mark the start,
/// each turn and the surfacing point against the video, and export it with a distance /
/// lap / speed HUD. No dive computer is needed.
struct PoolModeView: View {
    /// Returns to the mode picker. Nil when shown on its own (e.g. previews).
    var onSwitchMode: (() -> Void)? = nil
    @State private var confirmingModeSwitch = false

    @State private var session = PoolSession.demo
    @State private var hudSettings = PoolHUDSettings.load()
    @State private var selectedHUDItem = "distanceValue"
    @State private var isEditingLayout = true
    @State private var editorExpanded = false
    @State private var visibilityExpanded = false
    @State private var identityExpanded = false

    @State private var selectedPhotoVideo: PhotosPickerItem?
    @State private var showingFileImporter = false
    @State private var isImportingVideo = false
    @State private var videoURL: URL?
    /// The imported video's own file name, used to name exports.
    @State private var videoOriginalName: String?
    /// Not observed here on purpose: only the views that show the playback time read it.
    @State private var playback = PlaybackController()
    @State private var outputAspect: OutputAspect = .original
    @State private var showingFloatingPreview = false
    /// Preset slot (1 or 2) waiting for 「設為預設」 confirmation.
    @State private var confirmingPresetSlot: Int?
    @State private var savedPresetSlots = PoolHUDSettings.savedPresetSlots()
    @State private var confirmingAIAnalysis = false

    @State private var motionSignal: PoolMotionSignal?
    @State private var isAnalyzing = false
    @State private var analysisProgress = 0.0
    @State private var analysisTask: Task<Void, Never>?
    @State private var analysisMessage: String?

    @State private var finalDistanceDraft: Double = 150
    @State private var checkpointDistanceDraft: Double = 25
    @FocusState private var editingNumber: Bool
    @State private var timeEntryNodeID: UUID?
    @State private var timeEntryText = ""

    @State private var isExporting = false
    @State private var exportProgress = 0.0
    @State private var exportedVideoURL: URL?
    @State private var exportClock = ExportProgressClock()
    @State private var exportInfo = "依來源影片畫質輸出 MP4（4K 來源輸出 4K、1080P 來源輸出 1080P）；完成後另存為新的照片項目，原始影片不變。"
    @State private var statusMessage = "已載入示範數據（50 m 泳池、150 m）。匯入平潛影片後，依序標記出發、轉身與出水時間。"
    @State private var errorMessage: String?

    private var timelineResult: Result<PoolTimeline, Error> {
        Result { try PoolTimeline(session: session, motion: motionSignal) }
    }
    private var timeline: PoolTimeline? { try? timelineResult.get() }
    private var canExport: Bool { videoURL != nil && timeline != nil && !isExporting }
    private var videoContentTypes: [UTType] { [.movie, .mpeg4Movie, .quickTimeMovie] }
    /// Width ÷ height of the preview stage and of the export.
    private var stageRatio: CGFloat {
        playback.hasVideo ? outputAspect.ratio(source: playback.videoAspect) : 9.0 / 16.0
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    importSection
                    previewSection
                    timelineSection
                    hudAppearanceSection
                    visibilitySection
                    identitySection
                    exportSection
                    statusSection
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 34)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { editingNumber = false }
                }
            }
            .background(DepthStudioColors.background.ignoresSafeArea())
        }
        .overlay(alignment: .topTrailing) {
            if showingFloatingPreview {
                FloatingPreviewPanel(aspect: stageRatio, onClose: { showingFloatingPreview = false }) {
                    PoolFloatingPreview(playback: playback, timeline: timeline, settings: hudSettings)
                }
                .padding(.top, 8)
                .padding(.trailing, 12)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DepthStudioColors.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .confirmationDialog("將目前排版設為預設\(confirmingPresetSlot ?? 1)？", isPresented: presetConfirmationShown,
                            titleVisibility: .visible, presenting: confirmingPresetSlot) { slot in
            Button("設為預設\(slot)") { savePreset(slot) }
            Button("取消", role: .cancel) {}
        } message: { slot in
            Text(slot == 1
                 ? "儲存目前的位置、大小、旋轉、顯示欄位與字體顏色／陰影／對比。之後按「預設1」或「恢復預設位置」就會回到這個排版，重新啟動 App 也一樣。"
                 : "儲存目前的位置、大小、旋轉、顯示欄位與字體顏色／陰影／對比。之後按「預設2」就會套用這個排版，重新啟動 App 也一樣。")
        }
        .alert("AI 即時速率提醒", isPresented: $confirmingAIAnalysis) {
            Button("開始分析") { runAIAnalysis() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(Self.aiReminder)
        }
        .confirmationDialog("切換潛水模式？", isPresented: $confirmingModeSwitch, titleVisibility: .visible) {
            Button("回到模式選擇") { onSwitchMode?() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("目前匯入的影片與時間節點不會保留；HUD 外觀設定會保留。")
        }
        // The node is handed to the buttons (`presenting:`): the alert clears
        // timeEntryNodeID when it closes, which can happen before the button's action runs.
        .alert("輸入影片時間", isPresented: timeEntryPresented, presenting: timeEntryNodeID) { nodeID in
            TextField("例如 01:40.5", text: $timeEntryText)
                .keyboardType(.numbersAndPunctuation)
                .accessibilityIdentifier("timeEntry.field")
            Button("確定") { applyTimeEntry(nodeID) }
            Button("取消", role: .cancel) { timeEntryNodeID = nil }
        } message: { _ in
            Text(timeEntryHint)
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: videoContentTypes) { result in
            loadVideo(result)
        }
        .onChange(of: selectedPhotoVideo) { _, item in
            guard let item else { return }
            Task { await importVideoFromPhotos(item) }
        }
        .onChange(of: hudSettings) { _, newValue in newValue.save() }
        .onChange(of: hudSettings.displayName) { _, newValue in
            if newValue.count > 30 { hudSettings.displayName = String(newValue.prefix(30)) }
        }
        .onChange(of: finalDistanceDraft) { _, newValue in session.setFinalDistance(newValue) }
        .onChange(of: session.finalDistance) { _, newValue in
            if finalDistanceDraft != newValue { finalDistanceDraft = newValue }
        }
        .onDisappear {
            analysisTask?.cancel()
            playback.unload()
        }
        .task { await loadSampleVideoForUITests() }
    }

    static let aiReminder = "使用此功能容易受到影片中移動的物體干擾，建議畫面都在水中穩定拍攝時再使用。"

    private var presetConfirmationShown: Binding<Bool> {
        Binding(get: { confirmingPresetSlot != nil }, set: { if !$0 { confirmingPresetSlot = nil } })
    }

    /// UI tests start with a generated video and marked start/turn/finish times
    /// (launch argument -uitest-sample-video).
    private func loadSampleVideoForUITests() async {
        #if DEBUG
        guard UITestSupport.loadsSampleVideo, videoURL == nil,
              let url = try? await UITestSupport.sampleVideoURL() else { return }
        applyImportedVideo(url, displayName: url.lastPathComponent)
        let nodes = session.nodes
        for (index, node) in nodes.enumerated() {
            session.setTime(0.3 + Double(index) * 2.4 / Double(max(1, nodes.count - 1)), for: node.id)
        }
        #endif
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DEPTH STUDIO")
                    .font(.system(size: 25, weight: .black, design: .rounded))
                    .tracking(1.2).foregroundStyle(.white)
                Text("POOL · DYNAMIC APNEA")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(2.2).foregroundStyle(DepthStudioColors.cyan)
            }
            Spacer()
            if onSwitchMode != nil {
                ModeSwitchButton(title: "泳池平潛") { confirmingModeSwitch = true }
            }
            Image("JiaoliuLogo")
                .resizable().scaledToFit()
                .frame(width: 54, height: 46)
                .accessibilityLabel("蕉流自潛")
        }
        .padding(.vertical, 5)
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("01 / 匯入平潛影片", subtitle: "不需要潛水錶數據；距離與速率由影片時間節點計算。")
            PhotosPicker(selection: $selectedPhotoVideo, matching: .videos, photoLibrary: .shared()) {
                HStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle").font(.title2).foregroundStyle(DepthStudioColors.cyan)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("從照片匯入影片").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                        Text(isImportingVideo ? "正在載入影片…" : (videoOriginalName ?? videoURL?.lastPathComponent ?? "直接選擇 iPhone 相簿影片"))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    if isImportingVideo { ProgressView().tint(DepthStudioColors.cyan) }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DepthStudioColors.background, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(DepthStudioColors.cyan.opacity(0.22), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(isImportingVideo)

            HStack {
                Button { showingFileImporter = true } label: {
                    Label("或從檔案 App 選取影片", systemImage: "folder")
                        .font(.footnote.weight(.semibold)).foregroundStyle(DepthStudioColors.cyan)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { loadDemoData() } label: {
                    Label("載入示範數據", systemImage: "figure.pool.swim")
                        .font(.footnote.weight(.semibold)).foregroundStyle(DepthStudioColors.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(DepthStudioColors.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("影像與 HUD 預覽", subtitle: "排版開啟時可直接拖曳任一 HUD 欄位；點選後可在 03 調整大小與旋轉。")
            layoutButtons

            if playback.hasVideo {
                VStack(alignment: .leading, spacing: 6) {
                    Text("輸出版型").font(.caption.weight(.semibold)).foregroundStyle(DepthStudioColors.muted)
                    OutputAspectPicker(selection: $outputAspect)
                }
                PoolStageView(
                    playback: playback,
                    timeline: timeline,
                    settings: $hudSettings,
                    selectedHUDItem: $selectedHUDItem,
                    isEditing: isEditingLayout
                )
                .aspectRatio(stageRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(DepthStudioColors.cyan.opacity(0.25), lineWidth: 1))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("previewStage")
                PlaybackControls(playback: playback)
            } else {
                GeometryReader { proxy in
                    ZStack {
                        LinearGradient(colors: [Color(red: 0.05, green: 0.30, blue: 0.40),
                                                Color(red: 0.015, green: 0.075, blue: 0.11)],
                                       startPoint: .top, endPoint: .bottom)
                        VStack(spacing: 8) {
                            Image(systemName: "video.badge.plus")
                                .font(.system(size: 30, weight: .light)).foregroundStyle(DepthStudioColors.cyan)
                            Text("匯入泳池平潛影片以開始預覽")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            Text("HUD 位置可先在畫面上調整")
                                .font(.caption).foregroundStyle(DepthStudioColors.muted)
                        }
                    }
                    .overlay {
                        PoolHUDOverlay(
                            reading: timeline.map { $0.reading(atVideoTime: $0.startTime + $0.totalTime * 0.5) },
                            timeline: timeline,
                            settings: $hudSettings,
                            selectedItem: $selectedHUDItem,
                            isEditing: isEditingLayout
                        )
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(DepthStudioColors.cyan.opacity(0.25), lineWidth: 1))
                }
                .aspectRatio(9.0 / 16.0, contentMode: .fit)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("previewStage")
            }
        }
        .padding(14)
        .background(DepthStudioColors.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("02 / 泳池設定與時間節點",
                          subtitle: "播放影片到出發、每次轉身及出水的瞬間，按「標記」記下影片時間。")

            HStack {
                Text("泳池長度").font(.caption.weight(.semibold)).foregroundStyle(DepthStudioColors.muted)
                Spacer()
                Picker("泳池長度", selection: poolLengthBinding) {
                    ForEach(PoolSession.poolLengths, id: \.self) { length in
                        Text("\(Int(length)) m").tag(length)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            HStack {
                Text("項目").font(.caption.weight(.semibold)).foregroundStyle(DepthStudioColors.muted)
                Spacer()
                Picker("項目", selection: $hudSettings.discipline) {
                    ForEach(PoolHUDSettings.disciplines, id: \.self) { discipline in
                        Text(discipline).tag(discipline)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
            }

            HStack(spacing: 8) {
                Text("最終出水距離").font(.caption.weight(.semibold)).foregroundStyle(DepthStudioColors.muted)
                Spacer()
                numberField(value: $finalDistanceDraft)
                Text("m").font(.caption)
                Stepper("最終出水距離", value: $finalDistanceDraft, in: PoolSession.finalDistanceRange, step: 0.5)
                    .labelsHidden()
            }
            Text("最後一趟不一定游完整個泳池（例如 137.5 m），轉身節點會依泳池長度自動產生。")
                .font(.caption2).foregroundStyle(.secondary)

            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)

            HStack {
                Label("目前影片時間", systemImage: "play.circle")
                    .font(.caption.weight(.semibold)).foregroundStyle(DepthStudioColors.muted)
                Spacer()
                PlaybackTimeLabel(playback: playback)
            }

            VStack(spacing: 8) {
                ForEach(session.nodes) { node in
                    nodeRow(node)
                }
            }

            HStack(spacing: 8) {
                Text("新增校正點").font(.caption.weight(.semibold)).foregroundStyle(DepthStudioColors.muted)
                Spacer()
                numberField(value: $checkpointDistanceDraft)
                Text("m").font(.caption)
                Button("新增") { addCheckpoint() }
                    .buttonStyle(.bordered).tint(DepthStudioColors.cyan)
            }

            aiAnalysisCard

            switch timelineResult {
            case .success(let timeline):
                summaryCard(timeline)
            case .failure(let error):
                Text(error.localizedDescription)
                    .font(.footnote).foregroundStyle(.orange)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(14)
        .background(DepthStudioColors.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private func nodeRow(_ node: PoolNode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: node.kind))
                .font(.body.weight(.semibold))
                .foregroundStyle(DepthStudioColors.cyan)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(PoolFormat.distance(node.distance)) m")
                    .font(.subheadline.weight(.heavy)).monospacedDigit().foregroundStyle(.white)
                Text(node.title).font(.caption2).foregroundStyle(DepthStudioColors.muted)
            }
            Spacer(minLength: 4)
            Button { jump(to: node) } label: {
                Text(node.videoTime.map(PoolFormat.preciseClock) ?? "未標記")
                    .font(.system(.footnote, design: .monospaced).weight(.semibold))
                    .foregroundStyle(node.videoTime == nil ? DepthStudioColors.muted
                                     : isPastVideoEnd(node.videoTime) ? Color.orange : Color.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(Capsule().stroke(DepthStudioColors.cyan.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(node.videoTime == nil || !playback.hasVideo)
            .accessibilityLabel("跳到 \(PoolFormat.distance(node.distance)) 公尺的時間")
            .accessibilityValue(node.videoTime.map(PoolFormat.preciseClock) ?? "未標記")
            .accessibilityIdentifier("node.time.\(PoolFormat.distance(node.distance))")

            Button { session.setTime(playback.currentTime, for: node.id) } label: {
                Text("標記")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(playback.hasVideo ? .black : DepthStudioColors.muted)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(playback.hasVideo ? DepthStudioColors.cyan : Color.gray.opacity(0.3), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!playback.hasVideo)
            .accessibilityLabel("以目前影片時間標記 \(PoolFormat.distance(node.distance)) 公尺")

            Menu {
                Button("輸入時間…") { beginTimeEntry(for: node) }
                Button("−0.1 秒") { nudge(node, by: -0.1) }
                Button("+0.1 秒") { nudge(node, by: 0.1) }
                Button("−1 秒") { nudge(node, by: -1) }
                Button("+1 秒") { nudge(node, by: 1) }
                if node.videoTime != nil {
                    Button("清除時間", role: .destructive) { session.setTime(nil, for: node.id) }
                }
                if node.kind == .checkpoint {
                    Button("刪除校正點", role: .destructive) { session.removeNode(id: node.id) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(DepthStudioColors.muted)
            }
            .accessibilityLabel("\(PoolFormat.distance(node.distance)) 公尺的時間選項")
            .accessibilityIdentifier("node.menu.\(PoolFormat.distance(node.distance))")
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(DepthStudioColors.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private func summaryCard(_ timeline: PoolTimeline) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("平潛數據摘要").font(.subheadline.weight(.bold))
            HStack(spacing: 8) {
                summaryValue("總距離", value: "\(PoolFormat.distance(timeline.finalDistance)) m")
                summaryValue("閉氣時間", value: PoolFormat.preciseClock(timeline.totalTime))
                summaryValue("平均速率", value: "\(PoolFormat.speed(timeline.averageSpeed)) m/s")
            }
            VStack(spacing: 4) {
                ForEach(Array(timeline.segments.enumerated()), id: \.offset) { _, segment in
                    HStack {
                        Text("\(PoolFormat.distance(segment.startDistance))–\(PoolFormat.distance(segment.endDistance)) m")
                        Spacer()
                        Text(String(format: "%.1f 秒", segment.duration))
                        Text("\(PoolFormat.speed(segment.speed)) m/s")
                            .frame(width: 78, alignment: .trailing)
                            .foregroundStyle(DepthStudioColors.cyan)
                    }
                    .font(.caption.monospacedDigit())
                }
            }
            Text(speedSourceText(timeline))
                .font(.caption2).foregroundStyle(.secondary)
            if let warning = timelineWarning(timeline) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("timeline.warning")
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DepthStudioColors.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private var hudAppearanceSection: some View {
        DisclosureGroup(isExpanded: $editorExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $isEditingLayout) {
                    Label("開啟任意排版", systemImage: "hand.draw")
                        .font(.subheadline.weight(.semibold))
                }
                .tint(DepthStudioColors.cyan)
                .accessibilityIdentifier("layout.freeToggle")
                Text("與預覽區的「排版」按鈕同步；開啟後所有 HUD 欄位都可以直接拖曳。")
                    .font(.caption2).foregroundStyle(.secondary)

                Picker("目前編輯項目", selection: $selectedHUDItem) {
                    ForEach(PoolHUDItemDefinition.all) { item in Text(item.title).tag(item.id) }
                }
                .pickerStyle(.menu)

                sliderRow("項目大小", value: selectedScaleBinding, range: 0.3...3.0, suffix: "%", multiplier: 100)
                sliderRow("旋轉角度", value: selectedRotationBinding, range: 0...359, suffix: "°")

                HStack(spacing: 8) {
                    ForEach([0.0, 90.0, 180.0, 270.0], id: \.self) { angle in
                        Button("\(Int(angle))°") { setSelectedRotation(angle) }
                            .buttonStyle(.bordered).tint(DepthStudioColors.cyan)
                    }
                }
                HStack(spacing: 8) {
                    Button("逆時針 90°") { setSelectedRotation(currentRotation - 90) }
                    Button("順時針 90°") { setSelectedRotation(currentRotation + 90) }
                    Button("重設此項目") { hudSettings.transforms[selectedHUDItem] = HUDTransform() }
                }
                .buttonStyle(.bordered).tint(DepthStudioColors.muted)

                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                HUDStyleEditor(itemTitle: PoolHUDItemDefinition.all.first { $0.id == selectedHUDItem }?.title ?? "",
                               style: selectedStyleBinding,
                               originalColor: PoolHUDSettings.originalColor(for: selectedHUDItem),
                               onApplyToAll: applySelectedStyleToAll)

                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                sliderRow("HUD 透明度", value: $hudSettings.opacity, range: 0.2...1.0, suffix: "%", multiplier: 100, id: "hud.opacitySlider")
                sliderRow("HUD 字體大小", value: $hudSettings.fontScale, range: 0.7...1.4, suffix: "%", multiplier: 100, id: "hud.fontScaleSlider")
                sliderRow("HUD 整體垂直偏移", value: $hudSettings.verticalOffset, range: -15...25, suffix: "%")
                HStack {
                    Button("恢復預設位置") { hudSettings.resetLayout() }
                        .buttonStyle(.bordered).tint(DepthStudioColors.cyan)
                    Button("重設外觀") {
                        let name = hudSettings.displayName
                        let country = hudSettings.country
                        hudSettings = PoolHUDSettings()
                        hudSettings.resetLayout()
                        hudSettings.displayName = name
                        hudSettings.country = country
                    }
                    .buttonStyle(.bordered).tint(DepthStudioColors.muted)
                }
                HStack(spacing: 8) {
                    Text(savedPresetSlots.contains(1) ? "目前預設：預設1（你設定的排版）" : "目前預設：原廠排版")
                        .font(.caption2).foregroundStyle(DepthStudioColors.muted)
                    if savedPresetSlots.contains(1) {
                        Button("改回原廠預設") {
                            PoolHUDSettings.clearCustomDefaultLayout()
                            savedPresetSlots = PoolHUDSettings.savedPresetSlots()
                            statusMessage = "已清除預設1；「恢復預設位置」會回到原廠排版。"
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered).tint(DepthStudioColors.muted)
                    }
                }
                Text("排版模式開啟時，直接拖曳預覽中的任一 HUD 欄位；位置依畫面比例儲存，項目中心會吸附到畫面正中央（依目前版型）及其他可見欄位。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        } label: {
            sectionHeader("03 / HUD 外觀與自由排版", subtitle: "每個欄位可獨立移動、縮放與旋轉。")
        }
        .tint(DepthStudioColors.cyan)
        .padding(14)
        .background(DepthStudioColors.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var visibilitySection: some View {
        DisclosureGroup(isExpanded: $visibilityExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("全部顯示") { hudSettings.setAllVisible(true) }
                    Button("全部隱藏") { hudSettings.setAllVisible(false) }
                }
                .buttonStyle(.bordered).tint(DepthStudioColors.cyan)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                    ForEach(PoolHUDItemDefinition.all) { item in
                        Toggle(item.title, isOn: visibilityBinding(for: item.id))
                            .font(.caption)
                            .tint(DepthStudioColors.cyan)
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("visibility.\(item.id)")
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            sectionHeader("04 / HUD 資訊顯示與隱藏", subtitle: "單獨隱藏不會影響其他資訊欄位。")
        }
        .tint(DepthStudioColors.cyan)
        .padding(14)
        .background(DepthStudioColors.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var identitySection: some View {
        DisclosureGroup(isExpanded: $identityExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("姓名（最多 30 字）", text: $hudSettings.displayName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(11)
                    .background(DepthStudioColors.background, in: RoundedRectangle(cornerRadius: 10))
                Picker("國家／地區", selection: $hudSettings.country) {
                    ForEach(HUDCountryOption.all) { option in Text(option.title).tag(option.id) }
                }
                sliderRow("姓名、國旗與項目共同大小", value: $hudSettings.identityScale, range: 0.6...1.8, suffix: "%", multiplier: 100)
                Text("國旗、姓名及項目（DYN／DYNB／DNF）會作為同一組一起移動、縮放與旋轉。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        } label: {
            sectionHeader("05 / 姓名與國家旗幟", subtitle: "支援七個國家／地區。")
        }
        .tint(DepthStudioColors.cyan)
        .padding(14)
        .background(DepthStudioColors.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("06 / 輸出影片", subtitle: "依來源影片的畫質輸出新的 MP4，依選擇的版型裁切，保留來源影像與音訊。")
            Text(outputSpecText)
                .font(.caption.weight(.semibold)).foregroundStyle(DepthStudioColors.muted)
                .accessibilityIdentifier("export.spec")
            Button(action: exportVideo) {
                HStack {
                    if isExporting { ProgressView().tint(.black) }
                    Image(systemName: "square.and.arrow.down.on.square")
                    Text(isExporting ? "正在輸出影片…" : "輸出影片（另存新檔）")
                }
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(canExport ? DepthStudioColors.cyan : Color.gray.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(canExport ? .black : .white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .disabled(!canExport)
            .accessibilityIdentifier("export.start")
            Label("輸出影片不會覆蓋原始影片。", systemImage: "checkmark.shield")
                .font(.caption2.weight(.semibold)).foregroundStyle(DepthStudioColors.muted)
                .accessibilityIdentifier("export.keepsOriginal")

            if isExporting { ProgressView(value: exportProgress).tint(DepthStudioColors.cyan) }
            Text(isExporting ? exportClock.label(progress: exportProgress) : exportInfo)
                .font(.caption2).foregroundStyle(.secondary)
                .accessibilityIdentifier("export.progressText")
            if let exportedVideoURL {
                ShareLink(item: exportedVideoURL) {
                    Label("分享／另存輸出影片", systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                }
                .tint(DepthStudioColors.cyan)
            }
        }
        .padding(14)
        .background(DepthStudioColors.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorMessage {
                Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            Text(statusMessage).font(.footnote).foregroundStyle(DepthStudioColors.muted)
        }
    }

    // MARK: AI speed analysis

    private var aiAnalysisCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("AI 即時速率分析", systemImage: "sparkles")
                    .font(.subheadline.weight(.bold))
                Spacer()
                if isAnalyzing {
                    Button("取消") { analysisTask?.cancel() }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered).tint(DepthStudioColors.muted)
                } else {
                    Button(motionSignal == nil ? "開始分析" : "重新分析") { confirmingAIAnalysis = true }
                        .font(.caption.weight(.bold))
                        .buttonStyle(.borderedProminent).tint(DepthStudioColors.cyan)
                        .foregroundStyle(.black)
                        .disabled(!playback.hasVideo || timeline == nil)
                        .accessibilityIdentifier("ai.analyze")
                }
            }
            if isAnalyzing {
                ProgressView(value: analysisProgress).tint(DepthStudioColors.cyan)
            }
            Text(analysisMessage ?? "標記出發與出水後，AI 會分析影片中選手與泳池背景的相對移動，估算每一刻的速率變化；各段總距離仍以你標記的節點為準。無法辨識時，速率會在平均值上下約 0.01～0.3 m/s 自然浮動。\n提醒：\(Self.aiReminder)")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DepthStudioColors.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private func speedSourceText(_ timeline: PoolTimeline) -> String {
        let total = timeline.segmentSources.count
        let ai = timeline.aiSegmentCount
        if ai == total && total > 0 {
            return "速率來源：AI 影像分析（各段距離以標記節點校正）。"
        }
        if ai > 0 {
            return "速率來源：\(ai)／\(total) 段為 AI 影像分析，其餘為模擬浮動（約 ±0.01～0.3 m/s）。"
        }
        return "速率來源：模擬浮動（約 ±0.01～0.3 m/s，平均值等於各段實際平均速率）。可按「AI 即時速率分析」改用影像分析。"
    }

    private func runAIAnalysis() {
        guard let url = videoURL else {
            errorMessage = "請先匯入影片。"
            return
        }
        guard let timeline else {
            errorMessage = "請先標記出發與結束出水時間，再進行 AI 分析。"
            return
        }
        analysisTask?.cancel()
        errorMessage = nil
        isAnalyzing = true
        analysisProgress = 0
        analysisMessage = "AI 正在分析影片中的選手與泳池背景…"
        let analyzer = PoolMotionAnalyzer(url: url, startTime: timeline.startTime, endTime: timeline.finishTime)
        analysisTask = Task { @MainActor in
            do {
                let signal = try await analyzer.analyze { value in
                    Task { @MainActor in analysisProgress = value }
                }
                motionSignal = signal
                let rate = Int((signal.detectionRate * 100).rounded())
                if signal.detectionRate >= 0.3 {
                    analysisMessage = "AI 分析完成：\(rate)% 的影格辨識到選手，速率已依影像中的加速、滑行與轉身調整。"
                } else {
                    analysisMessage = "AI 分析完成：選手辨識率 \(rate)%，速率改依畫面整體移動估算；如需更準確，可在轉身點之間加上校正點。"
                }
            } catch is CancellationError {
                analysisMessage = "AI 分析已取消。"
            } catch PoolMotionAnalyzer.AnalysisError.cancelled {
                analysisMessage = "AI 分析已取消。"
            } catch {
                motionSignal = nil
                analysisMessage = "AI 無法分析這段影片（\(error.localizedDescription)），速率使用模擬浮動。"
            }
            isAnalyzing = false
        }
    }

    // MARK: Small views and bindings

    private var layoutButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    isEditingLayout.toggle()
                } label: {
                    Label(isEditingLayout ? "排版：開" : "排版：關", systemImage: isEditingLayout ? "hand.draw.fill" : "hand.draw")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isEditingLayout ? .black : DepthStudioColors.cyan)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(isEditingLayout ? DepthStudioColors.cyan : DepthStudioColors.background, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("layout.toggle")
                Spacer(minLength: 0)
            }
            HUDPresetButtons(savedSlots: savedPresetSlots,
                             onSave: { confirmingPresetSlot = $0 },
                             onApply: applyPreset)
        }
    }

    /// Section title with the 「預覽影像」 button that shows the floating preview.
    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            sectionTitle(title, subtitle: subtitle)
            Spacer(minLength: 4)
            FloatingPreviewButton(isShowing: $showingFloatingPreview)
        }
    }

    private func savePreset(_ slot: Int) {
        if slot == 1 { hudSettings.saveLayoutAsDefault() } else { hudSettings.savePreset(slot) }
        savedPresetSlots = PoolHUDSettings.savedPresetSlots()
        statusMessage = slot == 1
            ? "已將目前排版設為預設1；之後按「預設1」或「恢復預設位置」會回到這個排版，重新啟動 App 也一樣。"
            : "已將目前排版設為預設2；之後按「預設2」會套用這個排版，重新啟動 App 也一樣。"
    }

    private func applyPreset(_ slot: Int) {
        if hudSettings.applyPreset(slot) {
            statusMessage = "已套用預設\(slot)。"
        } else {
            statusMessage = "預設\(slot) 尚未設定；請先按「將目前排版設為預設\(slot)」。"
        }
    }

    /// 「輸出規格：9:16・1080 × 1920（1080P，依來源畫質）」
    private var outputSpecText: String {
        guard playback.hasVideo else { return "輸出規格：匯入影片後依來源畫質決定（最高 4K）" }
        guard let source = playback.videoSize else { return "輸出規格：\(outputAspect.title)・正在讀取來源畫質…" }
        let size = ExportSizing.renderSize(aspect: stageRatio, sourceSize: source)
        return "輸出規格：\(outputAspect.title)・\(Int(size.width)) × \(Int(size.height))（\(ExportSizing.qualityLabel(for: size))，依來源畫質）"
    }

    private var selectedStyleBinding: Binding<HUDItemStyle> {
        Binding(get: { hudSettings.style(for: selectedHUDItem) },
                set: { hudSettings.setStyle($0, for: selectedHUDItem) })
    }

    private func applySelectedStyleToAll() {
        let style = hudSettings.style(for: selectedHUDItem)
        for item in PoolHUDItemDefinition.all { hudSettings.setStyle(style, for: item.id) }
        statusMessage = "已將「\(PoolHUDItemDefinition.all.first { $0.id == selectedHUDItem }?.title ?? "")」的字體顏色、陰影與對比套用到所有欄位。"
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline.weight(.bold)).foregroundStyle(Color(red: 0.67, green: 0.91, blue: 0.98))
            Text(subtitle).font(.caption2).foregroundStyle(DepthStudioColors.muted)
        }
    }

    private func summaryValue(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.bold)).monospacedDigit().foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numberField(value: Binding<Double>) -> some View {
        TextField("0", value: value, format: .number.precision(.fractionLength(0...1)))
            .keyboardType(.decimalPad)
            .focused($editingNumber)
            .multilineTextAlignment(.trailing)
            .font(.footnote.monospacedDigit())
            .frame(width: 64)
            .padding(.vertical, 6).padding(.horizontal, 8)
            .background(DepthStudioColors.background, in: RoundedRectangle(cornerRadius: 8))
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           suffix: String, multiplier: Double = 1, id: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text("\(Int((value.wrappedValue * multiplier).rounded()))\(suffix)")
                    .font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(DepthStudioColors.cyan)
            }
            Slider(value: value, in: range).tint(DepthStudioColors.cyan)
                .accessibilityIdentifier(id ?? title)
        }
    }

    private func icon(for kind: PoolNodeKind) -> String {
        switch kind {
        case .start: return "flag"
        case .turn: return "arrow.left.arrow.right"
        case .checkpoint: return "mappin.and.ellipse"
        case .finish: return "stop.circle"
        }
    }

    private var poolLengthBinding: Binding<Double> {
        Binding(get: { session.poolLength }, set: { session.setPoolLength($0) })
    }

    private var timeEntryPresented: Binding<Bool> {
        Binding(get: { timeEntryNodeID != nil }, set: { if !$0 { timeEntryNodeID = nil } })
    }

    private var currentRotation: Double { hudSettings.transforms[selectedHUDItem]?.rotation ?? 0 }
    private var selectedScaleBinding: Binding<Double> {
        Binding(get: { hudSettings.transforms[selectedHUDItem]?.scale ?? 1 }, set: { value in
            var transform = hudSettings.transforms[selectedHUDItem] ?? HUDTransform()
            transform.scale = value
            hudSettings.transforms[selectedHUDItem] = transform
        })
    }
    private var selectedRotationBinding: Binding<Double> {
        Binding(get: { currentRotation }, set: { setSelectedRotation($0, snap: false) })
    }

    private func visibilityBinding(for id: String) -> Binding<Bool> {
        Binding(get: { hudSettings.visibility[id] ?? true }, set: { hudSettings.visibility[id] = $0 })
    }

    private func setSelectedRotation(_ value: Double, snap: Bool = true) {
        var transform = hudSettings.transforms[selectedHUDItem] ?? HUDTransform()
        var degree = (value.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        if snap {
            let nearest = (degree / 90).rounded() * 90
            let delta = min(abs(degree - nearest), 360 - abs(degree - nearest))
            if delta <= 7 { degree = nearest.truncatingRemainder(dividingBy: 360) }
        }
        transform.rotation = degree
        hudSettings.transforms[selectedHUDItem] = transform
    }

    // MARK: Timeline actions

    private func jump(to node: PoolNode) {
        guard playback.hasVideo, let time = node.videoTime else { return }
        playback.pause()
        playback.seek(to: time)
    }

    private func nudge(_ node: PoolNode, by delta: Double) {
        let base = node.videoTime ?? playback.currentTime
        var time = max(0, base + delta)
        if playback.hasVideo, playback.duration > 0 { time = min(time, playback.duration) }
        session.setTime(time, for: node.id)
    }

    private func isPastVideoEnd(_ time: Double?) -> Bool {
        guard let time, playback.hasVideo, playback.duration > 0 else { return false }
        return time > playback.duration + PoolFormat.durationTolerance
    }

    /// Why the HUD would not move in the video: the start is after the video's end, or the
    /// finish is past it.
    private func timelineWarning(_ timeline: PoolTimeline) -> String? {
        guard playback.hasVideo, playback.duration > 0 else { return nil }
        let duration = playback.duration
        if timeline.startTime >= duration - PoolFormat.durationTolerance {
            return "「0 m 出發」的時間 \(PoolFormat.preciseClock(timeline.startTime)) 在影片結束（\(PoolFormat.preciseClock(duration))）之後，"
                + "影片中的距離與時間會一直停在 0.0 m／00:00。請播放到出發的瞬間按「標記」，或重新輸入時間。"
        }
        if timeline.finishTime > duration + PoolFormat.durationTolerance {
            return "「結束出水」的時間 \(PoolFormat.preciseClock(timeline.finishTime)) 超過影片長度（\(PoolFormat.preciseClock(duration))），"
                + "影片結束前不會到達最終距離。請重新標記或輸入時間。"
        }
        return nil
    }

    private func beginTimeEntry(for node: PoolNode) {
        timeEntryText = node.videoTime.map(PoolFormat.preciseClock) ?? ""
        timeEntryNodeID = node.id
    }

    /// The time entry's help text, with the video's length when a video is loaded.
    private var timeEntryHint: String {
        let format = "格式為 分:秒 或 分:秒.小數（例如 00:12.5），也可以直接輸入秒數。"
        guard playback.hasVideo, playback.duration > 0 else { return format }
        return format + "影片長度 \(PoolFormat.preciseClock(playback.duration))。"
    }

    /// Applies a typed time to `id`. Times past the end of the video are refused (they
    /// would keep the HUD at 0.0 m / 00:00 for the whole video), and "00:12:5" typed with
    /// ":" instead of "." is read as 00:12.5 when 12 minutes would be past the video's end.
    private func applyTimeEntry(_ id: UUID) {
        timeEntryNodeID = nil
        let duration = playback.hasVideo && playback.duration > 0 ? playback.duration : nil
        guard let seconds = PoolFormat.parseTime(timeEntryText, videoDuration: duration) else {
            errorMessage = "無法辨識時間「\(timeEntryText)」，請輸入例如 00:12.5（分:秒.小數）或 12.5（秒）。"
            return
        }
        if let duration, seconds > duration + PoolFormat.durationTolerance {
            errorMessage = "輸入的時間 \(PoolFormat.preciseClock(seconds)) 超過影片長度 \(PoolFormat.preciseClock(duration))，"
                + "未套用。請輸入影片中的時間，例如 00:12.5（分:秒.小數）。"
            return
        }
        errorMessage = nil
        session.setTime(seconds, for: id)
        if let node = session.nodes.first(where: { $0.id == id }) {
            statusMessage = "已將「\(PoolFormat.distance(node.distance)) m \(node.title)」設為 \(PoolFormat.preciseClock(node.videoTime ?? seconds))。"
        }
    }

    private func addCheckpoint() {
        editingNumber = false
        if session.addCheckpoint(distance: checkpointDistanceDraft) {
            errorMessage = nil
            statusMessage = "已新增 \(PoolFormat.distance(checkpointDistanceDraft)) m 校正點，請播放到該位置後按「標記」。"
        } else {
            errorMessage = "校正點必須介於 0 m 與最終距離之間，且不可與其他節點重複。"
        }
    }

    private func loadDemoData() {
        session = PoolSession.demo
        finalDistanceDraft = session.finalDistance
        errorMessage = nil
        statusMessage = "已載入示範數據：50 m 泳池，00:02 出發、00:50 與 01:40 轉身、02:30 於 150 m 出水。"
    }

    // MARK: Video import

    @MainActor
    private func importVideoFromPhotos(_ item: PhotosPickerItem) async {
        isImportingVideo = true
        errorMessage = nil
        statusMessage = "正在從 iPhone 照片載入影片…"
        defer { isImportingVideo = false; selectedPhotoVideo = nil }
        do {
            guard let imported = try await item.loadTransferable(type: ImportedMovie.self) else {
                throw PoolVideoImportError.transferUnavailable
            }
            applyImportedVideo(imported.url, displayName: imported.originalName ?? imported.url.lastPathComponent)
        } catch {
            errorMessage = "照片影片匯入失敗：\(error.localizedDescription)"
            statusMessage = "請重新選取影片，或改用「從檔案 App 選取影片」。"
        }
    }

    private func loadVideo(_ result: Result<URL, Error>) {
        let selectedURL: URL
        do { selectedURL = try result.get() }
        catch { errorMessage = "影片選取失敗：\(error.localizedDescription)"; return }
        let access = selectedURL.startAccessingSecurityScopedResource()
        defer { if access { selectedURL.stopAccessingSecurityScopedResource() } }
        do {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("DepthStudio-\(UUID().uuidString)")
                .appendingPathExtension(selectedURL.pathExtension.isEmpty ? "mov" : selectedURL.pathExtension)
            try FileManager.default.copyItem(at: selectedURL, to: destination)
            applyImportedVideo(destination, displayName: selectedURL.lastPathComponent)
        } catch {
            errorMessage = "影片匯入失敗：\(error.localizedDescription)"
        }
    }

    private func applyImportedVideo(_ url: URL, displayName: String) {
        analysisTask?.cancel()
        isAnalyzing = false
        motionSignal = nil
        analysisMessage = nil
        videoURL = url
        videoOriginalName = displayName
        playback.load(url: url)
        exportedVideoURL = nil
        // Times from the demo or a previous video do not apply to this one.
        session.clearAllTimes()
        errorMessage = nil
        statusMessage = "影片匯入成功（\(displayName)）。播放到選手出發的瞬間按「0 m 出發」的標記，再依序標記轉身與出水。"
    }

    // MARK: Export

    private func exportVideo() {
        guard let videoURL else { return }
        let timeline: PoolTimeline
        do { timeline = try PoolTimeline(session: session, motion: motionSignal) }
        catch { errorMessage = "無法開始輸出：\(error.localizedDescription)"; return }

        // Always a new file; the imported video is never written to.
        let destination = ExportNaming.nextOutputURL(originalName: videoOriginalName ?? videoURL.lastPathComponent,
                                                     sourceURL: videoURL)
        playback.pause()
        isExporting = true
        exportProgress = 0
        exportClock = ExportProgressClock()
        exportedVideoURL = nil
        errorMessage = nil
        exportInfo = "正在分析來源影片並準備 MP4…"
        statusMessage = "開始輸出，請保持 App 在前景並避免中途關閉。"
        DiveVideoExporter().exportPool(
            videoURL: videoURL,
            timeline: timeline,
            settings: hudSettings,
            aspect: outputAspect,
            outputURL: destination,
            progress: { value in
                DispatchQueue.main.async { exportProgress = value }
            },
            completion: { result in
                DispatchQueue.main.async {
                    isExporting = false
                    switch result {
                    case .success(let outputURL):
                        exportedVideoURL = outputURL
                        ExportNaming.recordExport(at: outputURL, originalName: videoOriginalName ?? videoURL.lastPathComponent)
                        exportInfo = "MP4 已完成：\(outputURL.lastPathComponent)（\(outputSpecText.replacingOccurrences(of: "輸出規格：", with: ""))），已通過影片軌、尺寸、音訊及 MP4 容器檢查。"
                        Task { await saveExportToPhotos(outputURL) }
                    case .failure(let error):
                        errorMessage = "影片輸出失敗：\(error.localizedDescription)"
                        statusMessage = "輸出未完成，沒有產生可用影片。"
                    }
                }
            }
        )
    }

    @MainActor
    private func saveExportToPhotos(_ url: URL) async {
        let authorization = await withCheckedContinuation { (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized || authorization == .limited else {
            statusMessage = "影片已輸出並可透過分享按鈕另存；目前沒有照片新增權限。"
            return
        }
        do {
            try await PhotoLibrarySaver.saveNewVideo(at: url)
            statusMessage = "影片已另存為新的照片項目（\(url.lastPathComponent)），原始影片沒有被修改。"
        } catch {
            errorMessage = "影片已輸出，但儲存到照片失敗：\(error.localizedDescription)。可使用分享按鈕另存。"
        }
    }
}

private enum PoolVideoImportError: LocalizedError {
    case transferUnavailable
    case photoSaveFailed

    var errorDescription: String? {
        switch self {
        case .transferUnavailable: return "照片 App 沒有提供可讀取的影片檔案，請重新選擇或使用檔案 App 匯入。"
        case .photoSaveFailed: return "iOS 照片圖庫無法建立影片項目。"
        }
    }
}

/// Pool-mode stage: the imported video filling the chosen output shape (the same centre
/// crop as the export) with the editable pool HUD on top.
private struct PoolStageView: View {
    let playback: PlaybackController
    let timeline: PoolTimeline?
    @Binding var settings: PoolHUDSettings
    @Binding var selectedHUDItem: String
    let isEditing: Bool

    var body: some View {
        ZStack {
            Color.black
            PlayerLayerView(player: playback.player)
            PoolHUDOverlay(
                reading: timeline?.reading(atVideoTime: playback.currentTime),
                timeline: timeline,
                settings: $settings,
                selectedItem: $selectedHUDItem,
                isEditing: isEditing
            )
        }
    }
}

/// Floating 「預覽影像」 content for pool mode: the live video (the same player as the stage)
/// or the empty stage, with the HUD at the stage's proportions; not editable.
private struct PoolFloatingPreview: View {
    let playback: PlaybackController
    let timeline: PoolTimeline?
    let settings: PoolHUDSettings

    var body: some View {
        ZStack {
            if playback.hasVideo {
                PlayerLayerView(player: playback.player)
            } else {
                LinearGradient(colors: [Color(red: 0.05, green: 0.30, blue: 0.40), Color(red: 0.015, green: 0.075, blue: 0.11)],
                               startPoint: .top, endPoint: .bottom)
            }
            PoolHUDOverlay(
                reading: playback.hasVideo
                    ? timeline?.reading(atVideoTime: playback.currentTime)
                    : timeline.map { $0.reading(atVideoTime: $0.startTime + $0.totalTime * 0.5) },
                timeline: timeline,
                settings: .constant(settings),
                selectedItem: .constant(""),
                isEditing: false
            )
        }
    }
}

/// 「目前影片時間」, refreshed on its own during playback.
private struct PlaybackTimeLabel: View {
    let playback: PlaybackController

    var body: some View {
        Text(playback.hasVideo ? PoolFormat.preciseClock(playback.currentTime) : "尚未匯入影片")
            .font(.system(.footnote, design: .monospaced).weight(.bold))
            .foregroundStyle(playback.hasVideo ? DepthStudioColors.cyan : DepthStudioColors.muted)
    }
}
