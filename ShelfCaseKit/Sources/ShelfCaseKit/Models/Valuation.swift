import Foundation

// MARK: - Valuation primitives

/// Result of valuing a single item from its market observations.
public struct ItemValuation: Equatable, Sendable {
    /// Median of the sampled observations before the grade multiplier.
    public let rawMedianCents: Int
    /// `rawMedianCents` scaled by the item's condition-grade multiplier.
    public let adjustedCents: Int
    /// Number of observations actually used (at most `sampleWindow`).
    public let sampleCount: Int
    /// The observations used, newest first.
    public let usedObservations: [PriceObservation]

    public init(rawMedianCents: Int, adjustedCents: Int, sampleCount: Int, usedObservations: [PriceObservation]) {
        self.rawMedianCents = rawMedianCents
        self.adjustedCents = adjustedCents
        self.sampleCount = sampleCount
        self.usedObservations = usedObservations
    }
}

// MARK: - Pure valuation functions

public enum Valuation {
    /// How many of the most recent observations feed the median.
    public static let sampleWindow = 5

    /// Median of an integer sample. Returns `nil` for an empty sample.
    ///
    /// Even counts average the two central values (integer division, truncated
    /// toward zero), odd counts take the exact middle value.
    public static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let count = sorted.count
        if count % 2 == 1 {
            return sorted[count / 2]
        }
        let lower = sorted[count / 2 - 1]
        let upper = sorted[count / 2]
        return (lower + upper) / 2
    }

    /// Estimate the value of `item` from `observations`.
    ///
    /// The last `sampleWindow` observations *by `observedAt`* are taken, their
    /// median computed, then the grade multiplier applied and rounded to the
    /// nearest cent.
    ///
    /// - Returns: `nil` when there are no observations for the item.
    public static func estimatedValue(
        for item: CollectibleItem,
        observations: [PriceObservation]
    ) -> ItemValuation? {
        let matching = observations
            .filter { $0.itemId == item.id }
            .sorted { $0.observedAt > $1.observedAt }

        let window = Array(matching.prefix(sampleWindow))
        guard let rawMedian = median(window.map(\.valueCents)) else { return nil }

        let adjusted = Int((Double(rawMedian) * item.conditionGrade.multiplier).rounded())

        return ItemValuation(
            rawMedianCents: rawMedian,
            adjustedCents: adjusted,
            sampleCount: window.count,
            usedObservations: window
        )
    }

    /// Convenience: just the adjusted cents, or `nil` when unpriceable.
    public static func estimatedValueCents(
        for item: CollectibleItem,
        observations: [PriceObservation]
    ) -> Int? {
        estimatedValue(for: item, observations: observations)?.adjustedCents
    }
}

// MARK: - Portfolio summary

public struct CategoryBreakdown: Equatable, Sendable {
    public let category: ItemCategory
    public let itemCount: Int
    public let costCents: Int
    public let estimatedValueCents: Int

    public var unrealizedGainCents: Int { estimatedValueCents - costCents }

    public init(category: ItemCategory, itemCount: Int, costCents: Int, estimatedValueCents: Int) {
        self.category = category
        self.itemCount = itemCount
        self.costCents = costCents
        self.estimatedValueCents = estimatedValueCents
    }
}

public struct PortfolioSummary: Equatable, Sendable {
    public let itemCount: Int
    public let totalCostCents: Int
    public let totalEstimatedValueCents: Int
    public let unrealizedGainCents: Int
    public let byCategory: [CategoryBreakdown]

    /// Percentage gain relative to cost. `nil` when cost is zero (avoids
    /// dividing by zero for a fully-gifted collection).
    public var unrealizedGainPercent: Double? {
        guard totalCostCents != 0 else { return nil }
        return Double(unrealizedGainCents) / Double(totalCostCents) * 100.0
    }

    public init(
        itemCount: Int,
        totalCostCents: Int,
        totalEstimatedValueCents: Int,
        unrealizedGainCents: Int,
        byCategory: [CategoryBreakdown]
    ) {
        self.itemCount = itemCount
        self.totalCostCents = totalCostCents
        self.totalEstimatedValueCents = totalEstimatedValueCents
        self.unrealizedGainCents = unrealizedGainCents
        self.byCategory = byCategory
    }
}

public extension Valuation {
    /// Aggregate a portfolio: totals plus a per-category breakdown.
    ///
    /// Deleted items are excluded. Categories with no items are omitted from
    /// `byCategory` but the list is ordered deterministically by `ItemCategory`
    /// declaration order.
    static func portfolioSummary(items: [CollectibleItem]) -> PortfolioSummary {
        let live = items.filter { !$0.isDeleted }

        let totalCost = live.reduce(0) { $0 + $1.purchasePriceCents }
        let totalValue = live.reduce(0) { $0 + $1.estimatedValueCents }

        var breakdown: [CategoryBreakdown] = []
        for category in ItemCategory.allCases {
            let bucket = live.filter { $0.category == category }
            guard !bucket.isEmpty else { continue }
            breakdown.append(
                CategoryBreakdown(
                    category: category,
                    itemCount: bucket.count,
                    costCents: bucket.reduce(0) { $0 + $1.purchasePriceCents },
                    estimatedValueCents: bucket.reduce(0) { $0 + $1.estimatedValueCents }
                )
            )
        }

        return PortfolioSummary(
            itemCount: live.count,
            totalCostCents: totalCost,
            totalEstimatedValueCents: totalValue,
            unrealizedGainCents: totalValue - totalCost,
            byCategory: breakdown
        )
    }
}
