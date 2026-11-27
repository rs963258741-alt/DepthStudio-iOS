import SwiftUI

@main
struct DepthStudioApp: App {
    init() {
        // UI tests start from the built-in layouts so their drag checks are repeatable.
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset") {
            let keys = [HUDSettings.storageKey, PoolHUDSettings.storageKey]
                + Array(HUDSettings.presetKeys.values) + Array(PoolHUDSettings.presetKeys.values)
            for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    var body: some Scene {
        WindowGroup {
            DepthStudioRootView()
                .preferredColorScheme(.dark)
        }
    }
}
