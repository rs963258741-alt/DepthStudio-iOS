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
    @State private var player: AVPlayer?
    @State private var currentVideoTime: Double = 0

    @State private var finalDistanceDraft: Double = 150
    @State private var checkpointDistanceDraft: Double = 25
    @FocusState private var editingNumber: Bool
    @State private var timeEntryNodeID: UUID?
    @State private var timeEntryText = ""

    @State private var isExporting = false
    @State private var exportProgress = 0.0
    @State private var exportedVideoURL: URL?
    @State private var exportInfo = "輸出影片至少 4K（長邊 3840 px）；完成後可直接儲存到 iPhone 照片。"
    @State private var statusMessage = "已載入示範數據（50 m 泳池、150 m）。匯入平潛影片後，依序標記出發、轉身與出水時間。"
    @State private var errorMessage: String?

    private var timelineResult: Result<PoolTimeline, Error> { Result { try PoolTimeline(session: session) } }
    private var timeline: PoolTimeline? { try? timelineResult.get() }
    private var canExport: Bool { videoURL != nil && timeline != nil && !isExporting }
    private var videoContentTypes: [UTType] { [.movie, .mpeg4Movie, .quickTimeMovie] }

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DepthStudioColors.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .confirmationDialog("切換潛水模式？", isPresented: $confirmingModeSwitch, titleVisibility: .visible) {
            Button("回到模式選擇") { onSwitchMode?() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("目前匯入的影片與時間節點不會保留；HUD 外觀設定會保留。")
        }
        .alert("輸入影片時間", isPresented: timeEntryPresented) {
            TextField("例如 01:40.5", text: $timeEntryText)
                .keyboardType(.numbersAndPunctuation)
            Button("確定") { applyTimeEntry() }
            Button("取消", role: .cancel) { timeEntryNodeID = nil }
        } message: {
            Text("格式為 分:秒 或 分:秒.小數，也可以直接輸入秒數。")
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
        .onDisappear { player?.pause() }
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
                        Text(isImportingVideo ? "正在載入影片…" : (videoURL?.lastPathComponent ?? "直接選擇 iPhone 相簿影片"))
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
            HStack {
                sectionTitle("影像與 HUD 預覽", subtitle: "點選 HUD 項目後可拖曳、縮放及旋轉。")
                Spacer(minLength: 6)
                Button {
                    isEditingLayout.toggle()
                } label: {
                    Text(isEditingLayout ? "排版：開" : "排版：關")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isEditingLayout ? .black : DepthStudioColors.cyan)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(isEditingLayout ? DepthStudioColors.cyan : DepthStudioColors.background, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if let player {
                PoolVideoPreview(
                    player: player,
                    timeline: timeline,
                    settings: $hudSettings,
                    selectedHUDItem: $selectedHUDItem,
                    isEditing: isEditingLayout,
                    onTimeChange: { currentVideoTime = $0 }
                )
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
            }
        }
        .padding(14)
        .background(DepthStudioColors.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("02 / 泳池設定與時間節點",
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
                Text(player == nil ? "尚未匯入影片" : PoolFormat.preciseClock(currentVideoTime))
                    .font(.system(.footnote, design: .monospaced).weight(.bold))
                    .foregroundStyle(player == nil ? DepthStudioColors.muted : DepthStudioColors.cyan)
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
                    .foregroundStyle(node.videoTime == nil ? DepthStudioColors.muted : .white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .overlay(Capsule().stroke(DepthStudioColors.cyan.opacity(0.35), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(node.videoTime == nil || player == nil)
            .accessibilityLabel("跳到 \(PoolFormat.distance(node.distance)) 公尺的時間")

            Button { session.setTime(currentVideoTime, for: node.id) } label: {
                Text("標記")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(player == nil ? DepthStudioColors.muted : .black)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(player == nil ? Color.gray.opacity(0.3) : DepthStudioColors.cyan, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(player == nil)
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
            Text("基礎模式：節點之間以等速計算距離，速率為各段平均速率。AI 影像追蹤的浮動速率將在下一階段加入。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DepthStudioColors.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private var hudAppearanceSection: some View {
        DisclosureGroup(isExpanded: $editorExpanded) {
            VStack(alignment: .leading, spacing: 12) {
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
                sliderRow("HUD 透明度", value: $hudSettings.opacity, range: 0.2...1.0, suffix: "%", multiplier: 100)
                sliderRow("HUD 字體大小", value: $hudSettings.fontScale, range: 0.7...1.4, suffix: "%", multiplier: 100)
                sliderRow("HUD 整體垂直偏移", value: $hudSettings.verticalOffset, range: -15...25, suffix: "%")
                HStack {
                    Button("恢復預設位置") { hudSettings.resetLayout() }
                        .buttonStyle(.bordered).tint(DepthStudioColors.cyan)
                    Button("重設外觀") {
                        let name = hudSettings.displayName
                        let country = hudSettings.country
                        hudSettings = PoolHUDSettings()
                        hudSettings.displayName = name
                        hudSettings.country = country
                    }
                    .buttonStyle(.bordered).tint(DepthStudioColors.muted)
                }
                Text("排版模式開啟時，直接拖曳預覽中的任一 HUD 欄位；位置依畫面比例儲存，項目中心會吸附對齊其他可見欄位。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        } label: {
            sectionTitle("03 / HUD 外觀與自由排版", subtitle: "每個欄位可獨立移動、縮放與旋轉。")
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
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            sectionTitle("04 / HUD 資訊顯示與隱藏", subtitle: "單獨隱藏不會影響其他資訊欄位。")
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
            sectionTitle("05 / 姓名與國家旗幟", subtitle: "支援七個國家／地區。")
        }
        .tint(DepthStudioColors.cyan)
        .padding(14)
        .background(DepthStudioColors.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("06 / 輸出影片", subtitle: "輸出 MP4，長邊至少 3840 px，保留來源影像與音訊。")
            Button(action: exportVideo) {
                HStack {
                    if isExporting { ProgressView().tint(.black) }
                    Image(systemName: "4k.tv")
                    Text(isExporting ? "正在輸出影片…" : "輸出高畫質影片（至少 4K）")
                }
                .font(.headline.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(canExport ? DepthStudioColors.cyan : Color.gray.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(canExport ? .black : .white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .disabled(!canExport)

            if isExporting { ProgressView(value: exportProgress).tint(DepthStudioColors.cyan) }
            Text(isExporting ? "輸出進度 \(Int(exportProgress * 100))%" : exportInfo)
                .font(.caption2).foregroundStyle(.secondary)
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

    // MARK: Small views and bindings

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
                           suffix: String, multiplier: Double = 1) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text("\(Int((value.wrappedValue * multiplier).rounded()))\(suffix)")
                    .font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(DepthStudioColors.cyan)
            }
            Slider(value: value, in: range).tint(DepthStudioColors.cyan)
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
        guard let player, let time = node.videoTime else { return }
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func nudge(_ node: PoolNode, by delta: Double) {
        let base = node.videoTime ?? currentVideoTime
        session.setTime(max(0, base + delta), for: node.id)
    }

    private func beginTimeEntry(for node: PoolNode) {
        timeEntryText = node.videoTime.map(PoolFormat.preciseClock) ?? ""
        timeEntryNodeID = node.id
    }

    private func applyTimeEntry() {
        guard let id = timeEntryNodeID else { return }
        timeEntryNodeID = nil
        guard let seconds = PoolFormat.parseTime(timeEntryText) else {
            errorMessage = "無法辨識時間「\(timeEntryText)」，請輸入例如 01:40.5 或 100。"
            return
        }
        errorMessage = nil
        session.setTime(seconds, for: id)
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
            applyImportedVideo(imported.url, displayName: imported.url.lastPathComponent)
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
        player?.pause()
        videoURL = url
        player = AVPlayer(url: url)
        currentVideoTime = 0
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
        do { timeline = try PoolTimeline(session: session) }
        catch { errorMessage = "無法開始輸出：\(error.localizedDescription)"; return }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("DepthStudio_Pool_\(UUID().uuidString)_4K.mp4")
        player?.pause()
        isExporting = true
        exportProgress = 0
        exportedVideoURL = nil
        errorMessage = nil
        exportInfo = "正在分析來源影片並準備 4K MP4…"
        statusMessage = "開始輸出，請保持 App 在前景並避免中途關閉。"
        DiveVideoExporter().exportPool(
            videoURL: videoURL,
            timeline: timeline,
            settings: hudSettings,
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
                        exportInfo = "4K MP4 已完成，已通過影片軌、尺寸、音訊及 MP4 容器檢查。"
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
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }) { success, error in
                    if success { continuation.resume() }
                    else { continuation.resume(throwing: error ?? PoolVideoImportError.photoSaveFailed) }
                }
            }
            statusMessage = "4K 影片已成功儲存至 iPhone 照片。"
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

/// Video player with the pool HUD on top. Reports the playback time so the timeline
/// section can mark points at the current frame.
private struct PoolVideoPreview: View {
    let player: AVPlayer
    let timeline: PoolTimeline?
    @Binding var settings: PoolHUDSettings
    @Binding var selectedHUDItem: String
    let isEditing: Bool
    let onTimeChange: (Double) -> Void

    @StateObject private var clock: DivePlayerClock

    init(player: AVPlayer, timeline: PoolTimeline?, settings: Binding<PoolHUDSettings>,
         selectedHUDItem: Binding<String>, isEditing: Bool, onTimeChange: @escaping (Double) -> Void) {
        self.player = player
        self.timeline = timeline
        self._settings = settings
        self._selectedHUDItem = selectedHUDItem
        self.isEditing = isEditing
        self.onTimeChange = onTimeChange
        _clock = StateObject(wrappedValue: DivePlayerClock(player: player))
    }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.black
                VideoPlayer(player: player)
                    .background(Color.black)
                PoolHUDOverlay(
                    reading: timeline?.reading(atVideoTime: clock.currentVideoTime),
                    timeline: timeline,
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

                Text("\(PoolFormat.clock(clock.currentVideoTime)) / \(PoolFormat.clock(clock.duration))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            // Frame stepping for precise marking (about one frame at 30 fps, or 0.5 s).
            HStack(spacing: 8) {
                ForEach([-0.5, -0.033, 0.033, 0.5], id: \.self) { step in
                    Button(step > 0 ? String(format: "+%.2gs", step) : String(format: "%.2gs", step)) {
                        player.pause()
                        clock.seek(to: clock.currentVideoTime + step)
                    }
                    .font(.caption.monospacedDigit())
                    .buttonStyle(.bordered)
                    .tint(DepthStudioColors.muted)
                }
            }
        }
        .onChange(of: clock.currentVideoTime) { _, newValue in onTimeChange(newValue) }
    }
}
