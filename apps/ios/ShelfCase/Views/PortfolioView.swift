import SwiftUI
import SwiftData
import ShelfCaseKit

/// Portfolio summary: totals, unrealised gain/loss and a per-category breakdown,
/// all computed by the pure `Valuation.portfolioSummary` in ShelfCaseKit.
struct PortfolioView: View {
    @EnvironmentObject private var environment: AppEnvironment

    @Query(filter: #Predicate<ItemEntity> { $0.isDeleted == false })
    private var items: [ItemEntity]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Estimated value")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(CurrencyFormat.string(cents: summary.totalEstimatedValueCents))
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .monospacedDigit()

                        HStack(spacing: 16) {
                            metric("Cost", CurrencyFormat.string(cents: summary.totalCostCents))
                            metric("Unrealised", CurrencyFormat.string(cents: summary.unrealizedGainCents), tint: gainTint)
                            if let percent = summary.unrealizedGainPercent {
                                metric("Return", String(format: "%+.1f%%", percent), tint: gainTint)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("Items") {
                    LabeledContent("Total", value: "\(summary.itemCount)")
                    LabeledContent("Categories", value: "\(summary.byCategory.count)")
                }

                Section("By category") {
                    if summary.byCategory.isEmpty {
                        Text("Nothing catalogued yet.").foregroundStyle(.secondary)
                    }
                    ForEach(summary.byCategory, id: \.category) { breakdown in
                        CategoryRow(breakdown: breakdown,
                                    maximum: max(1, summary.totalEstimatedValueCents))
                    }
                }
            }
            .navigationTitle("Portfolio")
            .refreshable { await environment.syncNow() }
        }
    }

    private var summary: PortfolioSummary {
        Valuation.portfolioSummary(items: items.map(\.asDomain))
    }

    private var gainTint: Color {
        summary.unrealizedGainCents >= 0 ? .green : .red
    }

    private func metric(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(tint).monospacedDigit()
        }
    }
}

struct CategoryRow: View {
    let breakdown: CategoryBreakdown
    let maximum: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(breakdown.category.rawValue.capitalized).font(.subheadline.weight(.medium))
                Spacer()
                Text(CurrencyFormat.string(cents: breakdown.estimatedValueCents))
                    .font(.subheadline)
                    .monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 6)
            HStack {
                Text("\(breakdown.itemCount) item(s)")
                Spacer()
                Text(CurrencyFormat.string(cents: breakdown.unrealizedGainCents))
                    .foregroundStyle(breakdown.unrealizedGainCents >= 0 ? .green : .red)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var fraction: CGFloat {
        CGFloat(breakdown.estimatedValueCents) / CGFloat(maximum)
    }
}
