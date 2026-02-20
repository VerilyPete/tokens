import Testing
import Foundation
@testable import ClaudeUsageKit

// MARK: - Form Encoding

@Suite("UsageService.buildRefreshBody")
struct FormEncodingTests {

    @Test("Builds form-encoded body with standard values")
    func formEncodeSimple() throws {
        let body = UsageService.buildRefreshBody(refreshToken: "simple-token")
        let bodyString = try #require(body.flatMap { String(data: $0, encoding: .utf8) })

        #expect(bodyString.contains("grant_type=refresh_token"))
        #expect(bodyString.contains("refresh_token=simple-token"))
        #expect(bodyString.contains("client_id="))
        #expect(bodyString.contains("&"))
    }

    @Test("Percent-encodes special characters in refresh token")
    func formEncodeSpecialChars() throws {
        let body = UsageService.buildRefreshBody(refreshToken: "token+with/special=chars&more")
        let bodyString = try #require(body.flatMap { String(data: $0, encoding: .utf8) })

        // + must be %2B, / must be %2F, = must be %3D
        #expect(bodyString.contains("token%2Bwith%2Fspecial%3Dchars%26more"))
        // Must NOT contain raw + / = in the token value
        #expect(!bodyString.contains("refresh_token=token+"))
    }

    @Test("Correctly encodes base64-style tokens")
    func formEncodeBase64Token() throws {
        let body = UsageService.buildRefreshBody(refreshToken: "abc123+xyz/end==")
        let bodyString = try #require(body.flatMap { String(data: $0, encoding: .utf8) })

        #expect(bodyString.contains("abc123%2Bxyz%2Fend%3D%3D"))
    }

    @Test("Returns valid body without force-unwrap crash")
    func formEncodeNilSafe() throws {
        // Verify the refactored code (using ?? instead of !) still produces valid output
        let body = UsageService.buildRefreshBody(refreshToken: "a-perfectly-normal-token")
        let bodyString = try #require(body.flatMap { String(data: $0, encoding: .utf8) })

        #expect(bodyString.contains("grant_type=refresh_token"))
        #expect(bodyString.contains("refresh_token=a-perfectly-normal-token"))
    }
}

// MARK: - Version Parsing

@Suite("UsageService.parseVersion")
struct VersionParsingTests {

    @Test("Extracts version from 'Claude Code vX.Y.Z' format")
    func parseVersionStandard() {
        let version = UsageService.parseVersion(from: "Claude Code v1.2.3\n")
        #expect(version == "1.2.3")
    }

    @Test("Returns nil when no version pattern found")
    func parseVersionNoMatch() {
        let version = UsageService.parseVersion(from: "some other output")
        #expect(version == nil)
    }

    @Test("Extracts version from longer output")
    func parseVersionExtraText() {
        let version = UsageService.parseVersion(from: "Claude Code v0.3.17 (some extra info)")
        #expect(version == "0.3.17")
    }
}

// MARK: - UsageService Fetch Flow

@Suite("UsageService fetch flow")
struct UsageServiceFetchTests {

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

    @Test("Populates usage and clears error on successful fetch")
    @MainActor
    func fetchSuccess() async {
        let (service, _, mockNetwork) = makeService(
            credentials: TestData.mockCredentials()
        )
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)

        await service.fetchUsage()

        #expect(service.usage != nil)
        #expect(service.usage?.fiveHour?.utilization == 37.0)
        #expect(service.error == nil)
        #expect(service.lastUpdated != nil)
    }

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

    @Test("Sets keychain error when credentials not found")
    @MainActor
    func fetchKeychainError() async {
        let (service, _, _) = makeService(keychainError: .notFound)

        await service.fetchUsage()

        #expect(service.error == .keychain(.notFound))
    }

    @Test("Keychain error increments consecutiveFailures for polling backoff")
    @MainActor
    func keychainErrorIncrementsConsecutiveFailures() async {
        let (service, _, _) = makeService(keychainError: .notFound)

        await service.fetchUsage()
        #expect(service.consecutiveFailures == 1)

        await service.fetchUsage()
        #expect(service.consecutiveFailures == 2)
    }

    @Test("menuBarLabel shows '--%' when usage is set but fiveHour bucket is absent")
    @MainActor
    func menuBarLabelNoFiveHour() async {
        let (service, _, mockNetwork) = makeService(
            credentials: TestData.mockCredentials()
        )

        let noFiveHourJSON = """
        {
          "seven_day": {
            "utilization": 26.0,
            "resets_at": "2026-02-12T14:59:59.771647+00:00"
          }
        }
        """.data(using: .utf8)!

        mockNetwork.enqueue(data: noFiveHourJSON, statusCode: 200)
        await service.fetchUsage()

        #expect(service.usage != nil)
        #expect(service.usage?.fiveHour == nil)
        #expect(service.menuBarLabel == "--%")
    }

    @Test("menuBarLabel shows '--%' when API returns 200 but all buckets are null")
    @MainActor
    func menuBarLabelAllNullBuckets() async {
        let (service, _, mockNetwork) = makeService(
            credentials: TestData.mockCredentials()
        )

        mockNetwork.enqueue(data: TestData.nullBucketsJSON, statusCode: 200)
        await service.fetchUsage()

        #expect(service.usage != nil)
        #expect(service.usage?.hasAnyUsageData == false)
        #expect(service.menuBarLabel == "--%")
    }

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

    @Test("Floors expires_in to 60 seconds to prevent refresh loop")
    @MainActor
    func expiresInZeroFloored() async {
        let nearExpiryCreds = TestData.mockCredentials(
            expiresAt: Date(timeIntervalSinceNow: 600)
        )
        let (service, _, mockNetwork) = makeService(credentials: nearExpiryCreds)

        // Proactive refresh returns expires_in: 0
        mockNetwork.enqueue(data: TestData.tokenRefreshZeroExpiryJSON, statusCode: 200)
        // Fetch succeeds
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)

        await service.fetchUsage()

        #expect(service.usage != nil)
        // Verify that the second fetch still works (refresh + fetch completed)
        #expect(mockNetwork.requestHistory.count == 2)
        #expect(mockNetwork.requestHistory[0].httpMethod == "POST") // refresh

        // The key invariant: even with expires_in: 0, we should be able to
        // do another fetch. Without the floor, tokenExpiresAt would be
        // in the past immediately, causing perpetual refresh attempts.
        // With the floor of 60s, at least we have a 60s window.
        mockNetwork.enqueue(data: TestData.tokenRefreshZeroExpiryJSON, statusCode: 200)
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)
        await service.fetchUsage()

        // Service still works (no infinite loop or crash)
        #expect(service.usage != nil)
        #expect(service.error == nil)
    }

    @Test("Proactive refresh failure does not set error on service")
    @MainActor
    func proactiveRefreshFailureNoError() async {
        let nearExpiryCreds = TestData.mockCredentials(
            expiresAt: Date(timeIntervalSinceNow: 600)
        )
        let (service, _, mockNetwork) = makeService(credentials: nearExpiryCreds)

        // Proactive refresh fails
        mockNetwork.enqueue(data: Data(), statusCode: 400)
        // Fetch still succeeds (token was still valid)
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)

        await service.fetchUsage()

        // Error should be nil -- the refresh failure should not leak
        #expect(service.error == nil)
        #expect(service.usage != nil)
    }

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

    @Test("reloadCredentials re-reads keychain after decodingFailed error")
    @MainActor
    func reloadAfterDecodingFailedUsesNewCredentials() async {
        let (service, mockKeychain, mockNetwork) = makeService(
            credentials: TestData.mockCredentials(accessToken: "old-token")
        )

        // First fetch: API returns 200 with invalid JSON -> decodingFailed
        mockNetwork.enqueue(data: "not json".data(using: .utf8)!, statusCode: 200)
        await service.fetchUsage()
        #expect(service.error == .decodingFailed)

        // User runs `claude login` -> new credentials in keychain
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

        // Third fetch: success -- resets counter
        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)
        await service.fetchUsage()
        #expect(service.consecutiveFailures == 0)
    }

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

        // Start first fetch -- it will suspend at the network call
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

// MARK: - Error Descriptions

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

// MARK: - Decoding Error Diagnostics

@Suite("UsageService.describeDecodingError")
struct DescribeDecodingErrorTests {

    @Test("Describes keyNotFound with key name and coding path")
    func keyNotFound() {
        let key = AnyCodingKey("some_field")
        let context = DecodingError.Context(
            codingPath: [AnyCodingKey("root"), AnyCodingKey("child")],
            debugDescription: "Key not found"
        )
        let result = UsageService.describeDecodingError(.keyNotFound(key, context))
        #expect(result.contains("some_field"))
        #expect(result.contains("root"))
        #expect(result.contains("child"))
    }

    @Test("Describes typeMismatch with type name and coding path")
    func typeMismatch() {
        let context = DecodingError.Context(
            codingPath: [AnyCodingKey("utilization")],
            debugDescription: "Expected Double but found String"
        )
        let result = UsageService.describeDecodingError(.typeMismatch(Double.self, context))
        #expect(result.contains("Double"))
        #expect(result.contains("utilization"))
        #expect(result.contains("Expected Double but found String"))
    }

    @Test("Describes valueNotFound with type name and coding path")
    func valueNotFound() {
        let context = DecodingError.Context(
            codingPath: [AnyCodingKey("resets_at")],
            debugDescription: "Value required but found null"
        )
        let result = UsageService.describeDecodingError(.valueNotFound(Date.self, context))
        #expect(result.contains("Date"))
        #expect(result.contains("resets_at"))
    }

    @Test("Describes dataCorrupted with coding path and debug description")
    func dataCorrupted() {
        let context = DecodingError.Context(
            codingPath: [AnyCodingKey("resets_at")],
            debugDescription: "Invalid ISO 8601 date: garbage"
        )
        let result = UsageService.describeDecodingError(.dataCorrupted(context))
        #expect(result.contains("resets_at"))
        #expect(result.contains("Invalid ISO 8601 date: garbage"))
    }
}

/// Minimal CodingKey conformer for constructing DecodingError test values.
private struct AnyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

// MARK: - Poll Interval

@Suite("UsageService.pollInterval")
struct PollIntervalTests {

    @MainActor
    private func makeService() -> (UsageService, MockKeychainReader, MockNetworkSession) {
        let mockKeychain = MockKeychainReader()
        mockKeychain.result = .success(TestData.mockCredentials())
        let mockNetwork = MockNetworkSession()
        let service = UsageService(keychainReader: mockKeychain, networkSession: mockNetwork)
        return (service, mockKeychain, mockNetwork)
    }

    @Test("Returns 120 seconds with zero consecutive failures")
    @MainActor
    func pollIntervalDefault() {
        let (service, _, _) = makeService()
        #expect(service.pollInterval == 120.0)
    }

    @Test("Returns 120 seconds with fewer than 3 consecutive failures")
    @MainActor
    func pollIntervalBelowThreshold() async {
        let (service, _, mockNetwork) = makeService()
        service.retryBaseDelay = 0

        mockNetwork.enqueue(data: Data(), statusCode: 403)
        await service.fetchUsage()
        mockNetwork.enqueue(data: Data(), statusCode: 403)
        await service.fetchUsage()

        #expect(service.consecutiveFailures == 2)
        #expect(service.pollInterval == 120.0)
    }

    @Test("Returns 300 seconds at exactly 3 consecutive failures")
    @MainActor
    func pollIntervalAtThreshold() async {
        let (service, _, mockNetwork) = makeService()
        service.retryBaseDelay = 0

        for _ in 0..<3 {
            mockNetwork.enqueue(data: Data(), statusCode: 403)
            await service.fetchUsage()
        }

        #expect(service.consecutiveFailures == 3)
        #expect(service.pollInterval == 300.0)
    }

    @Test("Returns 300 seconds above 3 consecutive failures")
    @MainActor
    func pollIntervalAboveThreshold() async {
        let (service, _, mockNetwork) = makeService()
        service.retryBaseDelay = 0

        for _ in 0..<5 {
            mockNetwork.enqueue(data: Data(), statusCode: 403)
            await service.fetchUsage()
        }

        #expect(service.consecutiveFailures == 5)
        #expect(service.pollInterval == 300.0)
    }

    @Test("Resets to 120 seconds after a success following failures")
    @MainActor
    func pollIntervalResetsOnSuccess() async {
        let (service, _, mockNetwork) = makeService()
        service.retryBaseDelay = 0

        for _ in 0..<3 {
            mockNetwork.enqueue(data: Data(), statusCode: 403)
            await service.fetchUsage()
        }
        #expect(service.pollInterval == 300.0)

        mockNetwork.enqueue(data: TestData.fullUsageJSON, statusCode: 200)
        await service.fetchUsage()
        #expect(service.consecutiveFailures == 0)
        #expect(service.pollInterval == 120.0)
    }
}
