import SwiftUI
import ClaudeUsageKit

/// A color-coded horizontal progress bar for usage metrics.
struct UsageBarView: View {
    let label: String
    let percentage: Double
    let resetsAt: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.headline)

            HStack {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.secondary.opacity(0.2))
                            .frame(height: 6)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(usageColor(for: percentage))
                            .frame(
                                width: geometry.size.width * min(percentage / 100, 1.0),
                                height: 6
                            )
                    }
                }
                .frame(height: 6)

                Text("\(Int(percentage))%")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 45, alignment: .trailing)
            }

            if let resetsAt {
                Text("Resets in \(formatResetTime(from: resetsAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("\(label) usage")
        .accessibilityValue(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var desc = "\(Int(percentage)) percent"
        if let resetsAt {
            desc += ", resets in \(formatResetTime(from: resetsAt))"
        }
        return desc
    }
}
