import Foundation

// MARK: - API Response Models

/// Clamp a value to the range 0...100.
private func clampUtilization(_ value: Double) -> Double {
    max(0.0, min(value, 100.0))
}

/// A single usage bucket (5-hour, 7-day, per-model).
public struct UsageBucket: Codable, Sendable, Equatable {
    public let utilization: Double
    public let resetsAt: Date?

    public init(utilization: Double, resetsAt: Date? = nil) {
        self.utilization = clampUtilization(utilization)
        self.resetsAt = resetsAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawUtilization = try container.decode(Double.self, forKey: .utilization)
        utilization = clampUtilization(rawUtilization)
        if let dateString = try container.decodeIfPresent(String.self, forKey: .resetsAt) {
            guard let date = Date.fromAPI(dateString) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .resetsAt, in: container,
                    debugDescription: "Invalid ISO 8601 date: \(dateString)"
                )
            }
            resetsAt = date
        } else {
            resetsAt = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// Top-level usage API response.
public struct UsageResponse: Sendable, Equatable {
    public let fiveHour: UsageBucket?
    public let sevenDay: UsageBucket?
    public let sevenDayOpus: UsageBucket?
    public let sevenDaySonnet: UsageBucket?
    public let extraUsage: ExtraUsage?
    public let limits: [UsageLimit]

    /// Whether this response contains any renderable usage data.
    /// False when the API returns 200 but all buckets and limits are null/missing.
    public var hasAnyUsageData: Bool {
        !usageRows(for: self).isEmpty || (extraUsage?.isEnabled == true)
    }

    public init(
        fiveHour: UsageBucket? = nil,
        sevenDay: UsageBucket? = nil,
        sevenDayOpus: UsageBucket? = nil,
        sevenDaySonnet: UsageBucket? = nil,
        extraUsage: ExtraUsage? = nil,
        limits: [UsageLimit] = []
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.extraUsage = extraUsage
        self.limits = limits
    }
}

extension UsageResponse: Decodable {
    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
        case limits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try container.decodeIfPresent(UsageBucket.self, forKey: .fiveHour)
        sevenDay = try container.decodeIfPresent(UsageBucket.self, forKey: .sevenDay)
        sevenDayOpus = try container.decodeIfPresent(UsageBucket.self, forKey: .sevenDayOpus)
        sevenDaySonnet = try container.decodeIfPresent(UsageBucket.self, forKey: .sevenDaySonnet)
        extraUsage = try container.decodeIfPresent(ExtraUsage.self, forKey: .extraUsage)
        limits = (try? container.decodeIfPresent(LossyArray<UsageLimit>.self, forKey: .limits))?.elements ?? []
    }
}

// MARK: - Limits

/// What a scoped limit applies to (a model, a surface, or both).
public struct LimitScope: Sendable, Equatable {
    public let modelId: String?
    public let modelDisplayName: String?
    public let surface: String?

    public init(modelId: String? = nil, modelDisplayName: String? = nil, surface: String? = nil) {
        self.modelId = modelId
        self.modelDisplayName = modelDisplayName
        self.surface = surface
    }
}

/// One entry of the API's self-describing `limits` array.
public struct UsageLimit: Sendable, Equatable {
    public let kind: String
    public let group: String?
    public let percent: Double
    public let severity: String?
    public let resetsAt: Date?
    public let scope: LimitScope?
    public let isActive: Bool

    public var modelDisplayName: String? { scope?.modelDisplayName }

    public init(
        kind: String,
        group: String? = nil,
        percent: Double,
        severity: String? = nil,
        resetsAt: Date? = nil,
        scope: LimitScope? = nil,
        isActive: Bool = true
    ) {
        self.kind = kind
        self.group = group
        self.percent = clampUtilization(percent)
        self.severity = severity
        self.resetsAt = resetsAt
        self.scope = scope
        self.isActive = isActive
    }
}

extension UsageLimit: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(String.self, forKey: .kind),
            group: try? container.decodeIfPresent(String.self, forKey: .group),
            percent: try container.decode(Double.self, forKey: .percent),
            severity: try? container.decodeIfPresent(String.self, forKey: .severity),
            resetsAt: (try? container.decodeIfPresent(String.self, forKey: .resetsAt)).flatMap(Date.fromAPI),
            scope: try container.decodeIfPresent(LimitScope.self, forKey: .scope),
            isActive: (try? container.decodeIfPresent(Bool.self, forKey: .isActive)) ?? true
        )
    }
}

extension LimitScope: Decodable {
    private enum CodingKeys: String, CodingKey { case model, surface }

    /// A `{id, display_name}` object. Throws unless at least one field is a non-empty string,
    /// so an identity-less object can't masquerade as "no restriction".
    private struct Named: Decodable {
        let id: String?
        let displayName: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id).flatMap { $0.isEmpty ? nil : $0 }
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName).flatMap { $0.isEmpty ? nil : $0 }
            guard id != nil || displayName != nil else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Scope object has no id or display_name")
                )
            }
        }
    }

    /// Strict: a scope that is present but malformed throws, so the whole limit entry is
    /// dropped rather than silently treated as unrestricted.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let model = try container.decodeIfPresent(Named.self, forKey: .model)
        self.init(
            modelId: model?.id,
            modelDisplayName: model?.displayName,
            surface: try Self.decodeSurface(from: container)
        )
    }

    /// Surface may be absent/null, a string, or a `{id, display_name}` object.
    private static func decodeSurface(from container: KeyedDecodingContainer<CodingKeys>) throws -> String? {
        guard container.contains(.surface), try !container.decodeNil(forKey: .surface) else { return nil }
        if let string = try? container.decode(String.self, forKey: .surface) {
            return string
        }
        let named = try container.decode(Named.self, forKey: .surface)
        return named.displayName ?? named.id
    }
}

/// Decodes an array element by element, dropping elements that fail to decode.
struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                decoded.append(element)
            } else {
                _ = try container.decode(Skip.self)
            }
        }
        elements = decoded
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
/// Per RFC 6749 §6, the server MAY omit refresh_token in a refresh response;
/// the client should keep using the existing refresh token when absent.
public struct TokenRefreshResponse: Sendable, Equatable {
    public let accessToken: String
    public let tokenType: String
    public let expiresIn: Int
    public let refreshToken: String?

    public init(accessToken: String, tokenType: String, expiresIn: Int, refreshToken: String? = nil) {
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

        // Claude Code stores timestamps as JavaScript epoch (milliseconds).
        // Heuristic: values > 1 trillion are milliseconds; smaller values are seconds.
        let expiresAtRaw = try container.decodeFirstMatch(
            Double.self, keys: ["expiresAt", "expires_at"]
        )
        if expiresAtRaw > 1_000_000_000_000 {
            expiresAt = Date(timeIntervalSince1970: expiresAtRaw / 1000.0)
        } else {
            expiresAt = Date(timeIntervalSince1970: expiresAtRaw)
        }

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
    /// Throws the underlying error if a key is found but has the wrong type,
    /// or `keyNotFound` if none of the keys are present.
    public func decodeFirstMatch<T: Decodable>(
        _ type: T.Type, keys: [String]
    ) throws -> T {
        var lastTypeMismatch: Error?
        for keyName in keys {
            let key = FlexibleCodingKey(stringValue: keyName)
            if contains(key) {
                do {
                    return try decode(type, forKey: key)
                } catch {
                    lastTypeMismatch = error
                }
            }
        }
        if let lastTypeMismatch {
            throw lastTypeMismatch
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
    /// Parse ISO 8601 date strings from the API.
    /// Uses ISO8601DateFormatter with .withInternetDateTime which correctly
    /// handles colon-separated timezone offsets (+00:00) on all locales.
    /// (Date.ISO8601FormatStyle's timeZoneSeparator proved unreliable on
    /// some macOS configurations, silently interpreting +00:00 offsets using
    /// the system timezone instead of UTC.)

    private nonisolated(unsafe) static let isoFormatterWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private nonisolated(unsafe) static let isoFormatterBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func fromAPI(_ string: String) -> Date? {
        isoFormatterWithFractional.date(from: string)
            ?? isoFormatterBasic.date(from: string)
    }
}
