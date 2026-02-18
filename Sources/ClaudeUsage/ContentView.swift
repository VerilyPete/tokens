import SwiftUI
import ClaudeUsageKit

/// The main popover content shown when the menu bar icon is clicked.
struct ContentView: View {
    let service: UsageService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow
            Divider()

            if let error = service.error, service.usage == nil {
                errorBanner(error)
            } else if let usage = service.usage {
                usageContent(usage)
            } else {
                loadingView
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

            Button(action: { Task { await service.fetchUsage() } }) {
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

    // MARK: - Usage Content

    @ViewBuilder
    private func usageContent(_ usage: UsageResponse) -> some View {
        UsageBarView(
            label: "5-Hour Session",
            percentage: usage.fiveHour.utilization,
            resetsAt: usage.fiveHour.resetsAt
        )

        UsageBarView(
            label: "7-Day Weekly",
            percentage: usage.sevenDay.utilization,
            resetsAt: usage.sevenDay.resetsAt
        )

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
                let limitText = extra.monthlyLimit.map { String(format: "$%.2f", $0) } ?? "No cap"
                Text(String(format: "$%.2f / %@", used, limitText))
                    .font(.system(.body, design: .monospaced))

                if extra.monthlyLimit == nil {
                    Text("No spending cap set")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
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
                Task { await service.fetchUsage() }
            }
            .buttonStyle(.bordered)
        }
        .padding(8)
        .background(.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Loading

    private var loadingView: some View {
        HStack {
            ProgressView()
                .scaleEffect(0.7)
            Text("Loading usage data...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 20)
    }

    // MARK: - Footer

    private var footerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let lastUpdated = service.lastUpdated {
                Text("Updated \(formatTimeAgo(from: lastUpdated)) ago")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Reload Credentials") {
                Task { await service.reloadCredentials() }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}
