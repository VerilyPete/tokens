import Foundation
import Observation

/// Abstraction over the system login-item API (`SMAppService.mainApp` in production).
public protocol LoginItemManaging: AnyObject {
    var isEnabled: Bool { get }
    func register() throws
    func unregister() throws
}

/// Observable state for the "Launch at Login" toggle.
/// The system status isn't observable, so this mirrors it into a published property
/// and re-reads it after every change, on refresh, and after failures.
@MainActor @Observable
public final class LoginItemController {
    public private(set) var isEnabled: Bool
    public private(set) var lastError: String?

    private let manager: any LoginItemManaging

    public init(manager: any LoginItemManaging) {
        self.manager = manager
        self.isEnabled = manager.isEnabled
    }

    public func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try manager.register()
            } else {
                try manager.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    public func refresh() {
        isEnabled = manager.isEnabled
    }

    public func clearError() {
        lastError = nil
    }
}
