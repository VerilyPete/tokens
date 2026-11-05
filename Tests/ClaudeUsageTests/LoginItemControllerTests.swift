import Testing
import Foundation
@testable import ClaudeUsageKit

private struct LoginItemFailure: LocalizedError {
    var errorDescription: String? { "Operation not permitted" }
}

final class MockLoginItemManager: LoginItemManaging {
    var isEnabled: Bool
    var registerError: Error?
    var unregisterError: Error?
    private(set) var calls: [String] = []

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    func register() throws {
        calls.append("register")
        if let registerError { throw registerError }
        isEnabled = true
    }

    func unregister() throws {
        calls.append("unregister")
        if let unregisterError { throw unregisterError }
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
