import Foundation

/// Reads OAuth credentials from the macOS Keychain via the `security` CLI.
/// Uses `Task.detached` to run blocking `Process` code off the main thread.
public struct KeychainReader: KeychainReading {

    public init() {}

    /// Read and parse credentials from the keychain.
    public func readCredentials() async throws -> OAuthCredentials {
        let outputData: Data = try await Task.detached {
            try Self.runSecurityCLI()
        }.value
        return try Self.parseCredentials(from: outputData)
    }

    /// Synchronous helper — runs `security` CLI and returns stdout as Data.
    /// Called only from a detached task, so blocking is safe.
    /// All non-Sendable types (Process, Pipe) are created, used, and destroyed
    /// within this single synchronous scope — no Sendable violations.
    /// Terminates the child process and throws `.processTimeout` if it does
    /// not exit within `timeoutSeconds`.
    static let processTimeoutSeconds: Double = 10

    private static func runSecurityCLI() throws -> Data {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        try process.run()

        // Read stdout BEFORE waiting for exit to avoid pipe buffer deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        let deadline = DispatchTime.now() + processTimeoutSeconds
        if exited.wait(timeout: deadline) == .timedOut {
            process.terminate()
            // Give the process a moment to actually exit before returning.
            _ = exited.wait(timeout: .now() + 1)
            throw KeychainError.processTimeout
        }

        guard process.terminationStatus == 0 else {
            switch process.terminationStatus {
            case 44: throw KeychainError.notFound
            case 36: throw KeychainError.accessDenied
            default: throw KeychainError.processError(process.terminationStatus)
            }
        }
        return data
    }

    /// Parse keychain JSON into OAuthCredentials.
    /// Handles both `{ "claudeAiOauth": { ... } }` wrapper and bare `{ "accessToken": ... }` formats.
    /// Internal visibility for testability.
    static func parseCredentials(from data: Data) throws -> OAuthCredentials {
        guard let jsonString = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let jsonData = jsonString.data(using: .utf8) else {
            throw KeychainError.malformedJSON
        }

        // Try wrapped format first: { "claudeAiOauth": { ... } }
        struct Wrapper: Decodable {
            let claudeAiOauth: OAuthCredentials
        }
        if let wrapper = try? JSONDecoder().decode(Wrapper.self, from: jsonData) {
            return wrapper.claudeAiOauth
        }

        // Fall back to top-level: { "accessToken": "...", ... }
        do {
            return try JSONDecoder().decode(OAuthCredentials.self, from: jsonData)
        } catch {
            throw KeychainError.malformedJSON
        }
    }
}
