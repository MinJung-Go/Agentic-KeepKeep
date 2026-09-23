import Foundation

/// Logout replaces the session so outstanding streams cannot cross accounts.
final class ServiceTransport: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = ServiceTransport()
    private let lock = NSLock()
    private var current: URLSession?
    var session: URLSession {
        lock.lock(); defer { lock.unlock() }
        if let current { return current }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        let created = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        current = created
        return created
    }
    func cancelAll() {
        lock.lock(); let old = current; current = nil; lock.unlock()
        old?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    static let expired = Notification.Name("moveliq.session.expired")
    static func unauthorized(token: String) {
        NotificationCenter.default.post(name: expired, object: token)
    }
}

enum ServiceCredentials {
    private static let account = "moveliq-auth-session-v1"
    private struct Stored: Codable { let server: String; let session: ServiceSession }
    static var session: ServiceSession? {
        guard let value = KeychainStore.get(account: account), let data = value.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.server == ServiceEndpoint.baseURL else { return nil }
        return stored.session
    }
    static func save(_ session: ServiceSession) throws {
        let data = try JSONEncoder().encode(Stored(server: ServiceEndpoint.baseURL, session: session))
        guard KeychainStore.set(String(decoding: data, as: UTF8.self), account: account) else {
            throw AuthServiceError(status: 0, message: "无法保存登录凭据，请重试。")
        }
    }
    static func clear() { KeychainStore.delete(account: account) }
}

enum AuthAPI {
    static func request(_ path: String, method: String = "GET", body: [String: String]? = nil, token: String? = nil,
                        baseURL: String = ServiceEndpoint.baseURL, session: URLSession = ServiceTransport.shared.session) async throws -> Data {
        var request = URLRequest(url: try ServiceEndpoint.url(path, baseURL: baseURL))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AuthServiceError(status: 0, message: "服务响应异常。") }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 401, let token { ServiceTransport.unauthorized(token: token) }
            struct Failure: Decodable { struct Detail: Decodable { let message: String }; let error: Detail }
            let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error.message ?? "请求失败，请稍后再试。"
            throw AuthServiceError(status: http.statusCode, message: message)
        }
        return data
    }
}

final class ServiceRuntime: @unchecked Sendable {
    static let shared = ServiceRuntime()
    private let lock = NSLock()
    private var value: ServiceConfiguration?
    var configuration: ServiceConfiguration? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
