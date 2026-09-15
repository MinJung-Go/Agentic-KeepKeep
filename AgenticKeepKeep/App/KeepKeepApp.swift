import SwiftData
import SwiftUI

@main
struct KeepKeepApp: App {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(appearance.colorScheme)
        }
        .modelContainer(AppModelContainer.shared)
    }
}
