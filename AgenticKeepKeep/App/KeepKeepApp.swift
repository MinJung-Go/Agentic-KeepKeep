import SwiftData
import SwiftUI
import UIKit

@main
struct KeepKeepApp: App {
    @UIApplicationDelegateAdaptor(ModelDownloadAppDelegate.self) private var downloadDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(appearance.colorScheme)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        LocalModelStore.shared.enteredBackground()
                        Task { await LocalInferenceWorker.shared.unload() }
                    } else if phase == .active {
                        LocalModelStore.shared.becameActive()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                    Task { await LocalInferenceWorker.shared.unload() }
                }
        }
        .modelContainer(AppModelContainer.shared)
    }
}

/// Reconnects OS-owned transfers even when iOS launches us solely to deliver files.
final class ModelDownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = LocalModelStore.shared
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        LocalModelStore.shared.handleBackgroundEvents(identifier: identifier, completion: completionHandler)
    }
}
