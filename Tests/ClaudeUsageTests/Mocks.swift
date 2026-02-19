import Foundation
@testable import ClaudeUsageKit

// MARK: - Mock Keychain Reader

/// Test double for KeychainReading.
/// Supports sequential results via a FIFO queue for multi-read test scenarios.
final class MockKeychainReader: KeychainReading, @unchecked Sendable {
    private var queue: [Result<OAuthCredentials, Error>] = []
    var readCount = 0

    /// Set a single result that is returned on every call.
    var result: Result<OAuthCredentials, Error> = .failure(KeychainError.notFound) {
        didSet { queue = [] }  // Clear queue when single result is set
    }

    /// Enqueue a result for sequential multi-read scenarios.
    func enqueue(_ result: Result<OAuthCredentials, Error>) {
        queue.append(result)
    }

    func readCredentials() async throws -> OAuthCredentials {
        readCount += 1
        if !queue.isEmpty {
            return try queue.removeFirst().get()
        }
        return try result.get()
    }
}

// MARK: - Mock Network Session

/// Test double for NetworkSession. Returns canned responses or throws.
/// Uses a single FIFO queue so errors and successes can be interleaved.
final class MockNetworkSession: NetworkSession, @unchecked Sendable {
    private var queue: [Result<(Data, URLResponse), Error>] = []
    var requestHistory: [URLRequest] = []

    /// Enqueue a successful HTTP response.
    func enqueue(data: Data, statusCode: Int, url: String = "https://example.com") {
        let response = HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        queue.append(.success((data, response)))
    }

    /// Enqueue an error to throw.
    func enqueueError(_ error: Error) {
        queue.append(.failure(error))
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestHistory.append(request)
        guard !queue.isEmpty else {
            throw URLError(.badServerResponse)
        }
        return try queue.removeFirst().get()
    }
}

// MARK: - Holding Network Session (for concurrency tests)

/// Test double that suspends at the network call until explicitly released.
/// Used to keep a fetch "in-flight" while verifying the concurrent-fetch guard.
final class HoldingNetworkSession: NetworkSession, @unchecked Sendable {
    var requestCount = 0
    private var requestContinuation: CheckedContinuation<Void, Never>?
    private var responseContinuation: CheckedContinuation<(Data, URLResponse), Error>?

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestCount += 1
        requestContinuation?.resume()
        requestContinuation = nil
        return try await withCheckedThrowingContinuation { cont in
            responseContinuation = cont
        }
    }

    /// Suspends until the mock receives a network request.
    func waitForRequest() async {
        await withCheckedContinuation { cont in
            requestContinuation = cont
        }
    }

    /// Completes the suspended network call with the given response.
    func release(data: Data, statusCode: Int) {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        responseContinuation?.resume(returning: (data, response))
        responseContinuation = nil
    }
}

// MARK: - Test Data Helpers

enum TestData {
    static let fullUsageJSON = """
    {
      "five_hour": {
        "utilization": 37.0,
        "resets_at": "2026-02-08T04:59:59.000000+00:00"
      },
      "seven_day": {
        "utilization": 26.0,
        "resets_at": "2026-02-12T14:59:59.771647+00:00"
      },
      "seven_day_opus": null,
      "seven_day_sonnet": {
        "utilization": 1.0,
        "resets_at": "2026-02-13T20:59:59.771655+00:00"
      },
      "extra_usage": {
        "is_enabled": false,
        "monthly_limit": null,
        "used_credits": null,
        "utilization": null
      }
    }
    """.data(using: .utf8)!

    static let minimalUsageJSON = """
    {
      "five_hour": {
        "utilization": 50.0,
        "resets_at": "2026-02-08T05:00:00+00:00"
      },
      "seven_day": {
        "utilization": 10.0,
        "resets_at": "2026-02-12T15:00:00+00:00"
      }
    }
    """.data(using: .utf8)!

    /// ExtraUsage with actual non-null credit values.
    static let extraUsageEnabledJSON = """
    {
      "five_hour": {
        "utilization": 80.0,
        "resets_at": "2026-02-08T05:00:00+00:00"
      },
      "seven_day": {
        "utilization": 60.0,
        "resets_at": "2026-02-12T15:00:00+00:00"
      },
      "extra_usage": {
        "is_enabled": true,
        "monthly_limit": 100.0,
        "used_credits": 12.5,
        "utilization": 12.5
      }
    }
    """.data(using: .utf8)!

    static let camelCaseCredentialsJSON = """
    {
      "accessToken": "test-access-token",
      "refreshToken": "test-refresh-token",
      "expiresAt": 1708123456000,
      "subscriptionType": "Pro",
      "rateLimitTier": "tier_1"
    }
    """.data(using: .utf8)!

    static let snakeCaseCredentialsJSON = """
    {
      "access_token": "test-access-token",
      "refresh_token": "test-refresh-token",
      "expires_at": 1708123456000,
      "subscription_type": "Max",
      "rate_limit_tier": "tier_2"
    }
    """.data(using: .utf8)!

    static let wrappedCredentialsJSON = """
    {
      "claudeAiOauth": {
        "accessToken": "test-access-token",
        "refreshToken": "test-refresh-token",
        "expiresAt": 1708123456000,
        "subscriptionType": "Pro"
      }
    }
    """.data(using: .utf8)!

    static let tokenRefreshJSON = """
    {
      "access_token": "new-access-token",
      "token_type": "Bearer",
      "expires_in": 3600,
      "refresh_token": "new-refresh-token"
    }
    """.data(using: .utf8)!

    /// Token refresh response without refresh_token (permitted by RFC 6749 §6).
    static let tokenRefreshNoRotateJSON = """
    {
      "access_token": "new-access-token",
      "token_type": "Bearer",
      "expires_in": 3600
    }
    """.data(using: .utf8)!

    /// Build a mock OAuthCredentials with sensible defaults.
    static func mockCredentials(
        accessToken: String = "test-access-token",
        refreshToken: String = "test-refresh-token",
        expiresAt: Date = Date(timeIntervalSinceNow: 3600),
        subscriptionType: String? = "Pro"
    ) -> OAuthCredentials {
        OAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            subscriptionType: subscriptionType
        )
    }
}
