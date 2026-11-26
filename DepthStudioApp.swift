import SwiftUI

@main
struct DepthStudioApp: App {
    init() {
        // UI tests start from the built-in layouts so their drag checks are repeatable.
        if ProcessInfo.processInfo.arguments.contains("-uitest-reset") {
            for key in [HUDSettings.storageKey, HUDSettings.customDefaultLayoutKey,
                        PoolHUDSettings.storageKey, PoolHUDSettings.customDefaultLayoutKey] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            DepthStudioRootView()
                .preferredColorScheme(.dark)
        }
    }
}
