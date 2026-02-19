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
    public var isLoading = false
    public var subscriptionType: String?

    /// Menu bar label — computed from current state.
    public var menuBarLabel: String {
        formatMenuBarLabel(
            utilization: usage?.fiveHour.utilization,
            hasError: error != nil,
            hasData: usage != nil
        )
    }

    // MARK: Token state (in-memory only)

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiresAt: Date?
    private var pollTask: Task<Void, Never>?
    private var isRefreshing = false
    private var consecutiveFailures = 0
    private var wakeObserver: NSObjectProtocol?

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

    // MARK: Polling

    public func startPolling() {
        // Prevent double-registration: clean up any existing poll + wake observer
        stopPolling()

        pollTask = Task {
            await detectClaudeVersion()
            while !Task.isCancelled {
                await fetchUsage()
                let interval = consecutiveFailures >= 3 ? 300.0 : 120.0
                try? await Task.sleep(for: .seconds(interval))
            }
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            logger.info("System wake detected, scheduling refresh")
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                await self?.fetchUsage()
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    // MARK: Manual Actions

    /// Force a keychain re-read and immediate fetch.
    public func reloadCredentials() async {
        accessToken = nil
        refreshToken = nil
        tokenExpiresAt = nil
        error = nil
        await fetchUsage()
    }

    // MARK: Fetch

    public func fetchUsage() async {
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
                logger.error("Keychain read failed: \(err.localizedDescription)")
                return
            } catch {
                self.error = .keychain(.malformedJSON)
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
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeaderValue, forHTTPHeaderField: "anthropic-beta")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        // Retry loop: up to 4 attempts (initial + 3 retries) for transient errors
        for attempt in 0...3 {
            if attempt > 0 {
                let delay = retryBaseDelay * Double(1 << (attempt - 1))  // 2, 4, 8
                try? await Task.sleep(for: .seconds(delay))
            }

            do {
                let (data, response) = try await networkSession.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    if attempt < 3 { continue }
                    error = .network(URLError(.badServerResponse))
                    consecutiveFailures += 1
                    return
                }

                switch httpResponse.statusCode {
                case 200:
                    let decoded = try JSONDecoder().decode(UsageResponse.self, from: data)
                    usage = decoded
                    lastUpdated = Date()
                    error = nil
                    consecutiveFailures = 0
                    logger.info("Usage fetched: \(decoded.fiveHour.utilization)%")
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
                                await performFetch(retryOn401: false)
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
            } catch is DecodingError {
                // Decoding errors are not transient — don't retry
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
                error = .refreshFailed("HTTP \(code)")
                return false
            }

            let tokenResponse = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)
            accessToken = tokenResponse.accessToken
            refreshToken = tokenResponse.refreshToken
            tokenExpiresAt = Date(timeIntervalSinceNow: TimeInterval(tokenResponse.expiresIn))
            logger.info("Token refreshed, expires in \(tokenResponse.expiresIn)s")
            return true
        } catch {
            logger.error("Token refresh error: \(error.localizedDescription)")
            self.error = .refreshFailed(error.localizedDescription)
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
            let k = key.addingPercentEncoding(withAllowedCharacters: formValueAllowed)!
            let v = value.addingPercentEncoding(withAllowedCharacters: formValueAllowed)!
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return encoded.data(using: .utf8)
    }

    // MARK: Version Detection (internal static for testability)

    /// Parse version string like "Claude Code v1.2.3" → "1.2.3"
    nonisolated static func parseVersion(from output: String) -> String? {
        output.firstMatch(of: /v(\d+\.\d+\.\d+)/).map { String($0.1) }
    }

    private func detectClaudeVersion() async {
        let version: String? = try? await Task.detached {
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
            if let output = try? Self.runProcess("/bin/sh", arguments: ["-l", "-c", "claude --version"]) {
                return Self.parseVersion(from: output)
            }
            return nil
        }.value

        if let version {
            userAgent = "claude-code/\(version)"
        }
    }

    /// Run a process synchronously and return its stdout.
    /// Must be nonisolated static since it's called from Task.detached.
    private nonisolated static func runProcess(
        _ executablePath: String, arguments: [String]
    ) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw KeychainError.processError(process.terminationStatus)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
