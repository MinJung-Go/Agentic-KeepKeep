import XCTest
@testable import AgenticKeepKeep

final class AuthTransportTests: XCTestCase {
    func testEndpointRejectsUnsafeConfiguration() throws {
        for base in ["", "http://localhost:3000", "https://user:pass@example.com", "https://example.com?key=bad", "https://example.com#fragment"] {
            XCTAssertThrowsError(try ServiceEndpoint.url("/auth/me", baseURL: base))
        }
        XCTAssertEqual(try ServiceEndpoint.url("/auth/me", baseURL: "https://example.com/service").absoluteString,
                       "https://example.com/service/v1/auth/me")
    }
    func testBearerRequestAndServerError() async throws {
        let session = MockURLProtocol.makeSession()
        defer { session.invalidateAndCancel(); MockURLProtocol.reset() }
        MockURLProtocol.responder = { request in
            XCTAssertEqual(request.url?.path, "/v1/auth/logout")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer account-session")
            return (204, Data())
        }
        let data = try await AuthAPI.request("/auth/logout", method: "POST", token: "account-session",
                                             baseURL: "https://example.com", session: session)
        XCTAssertTrue(data.isEmpty)
        MockURLProtocol.responder = { _ in (429, Data(#"{"error":{"message":"请求过于频繁"}}"#.utf8)) }
        do {
            _ = try await AuthAPI.request("/auth/login", method: "POST", body: ["username": "alice", "password": "test-password"],
                                          baseURL: "https://example.com", session: session)
            XCTFail("Expected rate limit")
        } catch let error as AuthServiceError {
            XCTAssertEqual(error.status, 429)
            XCTAssertEqual(error.message, "请求过于频繁")
        }
    }
    func testUnauthorizedNotificationCarriesOnlyTheFailedSession() async throws {
        let session = MockURLProtocol.makeSession()
        defer { session.invalidateAndCancel(); MockURLProtocol.reset() }
        let notice = expectation(forNotification: ServiceTransport.expired, object: nil) { note in
            note.object as? String == "expired-session"
        }
        MockURLProtocol.responder = { _ in (401, Data(#"{"error":{"message":"请重新登录"}}"#.utf8)) }
        do {
            _ = try await AuthAPI.request("/auth/me", token: "expired-session", baseURL: "https://example.com", session: session)
            XCTFail("Expected unauthorized")
        } catch let error as AuthServiceError { XCTAssertEqual(error.status, 401) }
        await fulfillment(of: [notice], timeout: 1)
    }
}
