import Testing
import Foundation
import Observation
@testable import ClaudeUsageKit

private struct LoginItemFailure: LocalizedError {
    var errorDescription: String? { "Operation not permitted" }
}

final class MockLoginItemManager: LoginItemManaging {
    var isEnabled: Bool
    var registerError: Error?
    var unregisterError: Error?
    var statusAfterFailure: Bool?
    var registerLeavesDisabled = false
    private(set) var calls: [String] = []

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    func register() throws {
        calls.append("register")
        if let registerError {
            statusAfterFailure.map { isEnabled = $0 }
            throw registerError
        }
        isEnabled = !registerLeavesDisabled
    }

    func unregister() throws {
        calls.append("unregister")
        if let unregisterError {
            statusAfterFailure.map { isEnabled = $0 }
            throw unregisterError
        }
        isEnabled = false
    }
}

@Suite("Launch at Login controller")
@MainActor
struct LoginItemControllerTests {

    @Test("Initial state reflects the system status")
    func initialState() {
        #expect(LoginItemController(manager: MockLoginItemManager(isEnabled: true)).isEnabled)
        #expect(LoginItemController(manager: MockLoginItemManager(isEnabled: false)).isEnabled == false)
    }

    @Test("Unchecking unregisters and the published state updates immediately")
    func uncheckUpdatesState() {
        let manager = MockLoginItemManager(isEnabled: true)
        let controller = LoginItemController(manager: manager)

        controller.setEnabled(false)

        #expect(manager.calls == ["unregister"])
        #expect(controller.isEnabled == false)
        #expect(controller.lastError == nil)
    }

    @Test("Checking registers and the published state updates immediately")
    func checkUpdatesState() {
        let manager = MockLoginItemManager(isEnabled: false)
        let controller = LoginItemController(manager: manager)

        controller.setEnabled(true)

        #expect(manager.calls == ["register"])
        #expect(controller.isEnabled)
    }

    @Test("A failed change surfaces the error and keeps the real system state")
    func failureSurfacesError() {
        let manager = MockLoginItemManager(isEnabled: true)
        manager.unregisterError = LoginItemFailure()
        let controller = LoginItemController(manager: manager)

        controller.setEnabled(false)

        #expect(controller.isEnabled)
        #expect(controller.lastError == "Operation not permitted")
    }

    @Test("A failed change re-reads the system status rather than assuming it is unchanged")
    func failureRereadsStatus() {
        let manager = MockLoginItemManager(isEnabled: true)
        manager.unregisterError = LoginItemFailure()
        manager.statusAfterFailure = false
        let controller = LoginItemController(manager: manager)

        controller.setEnabled(false)

        #expect(controller.isEnabled == false)
        #expect(controller.lastError == "Operation not permitted")
    }

    @Test("Registration that still needs user approval shows as unchecked")
    func registerPendingApproval() {
        let manager = MockLoginItemManager(isEnabled: false)
        manager.registerLeavesDisabled = true
        let controller = LoginItemController(manager: manager)

        controller.setEnabled(true)

        #expect(controller.isEnabled == false)
        #expect(controller.lastError == nil)
    }

    @Test("Changing the setting notifies observers, so the checkbox redraws")
    func changeNotifiesObservers() {
        let controller = LoginItemController(manager: MockLoginItemManager(isEnabled: true))
        let changed = ChangeFlag()

        withObservationTracking {
            _ = controller.isEnabled
        } onChange: {
            changed.fired = true
        }
        controller.setEnabled(false)

        #expect(changed.fired)
    }

    @Test("Refresh picks up changes made outside the app (e.g. System Settings)")
    func refreshPicksUpExternalChange() {
        let manager = MockLoginItemManager(isEnabled: true)
        let controller = LoginItemController(manager: manager)

        manager.isEnabled = false
        controller.refresh()

        #expect(controller.isEnabled == false)
    }

    @Test("Clearing the error removes it")
    func clearError() {
        let manager = MockLoginItemManager()
        manager.registerError = LoginItemFailure()
        let controller = LoginItemController(manager: manager)
        controller.setEnabled(true)

        controller.clearError()

        #expect(controller.lastError == nil)
    }

    @Test("A successful change clears a previous error")
    func successClearsPreviousError() {
        let manager = MockLoginItemManager()
        manager.registerError = LoginItemFailure()
        let controller = LoginItemController(manager: manager)
        controller.setEnabled(true)

        manager.registerError = nil
        controller.setEnabled(true)

        #expect(controller.lastError == nil)
        #expect(controller.isEnabled)
    }
}

private final class ChangeFlag: @unchecked Sendable {
    var fired = false
}
