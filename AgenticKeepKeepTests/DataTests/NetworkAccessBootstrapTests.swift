import XCTest
@testable import AgenticKeepKeep

@MainActor
final class NetworkAccessBootstrapTests: XCTestCase {
    func testFirstAttemptIsAnonymousAndDoesNotRepeatAfterReload() async throws {
        let suite = "NetworkAccessBootstrapTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var requests: [URLRequest] = []
        let bootstrap = NetworkAccessBootstrap(defaults: defaults) { requests.append($0) }
        await bootstrap.requestOnce()
        await bootstrap.requestOnce()
        await NetworkAccessBootstrap(defaults: defaults) { requests.append($0) }.requestOnce()
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://open.bigmodel.cn/")
        XCTAssertEqual(request.httpMethod, "HEAD")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.timeoutInterval, 8)
    }

    func testDeniedOrOfflineDoesNotRetryOrThrow() async throws {
        let suite = "NetworkAccessBootstrapTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var count = 0
        let bootstrap = NetworkAccessBootstrap(defaults: defaults) { _ in
            count += 1
            throw URLError(.notConnectedToInternet)
        }
        await bootstrap.requestOnce()
        await bootstrap.requestOnce()
        XCTAssertEqual(count, 1)
        XCTAssertTrue(defaults.bool(forKey: NetworkAccessBootstrap.attemptedKey))
        XCTAssertFalse(defaults.bool(forKey: "hasCompletedOnboarding"))
    }

    func testReentrantAttemptWhileFirstRequestIsRunningIsIgnored() async throws {
        let suite = "NetworkAccessBootstrapTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var count = 0
        var bootstrap: NetworkAccessBootstrap?
        bootstrap = NetworkAccessBootstrap(defaults: defaults) { _ in
            count += 1
            await bootstrap?.requestOnce()
        }
        await bootstrap?.requestOnce()
        XCTAssertEqual(count, 1)
        bootstrap = nil
    }

    func testCancelledBeforeStartingDoesNotConsumeAttempt() async throws {
        let suite = "NetworkAccessBootstrapTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var count = 0
        let bootstrap = NetworkAccessBootstrap(defaults: defaults) { _ in count += 1 }
        let task = Task { await bootstrap.requestOnce() }
        task.cancel()
        await task.value
        XCTAssertEqual(count, 0)
        XCTAssertFalse(defaults.bool(forKey: NetworkAccessBootstrap.attemptedKey))
    }
}
