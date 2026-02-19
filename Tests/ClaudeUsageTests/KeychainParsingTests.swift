import Testing
import Foundation
@testable import ClaudeUsageKit

// MARK: - Phase 6: Keychain Parsing

@Suite("KeychainReader.parseCredentials")
struct KeychainParsingTests {

    // Cycle 6a: Wrapped format
    @Test("Parses wrapped format with claudeAiOauth key")
    func parseWrappedCredentials() throws {
        let creds = try KeychainReader.parseCredentials(from: TestData.wrappedCredentialsJSON)

        #expect(creds.accessToken == "test-access-token")
        #expect(creds.refreshToken == "test-refresh-token")
        #expect(creds.subscriptionType == "Pro")
    }

    // Cycle 6b: Bare format
    @Test("Parses bare format without wrapper key")
    func parseBareCredentials() throws {
        let creds = try KeychainReader.parseCredentials(from: TestData.camelCaseCredentialsJSON)

        #expect(creds.accessToken == "test-access-token")
        #expect(creds.refreshToken == "test-refresh-token")
    }

    // Cycle 6c: Malformed JSON
    @Test("Throws malformedJSON for invalid data")
    func parseMalformedJSON() throws {
        let garbage = "not json at all".data(using: .utf8)!

        #expect(throws: KeychainError.self) {
            try KeychainReader.parseCredentials(from: garbage)
        }
    }

    // Cycle 6d: Trailing whitespace
    @Test("Handles trailing newline in keychain output")
    func parseWithTrailingNewline() throws {
        let jsonWithNewline = """
        {"accessToken":"tok","refreshToken":"ref","expiresAt":1000000}\n
        """.data(using: .utf8)!

        let creds = try KeychainReader.parseCredentials(from: jsonWithNewline)
        #expect(creds.accessToken == "tok")
    }

    // Cycle 6e: Snake_case keys in wrapped format
    @Test("Parses wrapped format with snake_case keys inside")
    func parseWrappedSnakeCaseCredentials() throws {
        let json = """
        {
          "claudeAiOauth": {
            "access_token": "tok",
            "refresh_token": "ref",
            "expires_at": 1708123456000
          }
        }
        """.data(using: .utf8)!

        let creds = try KeychainReader.parseCredentials(from: json)
        #expect(creds.accessToken == "tok")
        #expect(creds.refreshToken == "ref")
    }
}
