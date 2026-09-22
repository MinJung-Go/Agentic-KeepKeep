import Foundation

enum AuthInputPolicy {
    static func username(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    static func validUsername(_ value: String) -> Bool {
        username(value).range(of: "^[a-z0-9_]{4,24}$", options: .regularExpression) != nil
    }
    static func validPassword(_ value: String) -> Bool { (12...128).contains(value.utf16.count) && value.utf8.count <= 512 }
}
struct ServiceUser: Codable, Equatable { let id: String; let username: String }
struct ServiceSession: Codable { let user: ServiceUser; let token: String; let expiresAt: String }
struct ServiceConfiguration: Codable {
    let model: String
    let contextWindow: Int
    let maxOutput: Int
    let searchEnabled: Bool
    let supportContact: String
    var validBudget: Bool {
        (4096...1_048_576).contains(contextWindow) && (512...(contextWindow - 2048)).contains(maxOutput)
    }
}
struct ServiceInvite: Decodable, Identifiable {
    let id: String
    let code: String?
    let status: String
    var available: Bool { status == "available" && code != nil }
}
struct AuthServiceError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}
