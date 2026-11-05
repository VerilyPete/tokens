import ServiceManagement
import ClaudeUsageKit

/// Production adapter: the app's own login item via `SMAppService.mainApp`.
final class SMAppServiceLoginItem: LoginItemManaging {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}
