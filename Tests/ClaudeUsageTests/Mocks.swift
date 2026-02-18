import Foundation
@testable import ClaudeUsageKit

// MARK: - Mock Keychain Reader

/// Test double for KeychainReading. Returns canned credentials or throws.
final class MockKeychainReader: KeychainReading, @unchecked Sendable {
    var result: Result<OAuthCredentials, Error> = .failure(KeychainError.notFound)
    var readCount = 0

    func readCredentials() async throws -> OAuthCredentials {
        readCount += 1
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
