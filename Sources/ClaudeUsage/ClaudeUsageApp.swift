import SwiftUI
import ClaudeUsageKit

@main
struct ClaudeUsageApp: App {
    // UsageService() auto-starts polling in its production init.
    @State private var usageService = UsageService()

    var body: some Scene {
        MenuBarExtra {
            ContentView(service: usageService)
        } label: {
            Text(usageService.menuBarLabel)
        }
        .menuBarExtraStyle(.window)
    }
}
