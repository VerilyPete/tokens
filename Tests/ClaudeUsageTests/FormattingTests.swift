import Testing
import Foundation
@testable import ClaudeUsageKit

// MARK: - Phase 7: Color Thresholds

@Suite("usageColor")
struct ColorThresholdTests {

    // Cycle 7a: Green zone
    @Test("Returns green for 0-49%")
    func colorGreen() {
        #expect(usageColor(for: 0) == .green)
        #expect(usageColor(for: 25) == .green)
        #expect(usageColor(for: 49.9) == .green)
    }

    // Cycle 7b: Yellow zone
    @Test("Returns yellow for 50-79%")
    func colorYellow() {
        #expect(usageColor(for: 50) == .yellow)
        #expect(usageColor(for: 65) == .yellow)
        #expect(usageColor(for: 79.9) == .yellow)
    }

    // Cycle 7c: Orange zone
    @Test("Returns orange for 80-89%")
    func colorOrange() {
        #expect(usageColor(for: 80) == .orange)
        #expect(usageColor(for: 85) == .orange)
        #expect(usageColor(for: 89.9) == .orange)
    }

    // Cycle 7d: Red zone
    @Test("Returns red for 90%+")
    func colorRed() {
        #expect(usageColor(for: 90) == .red)
        #expect(usageColor(for: 95) == .red)
        #expect(usageColor(for: 100) == .red)
    }

    // Cycle 7e: Boundary values
    @Test("Handles exact boundary values correctly")
    func colorBoundaries() {
        #expect(usageColor(for: 49.99) == .green)
        #expect(usageColor(for: 50.0) == .yellow)
        #expect(usageColor(for: 79.99) == .yellow)
        #expect(usageColor(for: 80.0) == .orange)
        #expect(usageColor(for: 89.99) == .orange)
        #expect(usageColor(for: 90.0) == .red)
    }
}

// MARK: - Phase 8: Time Formatting

@Suite("formatResetTime")
struct TimeFormattingTests {

    // Cycle 8a: "now" for past/zero
    @Test("Returns 'now' for zero or negative seconds")
    func timeStringNow() {
        #expect(formatResetTime(seconds: 0) == "now")
        #expect(formatResetTime(seconds: -100) == "now")
    }

    // Cycle 8b: Minutes only (< 90 min)
    @Test("Returns 'N min' for durations under 90 minutes")
    func timeStringMinutes() {
        #expect(formatResetTime(seconds: 60) == "1 min")
        #expect(formatResetTime(seconds: 600) == "10 min")
        #expect(formatResetTime(seconds: 5399) == "89 min")  // 89 min 59 sec
    }

    // Cycle 8c: Hours and minutes
    @Test("Returns 'Nh Mm' for durations between 90 min and 24 hours")
    func timeStringHoursMinutes() {
        #expect(formatResetTime(seconds: 5400) == "1h 30m")   // exactly 90 min
        #expect(formatResetTime(seconds: 8040) == "2h 14m")
        #expect(formatResetTime(seconds: 86399) == "23h 59m") // just under 24h
    }

    // Cycle 8d: Days and hours
    @Test("Returns 'Nd Nh' for durations of 24 hours or more")
    func timeStringDaysHours() {
        #expect(formatResetTime(seconds: 86400) == "1d 0h")    // exactly 24h
        #expect(formatResetTime(seconds: 108000) == "1d 6h")
        #expect(formatResetTime(seconds: 381600) == "4d 10h")
    }

    // Cycle 8e: Very small values
    @Test("Returns '1 min' for values under 60 seconds but positive")
    func timeStringSmallPositive() {
        #expect(formatResetTime(seconds: 1) == "1 min")
        #expect(formatResetTime(seconds: 30) == "1 min")
        #expect(formatResetTime(seconds: 59) == "1 min")
    }
}

// MARK: - Phase 9: Menu Bar Label

@Suite("formatMenuBarLabel")
struct MenuBarLabelTests {

    // Cycle 9a: Normal percentage
    @Test("Shows plain percentage for < 80%")
    func menuBarLabelNormal() {
        #expect(formatMenuBarLabel(utilization: 37, hasError: false, hasData: true) == "37%")
        #expect(formatMenuBarLabel(utilization: 0, hasError: false, hasData: true) == "0%")
        #expect(formatMenuBarLabel(utilization: 79, hasError: false, hasData: true) == "79%")
    }

    // Cycle 9b: Orange zone suffix
    @Test("Shows '!' suffix for 80-89%")
    func menuBarLabelOrange() {
        #expect(formatMenuBarLabel(utilization: 80, hasError: false, hasData: true) == "80%!")
        #expect(formatMenuBarLabel(utilization: 85, hasError: false, hasData: true) == "85%!")
        #expect(formatMenuBarLabel(utilization: 89, hasError: false, hasData: true) == "89%!")
    }

    // Cycle 9c: Red zone suffix
    @Test("Shows '!!' suffix for 90%+")
    func menuBarLabelRed() {
        #expect(formatMenuBarLabel(utilization: 90, hasError: false, hasData: true) == "90%!!")
        #expect(formatMenuBarLabel(utilization: 95, hasError: false, hasData: true) == "95%!!")
        #expect(formatMenuBarLabel(utilization: 100, hasError: false, hasData: true) == "100%!!")
    }

    // Cycle 9d: No data yet
    @Test("Shows '--%' before first fetch")
    func menuBarLabelNoData() {
        #expect(formatMenuBarLabel(utilization: nil, hasError: false, hasData: false) == "--%")
    }

    // Cycle 9e: Error state
    @Test("Shows '!!' on error with no cached data")
    func menuBarLabelError() {
        #expect(formatMenuBarLabel(utilization: nil, hasError: true, hasData: false) == "!!")
    }
}
