import SwiftUI
import ClaudeUsageKit

@main
struct ClaudeUsageApp: App {
    // UsageService() auto-starts polling in its production init.
    @State private var usageService = UsageService()
    @State private var loginItem = LoginItemController(manager: SMAppServiceLoginItem())

    var body: some Scene {
        MenuBarExtra {
            ContentView(service: usageService, loginItem: loginItem)
        } label: {
            Text(usageService.menuBarLabel)
        }
        .menuBarExtraStyle(.window)
    }
}
