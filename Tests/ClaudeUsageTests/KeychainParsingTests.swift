import Testing
import Foundation
@testable import ClaudeUsageKit

// MARK: - Keychain Parsing

@Suite("KeychainReader.parseCredentials")
struct KeychainParsingTests {

    @Test("Parses wrapped format with claudeAiOauth key")
    func parseWrappedCredentials() throws {
        let creds = try KeychainReader.parseCredentials(from: TestData.wrappedCredentialsJSON)

        #expect(creds.accessToken == "test-access-token")
        #expect(creds.refreshToken == "test-refresh-token")
        #expect(creds.subscriptionType == "Pro")
    }

    @Test("Parses bare format without wrapper key")
    func parseBareCredentials() throws {
        let creds = try KeychainReader.parseCredentials(from: TestData.camelCaseCredentialsJSON)

        #expect(creds.accessToken == "test-access-token")
        #expect(creds.refreshToken == "test-refresh-token")
    }

    @Test("Throws malformedJSON for invalid data")
    func parseMalformedJSON() throws {
        let garbage = "not json at all".data(using: .utf8)!

        #expect(throws: KeychainError.self) {
            try KeychainReader.parseCredentials(from: garbage)
        }
    }

    @Test("Handles trailing newline in keychain output")
    func parseWithTrailingNewline() throws {
        let jsonWithNewline = """
        {"accessToken":"tok","refreshToken":"ref","expiresAt":1000000}\n
        """.data(using: .utf8)!

        let creds = try KeychainReader.parseCredentials(from: jsonWithNewline)
        #expect(creds.accessToken == "tok")
    }

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
