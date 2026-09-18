import SwiftData
import SwiftUI
import UIKit

@main
struct KeepKeepApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(appearance.colorScheme)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        LocalModelStore.shared.pause()
                        Task { await LocalInferenceWorker.shared.unload() }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    Task { await LocalInferenceWorker.shared.unload() }
                }
        }
        .modelContainer(AppModelContainer.shared)
    }
}
