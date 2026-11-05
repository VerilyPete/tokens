import Testing
import Foundation
@testable import ClaudeUsageKit

@Suite("Limits Decoding")
struct LimitsDecodingTests {

    @Test("Ultra response decodes weekly-all and the Fable scoped limit")
    func decodesUltraLimits() throws {
        let usage = try Fixtures.decodeUsage(Fixtures.ultraUsageJSON)

        #expect(usage.limits.count == 2)
        #expect(usage.limits[0].kind == "weekly_all")
        #expect(usage.limits[0].percent == 3)
        #expect(usage.limits[0].isActive)
        #expect(usage.limits[0].modelDisplayName == nil)
        #expect(usage.limits[1].kind == "weekly_scoped")
        #expect(usage.limits[1].modelDisplayName == "Fable")
        #expect(usage.limits[1].isActive == false)
        let resetsAt = try #require(usage.limits[1].resetsAt)
        #expect(abs(resetsAt.timeIntervalSince1970 - 1_794_204_000) < 1)
    }

    @Test("Missing limits key decodes to empty array")
    func missingLimits() throws {
        let usage = try Fixtures.decodeUsage(#"{"seven_day": {"utilization": 5}}"#)
        #expect(usage.limits.isEmpty)
        #expect(usage.sevenDay?.utilization == 5)
    }

    @Test("Null limits decodes to empty array")
    func nullLimits() throws {
        let usage = try Fixtures.decodeUsage(#"{"limits": null}"#)
        #expect(usage.limits.isEmpty)
    }

    @Test("Wrong-type limits decodes to empty array without failing the response")
    func wrongTypeLimits() throws {
        let usage = try Fixtures.decodeUsage(#"{"limits": {"oops": 1}, "seven_day": {"utilization": 7}}"#)
        #expect(usage.limits.isEmpty)
        #expect(usage.sevenDay?.utilization == 7)
    }

    @Test("Malformed entry between valid entries is dropped, neighbours kept")
    func malformedEntrySkipped() throws {
        let json = Fixtures.usageJSON(limits: [
            Fixtures.limitJSON(kind: "weekly_all", percent: 10),
            #"{"kind": "weekly_scoped", "percent": "lots"}"#,
            #"42"#,
            Fixtures.limitJSON(kind: "weekly_scoped", percent: 20, model: "Opus"),
        ])
        let usage = try Fixtures.decodeUsage(json)
        #expect(usage.limits.map(\.kind) == ["weekly_all", "weekly_scoped"])
        #expect(usage.limits.map(\.percent) == [10, 20])
    }

    @Test("Unknown kind and severity survive as raw strings")
    func unknownKindSurvives() throws {
        let json = Fixtures.usageJSON(limits: [
            #"{"kind": "daily_burst", "group": "daily", "percent": 12, "severity": "spicy"}"#
        ])
        let limit = try #require(try Fixtures.decodeUsage(json).limits.first)
        #expect(limit.kind == "daily_burst")
        #expect(limit.group == "daily")
        #expect(limit.severity == "spicy")
    }

    @Test("Missing is_active is treated as active")
    func missingIsActive() throws {
        let json = Fixtures.usageJSON(limits: [#"{"kind": "weekly_all", "percent": 12}"#])
        let limit = try #require(try Fixtures.decodeUsage(json).limits.first)
        #expect(limit.isActive)
        #expect(limit.scope == nil)
    }

    @Test("Invalid resets_at becomes nil but keeps the entry")
    func invalidResetDate() throws {
        let json = Fixtures.usageJSON(limits: [
            #"{"kind": "weekly_all", "percent": 12, "resets_at": "soon"}"#
        ])
        let limit = try #require(try Fixtures.decodeUsage(json).limits.first)
        #expect(limit.resetsAt == nil)
        #expect(limit.percent == 12)
    }

    @Test("Percent is clamped to 0...100 when decoding")
    func percentClampedOnDecode() throws {
        let json = Fixtures.usageJSON(limits: [
            Fixtures.limitJSON(kind: "a", percent: 140),
            Fixtures.limitJSON(kind: "b", percent: -3),
        ])
        #expect(try Fixtures.decodeUsage(json).limits.map(\.percent) == [100, 0])
    }

    @Test("Percent is clamped in the memberwise initializer")
    func percentClampedOnInit() {
        #expect(UsageLimit(kind: "weekly_all", percent: 250).percent == 100)
        #expect(UsageLimit(kind: "weekly_all", percent: -1).percent == 0)
    }

    @Test("Scope keeps model id, display name, and string surface")
    func scopeFields() throws {
        let json = Fixtures.usageJSON(limits: [
            #"{"kind": "weekly_scoped", "percent": 1, "scope": {"model": {"id": "claude-fable", "display_name": "Fable"}, "surface": "claude_code"}}"#
        ])
        let limit = try #require(try Fixtures.decodeUsage(json).limits.first)
        #expect(limit.scope == LimitScope(modelId: "claude-fable", modelDisplayName: "Fable", surface: "claude_code"))
    }

    @Test("Object-shaped surface without display_name uses its id")
    func objectSurfaceWithoutDisplayNameUsesId() throws {
        let json = Fixtures.usageJSON(limits: [
            #"{"kind": "weekly_scoped", "percent": 1, "scope": {"surface": {"id": "cc"}}}"#
        ])
        #expect(try Fixtures.decodeUsage(json).limits.first?.scope?.surface == "cc")
    }

    @Test("Object-shaped surface uses its display_name")
    func objectSurface() throws {
        let json = Fixtures.usageJSON(limits: [
            #"{"kind": "weekly_scoped", "percent": 1, "scope": {"model": null, "surface": {"id": "cc", "display_name": "Claude Code"}}}"#
        ])
        let limit = try #require(try Fixtures.decodeUsage(json).limits.first)
        #expect(limit.scope?.surface == "Claude Code")
    }
}

@Suite("Limits Decoding (malformed scope)")
struct MalformedScopeTests {

    @Test("Malformed model drops the entry instead of broadening its scope")
    func malformedModel() throws {
        let json = Fixtures.usageJSON(
            limits: [#"{"kind": "weekly_all", "percent": 1, "scope": {"model": 42}}"#],
            legacy: #""seven_day": {"utilization": 30}"#
        )
        let usage = try Fixtures.decodeUsage(json)
        #expect(usage.limits.isEmpty)
        #expect(usageRows(for: usage).map(\.id) == ["legacy:seven_day"])
    }

    @Test("Unrecognised surface shape drops the entry")
    func malformedSurface() throws {
        let json = Fixtures.usageJSON(limits: [#"{"kind": "weekly_all", "percent": 1, "scope": {"surface": [1, 2]}}"#])
        #expect(try Fixtures.decodeUsage(json).limits.isEmpty)
    }

    @Test("Non-object scope drops the entry")
    func malformedScope() throws {
        let json = Fixtures.usageJSON(limits: [#"{"kind": "weekly_all", "percent": 1, "scope": "everything"}"#])
        #expect(try Fixtures.decodeUsage(json).limits.isEmpty)
    }

    @Test("Model or surface objects without a usable identity drop the entry", arguments: [
        #"{"model": {}}"#,
        #"{"model": {"id": null, "display_name": null}}"#,
        #"{"model": {"id": "", "display_name": ""}}"#,
        #"{"surface": {"unexpected": "claude_code"}}"#,
    ])
    func identitylessScope(scope: String) throws {
        let json = Fixtures.usageJSON(
            limits: ["{\"kind\": \"weekly_all\", \"percent\": 1, \"scope\": \(scope)}"],
            legacy: #""seven_day": {"utilization": 30}"#
        )
        let usage = try Fixtures.decodeUsage(json)
        #expect(usage.limits.isEmpty)
        #expect(usageRows(for: usage).map(\.id) == ["legacy:seven_day"])
    }

    @Test("Explicit null model and surface inside scope are fine")
    func nullInsideScope() throws {
        let json = Fixtures.usageJSON(limits: [#"{"kind": "weekly_all", "percent": 1, "scope": {"model": null, "surface": null}}"#])
        #expect(try Fixtures.decodeUsage(json).limits.count == 1)
    }
}
