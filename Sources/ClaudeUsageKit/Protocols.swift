import Foundation

// MARK: - Dependency Injection Protocols

/// Abstraction over keychain access for testability.
/// Concrete: `KeychainReader`. Test double: `MockKeychainReader`.
public protocol KeychainReading: Sendable {
    func readCredentials() async throws -> OAuthCredentials
}

/// Abstraction over URLSession for testability.
/// `URLSession` conforms via extension below. Test double: `MockNetworkSession`.
public protocol NetworkSession: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: NetworkSession {}

// MARK: - Keychain Errors

public enum KeychainError: Error, LocalizedError, Sendable, Equatable {
    case notFound
    case accessDenied
    case malformedJSON
    case processError(Int32)
    case processTimeout

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "No Claude Code credentials found. Run `claude login` in your terminal."
        case .accessDenied:
            return "Keychain access denied. Re-launch and click \"Always Allow\" when prompted."
        case .malformedJSON:
            return "Credential data is corrupted. Try running `claude login` again."
        case .processError(let code):
            return "Keychain read failed (exit code \(code))."
        case .processTimeout:
            return "Keychain read timed out. The security process may be unresponsive."
        }
    }
}

// MARK: - Usage Errors

public enum UsageError: Error, LocalizedError, Sendable, Equatable {
    case keychain(KeychainError)
    case network(URLError)
    case http(statusCode: Int)
    case unauthorized
    case forbidden
    case decodingFailed
    case refreshFailed(String)

    public var errorDescription: String? {
        switch self {
        case .keychain(let err): return err.errorDescription
        case .network: return "Network error. Check your internet connection."
        case .http(let code): return "Server returned HTTP \(code)."
        case .unauthorized: return "Session expired. Run `claude login` in your terminal."
        case .forbidden: return "Missing permissions. Run `claude login` (not `setup-token`)."
        case .decodingFailed: return "Unexpected API response format."
        case .refreshFailed(let reason): return "Token refresh failed: \(reason)"
        }
    }

    /// Whether this error indicates credentials are invalid and need to be
    /// refreshed from the keychain (i.e. the user should run `claude login`).
    /// Transient errors like network failures keep the existing valid token.
    public var requiresReauthentication: Bool {
        switch self {
        case .unauthorized, .forbidden, .refreshFailed, .keychain:
            return true
        case .network, .http, .decodingFailed:
            return false
        }
    }
}
