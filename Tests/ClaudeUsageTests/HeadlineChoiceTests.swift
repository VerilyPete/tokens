import Testing
import Foundation
@testable import ClaudeUsageKit

private let weeklyAll = UsageRow(id: "weekly_all", label: "Weekly (All Models)", percent: 3)
private let fableCapped = UsageRow(id: "weekly_scoped:m=Fable", label: "Fable (Weekly)", percent: 100)
private let opusIdle = UsageRow(id: "weekly_scoped:m=Opus", label: "Opus (Weekly)", percent: 1, isActive: false)

@Suite("Headline Selection (pinned)")
struct PinnedHeadlineTests {

    @Test("Pinned weekly-all beats a capped Fable limit")
    func pinnedBeatsHigher() {
        let rows = [weeklyAll, fableCapped]
        #expect(selectHeadline(from: rows, choice: .pinned("weekly_all")) == weeklyAll)
    }

    @Test("A pinned inactive row is still shown")
    func pinnedInactive() {
        let rows = [weeklyAll, opusIdle]
        #expect(selectHeadline(from: rows, choice: .pinned(opusIdle.id)) == opusIdle)
    }

    @Test("A missing pin falls back to auto")
    func missingPinFallsBack() {
        let rows = [weeklyAll, fableCapped]
        #expect(selectHeadline(from: rows, choice: .pinned("weekly_scoped:m=Gone")) == fableCapped)
    }

    @Test("Auto is the default choice")
    func autoDefault() {
        #expect(selectHeadline(from: [weeklyAll, fableCapped], choice: .auto) == fableCapped)
    }
}

@Suite("Headline Choice persistence")
@MainActor
struct HeadlineChoicePersistenceTests {

    private func usageJSON(fable: Bool) -> Data {
        var limits = [Fixtures.limitJSON(kind: "weekly_all", percent: 3)]
        if fable {
            limits.append(Fixtures.limitJSON(kind: "weekly_scoped", percent: 100, model: "Fable"))
        }
        return Data(Fixtures.usageJSON(limits: limits).utf8)
    }

    private func makeService(store: InMemoryHeadlinePreferenceStore) -> (UsageService, MockNetworkSession) {
        let keychain = MockKeychainReader()
        keychain.result = .success(TestData.mockCredentials())
        let network = MockNetworkSession()
        let service = UsageService(keychainReader: keychain, networkSession: network, headlineStore: store)
        return (service, network)
    }

    @Test("Defaults to auto with an empty store")
    func defaultsToAuto() {
        let (service, _) = makeService(store: InMemoryHeadlinePreferenceStore())
        #expect(service.headlineChoice == .auto)
    }

    @Test("Pin survives a missing row and a restart, then applies when the row reappears")
    func pinLifecycle() async {
        let store = InMemoryHeadlinePreferenceStore()
        let (service, network) = makeService(store: store)

        network.enqueue(data: usageJSON(fable: true), statusCode: 200)
        await service.fetchUsage()
        service.headlineChoice = .pinned("weekly_all")
        #expect(service.menuBarLabel == "3%")
        #expect(store.load() == .pinned("weekly_all"))

        service.headlineChoice = .pinned("weekly_scoped:m=Fable")
        network.enqueue(data: usageJSON(fable: false), statusCode: 200)
        await service.fetchUsage()
        #expect(service.menuBarLabel == "3%")
        #expect(service.isPinnedRowUnavailable)
        #expect(store.load() == .pinned("weekly_scoped:m=Fable"))

        let (restarted, restartedNetwork) = makeService(store: store)
        #expect(restarted.headlineChoice == .pinned("weekly_scoped:m=Fable"))

        restartedNetwork.enqueue(data: usageJSON(fable: true), statusCode: 200)
        await restarted.fetchUsage()
        #expect(restarted.menuBarLabel == "100%!!")
        #expect(restarted.isPinnedRowUnavailable == false)
    }

    @Test("Switching back to auto updates the store")
    func backToAuto() {
        let store = InMemoryHeadlinePreferenceStore()
        let (service, _) = makeService(store: store)
        service.headlineChoice = .pinned("weekly_all")
        service.headlineChoice = .auto
        #expect(store.load() == .auto)
    }

    @Test("A pin is not reported unavailable before the first fetch")
    func pinnedNotUnavailableBeforeFirstFetch() {
        let (service, _) = makeService(store: InMemoryHeadlinePreferenceStore(.pinned("weekly_all")))
        #expect(service.headlineChoice == .pinned("weekly_all"))
        #expect(service.isPinnedRowUnavailable == false)
    }

    @Test("Auto is never reported as an unavailable pin")
    func autoNotUnavailable() {
        let (service, _) = makeService(store: InMemoryHeadlinePreferenceStore())
        #expect(service.isPinnedRowUnavailable == false)
    }
}

@Suite("UserDefaults headline store")
struct UserDefaultsHeadlineStoreTests {

    @Test("Round-trips auto and pinned choices")
    func roundTrip() throws {
        let suite = "headline-store-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsHeadlinePreferenceStore(defaults: defaults)

        #expect(store.load() == .auto)
        store.save(.pinned("weekly_scoped:m=Fable"))
        #expect(UserDefaultsHeadlinePreferenceStore(defaults: defaults).load() == .pinned("weekly_scoped:m=Fable"))
        store.save(.auto)
        #expect(store.load() == .auto)
    }
}
