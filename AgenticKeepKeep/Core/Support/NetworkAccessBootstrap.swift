import Foundation

/// Makes the first network attempt while onboarding is visible. iOS owns any
/// regional network-consent alert; this is not a permission-status API.
@MainActor
final class NetworkAccessBootstrap {
    static let shared = NetworkAccessBootstrap()
    static let attemptedKey = "onboarding.networkAccessAttempted.v1"
    private let defaults: UserDefaults
    private let send: (URLRequest) async throws -> Void

    init(defaults: UserDefaults = .standard, send: ((URLRequest) async throws -> Void)? = nil) {
        self.defaults = defaults
        self.send = send ?? { request in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 8
            configuration.timeoutIntervalForResource = 8
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            _ = try await session.data(for: request)
        }
    }

    func requestOnce() async {
        guard !Task.isCancelled, !defaults.bool(forKey: Self.attemptedKey) else { return }
        // Set before suspension: view recreation or concurrent tasks must not retry.
        defaults.set(true, forKey: Self.attemptedKey)
        var request = URLRequest(url: URL(string: "https://open.bigmodel.cn/")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpMethod = "HEAD"
        request.httpShouldHandleCookies = false
        // No credentials, personal data, tracking identifiers, or inference request.
        do { try await send(request) }
        catch { /* Denial/offline must not block onboarding or become a retry loop. */ }
    }
}
