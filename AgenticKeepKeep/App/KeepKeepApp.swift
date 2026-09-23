import SwiftUI
import UIKit

@main
struct KeepKeepApp: App {
    @UIApplicationDelegateAdaptor(ModelDownloadAppDelegate.self) private var downloadDelegate
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system
    var body: some Scene {
        WindowGroup {
            AuthGateView().preferredColorScheme(appearance.colorScheme)
        }
    }
}

/// Reconnect only to cancel legacy OS-owned downloads; never instantiate the model store.
final class ModelDownloadAppDelegate: NSObject, UIApplicationDelegate, URLSessionDelegate {
    private var sessions: [URLSession] = []
    private var completions: [String: () -> Void] = [:]
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppModelContainer.lockWidget()
        UserDefaults.standard.set(false, forKey: "llm.useLocalModel")
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("localMilo.mlx.backgroundDownloadActive.") {
            UserDefaults.standard.set(false, forKey: key)
        }
        for suffix in ["wifi", "cellular"] {
            let configuration = URLSessionConfiguration.background(withIdentifier: "com.minjung.keepkeep.local-model.modelscope.v1." + suffix)
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
            sessions.append(session)
            session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        }
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard sessions.contains(where: { $0.configuration.identifier == identifier }) else { completionHandler(); return }
        completions[identifier] = completionHandler
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        completions.removeValue(forKey: identifier)?()
    }
}
