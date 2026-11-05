import Testing
import Foundation
@testable import ClaudeUsageKit

private func rows(_ json: String) throws -> [UsageRow] {
    usageRows(for: try Fixtures.decodeUsage(json))
}

private func headlinePercent(_ json: String) throws -> Double? {
    selectHeadline(from: try rows(json))?.percent
}

private let resets = #""resets_at": "2026-11-09T06:00:00+00:00""#

@Suite("Usage Rows")
struct UsageRowsTests {

    @Test("Ultra response yields weekly-all and Fable rows, de-duplicating legacy seven_day")
    func ultraRows() throws {
        let result = try rows(Fixtures.ultraUsageJSON)
        #expect(result.map(\.id) == ["weekly_all", "weekly_scoped:m=Fable"])
        #expect(result.map(\.label) == ["Weekly (All Models)", "Fable (Weekly)"])
        #expect(result.map(\.isActive) == [true, false])
    }

    @Test("Legacy-only response yields labelled rows in display order")
    func legacyRows() throws {
        let json = """
        {"seven_day_opus": {"utilization": 4}, "seven_day_sonnet": {"utilization": 5},
         "seven_day": {"utilization": 6}, "five_hour": {"utilization": 7, \(resets)}}
        """
        let result = try rows(json)
        #expect(result.map(\.id) == ["legacy:five_hour", "legacy:seven_day", "legacy:seven_day_opus", "legacy:seven_day_sonnet"])
        #expect(result.map(\.label) == ["5-Hour Session", "Weekly (All Models)", "Opus (Weekly)", "Sonnet (Weekly)"])
        #expect(result.allSatisfy { $0.isActive })
        #expect(result.first?.resetsAt != nil)
    }

    @Test("Ordering: 5-hour, weekly-all, scoped by label, then unknown kinds")
    func ordering() throws {
        let json = Fixtures.usageJSON(
            limits: [
                Fixtures.limitJSON(kind: "daily_burst", percent: 1),
                Fixtures.limitJSON(kind: "weekly_scoped", percent: 2, model: "Opus"),
                Fixtures.limitJSON(kind: "weekly_scoped", percent: 3, model: "Fable"),
                Fixtures.limitJSON(kind: "weekly_all", percent: 4),
            ],
            legacy: #""five_hour": {"utilization": 5}"#
        )
        #expect(try rows(json).map(\.label) == [
            "5-Hour Session", "Weekly (All Models)", "Fable (Weekly)", "Opus (Weekly)", "Daily burst",
        ])
    }

    @Test("Scoped row with a surface includes it in label and id")
    func surfaceInLabel() throws {
        let json = Fixtures.usageJSON(limits: [
            Fixtures.limitJSON(kind: "weekly_scoped", percent: 2, model: "Sonnet", surface: "claude_code")
        ])
        let row = try #require(try rows(json).first)
        #expect(row.id == "weekly_scoped:m=Sonnet:s=claude_code")
        #expect(row.label == "Sonnet (Weekly) · claude_code")
    }

    @Test("Partial limits array keeps a legacy bucket with no modern equivalent")
    func partialArrayKeepsLegacy() throws {
        let json = Fixtures.usageJSON(
            limits: [Fixtures.limitJSON(kind: "weekly_scoped", percent: 0, model: "Fable")],
            legacy: #""seven_day": {"utilization": 12}"#
        )
        #expect(try rows(json).map(\.id) == ["legacy:seven_day", "weekly_scoped:m=Fable"])
    }

    @Test("Unrelated non-weekly entry never suppresses the legacy five_hour bucket")
    func dailyDoesNotSuppressFiveHour() throws {
        let json = Fixtures.usageJSON(
            limits: [Fixtures.limitJSON(kind: "daily_burst", percent: 1)],
            legacy: #""five_hour": {"utilization": 40}"#
        )
        #expect(try rows(json).map(\.id) == ["legacy:five_hour", "daily_burst"])
    }

    @Test("Surface-specific modern Sonnet does not suppress the legacy Sonnet bucket")
    func surfaceSpecificKeepsLegacy() throws {
        let json = Fixtures.usageJSON(
            limits: [Fixtures.limitJSON(kind: "weekly_scoped", percent: 9, model: "Sonnet", surface: "claude_code")],
            legacy: #""seven_day_sonnet": {"utilization": 30}"#
        )
        #expect(try rows(json).map(\.id) == ["legacy:seven_day_sonnet", "weekly_scoped:m=Sonnet:s=claude_code"])
    }

    @Test("All-surface modern Sonnet replaces the legacy Sonnet bucket")
    func allSurfaceReplacesLegacy() throws {
        let json = Fixtures.usageJSON(
            limits: [Fixtures.limitJSON(kind: "weekly_scoped", percent: 9, model: "Sonnet")],
            legacy: #""seven_day_sonnet": {"utilization": 30}"#
        )
        let result = try rows(json)
        #expect(result.map(\.id) == ["weekly_scoped:m=Sonnet"])
        #expect(result.first?.percent == 9)
    }

    @Test("Each logical row keeps its id when the response is reordered")
    func idsStableAcrossReorder() throws {
        let entries = [
            Fixtures.limitJSON(kind: "weekly_all", percent: 11),
            Fixtures.limitJSON(kind: "weekly_scoped", percent: 22, model: "Fable"),
            Fixtures.limitJSON(kind: "weekly_scoped", percent: 33, model: "Opus"),
        ]
        let forward = try rows(Fixtures.usageJSON(limits: entries))
        let backward = try rows(Fixtures.usageJSON(limits: entries.reversed()))
        let byId = { (rows: [UsageRow]) in Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.percent) }) }
        #expect(byId(forward) == byId(backward))
        #expect(byId(forward) == ["weekly_all": 11, "weekly_scoped:m=Fable": 22, "weekly_scoped:m=Opus": 33])
    }

    @Test("Indistinguishable entries collapse order-independently (max percent, any active)")
    func duplicateCollapse() throws {
        let active80 = #"{"kind": "weekly_scoped", "percent": 80, "is_active": true, "resets_at": "2026-11-10T00:00:00+00:00", "scope": {"model": {"id": "fable-1", "display_name": "Fable"}}}"#
        let inactive95 = #"{"kind": "weekly_scoped", "percent": 95, "is_active": false, "resets_at": "2026-11-09T00:00:00+00:00", "scope": {"model": {"id": "fable-1", "display_name": "Fable Pro"}}}"#
        let other20 = Fixtures.limitJSON(kind: "weekly_all", percent: 20)

        let forward = try rows(Fixtures.usageJSON(limits: [active80, inactive95, other20]))
        let backward = try rows(Fixtures.usageJSON(limits: [other20, inactive95, active80]))

        #expect(forward == backward)
        let merged = try #require(forward.first { $0.id == "weekly_scoped:m=fable-1" })
        #expect(merged.percent == 95)
        #expect(merged.isActive)
        #expect(merged.label == "Fable (Weekly)")
        #expect(merged.resetsAt.map { Int($0.timeIntervalSince1970) } == 1_794_182_400)
        #expect(selectHeadline(from: forward)?.id == "weekly_scoped:m=fable-1")
    }
}

@Suite("Headline Selection (auto)")
struct HeadlineSelectionTests {

    @Test("Verified Ultra (five_hour null) headlines the weekly limit")
    func ultraHeadline() throws {
        #expect(try headlinePercent(Fixtures.ultraUsageJSON) == 3)
    }

    @Test("Session above weekly: session wins")
    func sessionWins() throws {
        #expect(try headlinePercent(#"{"five_hour": {"utilization": 85}, "seven_day": {"utilization": 40}}"#) == 85)
    }

    @Test("Weekly above session: weekly wins")
    func weeklyWins() throws {
        #expect(try headlinePercent(#"{"five_hour": {"utilization": 20}, "seven_day": {"utilization": 70}}"#) == 70)
    }

    @Test("Weekly-only legacy response headlines the weekly percent")
    func weeklyOnly() throws {
        #expect(try headlinePercent(#"{"seven_day": {"utilization": 26}}"#) == 26)
    }

    @Test("Inactive scoped limit does not drive the headline")
    func inactiveIgnored() throws {
        let json = Fixtures.usageJSON(limits: [
            Fixtures.limitJSON(kind: "weekly_all", percent: 10),
            Fixtures.limitJSON(kind: "weekly_scoped", percent: 95, model: "Fable", isActive: false),
        ])
        #expect(try headlinePercent(json) == 10)
    }

    @Test("With no active rows, the highest inactive row is used")
    func allInactive() throws {
        let json = Fixtures.usageJSON(limits: [
            Fixtures.limitJSON(kind: "weekly_scoped", percent: 15, model: "Opus", isActive: false),
            Fixtures.limitJSON(kind: "weekly_scoped", percent: 45, model: "Fable", isActive: false),
        ])
        #expect(try headlinePercent(json) == 45)
    }

    @Test("No rows: no headline")
    func noRows() {
        #expect(selectHeadline(from: []) == nil)
    }
}

@Suite("hasAnyUsageData with limits")
struct HasAnyUsageDataLimitsTests {

    @Test("Limits-only response counts as data")
    func limitsOnly() throws {
        let usage = try Fixtures.decodeUsage(Fixtures.usageJSON(limits: [Fixtures.limitJSON(kind: "weekly_all")]))
        #expect(usage.hasAnyUsageData)
    }

    @Test("Empty limits and null buckets is not data")
    func emptyLimits() throws {
        #expect(try Fixtures.decodeUsage(#"{"limits": [], "five_hour": null}"#).hasAnyUsageData == false)
    }
}

@Suite("Usage Rows (review round)")
struct UsageRowsReviewTests {

    @Test("Version-specific Sonnet limit does not suppress the legacy Sonnet bucket")
    func versionSpecificKeepsLegacy() throws {
        let json = Fixtures.usageJSON(
            limits: [#"{"kind": "weekly_scoped", "percent": 9, "scope": {"model": {"id": "claude-sonnet-4-5", "display_name": "Sonnet 4.5"}}}"#],
            legacy: #""seven_day_sonnet": {"utilization": 30}"#
        )
        #expect(try rows(json).map(\.id) == ["legacy:seven_day_sonnet", "weekly_scoped:m=claude-sonnet-4-5"])
    }

    @Test("Model name merely containing 'opus' does not suppress the legacy Opus bucket")
    func substringDoesNotMatch() throws {
        let json = Fixtures.usageJSON(
            limits: [Fixtures.limitJSON(kind: "weekly_scoped", percent: 9, model: "Magnum Opus")],
            legacy: #""seven_day_opus": {"utilization": 30}"#
        )
        #expect(try rows(json).contains { $0.id == "legacy:seven_day_opus" })
    }

    @Test("Same label, different ids: ordered deterministically by id")
    func sameLabelOrderedById() throws {
        let ids = ["e-id", "c-id", "a-id", "d-id", "b-id"]
        let entries = ids.map {
            #"{"kind": "weekly_scoped", "percent": 1, "scope": {"model": {"id": "\#($0)", "display_name": "Fable"}}}"#
        }
        let expected = ids.sorted().map { "weekly_scoped:m=\($0)" }
        #expect(try rows(Fixtures.usageJSON(limits: entries)).map(\.id) == expected)
        #expect(try rows(Fixtures.usageJSON(limits: entries.reversed())).map(\.id) == expected)
    }

    @Test("Surface-scoped weekly_all does not suppress legacy seven_day")
    func surfaceSpecificWeeklyAllKeepsLegacySevenDay() throws {
        let json = Fixtures.usageJSON(
            limits: [Fixtures.limitJSON(kind: "weekly_all", percent: 5, surface: "claude_code")],
            legacy: #""seven_day": {"utilization": 30}"#
        )
        #expect(try rows(json).map(\.id) == ["legacy:seven_day", "weekly_all:s=claude_code"])
    }

    @Test("Model-scoped weekly_all does not suppress legacy seven_day", arguments: [
        #"{"id": null, "display_name": "Fable"}"#,
        #"{"id": "fable-1", "display_name": null}"#,
    ])
    func modelScopedWeeklyAllKeepsSevenDay(model: String) throws {
        let json = Fixtures.usageJSON(
            limits: ["{\"kind\": \"weekly_all\", \"percent\": 5, \"scope\": {\"model\": \(model)}}"],
            legacy: #""seven_day": {"utilization": 30}"#
        )
        #expect(try rows(json).contains { $0.id == "legacy:seven_day" })
    }

    @Test("Unscoped non-weekly entry does not suppress legacy seven_day")
    func unscopedDailyDoesNotSuppressSevenDay() throws {
        let json = Fixtures.usageJSON(
            limits: [Fixtures.limitJSON(kind: "daily_burst", percent: 5)],
            legacy: #""seven_day": {"utilization": 30}"#
        )
        #expect(try rows(json).contains { $0.id == "legacy:seven_day" })
    }

    @Test("Non-weekly Sonnet entry does not suppress legacy Sonnet")
    func nonWeeklySonnetDoesNotSuppressLegacySonnet() throws {
        let json = Fixtures.usageJSON(
            limits: [Fixtures.limitJSON(kind: "daily_burst", percent: 5, model: "Sonnet")],
            legacy: #""seven_day_sonnet": {"utilization": 30}"#
        )
        #expect(try rows(json).contains { $0.id == "legacy:seven_day_sonnet" })
    }

    @Test("Model id alone can match the legacy Sonnet family")
    func modelIdOnlySonnetReplacesLegacy() throws {
        let json = Fixtures.usageJSON(
            limits: [#"{"kind": "weekly_scoped", "percent": 5, "scope": {"model": {"id": "sonnet", "display_name": null}}}"#],
            legacy: #""seven_day_sonnet": {"utilization": 30}"#
        )
        #expect(try rows(json).map(\.id) == ["weekly_scoped:m=sonnet"])
    }

    @Test("All-surface modern Opus replaces the legacy Opus bucket")
    func allSurfaceOpusReplacesLegacyOpus() throws {
        let json = Fixtures.usageJSON(
            limits: [Fixtures.limitJSON(kind: "weekly_scoped", percent: 5, model: "Opus")],
            legacy: #""seven_day_opus": {"utilization": 30}"#
        )
        #expect(try rows(json).map(\.id) == ["weekly_scoped:m=Opus"])
    }

    @Test("Scoped label falls back to model id when there is no display name")
    func scopedLabelFallsBackToModelId() throws {
        let json = Fixtures.usageJSON(limits: [#"{"kind": "weekly_scoped", "percent": 5, "scope": {"model": {"id": "fable-1"}}}"#])
        #expect(try rows(json).first?.label == "fable-1 (Weekly)")
    }

    @Test("Unknown-kind label includes the model name")
    func unknownKindLabelIncludesModel() throws {
        let json = Fixtures.usageJSON(limits: [Fixtures.limitJSON(kind: "daily_burst", percent: 5, model: "Fable")])
        #expect(try rows(json).first?.label == "Daily burst · Fable")
    }
}
