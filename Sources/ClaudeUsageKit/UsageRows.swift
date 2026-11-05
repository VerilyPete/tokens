import Foundation

/// A normalised, display-ready usage limit. Single source for both the popover and the menu bar headline.
public struct UsageRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let percent: Double
    public let resetsAt: Date?
    public let isActive: Bool

    public init(id: String, label: String, percent: Double, resetsAt: Date? = nil, isActive: Bool = true) {
        self.id = id
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
        self.isActive = isActive
    }
}

private enum RowRank: Int, Comparable {
    case session, weeklyAll, scoped, other

    static func < (lhs: RowRank, rhs: RowRank) -> Bool { lhs.rawValue < rhs.rawValue }
}

private struct RankedRow {
    let rank: RowRank
    let row: UsageRow
}

/// Build display rows from the modern `limits` array, merging in each legacy bucket
/// unless a modern row of equal scope breadth already covers it.
public func usageRows(for usage: UsageResponse) -> [UsageRow] {
    let modern = collapseDuplicates(usage.limits.map(modernRow))
    let legacy = legacyRows(for: usage).filter { !$0.isCovered(by: usage.limits) }.map(\.ranked)
    return (modern + legacy)
        .sorted { ($0.rank, $0.row.label, $0.row.id) < ($1.rank, $1.row.label, $1.row.id) }
        .map(\.row)
}

/// The row that drives the menu bar. A pin wins when its row is present (even if inactive);
/// otherwise auto: the highest percent among active rows, or the highest overall if none are active.
public func selectHeadline(from rows: [UsageRow], choice: HeadlineChoice = .auto) -> UsageRow? {
    if case .pinned(let id) = choice, let pinned = rows.first(where: { $0.id == id }) {
        return pinned
    }
    let active = rows.filter(\.isActive)
    let candidates = active.isEmpty ? rows : active
    return candidates.reduce(nil) { best, row in
        guard let best else { return row }
        return row.percent > best.percent ? row : best
    }
}

// MARK: - Modern rows

private func modernRow(_ limit: UsageLimit) -> RankedRow {
    let model = limit.scope?.modelId ?? limit.scope?.modelDisplayName
    let surface = limit.scope?.surface
    let id = [limit.kind, model.map { "m=\($0)" }, surface.map { "s=\($0)" }]
        .compactMap { $0 }
        .joined(separator: ":")
    return RankedRow(
        rank: rank(forKind: limit.kind),
        row: UsageRow(
            id: id,
            label: label(for: limit),
            percent: limit.percent,
            resetsAt: limit.resetsAt,
            isActive: limit.isActive
        )
    )
}

private func rank(forKind kind: String) -> RowRank {
    switch kind {
    case "weekly_all": .weeklyAll
    case "weekly_scoped": .scoped
    default: .other
    }
}

private func label(for limit: UsageLimit) -> String {
    let base: String = switch limit.kind {
    case "weekly_all": "Weekly (All Models)"
    case "weekly_scoped": "\(limit.modelDisplayName ?? limit.scope?.modelId ?? "Scoped") (Weekly)"
    default: [humanize(limit.kind), limit.modelDisplayName].compactMap { $0 }.joined(separator: " · ")
    }
    return [base, limit.scope?.surface].compactMap { $0 }.joined(separator: " · ")
}

private func humanize(_ kind: String) -> String {
    let spaced = kind.replacingOccurrences(of: "_", with: " ")
    return spaced.prefix(1).uppercased() + spaced.dropFirst()
}

/// Entries that produce the same id are indistinguishable; merge them so the result
/// is independent of API order and can only overstate usage.
private func collapseDuplicates(_ rows: [RankedRow]) -> [RankedRow] {
    Dictionary(grouping: rows, by: \.row.id).values.compactMap { group in
        guard let first = group.first else { return nil }
        let members = group.map(\.row)
        return RankedRow(
            rank: first.rank,
            row: UsageRow(
                id: first.row.id,
                label: members.map(\.label).min() ?? first.row.label,
                percent: members.map(\.percent).max() ?? first.row.percent,
                resetsAt: members.compactMap(\.resetsAt).min(),
                isActive: members.contains(where: \.isActive)
            )
        )
    }
}

// MARK: - Legacy rows

private struct LegacyRow {
    let ranked: RankedRow
    let isCovered: ([UsageLimit]) -> Bool

    func isCovered(by limits: [UsageLimit]) -> Bool { isCovered(limits) }
}

private func legacyRows(for usage: UsageResponse) -> [LegacyRow] {
    let entries: [(String, String, RowRank, UsageBucket?, ([UsageLimit]) -> Bool)] = [
        ("five_hour", "5-Hour Session", .session, usage.fiveHour, { _ in false }),
        ("seven_day", "Weekly (All Models)", .weeklyAll, usage.sevenDay, { limits in
            limits.contains { $0.kind == "weekly_all" && $0.coversAllSurfacesAndModels }
        }),
        ("seven_day_opus", "Opus (Weekly)", .scoped, usage.sevenDayOpus, coveredByModel("opus")),
        ("seven_day_sonnet", "Sonnet (Weekly)", .scoped, usage.sevenDaySonnet, coveredByModel("sonnet")),
    ]
    return entries.compactMap { key, label, rank, bucket, covered in
        bucket.map { bucket in
            LegacyRow(
                ranked: RankedRow(
                    rank: rank,
                    row: UsageRow(
                        id: "legacy:\(key)",
                        label: label,
                        percent: bucket.utilization,
                        resetsAt: bucket.resetsAt,
                        isActive: true
                    )
                ),
                isCovered: covered
            )
        }
    }
}

private func coveredByModel(_ family: String) -> ([UsageLimit]) -> Bool {
    { limits in
        limits.contains { limit in
            limit.kind == "weekly_scoped"
                && limit.scope?.surface == nil
                && [limit.scope?.modelId, limit.scope?.modelDisplayName]
                    .compactMap { $0?.lowercased() }
                    .contains(family)
        }
    }
}

private extension UsageLimit {
    var coversAllSurfacesAndModels: Bool {
        scope?.surface == nil && scope?.modelId == nil && scope?.modelDisplayName == nil
    }
}
