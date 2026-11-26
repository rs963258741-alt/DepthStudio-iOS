import SwiftUI

/// 泳池平潛 mode. Placeholder screen until the pool HUD, data import and export are built.
struct PoolModeView: View {
    var onSwitchMode: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                if let onSwitchMode {
                    ModeSwitchButton(title: "泳池平潛", action: onSwitchMode)
                }
                Image("JiaoliuLogo")
                    .resizable().scaledToFit()
                    .frame(width: 54, height: 46)
                    .accessibilityLabel("蕉流自潛")
            }
            .padding(.vertical, 5)

            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "figure.pool.swim")
                    .font(.system(size: 56, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                Text("泳池平潛介面建置中")
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Text("距離、趟數、時間與速度 HUD 即將加入。")
                    .font(.footnote)
                    .foregroundStyle(DepthStudioColors.muted)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DepthStudioColors.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}
