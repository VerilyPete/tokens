import AppKit
import Foundation
import Observation
import os

private let logger = Logger(subsystem: "com.tokens.claude-usage", category: "UsageService")

/// OAuth client ID for Claude Code.
let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

/// Beta header value required for the usage API.
let betaHeaderValue = "oauth-2025-04-20"

/// Allowed chars for form-urlencoded values: unreserved chars only (RFC 3986).
/// Module-level so nonisolated static methods can access it without actor hop.
private let formValueAllowed: CharacterSet = {
    var cs = CharacterSet.alphanumerics
    cs.insert(charactersIn: "-._~")
    return cs
}()

// MARK: - UsageService

@MainActor @Observable
public final class UsageService {
    // MARK: Published state (drives UI)

    public var usage: UsageResponse?
    public var error: UsageError?
    public var lastUpdated: Date?
    public private(set) var isLoading = false
    public var subscriptionType: String?

    /// Menu bar label — computed from current state.
    /// Uses `hasAnyUsageData` so we don't imply data is present when all buckets are null.
    public var menuBarLabel: String {
        formatMenuBarLabel(
            utilization: usage?.fiveHour?.utilization,
            hasError: error != nil,
            hasData: usage?.hasAnyUsageData ?? false
        )
    }

    // MARK: Token state (in-memory only)

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiresAt: Date?
    private nonisolated(unsafe) var pollTask: Task<Void, Never>?
    private nonisolated(unsafe) var wakeTask: Task<Void, Never>?
    private nonisolated(unsafe) var wakeObserver: NSObjectProtocol?
    private var isRefreshing = false
    private(set) var consecutiveFailures = 0

    // MARK: Dependencies (injected for testability)

    private let keychainReader: any KeychainReading
    private let networkSession: any NetworkSession
    /// User-Agent header value. Internal for test verification.
    var userAgent: String = "claude-code/0.0.0"
    /// Base delay for transient error retries (seconds). Set to 0 in tests.
    var retryBaseDelay: TimeInterval = 2.0

    // MARK: Init

    /// Production initializer — uses real keychain and URLSession.
    /// Starts polling immediately (not from .onAppear, because MenuBarExtra
    /// with .window style fires .onAppear lazily when popover is first opened).
    public convenience init() {
        self.init(
            keychainReader: KeychainReader(),
            networkSession: URLSession.shared,
            startPollingOnInit: true
        )
    }

    /// Testable initializer — inject mock dependencies.
    /// Does NOT auto-start polling (tests call fetchUsage() directly).
    public init(
        keychainReader: any KeychainReading,
        networkSession: any NetworkSession,
        startPollingOnInit: Bool = false
    ) {
        self.keychainReader = keychainReader
        self.networkSession = networkSession
        if startPollingOnInit {
            startPolling()
        }
    }

    deinit {
        pollTask?.cancel()
        wakeTask?.cancel()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    // MARK: Polling

    /// Polling interval based on consecutive failure count.
    /// Returns 300 s after 3+ consecutive failures, 120 s otherwise.
    var pollInterval: TimeInterval {
        consecutiveFailures >= 3 ? 300.0 : 120.0
    }

    public func startPolling() {
        // Prevent double-registration: clean up any existing poll + wake observer
        stopPolling()

        // Fire-and-forget: version detection runs in parallel with first fetch
        Task { await detectClaudeVersion() }

        pollTask = Task {
            while !Task.isCancelled {
                await fetchUsage()
                let interval = pollInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                logger.info("System wake detected, scheduling refresh")
                self?.wakeTask?.cancel()
                self?.wakeTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    await self?.fetchUsage()
                }
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        wakeTask?.cancel()
        wakeTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    // MARK: Manual Actions

    /// Force a keychain re-read and immediate fetch.
    /// Always clears in-memory tokens so the next fetch re-reads the keychain.
    /// If a fetch is already in-flight, skips clearing the error to avoid a
    /// misleading state where the error disappears but no new fetch runs.
    public func reloadCredentials() async {
        accessToken = nil
        refreshToken = nil
        tokenExpiresAt = nil
        guard !isLoading else { return }
        error = nil
        await fetchUsage()
    }

    // MARK: Fetch

    public func fetchUsage() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        // Ensure we have a token
        if accessToken == nil {
            do {
                let creds = try await keychainReader.readCredentials()
                accessToken = creds.accessToken
                refreshToken = creds.refreshToken
                tokenExpiresAt = creds.expiresAt
                subscriptionType = creds.subscriptionType
                logger.info("Keychain read succeeded, subscription: \(creds.subscriptionType ?? "unknown")")
            } catch let err as KeychainError {
                error = .keychain(err)
                consecutiveFailures += 1
                logger.error("Keychain read failed: \(err.localizedDescription)")
                return
            } catch {
                self.error = .keychain(.malformedJSON)
                consecutiveFailures += 1
                return
            }
        }

        // Proactive refresh if token expires within 15 minutes
        if let expiresAt = tokenExpiresAt,
           expiresAt.timeIntervalSinceNow < 900 {
            _ = await refreshTokenIfNeeded()
        }

        // Make the API request (with retry on 401)
        await performFetch(retryOn401: true)
    }

    private func performFetch(retryOn401: Bool) async {
        guard let token = accessToken else {
            error = .unauthorized
            return
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeaderValue, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        // Retry loop: up to 4 attempts (initial + 3 retries) for transient errors
        var lastResponseBody: String?
        for attempt in 0...3 {
            guard !Task.isCancelled else { return }
            if attempt > 0 {
                let delay = retryBaseDelay * Double(1 << (attempt - 1))  // 2, 4, 8
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
            }

            do {
                let (data, response) = try await networkSession.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    if attempt < 3 { continue }
                    error = .network(URLError(.badServerResponse))
                    consecutiveFailures += 1
                    return
                }

                let bodyString = String(data: data, encoding: .utf8) ?? "<non-UTF8, \(data.count) bytes>"
                lastResponseBody = bodyString
                logger.debug("HTTP \(httpResponse.statusCode) response body: \(bodyString, privacy: .public)")

                switch httpResponse.statusCode {
                case 200:
                    let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
                    usage = decoded
                    lastUpdated = Date()
                    error = nil
                    consecutiveFailures = 0
                    logger.info("Usage fetched: \(decoded.fiveHour?.utilization.description ?? "nil")%")
                    return

                case 401:
                    // Not transient — handle auth specifically, no backoff retry
                    if retryOn401 {
                        logger.info("Got 401, attempting token refresh")
                        let refreshed = await refreshTokenIfNeeded()
                        if refreshed {
                            await performFetch(retryOn401: false)
                        } else {
                            // Refresh failed — try re-reading keychain
                            do {
                                let creds = try await keychainReader.readCredentials()
                                accessToken = creds.accessToken
                                refreshToken = creds.refreshToken
                                tokenExpiresAt = creds.expiresAt
                                subscriptionType = creds.subscriptionType
                                await performFetch(retryOn401: false)
                            } catch let keychainErr as KeychainError {
                                self.error = .keychain(keychainErr)
                                consecutiveFailures += 1
                            } catch {
                                self.error = .unauthorized
                                consecutiveFailures += 1
                            }
                        }
                    } else {
                        error = .unauthorized
                        consecutiveFailures += 1
                    }
                    return

                case 403:
                    error = .forbidden
                    consecutiveFailures += 1
                    logger.error("403 Forbidden — likely wrong scope (setup-token vs login)")
                    return

                case 429, 500...599:
                    // Transient — retry with backoff
                    logger.warning("Transient error: HTTP \(httpResponse.statusCode), attempt \(attempt + 1)/4")
                    if attempt < 3 { continue }
                    error = .http(statusCode: httpResponse.statusCode)
                    consecutiveFailures += 1
                    return

                default:
                    error = .http(statusCode: httpResponse.statusCode)
                    consecutiveFailures += 1
                    return
                }
            } catch let urlError as URLError {
                // Network errors are transient — retry with backoff
                logger.error("Network error (attempt \(attempt + 1)/4): \(urlError.localizedDescription)")
                if attempt < 3 { continue }
                error = .network(urlError)
                consecutiveFailures += 1
                return
            } catch let decodingError as DecodingError {
                // Decoding errors are not transient — don't retry
                let detail = Self.describeDecodingError(decodingError)
                logger.error("API response decoding failed: \(detail, privacy: .public)")
                if let rawBody = lastResponseBody {
                    logger.error("Raw response body was: \(rawBody, privacy: .public)")
                }
                error = .decodingFailed
                consecutiveFailures += 1
                return
            } catch {
                self.error = .network(URLError(.unknown))
                consecutiveFailures += 1
                return
            }
        }
    }

    // MARK: Token Refresh

    func refreshTokenIfNeeded() async -> Bool {
        guard !isRefreshing else { return false }
        guard let currentRefreshToken = refreshToken else { return false }
        isRefreshing = true
        defer { isRefreshing = false }

        guard let body = Self.buildRefreshBody(refreshToken: currentRefreshToken) else {
            return false
        }

        var request = URLRequest(url: URL(string: "https://console.anthropic.com/v1/oauth/token")!)
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        do {
            let (data, response) = try await networkSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                logger.error("Token refresh failed: HTTP \(code)")
                return false
            }

            let tokenResponse = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)
            accessToken = tokenResponse.accessToken
            if let newRefreshToken = tokenResponse.refreshToken {
                refreshToken = newRefreshToken
            }
            let expiresIn = max(tokenResponse.expiresIn, 60)
            tokenExpiresAt = Date(timeIntervalSinceNow: TimeInterval(expiresIn))
            logger.info("Token refreshed, expires in \(expiresIn)s")
            return true
        } catch {
            logger.error("Token refresh error: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: Form Encoding (nonisolated static for testability)

    /// Build form-urlencoded body for token refresh.
    /// Uses strict percent-encoding to prevent token corruption.
    nonisolated static func buildRefreshBody(refreshToken: String) -> Data? {
        let pairs: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", oauthClientId),
        ]
        let encoded = pairs.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: formValueAllowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: formValueAllowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return encoded.data(using: .utf8)
    }

    // MARK: Decoding Error Diagnostics

    /// Extract a human-readable description from a DecodingError for logging.
    nonisolated static func describeDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return "Missing key '\(key.stringValue)' at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .typeMismatch(let type, let context):
            return "Type mismatch for \(type) at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "Null value for \(type) at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .dataCorrupted(let context):
            return "Data corrupted at \(context.codingPath.map(\.stringValue).joined(separator: ".")): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    // MARK: Version Detection (internal static for testability)

    /// Parse version string like "Claude Code v1.2.3" → "1.2.3"
    nonisolated static func parseVersion(from output: String) -> String? {
        output.firstMatch(of: /v(\d+\.\d+\.\d+)/).map { String($0.1) }
    }

    private func detectClaudeVersion() async {
        let version: String? = await Task.detached {
            let candidates = [
                "\(NSHomeDirectory())/.claude/bin/claude",
                "/usr/local/bin/claude",
            ]
            for path in candidates {
                if FileManager.default.isExecutableFile(atPath: path),
                   let output = try? Self.runProcess(path, arguments: ["--version"]) {
                    return Self.parseVersion(from: output)
                }
            }
            if let output = try? Self.runProcess("/bin/sh", arguments: ["-c", "claude --version"]) {
                return Self.parseVersion(from: output)
            }
            return nil
        }.value

        if let version {
            userAgent = "claude-code/\(version)"
        }
    }

    /// Errors specific to version-detection subprocess execution.
    private enum ProcessError: Error {
        case timeout
        case nonZeroExit(Int32)
    }

    /// Run a process synchronously and return its stdout.
    /// Must be nonisolated static since it's called from Task.detached.
    /// Terminates the child process and throws `.timeout` if it does
    /// not exit within `processTimeoutSeconds`.
    private nonisolated static let processTimeoutSeconds: Double = 10

    private nonisolated static func runProcess(
        _ executablePath: String, arguments: [String]
    ) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        let deadline = DispatchTime.now() + processTimeoutSeconds
        if exited.wait(timeout: deadline) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
            throw ProcessError.timeout
        }

        guard process.terminationStatus == 0 else {
            throw ProcessError.nonZeroExit(process.terminationStatus)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
