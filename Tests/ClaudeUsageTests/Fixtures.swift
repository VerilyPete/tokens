import Foundation
@testable import ClaudeUsageKit

enum Fixtures {
    /// Live /api/oauth/usage response from a verified Ultra account (2026-11-05),
    /// trimmed of unrelated null keys. No PII.
    static let ultraUsageJSON = """
    {
        "five_hour": null,
        "seven_day": {
            "utilization": 3.0,
            "resets_at": "2026-11-09T05:59:59.749846+00:00",
            "limit_dollars": null,
            "used_dollars": null,
            "remaining_dollars": null,
            "locked_reason": null
        },
        "seven_day_oauth_apps": null,
        "seven_day_opus": null,
        "seven_day_sonnet": null,
        "extra_usage": {
            "is_enabled": false,
            "monthly_limit": 7000,
            "used_credits": 0.0,
            "utilization": 0.0,
            "currency": "USD"
        },
        "limits": [
            {
                "kind": "weekly_all",
                "group": "weekly",
                "percent": 3,
                "severity": "normal",
                "resets_at": "2026-11-09T05:59:59.749846+00:00",
                "scope": null,
                "is_active": true
            },
            {
                "kind": "weekly_scoped",
                "group": "weekly",
                "percent": 0,
                "severity": "normal",
                "resets_at": "2026-11-09T06:00:00+00:00",
                "scope": {
                    "model": {"id": null, "display_name": "Fable"},
                    "surface": null
                },
                "is_active": false
            }
        ]
    }
    """

    static func decodeUsage(_ json: String) throws -> UsageResponse {
        try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
    }

    static func limitJSON(
        kind: String = "weekly_scoped",
        percent: Double = 10,
        model: String? = nil,
        surface: String? = nil,
        isActive: Bool = true
    ) -> String {
        let modelJSON = model.map { "{\"id\": null, \"display_name\": \"\($0)\"}" } ?? "null"
        let surfaceJSON = surface.map { "\"\($0)\"" } ?? "null"
        let scope = (model == nil && surface == nil)
            ? "null"
            : "{\"model\": \(modelJSON), \"surface\": \(surfaceJSON)}"
        return """
        {"kind": "\(kind)", "group": "weekly", "percent": \(percent), "severity": "normal",
         "resets_at": "2026-11-09T06:00:00+00:00", "scope": \(scope), "is_active": \(isActive)}
        """
    }

    static func usageJSON(limits: [String], legacy: String = "") -> String {
        let prefix = legacy.isEmpty ? "" : legacy + ","
        return "{\(prefix) \"limits\": [\(limits.joined(separator: ","))]}"
    }
}
