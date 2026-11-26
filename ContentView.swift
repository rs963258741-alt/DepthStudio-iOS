import SwiftUI
import AVKit
import UniformTypeIdentifiers
import PhotosUI
import CoreTransferable
import Photos

private enum DepthStudioColors {
    static let background = Color(red: 0.025, green: 0.055, blue: 0.08)
    static let card = Color(red: 0.045, green: 0.085, blue: 0.105)
    static let cyan = Color(red: 0.24, green: 0.87, blue: 0.97)
    static let muted = Color(red: 0.55, green: 0.70, blue: 0.75)
}

/// PhotosPicker's temporary movie URL is copied while the transfer remains valid.
private struct ImportedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let source = received.file
            let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("DepthStudio-\(UUID().uuidString)")
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: source, to: destination)
            return ImportedMovie(url: destination)
        }
    }
}

private enum FileImportKind: Equatable { case diveLog, video }

struct ContentView: View {
    @State private var hudSettings = HUDSettings.load()
    @State private var selectedHUDItem = "depthValue"
    @State private var isEditingLayout = true
    @State private var editorExpanded = true
    @State private var identityExpanded = false
    @State private var visibilityExpanded = false

    @State private var showingLaunchAnimation = true
    @State private var showingFileImporter = false
    @State private var fileImportKind: FileImportKind?
    @State private var selectedPhotoVideo: PhotosPickerItem?
    @State private var diveRecord: DiveRecord? = Self.demoDiveRecord
    @State private var diveLogFileName: String? = "V8.18 示範資料"
    @State private var diveLogFormat: String? = "示範潛水紀錄"
    @State private var videoURL: URL?
    @State private var player: AVPlayer?

    @State private var statusMessage = "已載入示範潛水資料。請匯入 iPhone 照片中的影片及你的 FIT／UDDF 紀錄。"
    @State private var errorMessage: String?
    @State private var isImportingDiveLog = false
    @State private var isImportingVideo = false
    @State private var isExporting = false
    @State private var exportProgress = 0.0
    @State private var exportedVideoURL: URL?
    @State private var exportInfo = "輸出影片至少 4K（長邊 3840 px）；完成後可直接儲存到 iPhone 照片。"

    private var diveLogContentTypes: [UTType] {
        var types: [UTType] = [.data, .xml]
        if let fit = UTType(filenameExtension: "fit", conformingTo: .data) { types.append(fit) }
        if let uddf = UTType(filenameExtension: "uddf", conformingTo: .data) { types.append(uddf) }
        return types
    }

    private var videoContentTypes: [UTType] { [.movie, .mpeg4Movie, .quickTimeMovie] }
    private var canExport: Bool { videoURL != nil && (diveRecord?.samples.count ?? 0) >= 2 && !isExporting }
    private var maximumDepth: Double { diveRecord?.maximumDepthMeters ?? diveRecord?.samples.map(\.depthMeters).max() ?? 10 }
    private var deviceName: String { diveRecord?.computerModel ?? "DEPTH STUDIO" }

    var body: some View {
        ZStack {
            DepthStudioColors.background.ignoresSafeArea()

            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        importSection
                        previewSection
                        if let diveRecord { diveSummary(diveRecord) }
                        hudAppearanceSection
                        visibilitySection
                        identitySection
                        syncSection
                        exportSection
                        statusSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 34)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollIndicators(.hidden)
                .toolbar(.hidden, for: .navigationBar)
                .background(.clear)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.clear)

            if showingLaunchAnimation {
                DepthStudioLaunchAnimation()
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DepthStudioColors.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden(showingLaunchAnimation)
        .fileImporter(isPresented: $showingFileImporter,
                      allowedContentTypes: fileImportKind == .video ? videoContentTypes : diveLogContentTypes) { result in
            guard let kind = fileImportKind else { return }
            fileImportKind = nil
            switch kind {
            case .diveLog: loadDiveLog(result)
            case .video: loadVideo(result)
            }
        }
        .onChange(of: selectedPhotoVideo) { _, item in
            guard let item else { return }
            Task { await importVideoFromPhotos(item) }
        }
        .onChange(of: hudSettings) { _, newValue in newValue.save() }
        .onChange(of: hudSettings.displayName) { _, newValue in
            if newValue.count > 30 { hudSettings.displayName = String(newValue.prefix(30)) }
        }
        .task {
            try? await Task.sleep(nanoseconds: 2_700_000_000)
            withAnimation(.easeInOut(duration: 0.55)) { showingLaunchAnimation = false }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("DEPTH STUDIO")
                    .font(.system(size: 25, weight: .black, design: .rounded))
                    .tracking(1.2).foregroundStyle(.white)
                Text("DIVE DATA · VIDEO STUDIO")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .tracking(2.2).foregroundStyle(DepthStudioColors.cyan)
            }
            Spacer()
            Image("JiaoliuLogo")
                .resizable().scaledToFit()
                .frame(width: 54, height: 46)
                .accessibilityLabel("蕉流自潛")
        }
        .padding(.vertical, 5)
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("01 / 匯入素材", subtitle: "支援 iPhone 照片影片、MP4／MOV、ATMOS UDDF 及 Garmin FIT。")
            HStack(alignment: .top, spacing: 10) {
                importCard(title: "匯入潛水紀錄",
                           subtitle: isImportingDiveLog ? "正在解析數據…" : (diveLogFileName ?? "Garmin FIT / ATMOS UDDF"),
                           icon: "waveform.path", loading: isImportingDiveLog) {
                    beginFileImport(.diveLog)
                }
                PhotosPicker(selection: $selectedPhotoVideo, matching: .videos, photoLibrary: .shared()) {
                    importCardLabel(title: "從照片匯入影片",
                                    subtitle: isImportingVideo ? "正在載入影片…" : (videoURL?.lastPathComponent ?? "直接選擇 iPhone 相簿影片"),
                                    icon: "photo.on.rectangle", loading: isImportingVideo)
                }
                .buttonStyle(.plain)
                .disabled(isImportingVideo)
            }
            HStack {
                Button { beginFileImport(.video) } label: {
                    Label("或從檔案 App 選取影片", systemImage: "folder")
                        .font(.footnote.weight(.semibold)).foregroundStyle(DepthStudioColors.cyan)
                }
                .buttonStyle(.plain)
                Spacer()
                Button { loadDemoData() } label: {
                    Label("載入示範資料", systemImage: "waveform.path.ecg")
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
                        .background(isEditingLayout ? DepthStudioColors.cyan : DepthStudioColors.background,
                                    in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if let player, let record = diveRecord,
               let sync = try? TimelineSync(offsetSeconds: hudSettings.syncOffset) {
                DiveVideoPreview(
                    player: player,
                    samples: record.samples,
                    sync: sync,
                    maximumDepth: maximumDepth,
                    deviceName: deviceName,
                    settings: $hudSettings,
                    selectedHUDItem: $selectedHUDItem,
                    isEditing: isEditingLayout
                )
            } else {
                GeometryReader { proxy in
                    ZStack {
                        LinearGradient(colors: [Color(red: 0.04, green: 0.20, blue: 0.28),
                                                Color(red: 0.015, green: 0.055, blue: 0.085)],
                                       startPoint: .top, endPoint: .bottom)
                        VStack(spacing: 8) {
                            Image(systemName: "video.badge.plus")
                                .font(.system(size: 30, weight: .light)).foregroundStyle(DepthStudioColors.cyan)
                            Text("匯入潛水影片以開始預覽")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            Text("HUD 位置可先在畫面上調整")
                                .font(.caption).foregroundStyle(DepthStudioColors.muted)
                        }
                    }
                    .overlay {
                        if let record = diveRecord {
                            DiveHUDOverlay(
                                reading: (try? DiveDataInterpolator(samples: record.samples))?.reading(at: 11.8),
                                samples: record.samples,
                                maximumDepth: maximumDepth,
                                deviceName: deviceName,
                                settings: $hudSettings,
                                selectedItem: $selectedHUDItem,
                                isEditing: isEditingLayout
                            )
                        }
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

    private var hudAppearanceSection: some View {
        DisclosureGroup(isExpanded: $editorExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("目前編輯項目", selection: $selectedHUDItem) {
                    ForEach(HUDItemDefinition.all) { item in Text(item.title).tag(item.id) }
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
                    Button("重設此項目") {
                        hudSettings.transforms[selectedHUDItem] = HUDTransform()
                        hudSettings.save()
                    }
                }
                .buttonStyle(.bordered).tint(DepthStudioColors.muted)

                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                sliderRow("HUD 透明度", value: $hudSettings.opacity, range: 0.2...1.0, suffix: "%", multiplier: 100)
                sliderRow("HUD 字體大小", value: $hudSettings.fontScale, range: 0.7...1.4, suffix: "%", multiplier: 100)
                sliderRow("HUD 整體垂直偏移", value: $hudSettings.verticalOffset, range: -15...25, suffix: "%")
                HStack {
                    Button("恢復預設位置") {
                        hudSettings.resetLayout()
                        hudSettings.save()
                    }
                    .buttonStyle(.bordered).tint(DepthStudioColors.cyan)
                    Button("重設外觀") {
                        hudSettings = HUDSettings()
                        hudSettings.save()
                    }
                    .buttonStyle(.bordered).tint(DepthStudioColors.muted)
                }
                Text("排版模式開啟時，直接拖曳預覽中的任一 HUD 欄位；位置會依畫面比例儲存，項目中心會吸附對齊其他可見欄位。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        } label: {
            sectionTitle("02 / HUD 外觀與自由排版", subtitle: "每個欄位可獨立移動、縮放與旋轉。")
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
                    ForEach(HUDItemDefinition.all) { item in
                        Toggle(item.title, isOn: visibilityBinding(for: item.id))
                            .font(.caption)
                            .tint(DepthStudioColors.cyan)
                            .toggleStyle(.switch)
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            sectionTitle("03 / HUD 資訊顯示與隱藏", subtitle: "單獨隱藏不會影響其他資訊欄位。")
        }
        .tint(DepthStudioColors.cyan)
        .padding(14)
        .background(DepthStudioColors.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var identitySection: some View {
        DisclosureGroup(isExpanded: $identityExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("姓名（最多 30 字）", text: $hudSettings.displayName)
                    .onChange(of: hudSettings.displayName) { _, newValue in
                        if newValue.count > 30 { hudSettings.displayName = String(newValue.prefix(30)) }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(11)
                    .background(DepthStudioColors.background, in: RoundedRectangle(cornerRadius: 10))
                Picker("國家／地區", selection: $hudSettings.country) {
                    ForEach(HUDCountryOption.all) { option in Text(option.title).tag(option.id) }
                }
                Picker("潛水種類", selection: $hudSettings.divingType) {
                    ForEach(HUDSettings.diveTypes, id: \.self) { type in Text(type).tag(type) }
                }
                sliderRow("姓名、國旗與潛水種類共同大小", value: $hudSettings.identityScale, range: 0.6...1.8, suffix: "%", multiplier: 100)
                Text("國旗、姓名及潛水種類會作為同一組一起移動、縮放與旋轉。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        } label: {
            sectionTitle("04 / 姓名與國家旗幟", subtitle: "支援七個國家／地區及六種潛水種類。")
        }
        .tint(DepthStudioColors.cyan)
        .padding(14)
        .background(DepthStudioColors.card, in: RoundedRectangle(cornerRadius: 18))
    }

    private var syncSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("05 / 潛水紀錄摘要與時間同步", subtitle: "影片與手錶紀錄時間差，支援 -120 至 +120 秒。")
            HStack {
                Text("影片與潛水資料時間差")
                Spacer()
                Text(String(format: "%+.1f 秒", hudSettings.syncOffset)).monospacedDigit().foregroundStyle(DepthStudioColors.cyan)
            }
            Slider(value: $hudSettings.syncOffset, in: -120...120, step: 0.5).tint(DepthStudioColors.cyan)
            if let diveRecord { diveSummary(diveRecord) }
        }
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

    private var currentRotation: Double { hudSettings.transforms[selectedHUDItem]?.rotation ?? 0 }
    private var selectedScaleBinding: Binding<Double> {
        Binding(get: { hudSettings.transforms[selectedHUDItem]?.scale ?? 1 }, set: { value in
            var transform = hudSettings.transforms[selectedHUDItem] ?? HUDTransform()
            transform.scale = value; hudSettings.transforms[selectedHUDItem] = transform
        })
    }
    private var selectedRotationBinding: Binding<Double> {
        Binding(get: { currentRotation }, set: { setSelectedRotation($0, snap: false) })
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline.weight(.bold)).foregroundStyle(Color(red: 0.67, green: 0.91, blue: 0.98))
            Text(subtitle).font(.caption2).foregroundStyle(DepthStudioColors.muted)
        }
    }

    private func importCard(title: String, subtitle: String, icon: String, loading: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            importCardLabel(title: title, subtitle: subtitle, icon: icon, loading: loading)
        }
        .buttonStyle(.plain)
        .disabled(loading)
    }

    private func importCardLabel(title: String, subtitle: String, icon: String, loading: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).font(.title2).foregroundStyle(DepthStudioColors.cyan)
                Spacer(minLength: 0)
                if loading { ProgressView().tint(DepthStudioColors.cyan) }
            }
            Text(title).font(.subheadline.weight(.bold)).foregroundStyle(.white)
            Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
        }
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
        .padding(12)
        .background(DepthStudioColors.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(DepthStudioColors.cyan.opacity(0.22), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 14))
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

    private func diveSummary(_ record: DiveRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("潛水紀錄摘要").font(.subheadline.weight(.bold))
            HStack(spacing: 8) {
                summaryValue("最大深度", value: record.maximumDepthMeters.map { String(format: "%.1f m", $0) } ?? "—")
                summaryValue("平均深度", value: record.averageDepthMeters.map { String(format: "%.1f m", $0) } ?? "—")
                summaryValue("紀錄時間", value: record.durationSeconds.map(timeLabel) ?? "—")
            }
            if let model = record.computerModel { Text("裝置：\(model)").font(.caption2).foregroundStyle(.secondary) }
            if let serial = record.serialNumber { Text("序號：\(serial)").font(.caption2).foregroundStyle(.secondary) }
            if let date = record.dateTime { Text("紀錄時間：\(date)").font(.caption2).foregroundStyle(.secondary) }
            if let fileName = diveLogFileName { Text("來源：\(fileName)").font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DepthStudioColors.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private func summaryValue(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(DepthStudioColors.cyan)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func beginFileImport(_ kind: FileImportKind) {
        errorMessage = nil
        fileImportKind = kind
        showingFileImporter = true
    }

    private func copyToTemporaryDirectory(_ sourceURL: URL) throws -> URL {
        let ext = sourceURL.pathExtension.isEmpty ? "dat" : sourceURL.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("DepthStudio-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    private func loadDiveLog(_ result: Result<URL, Error>) {
        let selectedURL: URL
        do { selectedURL = try result.get() }
        catch { errorMessage = "潛水紀錄選取失敗：\(error.localizedDescription)"; return }

        let ext = selectedURL.pathExtension.lowercased()
        guard ["fit", "uddf", "xml"].contains(ext) else {
            errorMessage = "不支援的潛水紀錄格式。請選擇 FIT、UDDF 或 XML。"
            statusMessage = "請確認你選取的是單筆潛水紀錄原始檔。"
            return
        }
        let access = selectedURL.startAccessingSecurityScopedResource()
        let localURL: URL
        do {
            localURL = try copyToTemporaryDirectory(selectedURL)
            if access { selectedURL.stopAccessingSecurityScopedResource() }
        } catch {
            if access { selectedURL.stopAccessingSecurityScopedResource() }
            errorMessage = "無法複製潛水紀錄：\(error.localizedDescription)"
            return
        }

        isImportingDiveLog = true
        errorMessage = nil
        statusMessage = "正在讀取 \(selectedURL.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? FileManager.default.removeItem(at: localURL) }
            do {
                let record: DiveRecord
                let format: String
                switch ext {
                case "fit": record = try GarminFITParser().parse(fileURL: localURL); format = "Garmin FIT"
                default:
                    record = try AtmosUDDFParser().parse(data: Data(contentsOf: localURL, options: .mappedIfSafe))
                    format = "ATMOS UDDF"
                }
                DispatchQueue.main.async {
                    diveRecord = record
                    diveLogFileName = selectedURL.lastPathComponent
                    diveLogFormat = format
                    isImportingDiveLog = false
                    errorMessage = nil
                    statusMessage = "\(format) 匯入成功：\(record.samples.count) 筆深度樣本。"
                }
            } catch {
                DispatchQueue.main.async {
                    isImportingDiveLog = false
                    errorMessage = "\(ext.uppercased()) 匯入失敗：\(error.localizedDescription)"
                    statusMessage = "原有潛水資料保持不變；請確認檔案完整且屬於單筆潛水紀錄。"
                }
            }
        }
    }

    @MainActor
    private func importVideoFromPhotos(_ item: PhotosPickerItem) async {
        isImportingVideo = true
        errorMessage = nil
        statusMessage = "正在從 iPhone 照片載入影片…"
        defer { isImportingVideo = false; selectedPhotoVideo = nil }
        do {
            guard let imported = try await item.loadTransferable(type: ImportedMovie.self) else {
                throw VideoImportError.transferUnavailable
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
        do {
            let localURL = try copyToTemporaryDirectory(selectedURL)
            if access { selectedURL.stopAccessingSecurityScopedResource() }
            applyImportedVideo(localURL, displayName: selectedURL.lastPathComponent)
        } catch {
            if access { selectedURL.stopAccessingSecurityScopedResource() }
            errorMessage = "影片匯入失敗：\(error.localizedDescription)"
        }
    }

    private func applyImportedVideo(_ url: URL, displayName: String) {
        player?.pause()
        videoURL = url
        player = AVPlayer(url: url)
        exportedVideoURL = nil
        statusMessage = "影片匯入成功（\(displayName)）。請確認與手錶紀錄相同一趟潛水，再微調時間差。"
        errorMessage = nil
    }

    private func loadDemoData() {
        diveRecord = Self.demoDiveRecord
        diveLogFileName = "V8.18 示範資料"
        diveLogFormat = "示範潛水紀錄"
        statusMessage = "已載入 ATMOS Mission2 示範紀錄：37 個 waypoint，最大深度 11.9 m。"
        errorMessage = nil
    }

    private func exportVideo() {
        guard let videoURL, let record = diveRecord else { return }
        do {
            let sync = try TimelineSync(offsetSeconds: hudSettings.syncOffset)
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("DepthStudio_\(UUID().uuidString)_4K.mp4")
            isExporting = true
            exportProgress = 0
            exportedVideoURL = nil
            exportInfo = "正在分析來源影片並準備 4K MP4…"
            statusMessage = "開始輸出，請保持 App 在前景並避免中途關閉。"
            let settings = DiveExportSettings(hudSettings: hudSettings, deviceName: record.computerModel ?? "DEPTH STUDIO")
            DiveVideoExporter().export(videoURL: videoURL, samples: record.samples, maximumDepth: maximumDepth, sync: sync,
                                       settings: settings, outputURL: destination,
                                       progress: { value in
                DispatchQueue.main.async { exportProgress = value }
            }, completion: { result in
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
            })
        } catch {
            errorMessage = "無法開始輸出：\(error.localizedDescription)"
        }
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
                    else { continuation.resume(throwing: error ?? PhotoSaveError.saveFailed) }
                }
            }
            statusMessage = "4K 影片已成功儲存至 iPhone 照片。"
        } catch {
            errorMessage = "影片已輸出，但儲存到照片失敗：\(error.localizedDescription)。可使用分享按鈕另存。"
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    private static let demoDiveRecord: DiveRecord = {
        let depths: [Double] = [0, 2.3, 3, 3.3, 3.4, 3.9, 5, 5.7, 6.5, 7.7, 8.3, 8.8, 9.1, 9.9, 10.5, 11.2, 11.5, 11.9, 11.9, 11.9, 11.9, 11.2, 10.8, 10.1, 9.5, 8.8, 8.2, 7.5, 6.8, 5.9, 5.2, 4.3, 3.5, 2.7, 1.8, 0.9, 0]
        let samples = depths.enumerated().map { index, depth in
            DiveSample(id: index, elapsedSeconds: Double(index), depthMeters: depth, temperatureCelsius: 29.4)
        }
        return DiveRecord(manufacturer: "ATMOS", computerModel: "ATMOS MISSION 2", serialNumber: nil,
                          dateTime: nil, durationSeconds: 36, maximumDepthMeters: 11.9,
                          averageDepthMeters: 6.9, samples: samples)
    }()
}

private enum VideoImportError: LocalizedError {
    case transferUnavailable
    var errorDescription: String? {
        "照片 App 沒有提供可讀取的影片檔案，請重新選擇或使用檔案 App 匯入。"
    }
}

private enum PhotoSaveError: LocalizedError {
    case saveFailed
    var errorDescription: String? { "iOS 照片圖庫無法建立影片項目。" }
}

private struct DepthStudioLaunchAnimation: View {
    @State private var ringProgress: CGFloat = 0
    @State private var wavePhase: CGFloat = 0
    @State private var glow = false
    @State private var titleVisible = false

    var body: some View {
        ZStack {
            DepthStudioColors.background.ignoresSafeArea()
            RadialGradient(colors: [DepthStudioColors.cyan.opacity(0.16), .clear], center: .center,
                           startRadius: 20, endRadius: 320).ignoresSafeArea()
            VStack(spacing: 15) {
                // The white/silver logo variant is used because it remains legible on the dark ocean background.
                Image("JiaoliuLogo")
                    .resizable().scaledToFit().frame(width: 56, height: 46)
                    .opacity(titleVisible ? 1 : 0.15)
                    .shadow(color: DepthStudioColors.cyan.opacity(0.3), radius: 8)

                ZStack {
                    Circle().stroke(DepthStudioColors.cyan.opacity(0.10), lineWidth: 1).frame(width: 156, height: 156)
                    Circle().trim(from: 0, to: ringProgress)
                        .stroke(AngularGradient(colors: [.white.opacity(0.9), DepthStudioColors.cyan, .white.opacity(0.25)], center: .center),
                                style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: 156, height: 156)
                    Circle().fill(DepthStudioColors.cyan.opacity(glow ? 0.12 : 0.04))
                        .frame(width: 116, height: 116).blur(radius: glow ? 20 : 10)
                    Image(systemName: "figure.pool.swim")
                        .font(.system(size: 68, weight: .light)).symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white).shadow(color: DepthStudioColors.cyan.opacity(0.75), radius: glow ? 20 : 6)
                    Circle().fill(DepthStudioColors.cyan).frame(width: 6, height: 6)
                        .offset(x: 71, y: -31).shadow(color: DepthStudioColors.cyan, radius: 8)
                }

                VStack(spacing: 7) {
                    Text("DEPTH STUDIO")
                        .font(.system(size: 15, weight: .heavy, design: .rounded)).tracking(4.5)
                        .foregroundStyle(DepthStudioColors.cyan)
                    Text("DIVE DATA · VIDEO STUDIO")
                        .font(.system(size: 9, weight: .bold, design: .rounded)).tracking(2.4)
                        .foregroundStyle(DepthStudioColors.muted)
                }
                .opacity(titleVisible ? 1 : 0).offset(y: titleVisible ? 0 : 10)

                ZStack {
                    AnimatedOceanWave(phase: wavePhase, amplitude: 6).fill(DepthStudioColors.cyan.opacity(0.16)).frame(height: 38)
                    AnimatedOceanWave(phase: wavePhase + 1.1, amplitude: 4.5).stroke(DepthStudioColors.cyan.opacity(0.75), lineWidth: 1.4).frame(height: 38)
                }
                .frame(maxWidth: 215).padding(.top, 4)
            }
            .padding(.horizontal, 28)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.15)) { ringProgress = 1 }
            withAnimation(.easeInOut(duration: 1.0).delay(0.25)) { titleVisible = true }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { glow = true }
            withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) { wavePhase = .pi * 2 }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("蕉流自潛 Depth Studio 啟動畫面")
    }
}

private struct AnimatedOceanWave: Shape {
    var phase: CGFloat
    var amplitude: CGFloat
    var animatableData: CGFloat { get { phase } set { phase = newValue } }
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 64
        for step in 0...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let x = progress * rect.width
            let y = rect.midY + sin(progress * .pi * 2 + phase) * amplitude
            if step == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
