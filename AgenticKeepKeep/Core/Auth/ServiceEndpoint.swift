import Foundation

// Temporary HTTP exception is restricted to the explicitly configured deployment.
enum ServiceEndpoint {
    static var baseURL: String {
        (Bundle.main.object(forInfoDictionaryKey: "MoveliqServiceURL") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    static func url(_ path: String, baseURL: String = ServiceEndpoint.baseURL) throws -> URL {
        guard let base = URL(string: baseURL), (base.scheme == "https" || baseURL == "http://47.100.234.212:8080"), base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              let url = URL(string: baseURL + "/v1" + path) else {
            throw AuthServiceError(status: 0, message: "服务地址尚未配置，请联系管理员获取已配置的安装版本。")
        }
        return url
    }
    static func isProxy(_ base: String) -> Bool { !baseURL.isEmpty && base == baseURL + "/v1" }
}

