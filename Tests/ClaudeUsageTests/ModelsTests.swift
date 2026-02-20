import Testing
import Foundation
@testable import ClaudeUsageKit

// MARK: - Phase 2: UsageBucket

@Suite("UsageBucket Decoding")
struct UsageBucketTests {

    // Cycle 2a: Decode with fractional seconds
    @Test("Decodes utilization and ISO 8601 date with fractional seconds")
    func decodeBucketWithFractionalSeconds() throws {
        let json = """
        {"utilization": 37.0, "resets_at": "2026-02-08T04:59:59.000000+00:00"}
        """.data(using: .utf8)!

        let bucket = try JSONDecoder().decode(UsageBucket.self, from: json)

        #expect(bucket.utilization == 37.0)
        // 2026-02-08T04:59:59Z = 1770526799 seconds since epoch
        let resetsAt = try #require(bucket.resetsAt)
        #expect(abs(resetsAt.timeIntervalSince1970 - 1770526799) < 1)
    }

    // Cycle 2b: Decode without fractional seconds
    @Test("Decodes ISO 8601 date without fractional seconds")
    func decodeBucketWithoutFractionalSeconds() throws {
        let json = """
        {"utilization": 50.0, "resets_at": "2026-02-08T05:00:00+00:00"}
        """.data(using: .utf8)!

        let bucket = try JSONDecoder().decode(UsageBucket.self, from: json)

        #expect(bucket.utilization == 50.0)
        // 2026-02-08T05:00:00Z = 1770526800 seconds since epoch
        let resetsAt = try #require(bucket.resetsAt)
        #expect(abs(resetsAt.timeIntervalSince1970 - 1770526800) < 1)
    }

    // Cycle 2c: Reject malformed date
    @Test("Throws on malformed date string")
    func decodeBucketWithBadDate() throws {
        let json = """
        {"utilization": 37.0, "resets_at": "not-a-date"}
        """.data(using: .utf8)!

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(UsageBucket.self, from: json)
        }
    }

    // Cycle 2d: Negative utilization clamped to 0
    @Test("Clamps negative utilization to 0")
    func decodeBucketClampsNegative() throws {
        let json = """
        {"utilization": -5.0, "resets_at": "2026-02-08T04:59:59.000000+00:00"}
        """.data(using: .utf8)!

        let bucket = try JSONDecoder().decode(UsageBucket.self, from: json)
        #expect(bucket.utilization == 0.0)
    }

    // Cycle 2e: Utilization above 100 clamped to 100
    @Test("Clamps utilization above 100 to 100")
    func decodeBucketClampsOver100() throws {
        let json = """
        {"utilization": 150.0, "resets_at": "2026-02-08T04:59:59.000000+00:00"}
        """.data(using: .utf8)!

        let bucket = try JSONDecoder().decode(UsageBucket.self, from: json)
        #expect(bucket.utilization == 100.0)
    }

    // Cycle 2f: Programmatic init clamps negative utilization
    @Test("Programmatic init clamps negative utilization to 0")
    func programmaticInitClampsNegative() {
        let bucket = UsageBucket(utilization: -10.0, resetsAt: Date())
        #expect(bucket.utilization == 0.0)
    }

    // Cycle 2g: Programmatic init clamps utilization above 100
    @Test("Programmatic init clamps utilization above 100 to 100")
    func programmaticInitClampsOver100() {
        let bucket = UsageBucket(utilization: 200.0, resetsAt: Date())
        #expect(bucket.utilization == 100.0)
    }

    // Cycle 2h: Programmatic init preserves valid utilization
    @Test("Programmatic init preserves valid utilization unchanged")
    func programmaticInitPreservesValid() {
        let bucket = UsageBucket(utilization: 42.5, resetsAt: Date())
        #expect(bucket.utilization == 42.5)
    }

    // Cycle 2i: Decode with null resets_at
    @Test("Decodes bucket with null resets_at as nil date")
    func decodeBucketWithNullResetsAt() throws {
        let json = """
        {"utilization": 0.0, "resets_at": null}
        """.data(using: .utf8)!

        let bucket = try JSONDecoder().decode(UsageBucket.self, from: json)
        #expect(bucket.utilization == 0.0)
        #expect(bucket.resetsAt == nil)
    }
}

// MARK: - Phase 3: UsageResponse

@Suite("UsageResponse Decoding")
struct UsageResponseTests {

    // Cycle 3a: Full response with all fields
    @Test("Decodes complete API response with all fields")
    func decodeFullUsageResponse() throws {
        let response = try JSONDecoder().decode(UsageResponse.self, from: TestData.fullUsageJSON)

        #expect(response.fiveHour?.utilization == 37.0)
        #expect(response.sevenDay?.utilization == 26.0)
        #expect(response.sevenDayOpus == nil)
        #expect(response.sevenDaySonnet != nil)
        #expect(response.sevenDaySonnet?.utilization == 1.0)
        #expect(response.extraUsage != nil)
        #expect(response.extraUsage?.isEnabled == false)
    }

    // Cycle 3b: Response with null/missing optional fields
    @Test("Decodes response with null and missing optional fields")
    func decodeResponseWithNullOptionals() throws {
        let response = try JSONDecoder().decode(UsageResponse.self, from: TestData.minimalUsageJSON)

        #expect(response.fiveHour?.utilization == 50.0)
        #expect(response.sevenDay?.utilization == 10.0)
        #expect(response.sevenDayOpus == nil)
        #expect(response.sevenDaySonnet == nil)
        #expect(response.extraUsage == nil)
    }

    // Cycle 3c: Response with null five_hour and seven_day
    @Test("Decodes response where five_hour and seven_day are null")
    func decodeResponseWithNullRequiredBuckets() throws {
        let response = try JSONDecoder().decode(UsageResponse.self, from: TestData.nullBucketsJSON)

        #expect(response.fiveHour == nil)
        #expect(response.sevenDay == nil)
    }

    // Cycle 3d: Response with only five_hour present
    @Test("Decodes response where only five_hour is present")
    func decodeResponseWithPartialBuckets() throws {
        let json = """
        {
          "five_hour": {
            "utilization": 25.0,
            "resets_at": "2026-02-08T05:00:00+00:00"
          },
          "seven_day": null
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(UsageResponse.self, from: json)

        #expect(response.fiveHour?.utilization == 25.0)
        #expect(response.sevenDay == nil)
    }

    // Cycle 3e: Empty response (no fields at all)
    @Test("Decodes empty JSON object with all buckets nil")
    func decodeEmptyResponse() throws {
        let json = "{}".data(using: .utf8)!
        let response = try JSONDecoder().decode(UsageResponse.self, from: json)

        #expect(response.fiveHour == nil)
        #expect(response.sevenDay == nil)
        #expect(response.sevenDayOpus == nil)
        #expect(response.sevenDaySonnet == nil)
        #expect(response.extraUsage == nil)
    }

    // Cycle 3f: Unknown API fields must not cause a throw
    @Test("Ignores unknown API keys and decodes known fields correctly")
    func decodeResponseWithUnknownFields() throws {
        let response = try JSONDecoder().decode(UsageResponse.self, from: TestData.unknownFieldsUsageJSON)

        #expect(response.fiveHour?.utilization == 42.0)
        #expect(response.sevenDay?.utilization == 20.0)
        #expect(response.sevenDaySonnet?.utilization == 5.0)
        #expect(response.sevenDayOpus == nil)
        let extra = try #require(response.extraUsage)
        #expect(extra.isEnabled == true)
        #expect(extra.usedCredits == 1250.0)
        #expect(extra.monthlyLimit == 5000.0)
    }

    // Cycle 3g: seven_day_sonnet with null resets_at decodes correctly
    @Test("Decodes seven_day_sonnet with null resets_at in a complete payload")
    func decodeResponseSonnetNullResetsAt() throws {
        let response = try JSONDecoder().decode(UsageResponse.self, from: TestData.sonnetNullResetsAtJSON)

        let sonnet = try #require(response.sevenDaySonnet)
        #expect(sonnet.utilization == 10.0)
        #expect(sonnet.resetsAt == nil)
        #expect(response.fiveHour?.utilization == 37.0)
        #expect(response.extraUsage?.isEnabled == false)
    }
}

// MARK: - Phase 4: OAuthCredentials

@Suite("OAuthCredentials Decoding")
struct OAuthCredentialsTests {

    // Cycle 4a: CamelCase keys
    @Test("Decodes credentials with camelCase keys")
    func decodeCredentialsCamelCase() throws {
        let creds = try JSONDecoder().decode(
            OAuthCredentials.self, from: TestData.camelCaseCredentialsJSON
        )

        #expect(creds.accessToken == "test-access-token")
        #expect(creds.refreshToken == "test-refresh-token")
        #expect(creds.subscriptionType == "Pro")
        #expect(creds.rateLimitTier == "tier_1")
    }

    // Cycle 4b: Snake_case keys
    @Test("Decodes credentials with snake_case keys")
    func decodeCredentialsSnakeCase() throws {
        let creds = try JSONDecoder().decode(
            OAuthCredentials.self, from: TestData.snakeCaseCredentialsJSON
        )

        #expect(creds.accessToken == "test-access-token")
        #expect(creds.refreshToken == "test-refresh-token")
        #expect(creds.subscriptionType == "Max")
        #expect(creds.rateLimitTier == "tier_2")
    }

    // Cycle 4c: Epoch milliseconds → Date conversion
    @Test("Converts expiresAt from epoch milliseconds to Date")
    func credentialsExpiresAtConversion() throws {
        let creds = try JSONDecoder().decode(
            OAuthCredentials.self, from: TestData.camelCaseCredentialsJSON
        )

        // 1708123456000 ms = 1708123456.0 seconds since epoch
        let expectedDate = Date(timeIntervalSince1970: 1708123456.0)
        #expect(abs(creds.expiresAt.timeIntervalSince(expectedDate)) < 0.001)
    }

    // Cycle 4d: expiresAt seconds (Unix timestamp) heuristic
    @Test("Handles expiresAt in seconds (not milliseconds)")
    func credentialsExpiresAtSeconds() throws {
        let json = """
        {"accessToken": "tok", "refreshToken": "ref", "expiresAt": 1770559200}
        """.data(using: .utf8)!

        let creds = try JSONDecoder().decode(OAuthCredentials.self, from: json)

        // 1770559200 is in seconds (10 digits) — should NOT divide by 1000
        let expectedDate = Date(timeIntervalSince1970: 1770559200)
        #expect(abs(creds.expiresAt.timeIntervalSince(expectedDate)) < 0.001)
    }

    // Cycle 4f: Type mismatch propagated (not masked as key-not-found)
    @Test("Propagates type mismatch when key exists with wrong type")
    func credentialsTypeMismatchPropagated() {
        // accessToken is an integer, not a string — should throw typeMismatch
        let json = """
        {"accessToken": 12345, "refreshToken": "ref", "expiresAt": 1000000}
        """.data(using: .utf8)!

        do {
            _ = try JSONDecoder().decode(OAuthCredentials.self, from: json)
            Issue.record("Expected decoding to throw")
        } catch let error as DecodingError {
            guard case .typeMismatch = error else {
                Issue.record("Expected .typeMismatch but got \(error)")
                return
            }
        } catch {
            Issue.record("Expected DecodingError but got \(error)")
        }
    }

    // Cycle 4e: Optional fields absent
    @Test("Handles missing optional fields gracefully")
    func credentialsOptionalFields() throws {
        let json = """
        {"accessToken": "tok", "refreshToken": "ref", "expiresAt": 1000000}
        """.data(using: .utf8)!

        let creds = try JSONDecoder().decode(OAuthCredentials.self, from: json)

        #expect(creds.accessToken == "tok")
        #expect(creds.subscriptionType == nil)
        #expect(creds.rateLimitTier == nil)
    }
}

// MARK: - Phase 5: TokenRefreshResponse

@Suite("TokenRefreshResponse Decoding")
struct TokenRefreshResponseTests {

    // Cycle 5a: Decode refresh response
    @Test("Decodes token refresh response with snake_case keys")
    func decodeTokenRefreshResponse() throws {
        let response = try JSONDecoder().decode(
            TokenRefreshResponse.self, from: TestData.tokenRefreshJSON
        )

        #expect(response.accessToken == "new-access-token")
        #expect(response.tokenType == "Bearer")
        #expect(response.expiresIn == 3600)
        #expect(response.refreshToken == "new-refresh-token")
    }

    // Cycle 5b: Decode refresh response without refresh_token (RFC 6749 §6)
    @Test("Decodes refresh response without refresh_token field")
    func decodeTokenRefreshWithoutRefreshToken() throws {
        let response = try JSONDecoder().decode(
            TokenRefreshResponse.self, from: TestData.tokenRefreshNoRotateJSON
        )

        #expect(response.accessToken == "new-access-token")
        #expect(response.tokenType == "Bearer")
        #expect(response.expiresIn == 3600)
        #expect(response.refreshToken == nil)
    }
}

// MARK: - Date.fromAPI

@Suite("Date.fromAPI Parsing")
struct DateFromAPITests {

    @Test("Parses ISO 8601 with microsecond fractional seconds")
    func parseWithMicroseconds() {
        let date = Date.fromAPI("2026-02-12T14:59:59.771647+00:00")
        #expect(date != nil)
        // Verify correct UTC epoch (not shifted by local timezone)
        if let date {
            #expect(abs(date.timeIntervalSince1970 - 1770908399.771647) < 0.01)
        }
    }

    @Test("Parses ISO 8601 without fractional seconds")
    func parseWithoutFractional() {
        let date = Date.fromAPI("2026-02-08T05:00:00+00:00")
        #expect(date != nil)
        if let date {
            #expect(abs(date.timeIntervalSince1970 - 1770526800) < 1)
        }
    }

    @Test("Returns nil for invalid date strings")
    func parseInvalidDate() {
        let date = Date.fromAPI("not-a-date")
        #expect(date == nil)
    }

    @Test("Parses ISO 8601 with Z shorthand timezone")
    func parseWithZTimezone() {
        let date = Date.fromAPI("2026-02-08T05:00:00Z")
        #expect(date != nil)
        if let date {
            #expect(abs(date.timeIntervalSince1970 - 1770526800) < 1)
        }
    }

    @Test("Parses ISO 8601 with non-UTC offset")
    func parseWithNonUTCOffset() {
        let date = Date.fromAPI("2026-02-08T10:30:00+05:30")
        #expect(date != nil)
        // +05:30 offset: 10:30 local = 05:00 UTC = epoch 1770526800
        if let date {
            #expect(abs(date.timeIntervalSince1970 - 1770526800) < 1)
        }
    }
}

// MARK: - ExtraUsage Decoding

@Suite("ExtraUsage Decoding")
struct ExtraUsageTests {

    @Test("Decodes ExtraUsage with non-null credit values")
    func decodeExtraUsageEnabled() throws {
        let response = try JSONDecoder().decode(UsageResponse.self, from: TestData.extraUsageEnabledJSON)

        let extra = try #require(response.extraUsage)
        #expect(extra.isEnabled == true)
        #expect(extra.monthlyLimit == 100.0)
        #expect(extra.usedCredits == 12.5)
        #expect(extra.utilization == 12.5)
    }

    @Test("Decodes ExtraUsage with all-null optional fields")
    func decodeExtraUsageDisabled() throws {
        let response = try JSONDecoder().decode(UsageResponse.self, from: TestData.fullUsageJSON)

        let extra = try #require(response.extraUsage)
        #expect(extra.isEnabled == false)
        #expect(extra.monthlyLimit == nil)
        #expect(extra.usedCredits == nil)
        #expect(extra.utilization == nil)
    }

    @Test("Missing extra_usage key decodes as nil")
    func decodeExtraUsageMissing() throws {
        let response = try JSONDecoder().decode(UsageResponse.self, from: TestData.minimalUsageJSON)
        #expect(response.extraUsage == nil)
    }
}
