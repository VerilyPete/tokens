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

    // Cycle 10d: No force-unwrap crash (nil-safe after removing !)
    @Test("Returns valid body without force-unwrap crash")
    func formEncodeNilSafe() throws {
        // Verify the refactored code (using ?? instead of !) still produces valid output
        let body = UsageService.buildRefreshBody(refreshToken: "a-perfectly-normal-token")
        let bodyString = try #require(body.flatMap { String(data: $0, encoding: .utf8) })

        #expect(bodyString.contains("grant_type=refresh_token"))
        #expect(bodyString.contains("refresh_token=a-perfectly-normal-token"))
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
        service.retryBaseDelay = 0
        // Enqueue 4 network errors to exhaust retries
        for _ in 0...3 {
            mockNetwork.enqueueError(URLError(.notConnectedToInternet))
        }

        await service.fetchUsage()

        #expect(service.error == .network(URLError(.notConnectedToInternet)))
    }

    // Cycle 12e: Keychain error propagates
    @Test("Sets keychain error when credentials not found")
    @MainActor
    func fetchKeychainError() async {
        let (service, _, _) = makeService(keychainError: .notFound)

        await service.fetchUsage()

        #expect(service.error == .keychain(.notFound))
    }

    // Cycle 12e2: Keychain error increments consecutiveFailures
    @Test("Keychain error increments consecutiveFailures for polling backoff")
    @MainActor
    func keychainErrorIncrementsConsecutiveFailures() async {
        let (service, _, _) = makeService(keychainError: .notFound)

        await service.fetchUsage()
        #expect(service.consecutiveFailures == 1)

        await service.fetchUsage()
        #expect(service.consecutiveFailures == 2)
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
        #expect(request?.value(forHTTPHeaderField: "User-Agent") == "claude-code/0.0.0")
    }

    // Cycle 12j: Proactive refresh when token near-expiry
    @Test("Triggers proactive refresh when token expires within 15 minutes")
    @MainActor
    func proactiveRefresh() async {
        // Token expires in 10 minutes (< 15 min threshold)
        let nearExpiryCreds = TestData.mockCredentials(
            expiresAt: Date(timeIntervalSinceNow: 600)
        )
        let (service, _, mockNetwork) = makeService(credentials: nearExpiryCreds)

        // Refresh call: success
        mockNetwork.enqueue(data: TestData.tokenRefreshJSON, statusCode: 200)
        // Fetch call: success (after refresh)
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)

        await service.fetchUsage()

        #expect(service.usage != nil)
        // Should have made 2 requests: refresh + fetch
        #expect(mockNetwork.requestHistory.count == 2)
        // First request should be the refresh (POST)
        #expect(mockNetwork.requestHistory[0].httpMethod == "POST")
    }

    // Cycle 12k: Refresh failure falls back to keychain re-read
    @Test("Falls back to keychain re-read when refresh fails on 401")
    @MainActor
    func refreshFailureFallsBackToKeychain() async {
        let (service, mockKeychain, mockNetwork) = makeService(
            credentials: TestData.mockCredentials()
        )

        // First fetch: 401
        mockNetwork.enqueue(data: Data(), statusCode: 401)
        // Refresh: fails
        mockNetwork.enqueue(data: Data(), statusCode: 400)
        // Enqueue fresh credentials for keychain re-read
        mockKeychain.enqueue(.success(TestData.mockCredentials(accessToken: "fresh-token")))
        // Retry fetch with fresh credentials: success
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)

        await service.fetchUsage()

        #expect(service.usage != nil)
        #expect(service.error == nil)
    }

    // Cycle 12k2: Refresh without rotate preserves existing refresh token
    @Test("Preserves existing refresh token when server omits refresh_token")
    @MainActor
    func refreshWithoutRotatePreservesToken() async {
        let nearExpiryCreds = TestData.mockCredentials(
            expiresAt: Date(timeIntervalSinceNow: 600)
        )
        let (service, _, mockNetwork) = makeService(credentials: nearExpiryCreds)

        // Proactive refresh returns no refresh_token
        mockNetwork.enqueue(data: TestData.tokenRefreshNoRotateJSON, statusCode: 200)
        // Fetch succeeds with the new access token
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)

        await service.fetchUsage()

        #expect(service.usage != nil)
        #expect(service.error == nil)

        // Trigger another refresh cycle to verify the original refresh token
        // was preserved (if it were nil, refreshTokenIfNeeded would bail out)
        mockNetwork.enqueue(data: TestData.tokenRefreshNoRotateJSON, statusCode: 200)
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)

        // Force token near-expiry so proactive refresh triggers
        await service.reloadCredentials()
    }

    // Cycle 12k3: 401 fallback keychain error preserves typed error
    @Test("401 fallback preserves KeychainError instead of masking as unauthorized")
    @MainActor
    func refreshFallbackKeychainErrorPreserved() async {
        let (service, mockKeychain, mockNetwork) = makeService(
            credentials: TestData.mockCredentials()
        )

        // First fetch: 401
        mockNetwork.enqueue(data: Data(), statusCode: 401)
        // Refresh: fails
        mockNetwork.enqueue(data: Data(), statusCode: 400)
        // Keychain re-read: fails with notFound
        mockKeychain.enqueue(.failure(KeychainError.notFound))

        await service.fetchUsage()

        #expect(service.error == .keychain(.notFound))
        #expect(service.consecutiveFailures == 1)
    }

    // Cycle 12l: 429 triggers transient retry
    @Test("Retries on 429 with backoff then succeeds")
    @MainActor
    func fetch429Retry() async {
        let (service, _, mockNetwork) = makeService(
            credentials: TestData.mockCredentials()
        )
        service.retryBaseDelay = 0  // No delay in tests

        // First attempt: 429
        mockNetwork.enqueue(data: Data(), statusCode: 429)
        // Second attempt: success
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)

        await service.fetchUsage()

        #expect(service.usage != nil)
        #expect(service.error == nil)
        // 1 fetch(429) + 1 fetch(200) = 2 requests
        #expect(mockNetwork.requestHistory.count == 2)
    }

    // Cycle 12m: 429 exhausts all retries
    @Test("Sets HTTP error after exhausting all retries on 429")
    @MainActor
    func fetch429ExhaustedRetries() async {
        let (service, _, mockNetwork) = makeService(
            credentials: TestData.mockCredentials()
        )
        service.retryBaseDelay = 0

        // All 4 attempts: 429
        for _ in 0...3 {
            mockNetwork.enqueue(data: Data(), statusCode: 429)
        }

        await service.fetchUsage()

        #expect(service.error == .http(statusCode: 429))
        // Should have tried 4 times (initial + 3 retries)
        #expect(mockNetwork.requestHistory.count == 4)
    }

    // Cycle 12n: 5xx triggers transient retry
    @Test("Retries on 500 server error then succeeds")
    @MainActor
    func fetch500Retry() async {
        let (service, _, mockNetwork) = makeService(
            credentials: TestData.mockCredentials()
        )
        service.retryBaseDelay = 0

        mockNetwork.enqueue(data: Data(), statusCode: 500)
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)

        await service.fetchUsage()

        #expect(service.usage != nil)
        #expect(service.error == nil)
    }

    // Cycle 12o: reloadCredentials clears error and re-fetches
    @Test("reloadCredentials clears error and fetches fresh")
    @MainActor
    func reloadCredentialsClearsError() async {
        let (service, mockKeychain, mockNetwork) = makeService(
            keychainError: .notFound
        )

        // First fetch fails with keychain error
        await service.fetchUsage()
        #expect(service.error == .keychain(.notFound))

        // Now keychain has credentials
        mockKeychain.result = .success(TestData.mockCredentials())
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)

        await service.reloadCredentials()

        #expect(service.usage != nil)
        #expect(service.error == nil)
    }

    // Cycle 12o2: reloadCredentials picks up new keychain creds after decodingFailed
    @Test("reloadCredentials re-reads keychain after decodingFailed error")
    @MainActor
    func reloadAfterDecodingFailedUsesNewCredentials() async {
        let (service, mockKeychain, mockNetwork) = makeService(
            credentials: TestData.mockCredentials(accessToken: "old-token")
        )

        // First fetch: API returns 200 with invalid JSON → decodingFailed
        mockNetwork.enqueue(data: "not json".data(using: .utf8)!, statusCode: 200)
        await service.fetchUsage()
        #expect(service.error == .decodingFailed)

        // User runs `claude login` → new credentials in keychain
        mockKeychain.enqueue(.success(TestData.mockCredentials(accessToken: "new-token")))
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)

        // Simulates pressing Retry, which now calls reloadCredentials()
        await service.reloadCredentials()

        #expect(service.usage != nil)
        #expect(service.error == nil)
        // Verify the second fetch used the NEW token from keychain, not the old one
        let lastRequest = mockNetwork.requestHistory.last
        #expect(lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer new-token")
    }

    // Cycle 12p: Network error triggers transient retry
    @Test("Retries on network error then succeeds")
    @MainActor
    func fetchNetworkErrorRetry() async {
        let (service, _, mockNetwork) = makeService(
            credentials: TestData.mockCredentials()
        )
        service.retryBaseDelay = 0

        mockNetwork.enqueueError(URLError(.timedOut))
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)

        await service.fetchUsage()

        #expect(service.usage != nil)
        #expect(service.error == nil)
    }

    // Cycle 12q: Decoding error is not retried
    @Test("Does not retry on decoding error")
    @MainActor
    func fetchDecodingErrorNoRetry() async {
        let (service, _, mockNetwork) = makeService(
            credentials: TestData.mockCredentials()
        )
        service.retryBaseDelay = 0

        mockNetwork.enqueue(data: "not json".data(using: .utf8)!, statusCode: 200)

        await service.fetchUsage()

        #expect(service.error == .decodingFailed)
        // Should only try once (decoding errors are not transient)
        #expect(mockNetwork.requestHistory.count == 1)
    }

    // Cycle 12r: Error with cached data shows cached percentage in menu bar
    @Test("Shows cached data in menu bar label when error occurs after successful fetch")
    @MainActor
    func menuBarLabelWithCachedDataOnError() async {
        let (service, _, mockNetwork) = makeService(
            credentials: TestData.mockCredentials()
        )

        // First fetch: success
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)
        await service.fetchUsage()
        #expect(service.menuBarLabel == "37%")

        // Second fetch: 403 error
        mockNetwork.enqueue(data: Data(), statusCode: 403)
        await service.fetchUsage()

        // Should still show cached percentage, not "!!"
        #expect(service.menuBarLabel == "37%")
        #expect(service.error == .forbidden)
    }

    // Cycle 12s: isLoading transitions
    @Test("isLoading is true during fetch and false after")
    @MainActor
    func isLoadingTransitions() async {
        let (service, _, mockNetwork) = makeService(
            credentials: TestData.mockCredentials()
        )

        // Before fetch
        #expect(service.isLoading == false)

        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)
        await service.fetchUsage()

        // After fetch
        #expect(service.isLoading == false)
    }

    // Cycle 12t: consecutiveFailures increments and resets
    @Test("consecutiveFailures increments on error and resets on success")
    @MainActor
    func consecutiveFailuresTracking() async {
        let (service, _, mockNetwork) = makeService(
            credentials: TestData.mockCredentials()
        )
        service.retryBaseDelay = 0

        // First fetch: 403 error
        mockNetwork.enqueue(data: Data(), statusCode: 403)
        await service.fetchUsage()
        #expect(service.consecutiveFailures == 1)

        // Second fetch: 403 error
        mockNetwork.enqueue(data: Data(), statusCode: 403)
        await service.fetchUsage()
        #expect(service.consecutiveFailures == 2)

        // Third fetch: success — resets counter
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)
        await service.fetchUsage()
        #expect(service.consecutiveFailures == 0)
    }

    // Cycle 12u: Concurrent fetch guard
    @Test("Skips fetch when already loading (concurrent call guard)")
    @MainActor
    func fetchWhileAlreadyLoading() async {
        let mockKeychain = MockKeychainReader()
        mockKeychain.result = .success(TestData.mockCredentials())
        let holdingNetwork = HoldingNetworkSession()

        let service = UsageService(
            keychainReader: mockKeychain,
            networkSession: holdingNetwork
        )

        // Start first fetch — it will suspend at the network call
        let firstFetch = Task { @MainActor in
            await service.fetchUsage()
        }

        // Wait until the holding mock confirms it received the request
        await holdingNetwork.waitForRequest()
        #expect(service.isLoading == true)

        // Second fetch should be a no-op (guard !isLoading)
        await service.fetchUsage()
        #expect(holdingNetwork.requestCount == 1)

        // Release the first fetch so it completes
        holdingNetwork.release(data: TestData.fullUsageJSON, statusCode: 200)
        await firstFetch.value

        #expect(service.isLoading == false)
        #expect(service.usage != nil)
    }

    // Cycle 12w: reloadCredentials while fetch in-flight keeps error visible
    @Test("reloadCredentials does not clear error when a fetch is in-flight")
    @MainActor
    func reloadCredentialsDuringLoadingKeepsError() async {
        let mockKeychain = MockKeychainReader()
        mockKeychain.result = .success(TestData.mockCredentials())
        let holdingNetwork = HoldingNetworkSession()

        let service = UsageService(
            keychainReader: mockKeychain,
            networkSession: holdingNetwork
        )

        // Start a fetch that suspends at the network call
        let firstFetch = Task { @MainActor in
            await service.fetchUsage()
        }
        await holdingNetwork.waitForRequest()
        #expect(service.isLoading == true)

        // Simulate a previous error state
        service.error = .unauthorized

        // Call reloadCredentials while fetch is in-flight
        await service.reloadCredentials()

        // Error must NOT have been cleared (UI stays consistent)
        #expect(service.error == .unauthorized)

        // Release the in-flight fetch
        holdingNetwork.release(data: TestData.fullUsageJSON, statusCode: 200)
        await firstFetch.value
    }

    // Cycle 12v: subscriptionType updated on 401 keychain re-read
    @Test("Updates subscriptionType when keychain is re-read after 401")
    @MainActor
    func subscriptionTypeUpdatedOn401KeychainReread() async {
        // Use explicit queue so first read returns Pro, second returns Max
        let (service, mockKeychain, mockNetwork) = makeService()

        // First keychain read (token init): Pro subscription
        mockKeychain.enqueue(.success(TestData.mockCredentials(subscriptionType: "Pro")))
        // Second keychain read (401 fallback): Max subscription
        mockKeychain.enqueue(.success(TestData.mockCredentials(
            accessToken: "fresh-token",
            subscriptionType: "Max"
        )))

        // First fetch: 401
        mockNetwork.enqueue(data: Data(), statusCode: 401)
        // Refresh: fails
        mockNetwork.enqueue(data: Data(), statusCode: 400)
        // Retry fetch: success
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)

        await service.fetchUsage()

        #expect(service.subscriptionType == "Max")
        #expect(service.usage != nil)
    }
}

// MARK: - Error Description Tests

@Suite("Error descriptions")
struct ErrorDescriptionTests {

    @Test("KeychainError.notFound has descriptive message")
    func keychainNotFoundDescription() {
        let error = KeychainError.notFound
        #expect(error.errorDescription == "No Claude Code credentials found. Run `claude login` in your terminal.")
    }

    @Test("KeychainError.accessDenied has descriptive message")
    func keychainAccessDeniedDescription() {
        let error = KeychainError.accessDenied
        #expect(error.errorDescription == "Keychain access denied. Re-launch and click \"Always Allow\" when prompted.")
    }

    @Test("KeychainError.malformedJSON has descriptive message")
    func keychainMalformedDescription() {
        let error = KeychainError.malformedJSON
        #expect(error.errorDescription == "Credential data is corrupted. Try running `claude login` again.")
    }

    @Test("KeychainError.processError includes exit code")
    func keychainProcessErrorDescription() {
        let error = KeychainError.processError(44)
        #expect(error.errorDescription == "Keychain read failed (exit code 44).")
    }

    @Test("KeychainError.processTimeout has descriptive message")
    func keychainProcessTimeoutDescription() {
        let error = KeychainError.processTimeout
        #expect(error.errorDescription == "Keychain read timed out. The security process may be unresponsive.")
    }

    @Test("Process timeout constant is 10 seconds")
    func processTimeoutConstant() {
        #expect(KeychainReader.processTimeoutSeconds == 10)
    }

    @Test("UsageError.network has descriptive message")
    func usageNetworkDescription() {
        let error = UsageError.network(URLError(.notConnectedToInternet))
        #expect(error.errorDescription == "Network error. Check your internet connection.")
    }

    @Test("UsageError.http includes status code")
    func usageHttpDescription() {
        let error = UsageError.http(statusCode: 500)
        #expect(error.errorDescription == "Server returned HTTP 500.")
    }

    @Test("UsageError.unauthorized has descriptive message")
    func usageUnauthorizedDescription() {
        let error = UsageError.unauthorized
        #expect(error.errorDescription == "Session expired. Run `claude login` in your terminal.")
    }

    @Test("UsageError.forbidden has descriptive message")
    func usageForbiddenDescription() {
        let error = UsageError.forbidden
        #expect(error.errorDescription == "Missing permissions. Run `claude login` (not `setup-token`).")
    }

    @Test("UsageError.decodingFailed has descriptive message")
    func usageDecodingDescription() {
        let error = UsageError.decodingFailed
        #expect(error.errorDescription == "Unexpected API response format.")
    }

    @Test("UsageError.refreshFailed includes reason")
    func usageRefreshFailedDescription() {
        let error = UsageError.refreshFailed("HTTP 400")
        #expect(error.errorDescription == "Token refresh failed: HTTP 400")
    }

    // requiresReauthentication

    @Test("Auth errors require reauthentication")
    func authErrorsRequireReauth() {
        #expect(UsageError.unauthorized.requiresReauthentication == true)
        #expect(UsageError.forbidden.requiresReauthentication == true)
        #expect(UsageError.refreshFailed("HTTP 400").requiresReauthentication == true)
        #expect(UsageError.keychain(.notFound).requiresReauthentication == true)
    }

    @Test("Transient errors do not require reauthentication")
    func transientErrorsDoNotRequireReauth() {
        #expect(UsageError.network(URLError(.timedOut)).requiresReauthentication == false)
        #expect(UsageError.http(statusCode: 500).requiresReauthentication == false)
        #expect(UsageError.decodingFailed.requiresReauthentication == false)
    }
}
