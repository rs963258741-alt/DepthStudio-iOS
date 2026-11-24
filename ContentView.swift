import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var showingDiveLogPicker = false
    @State private var showingVideoPicker = false
    @State private var diveRecord: DiveRecord?
    @State private var diveLogFileName: String?
    @State private var diveLogFormat: String?
    @State private var videoURL: URL?
    @State private var player: AVPlayer?
    @State private var syncOffset = 0.0
    @State private var statusMessage = "請先匯入 Garmin FIT 或 ATMOS UDDF 潛水紀錄與影片。"
    @State private var errorMessage: String?
    @State private var isImportingDiveLog = false

    private var canPreview: Bool { diveRecord != nil && player != nil }
    private var diveLogContentTypes: [UTType] {
        var types: [UTType] = [.xml]
        if let fit = UTType(filenameExtension: "fit") { types.append(fit) }
        if let uddf = UTType(filenameExtension: "uddf") { types.append(uddf) }
        return types
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    HStack(spacing: 12) {
                        importCard(
                            title: "匯入潛水紀錄",
                            subtitle: diveRecord == nil
                                ? "Garmin FIT / ATMOS UDDF"
                                : "\(diveLogFormat ?? "潛水紀錄") · 已載入 \(diveRecord!.samples.count) 筆資料",
                            icon: "waveform.path",
                            action: { showingDiveLogPicker = true }
                        )
                        .disabled(isImportingDiveLog)

                        importCard(
                            title: "匯入影片",
                            subtitle: videoURL?.lastPathComponent ?? "MP4 / MOV 等影片",
                            icon: "video",
                            action: { showingVideoPicker = true }
                        )
                    }

                    if let record = diveRecord { diveSummary(record) }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                    if isImportingDiveLog {
                        HStack(spacing: 10) {
                            ProgressView().tint(.cyan)
                            Text("正在解析潛水紀錄…").font(.footnote).foregroundStyle(.secondary)
                        }
                    }

                    if canPreview, let player, let record = diveRecord {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("影片與數據預覽").font(.headline)
                            Text("先用單一時間偏移進行同步；雙錨點校正會在下一階段加入。")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Text("手錶時間偏移")
                                Spacer()
                                Text(String(format: "%+.1f 秒", syncOffset)).monospacedDigit()
                            }
                            Slider(value: $syncOffset, in: -300...300, step: 0.5)
                            if let sync = try? TimelineSync(offsetSeconds: syncOffset) {
                                DiveVideoPreview(
                                    player: player,
                                    samples: record.samples,
                                    sync: sync,
                                    maximumDepth: record.maximumDepthMeters ?? record.samples.map(\.depthMeters).max() ?? 10
                                )
                                .frame(minHeight: 360)
                            }
                        }
                    }
                    Text(statusMessage).font(.footnote).foregroundStyle(.secondary)
                }
                .padding()
            }
            .background(Color(red: 0.025, green: 0.055, blue: 0.08))
            .navigationTitle("Depth Studio")
            .fileImporter(
                isPresented: $showingDiveLogPicker,
                allowedContentTypes: diveLogContentTypes
            ) { result in
                loadDiveLog(result)
            }
            .fileImporter(
                isPresented: $showingVideoPicker,
                allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]
            ) { result in
                loadVideo(result)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DIVE DATA · VIDEO STUDIO")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(Color.cyan)
            Text("讓每一次下潛，都有數據可回看。")
                .font(.title2.bold())
            Text("匯入手錶紀錄，與任意運動相機影片進行時間同步。")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }

    private func importCard(title: String, subtitle: String, icon: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon).font(.title2).foregroundStyle(.cyan)
                Text(title).font(.headline).foregroundStyle(.white)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
            .padding(14)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.cyan.opacity(0.2), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func diveSummary(_ record: DiveRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("潛水紀錄摘要").font(.headline)
            HStack {
                summaryValue("最大深度", value: record.maximumDepthMeters.map { String(format: "%.1f m", $0) } ?? "—")
                summaryValue("平均深度", value: record.averageDepthMeters.map { String(format: "%.1f m", $0) } ?? "—")
                summaryValue("樣本數", value: "\(record.samples.count)")
            }
            if let model = record.computerModel {
                Text("裝置：\(model)").font(.caption).foregroundStyle(.secondary)
            }
            if let serial = record.serialNumber {
                Text("序號：\(serial)").font(.caption).foregroundStyle(.secondary)
            }
            if let date = record.dateTime {
                Text("紀錄時間：\(date)").font(.caption).foregroundStyle(.secondary)
            }
            if let fileName = diveLogFileName {
                Text("來源檔案：\(fileName)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16))
    }

    private func summaryValue(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(.cyan)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadDiveLog(_ result: Result<URL, Error>) {
        let url: URL
        do {
            url = try result.get()
        } catch {
            errorMessage = "潛水紀錄選取失敗：\(error.localizedDescription)"
            return
        }

        let fileExtension = url.pathExtension.lowercased()
        guard ["fit", "uddf", "xml"].contains(fileExtension) else {
            errorMessage = "不支援的潛水紀錄格式。請選擇 FIT、UDDF 或 XML。"
            return
        }

        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        isImportingDiveLog = true
        errorMessage = nil
        statusMessage = "正在讀取 \(url.lastPathComponent)…"

        // Read and parse off the main thread so larger FIT/UDDF logs do not
        // block playback controls or make the interface appear frozen.
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
            }

            do {
                let record: DiveRecord
                let formatLabel: String
                switch fileExtension {
                case "fit":
                    // Garmin's native decoder reads the security-scoped file URL
                    // directly and validates the FIT header and CRC before decode.
                    record = try GarminFITParser().parse(fileURL: url)
                    formatLabel = "Garmin FIT"
                default:
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    record = try AtmosUDDFParser().parse(data: data)
                    formatLabel = "ATMOS UDDF"
                }

                DispatchQueue.main.async {
                    diveRecord = record
                    diveLogFileName = url.lastPathComponent
                    diveLogFormat = formatLabel
                    isImportingDiveLog = false
                    errorMessage = nil
                    statusMessage = "\(formatLabel) 匯入成功。請匯入對應影片並調整時間偏移。"
                }
            } catch {
                DispatchQueue.main.async {
                    isImportingDiveLog = false
                    errorMessage = "\(fileExtension.uppercased()) 匯入失敗：\(error.localizedDescription)"
                    statusMessage = "請確認檔案完整，並且與影片屬於同一趟潛水。"
                }
            }
        }
    }

    private func loadVideo(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let access = url.startAccessingSecurityScopedResource()
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: url, to: destination)
                if access { url.stopAccessingSecurityScopedResource() }
            } catch {
                if access { url.stopAccessingSecurityScopedResource() }
                throw error
            }
            videoURL = destination
            player = AVPlayer(url: destination)
            errorMessage = nil
            statusMessage = "影片匯入成功。確認與手錶紀錄相同一趟潛水後，再調整時間偏移。"
        } catch {
            errorMessage = "影片匯入失敗：\(error.localizedDescription)"
        }
    }
}
