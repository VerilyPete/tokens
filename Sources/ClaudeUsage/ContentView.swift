import SwiftUI
import ServiceManagement
import ClaudeUsageKit

/// The main popover content shown when the menu bar icon is clicked.
struct ContentView: View {
    let service: UsageService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            Divider()

            if let error = service.error, service.usage == nil {
                errorContent(error)
            } else if let usage = service.usage {
                usageContent(usage)
            } else {
                onboardingLoadingView
            }

            Divider()
            footerRow
        }
        .padding()
        .frame(width: 300)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("Claude Usage")
                .font(.title3)
                .fontWeight(.semibold)

            if let tier = service.subscriptionType {
                Text(tier)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.2))
                    .clipShape(Capsule())
            }

            Spacer()

            Button(action: { Task { await service.reloadCredentials() } }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(service.isLoading)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Error Content (no cached data)

    @ViewBuilder
    private func errorContent(_ error: UsageError) -> some View {
        switch error {
        case .keychain(.notFound):
            setupGuide
        case .keychain(.accessDenied):
            keychainHelpMessage
        default:
            errorBanner(error)
        }
    }

    // MARK: - Setup Guide (no credentials found)

    private var setupGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("No Credentials Found")
                    .font(.headline)
            }

            Text("Install Claude Code and log in to see your usage:")
                .font(.callout)

            VStack(alignment: .leading, spacing: 4) {
                Text("1. Install Claude Code")
                    .font(.callout.bold())
                Text("2. Run `claude login` in your terminal")
                    .font(.system(.callout, design: .monospaced))
                Text("3. Relaunch this app")
                    .font(.callout.bold())
            }
            .padding(.leading, 4)

            Button("Reload Credentials") {
                Task { await service.reloadCredentials() }
            }
            .buttonStyle(.bordered)
        }
        .padding(8)
        .background(.blue.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Keychain Help (access denied)

    private var keychainHelpMessage: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "lock.shield")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("Keychain Access Denied")
                    .font(.headline)
            }

            Text("macOS blocked access to Claude Code credentials.")
                .font(.callout)

            Text("To fix: re-launch ClaudeUsage and click **\"Always Allow\"** (not just \"Allow\") when the keychain dialog appears.")
                .font(.callout)

            Button("Retry") {
                Task { await service.reloadCredentials() }
            }
            .buttonStyle(.bordered)
        }
        .padding(8)
        .background(.orange.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Usage Content

    @ViewBuilder
    private func usageContent(_ usage: UsageResponse) -> some View {
        if let fiveHour = usage.fiveHour {
            UsageBarView(
                label: "5-Hour Session",
                percentage: fiveHour.utilization,
                resetsAt: fiveHour.resetsAt
            )
        }

        if let sevenDay = usage.sevenDay {
            UsageBarView(
                label: "7-Day Weekly",
                percentage: sevenDay.utilization,
                resetsAt: sevenDay.resetsAt
            )
        }

        if let sonnet = usage.sevenDaySonnet {
            UsageBarView(
                label: "Sonnet (7-Day)",
                percentage: sonnet.utilization,
                resetsAt: sonnet.resetsAt
            )
        }

        if let opus = usage.sevenDayOpus {
            UsageBarView(
                label: "Opus (7-Day)",
                percentage: opus.utilization,
                resetsAt: opus.resetsAt
            )
        }

        if let extra = usage.extraUsage, extra.isEnabled {
            extraUsageSection(extra)
        }

        if !usage.hasAnyUsageData, service.error == nil {
            Text("No usage data available yet")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        }

        if let error = service.error {
            errorBanner(error)
        }
    }

    // MARK: - Extra Usage

    @ViewBuilder
    private func extraUsageSection(_ extra: ExtraUsage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Extra Usage")
                .font(.headline)

            if let used = extra.usedCredits {
                let limitText = extra.monthlyLimit.map { formatCredits($0) } ?? "No cap"
                Text("\(formatCredits(used)) / \(limitText)")
                    .font(.system(.body, design: .monospaced))

                if extra.monthlyLimit == nil {
                    Text("No spending cap set")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("Enabled — no charges yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: UsageError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(error.localizedDescription)
                    .font(.callout)
            }

            Button("Retry") {
                Task {
                    if error.requiresReauthentication {
                        await service.reloadCredentials()
                    } else {
                        await service.fetchUsage()
                    }
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(8)
        .background(.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Loading (with first-launch onboarding)

    private var onboardingLoadingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Loading usage data...")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Text("If a keychain dialog appears, click **\"Always Allow\"** to grant permanent access.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
    }

    // MARK: - Footer

    private var footerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let lastUpdated = service.lastUpdated {
                Text("Updated \(formatTimeAgo(from: lastUpdated))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Launch at Login", isOn: Binding(
                get: { SMAppService.mainApp.status == .enabled },
                set: { newValue in
                    try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)

            Button("Reload Credentials") {
                Task { await service.reloadCredentials() }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}
