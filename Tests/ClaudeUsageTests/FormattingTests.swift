import Testing
import Foundation
@testable import ClaudeUsageKit

// MARK: - Phase 7: Usage Level Thresholds

@Suite("usageLevel")
struct UsageLevelTests {

    @Test("Returns green for 0-49%")
    func levelGreen() {
        #expect(usageLevel(for: 0) == .green)
        #expect(usageLevel(for: 25) == .green)
        #expect(usageLevel(for: 49.9) == .green)
    }

    @Test("Returns yellow for 50-79%")
    func levelYellow() {
        #expect(usageLevel(for: 50) == .yellow)
        #expect(usageLevel(for: 65) == .yellow)
        #expect(usageLevel(for: 79.9) == .yellow)
    }

    @Test("Returns orange for 80-89%")
    func levelOrange() {
        #expect(usageLevel(for: 80) == .orange)
        #expect(usageLevel(for: 85) == .orange)
        #expect(usageLevel(for: 89.9) == .orange)
    }

    @Test("Returns red for 90%+")
    func levelRed() {
        #expect(usageLevel(for: 90) == .red)
        #expect(usageLevel(for: 95) == .red)
        #expect(usageLevel(for: 100) == .red)
    }

    @Test("Handles exact boundary values correctly")
    func levelBoundaries() {
        #expect(usageLevel(for: 49.99) == .green)
        #expect(usageLevel(for: 50.0) == .yellow)
        #expect(usageLevel(for: 79.99) == .yellow)
        #expect(usageLevel(for: 80.0) == .orange)
        #expect(usageLevel(for: 89.99) == .orange)
        #expect(usageLevel(for: 90.0) == .red)
    }

    @Test("Returns green for negative and red for >100%")
    func levelEdgeCases() {
        #expect(usageLevel(for: -5) == .green)
        #expect(usageLevel(for: 105) == .red)
    }
}

// MARK: - Phase 8: Time Formatting

@Suite("formatResetTime")
struct TimeFormattingTests {

    @Test("Returns 'now' for zero or negative seconds")
    func timeStringNow() {
        #expect(formatResetTime(seconds: 0) == "now")
        #expect(formatResetTime(seconds: -100) == "now")
    }

    @Test("Returns 'N min' for durations under 90 minutes")
    func timeStringMinutes() {
        #expect(formatResetTime(seconds: 60) == "1 min")
        #expect(formatResetTime(seconds: 600) == "10 min")
        #expect(formatResetTime(seconds: 5399) == "89 min")
    }

    @Test("Returns 'Nh Mm' for durations between 90 min and 24 hours")
    func timeStringHoursMinutes() {
        #expect(formatResetTime(seconds: 5400) == "1h 30m")
        #expect(formatResetTime(seconds: 8040) == "2h 14m")
        #expect(formatResetTime(seconds: 86399) == "23h 59m")
    }

    @Test("Returns 'Nd Nh' for durations of 24 hours or more")
    func timeStringDaysHours() {
        #expect(formatResetTime(seconds: 86400) == "1d 0h")
        #expect(formatResetTime(seconds: 108000) == "1d 6h")
        #expect(formatResetTime(seconds: 381600) == "4d 10h")
    }

    @Test("Returns '1 min' for values under 60 seconds but positive")
    func timeStringSmallPositive() {
        #expect(formatResetTime(seconds: 1) == "1 min")
        #expect(formatResetTime(seconds: 30) == "1 min")
        #expect(formatResetTime(seconds: 59) == "1 min")
    }
}

// MARK: - formatResetTime(from:now:) Date wrapper

@Suite("formatResetTime from Date")
struct ResetTimeDateTests {

    @Test("Formats future date as reset time")
    func futureDate() {
        let now = Date()
        let future = now.addingTimeInterval(5400) // 90 min from now
        let result = formatResetTime(from: future, now: now)
        #expect(result == "1h 30m")
    }

    @Test("Returns 'now' for past date")
    func pastDate() {
        let now = Date()
        let past = now.addingTimeInterval(-300)
        let result = formatResetTime(from: past, now: now)
        #expect(result == "now")
    }
}

// MARK: - formatTimeAgo

@Suite("formatTimeAgo")
struct TimeAgoTests {

    @Test("Returns 'just now' for < 60 seconds ago")
    func justNow() {
        let now = Date()
        #expect(formatTimeAgo(from: now, now: now) == "just now")
        #expect(formatTimeAgo(from: now.addingTimeInterval(-30), now: now) == "just now")
        #expect(formatTimeAgo(from: now.addingTimeInterval(-59), now: now) == "just now")
    }

    @Test("Returns 'N min ago' for minutes")
    func minutesAgo() {
        let now = Date()
        #expect(formatTimeAgo(from: now.addingTimeInterval(-120), now: now) == "2 min ago")
        #expect(formatTimeAgo(from: now.addingTimeInterval(-600), now: now) == "10 min ago")
    }

    @Test("Returns 'Nh Mm ago' for hours")
    func hoursAgo() {
        let now = Date()
        #expect(formatTimeAgo(from: now.addingTimeInterval(-7200), now: now) == "2h 0m ago")
    }
}

// MARK: - Phase 9: Menu Bar Label

@Suite("formatMenuBarLabel")
struct MenuBarLabelTests {

    @Test("Shows plain percentage for < 80%")
    func menuBarLabelNormal() {
        #expect(formatMenuBarLabel(utilization: 37, hasError: false, hasData: true) == "37%")
        #expect(formatMenuBarLabel(utilization: 0, hasError: false, hasData: true) == "0%")
        #expect(formatMenuBarLabel(utilization: 79, hasError: false, hasData: true) == "79%")
    }

    @Test("Shows '!' suffix for 80-89%")
    func menuBarLabelOrange() {
        #expect(formatMenuBarLabel(utilization: 80, hasError: false, hasData: true) == "80%!")
        #expect(formatMenuBarLabel(utilization: 85, hasError: false, hasData: true) == "85%!")
        #expect(formatMenuBarLabel(utilization: 89, hasError: false, hasData: true) == "89%!")
    }

    @Test("Shows '!!' suffix for 90%+")
    func menuBarLabelRed() {
        #expect(formatMenuBarLabel(utilization: 90, hasError: false, hasData: true) == "90%!!")
        #expect(formatMenuBarLabel(utilization: 95, hasError: false, hasData: true) == "95%!!")
        #expect(formatMenuBarLabel(utilization: 100, hasError: false, hasData: true) == "100%!!")
    }

    @Test("Shows '--%' before first fetch")
    func menuBarLabelNoData() {
        #expect(formatMenuBarLabel(utilization: nil, hasError: false, hasData: false) == "--%")
    }

    @Test("Shows '!!' on error with no cached data")
    func menuBarLabelError() {
        #expect(formatMenuBarLabel(utilization: nil, hasError: true, hasData: false) == "!!")
    }

    @Test("Shows cached percentage when error occurs with existing data")
    func menuBarLabelErrorWithCachedData() {
        // Error + cached data → show the cached percentage, not "!!"
        #expect(formatMenuBarLabel(utilization: 37, hasError: true, hasData: true) == "37%")
    }
}
