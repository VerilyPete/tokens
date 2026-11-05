import Foundation

/// Which usage row drives the menu bar label.
public enum HeadlineChoice: Sendable, Equatable, Hashable {
    case auto
    case pinned(String)
}

/// Persists the user's menu bar headline choice.
public protocol HeadlinePreferenceStore: AnyObject {
    func load() -> HeadlineChoice
    func save(_ choice: HeadlineChoice)
}

/// Production store backed by `UserDefaults`. Absent key means `.auto`.
public final class UserDefaultsHeadlinePreferenceStore: HeadlinePreferenceStore {
    private static let pinnedRowKey = "menuBarHeadlinePinnedRowId"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> HeadlineChoice {
        defaults.string(forKey: Self.pinnedRowKey).map(HeadlineChoice.pinned) ?? .auto
    }

    public func save(_ choice: HeadlineChoice) {
        switch choice {
        case .auto: defaults.removeObject(forKey: Self.pinnedRowKey)
        case .pinned(let id): defaults.set(id, forKey: Self.pinnedRowKey)
        }
    }
}

/// Non-persistent store for tests and previews.
public final class InMemoryHeadlinePreferenceStore: HeadlinePreferenceStore {
    private var choice: HeadlineChoice

    public init(_ choice: HeadlineChoice = .auto) {
        self.choice = choice
    }

    public func load() -> HeadlineChoice { choice }
    public func save(_ choice: HeadlineChoice) { self.choice = choice }
}
