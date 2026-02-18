import Testing
import Foundation
@testable import ClaudeUsageKit

// MARK: - Phase 10: Form Encoding

@Suite("UsageService.buildRefreshBody")
struct FormEncodingTests {

    // Cycle 10a: Simple values
    @Test("Builds form-encoded body with standard values")
    func formEncodeSimple() throws {
        let body = UsageService.buildRefreshBody(refreshToken: "simple-token")
        let bodyString = try #require(body.flatMap { String(data: $0, encoding: .utf8) })

        #expect(bodyString.contains("grant_type=refresh_token"))
        #expect(bodyString.contains("refresh_token=simple-token"))
        #expect(bodyString.contains("client_id="))
        #expect(bodyString.contains("&"))
    }

    // Cycle 10b: Special characters get percent-encoded
    @Test("Percent-encodes special characters in refresh token")
    func formEncodeSpecialChars() throws {
        let body = UsageService.buildRefreshBody(refreshToken: "token+with/special=chars&more")
        let bodyString = try #require(body.flatMap { String(data: $0, encoding: .utf8) })

        // + must be %2B, / must be %2F, = must be %3D
        #expect(bodyString.contains("token%2Bwith%2Fspecial%3Dchars%26more"))
        // Must NOT contain raw + / = in the token value
        #expect(!bodyString.contains("refresh_token=token+"))
    }

    // Cycle 10c: Token with base64 characters
    @Test("Correctly encodes base64-style tokens")
    func formEncodeBase64Token() throws {
        let body = UsageService.buildRefreshBody(refreshToken: "abc123+xyz/end==")
        let bodyString = try #require(body.flatMap { String(data: $0, encoding: .utf8) })

        #expect(bodyString.contains("abc123%2Bxyz%2Fend%3D%3D"))
    }
}

// MARK: - Phase 11: Version Parsing

@Suite("UsageService.parseVersion")
struct VersionParsingTests {

    // Cycle 11a: Standard version string
    @Test("Extracts version from 'Claude Code vX.Y.Z' format")
    func parseVersionStandard() {
        let version = UsageService.parseVersion(from: "Claude Code v1.2.3\n")
        #expect(version == "1.2.3")
    }

    // Cycle 11b: No version found
    @Test("Returns nil when no version pattern found")
    func parseVersionNoMatch() {
        let version = UsageService.parseVersion(from: "some other output")
        #expect(version == nil)
    }

    // Cycle 11c: Version with extra text
    @Test("Extracts version from longer output")
    func parseVersionExtraText() {
        let version = UsageService.parseVersion(from: "Claude Code v0.3.17 (some extra info)")
        #expect(version == "0.3.17")
    }
}

// MARK: - Phase 12: UsageService Fetch Flow

@Suite("UsageService fetch flow")
struct UsageServiceFetchTests {

    // Helper: create a UsageService with mocked dependencies
    @MainActor
    private func makeService(
        credentials: OAuthCredentials? = nil,
        keychainError: KeychainError? = nil
    ) -> (UsageService, MockKeychainReader, MockNetworkSession) {
        let mockKeychain = MockKeychainReader()
        let mockNetwork = MockNetworkSession()

        if let credentials {
            mockKeychain.result = .success(credentials)
        } else if let keychainError {
            mockKeychain.result = .failure(keychainError)
        }

        let service = UsageService(
            keychainReader: mockKeychain,
            networkSession: mockNetwork
        )
        return (service, mockKeychain, mockNetwork)
    }

    // Cycle 12a: Successful fetch
    @Test("Populates usage and clears error on successful fetch")
    @MainActor
    func fetchSuccess() async {
        let (service, _, mockNetwork) = makeService(
            credentials: TestData.mockCredentials()
        )
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)

        await service.fetchUsage()

        #expect(service.usage != nil)
        #expect(service.usage?.fiveHour.utilization == 37.0)
        #expect(service.error == nil)
        #expect(service.lastUpdated != nil)
    }

    // Cycle 12b: 401 triggers refresh then retry
    @Test("Refreshes token and retries on 401")
    @MainActor
    func fetch401RefreshAndRetry() async {
        let (service, _, mockNetwork) = makeService(
            credentials: TestData.mockCredentials()
        )

        // First call: 401
        mockNetwork.enqueue(data: Data(), statusCode: 401)
        // Refresh call: success
        mockNetwork.enqueue(data: TestData.tokenRefreshJSON, statusCode: 200)
        // Retry call: success
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)

        await service.fetchUsage()

        #expect(service.usage != nil)
        #expect(service.error == nil)
        // Should have made 3 network requests: fetch, refresh, retry
        #expect(mockNetwork.requestHistory.count == 3)
    }

    // Cycle 12c: 403 gives specific error
    @Test("Sets forbidden error on 403 without attempting refresh")
    @MainActor
    func fetch403Forbidden() async {
        let (service, _, mockNetwork) = makeService(
            credentials: TestData.mockCredentials()
        )
        mockNetwork.enqueue(data: Data(), statusCode: 403)

        await service.fetchUsage()

        #expect(service.error == .forbidden)
        // Should have made only 1 request (no refresh attempt)
        #expect(mockNetwork.requestHistory.count == 1)
    }

    // Cycle 12d: Network error
    @Test("Wraps URLError in .network error")
    @MainActor
    func fetchNetworkError() async {
        let (service, _, mockNetwork) = makeService(
            credentials: TestData.mockCredentials()
        )
        mockNetwork.enqueueError(URLError(.notConnectedToInternet))

        await service.fetchUsage()

        if case .network = service.error {
            // Expected
        } else {
            Issue.record("Expected .network error, got \(String(describing: service.error))")
        }
    }

    // Cycle 12e: Keychain error propagates
    @Test("Sets keychain error when credentials not found")
    @MainActor
    func fetchKeychainError() async {
        let (service, _, _) = makeService(keychainError: .notFound)

        await service.fetchUsage()

        if case .keychain(.notFound) = service.error {
            // Expected
        } else {
            Issue.record("Expected .keychain(.notFound) error, got \(String(describing: service.error))")
        }
    }

    // Cycle 12f: Menu bar label reflects state
    @Test("menuBarLabel updates based on fetched usage")
    @MainActor
    func menuBarLabelUpdates() async {
        let (service, _, mockNetwork) = makeService(
            credentials: TestData.mockCredentials()
        )

        // Before fetch: no data
        #expect(service.menuBarLabel == "--%")

        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)
        await service.fetchUsage()

        // After fetch: shows percentage
        #expect(service.menuBarLabel == "37%")
    }

    // Cycle 12g: Subscription type is set from keychain
    @Test("Sets subscriptionType from keychain credentials")
    @MainActor
    func subscriptionTypeFromKeychain() async {
        let (service, _, mockNetwork) = makeService(
            credentials: TestData.mockCredentials(subscriptionType: "Max")
        )
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)

        await service.fetchUsage()

        #expect(service.subscriptionType == "Max")
    }

    // Cycle 12h: Decoding error
    @Test("Sets decodingFailed error for malformed response")
    @MainActor
    func fetchDecodingError() async {
        let (service, _, mockNetwork) = makeService(
            credentials: TestData.mockCredentials()
        )
        mockNetwork.enqueue(data: "not json".data(using: .utf8)!, statusCode: 200)

        await service.fetchUsage()

        #expect(service.error == .decodingFailed)
    }

    // Cycle 12i: Headers are set correctly
    @Test("Sets required Authorization, anthropic-beta, and User-Agent headers")
    @MainActor
    func fetchSetsHeaders() async {
        let (service, _, mockNetwork) = makeService(
            credentials: TestData.mockCredentials(accessToken: "my-token")
        )
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)

        await service.fetchUsage()

        let request = mockNetwork.requestHistory.first
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer my-token")
        #expect(request?.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request?.value(forHTTPHeaderField: "User-Agent") != nil)
    }
}
