import Foundation

// MARK: - API Response Models

/// A single usage bucket (5-hour, 7-day, per-model).
public struct UsageBucket: Codable, Sendable, Equatable {
    public let utilization: Double
    public let resetsAt: Date

    public init(utilization: Double, resetsAt: Date) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        utilization = try container.decode(Double.self, forKey: .utilization)
        let dateString = try container.decode(String.self, forKey: .resetsAt)
        guard let date = Date.fromAPI(dateString) else {
            throw DecodingError.dataCorruptedError(
                forKey: .resetsAt, in: container,
                debugDescription: "Invalid ISO 8601 date: \(dateString)"
            )
        }
        resetsAt = date
    }

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// Top-level usage API response.
public struct UsageResponse: Sendable, Equatable {
    public let fiveHour: UsageBucket
    public let sevenDay: UsageBucket
    public let sevenDayOpus: UsageBucket?
    public let sevenDaySonnet: UsageBucket?
    public let extraUsage: ExtraUsage?

    public init(
        fiveHour: UsageBucket,
        sevenDay: UsageBucket,
        sevenDayOpus: UsageBucket? = nil,
        sevenDaySonnet: UsageBucket? = nil,
        extraUsage: ExtraUsage? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.extraUsage = extraUsage
    }
}

extension UsageResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try container.decode(UsageBucket.self, forKey: .fiveHour)
        sevenDay = try container.decode(UsageBucket.self, forKey: .sevenDay)
        sevenDayOpus = try container.decodeIfPresent(UsageBucket.self, forKey: .sevenDayOpus)
        sevenDaySonnet = try container.decodeIfPresent(UsageBucket.self, forKey: .sevenDaySonnet)
        extraUsage = try container.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
    }
}

/// Extra usage (overuse billing) info.
public struct ExtraUsage: Codable, Sendable, Equatable {
    public let isEnabled: Bool
    public let monthlyLimit: Double?
    public let usedCredits: Double?
    public let utilization: Double?

    public init(isEnabled: Bool, monthlyLimit: Double? = nil, usedCredits: Double? = nil, utilization: Double? = nil) {
        self.isEnabled = isEnabled
        self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits
        self.utilization = utilization
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
    }
}

// MARK: - Token Refresh Response

/// Response from POST /v1/oauth/token.
public struct TokenRefreshResponse: Sendable, Equatable {
    public let accessToken: String
    public let tokenType: String
    public let expiresIn: Int
    public let refreshToken: String

    public init(accessToken: String, tokenType: String, expiresIn: Int, refreshToken: String) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
        self.refreshToken = refreshToken
    }
}

extension TokenRefreshResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

// MARK: - OAuth Credentials (from Keychain)

/// Parsed from the macOS Keychain JSON. Supports both camelCase and snake_case keys.
public struct OAuthCredentials: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let subscriptionType: String?
    public let rateLimitTier: String?

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }
}

extension OAuthCredentials: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: FlexibleCodingKey.self)

        accessToken = try container.decodeFirstMatch(
            String.self, keys: ["accessToken", "access_token"]
        )
        refreshToken = try container.decodeFirstMatch(
            String.self, keys: ["refreshToken", "refresh_token"]
        )

        let expiresAtMs = try container.decodeFirstMatch(
            Double.self, keys: ["expiresAt", "expires_at"]
        )
        expiresAt = Date(timeIntervalSince1970: expiresAtMs / 1000.0)

        subscriptionType = try? container.decodeFirstMatch(
            String.self, keys: ["subscriptionType", "subscription_type"]
        )
        rateLimitTier = try? container.decodeFirstMatch(
            String.self, keys: ["rateLimitTier", "rate_limit_tier"]
        )
    }
}

// MARK: - Flexible Decoding Helpers

/// A CodingKey that accepts any string — used for trying multiple key variants.
public struct FlexibleCodingKey: CodingKey {
    public var stringValue: String
    public var intValue: Int?

    public init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    public init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension KeyedDecodingContainer where Key == FlexibleCodingKey {
    /// Try decoding a value using multiple possible key names, in order.
    /// Throws if none of the keys are present.
    public func decodeFirstMatch<T: Decodable>(
        _ type: T.Type, keys: [String]
    ) throws -> T {
        for keyName in keys {
            let key = FlexibleCodingKey(stringValue: keyName)
            if let value = try? decode(type, forKey: key) {
                return value
            }
        }
        throw DecodingError.keyNotFound(
            FlexibleCodingKey(stringValue: keys.first ?? "unknown"),
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "None of the keys \(keys) found"
            )
        )
    }
}

// MARK: - Date Parsing

extension Date {
    /// Parse ISO 8601 with fractional seconds; fall back to without.
    /// Uses Date.ISO8601FormatStyle which is Sendable (unlike ISO8601DateFormatter).
    public static func fromAPI(_ string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse(string) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(string)
    }
}
