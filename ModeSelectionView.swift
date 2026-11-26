import SwiftUI

/// The two kinds of footage the app works with. Chosen at launch; each has its own screen.
enum DiveMode: String, CaseIterable, Identifiable {
    case depth
    case pool

    var id: String { rawValue }

    var title: String {
        switch self {
        case .depth: return "深度潛水"
        case .pool: return "泳池平潛"
        }
    }

    var tag: String {
        switch self {
        case .depth: return "DEPTH · OPEN WATER"
        case .pool: return "POOL · DYNAMIC APNEA"
        }
    }

    var subtitle: String {
        switch self {
        case .depth: return "海洋／深潛池的垂直下潛。匯入 Garmin FIT 或 ATMOS UDDF，疊加深度、時間、水溫與下潛曲線。"
        case .pool: return "泳池水平閉氣潛泳（DYN／DYNB／DNF）。疊加距離、趟數、時間與速度。"
        }
    }

    var icon: String {
        switch self {
        case .depth: return "arrow.down.to.line"
        case .pool: return "figure.pool.swim"
        }
    }

    var highlights: [String] {
        switch self {
        case .depth: return ["深度", "下潛曲線", "水溫", "垂直速度"]
        case .pool: return ["距離", "趟數", "時間", "速度"]
        }
    }
}

/// First screen after the launch animation: pick 深度潛水 or 泳池平潛.
struct ModeSelectionView: View {
    let onSelect: (DiveMode) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                VStack(alignment: .leading, spacing: 6) {
                    Text("選擇潛水模式")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Text("兩種模式使用不同的數據與 HUD 介面。進入後可從右上角的模式按鈕回到這裡。")
                        .font(.footnote)
                        .foregroundStyle(DepthStudioColors.muted)
                }
                .padding(.top, 8)

                ForEach(DiveMode.allCases) { mode in
                    Button { onSelect(mode) } label: { ModeCard(mode: mode) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("進入\(mode.title)模式")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.hidden)
        .background(DepthStudioColors.background.ignoresSafeArea())
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
}

private struct ModeCard: View {
    let mode: DiveMode

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle().fill(DepthStudioColors.cyan.opacity(0.14))
                    Circle().stroke(DepthStudioColors.cyan.opacity(0.45), lineWidth: 1)
                    Image(systemName: mode.icon)
                        .font(.system(size: 28, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.white)
                }
                .frame(width: 62, height: 62)

                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.tag)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.6)
                        .foregroundStyle(DepthStudioColors.cyan)
                    Text(mode.title)
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(DepthStudioColors.muted)
            }

            Text(mode.subtitle)
                .font(.footnote)
                .foregroundStyle(DepthStudioColors.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                ForEach(mode.highlights, id: \.self) { item in
                    Text(item)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.07)))
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(DepthStudioColors.card))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .stroke(DepthStudioColors.cyan.opacity(0.22), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Small capsule in each mode's header showing the current mode; tapping returns to the picker.
struct ModeSwitchButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.left.arrow.right")
                Text(title)
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(DepthStudioColors.cyan)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(DepthStudioColors.cyan.opacity(0.12)))
            .overlay(Capsule().stroke(DepthStudioColors.cyan.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("目前為\(title)模式，點一下切換模式")
    }
}
