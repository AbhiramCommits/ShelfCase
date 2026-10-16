import Foundation
import Testing
@testable import ShelfCaseKit

@Suite("Valuation")
struct ValuationTests {

    // MARK: - Median

    @Test("median of an empty sample is nil")
    func medianOfEmptySampleIsNil() {
        #expect(Valuation.median([]) == nil)
    }

    @Test("median of an odd-count sample is the middle element")
    func medianOfOddCountSample() {
        #expect(Valuation.median([10]) == 10)
        #expect(Valuation.median([30, 10, 20]) == 20)
        #expect(Valuation.median([5, 1, 9, 3, 7]) == 5)
    }

    @Test("median of an even-count sample averages the central pair")
    func medianOfEvenCountSampleAveragesCentralPair() {
        // 10, 20, 30, 40 -> (20 + 30) / 2 = 25
        #expect(Valuation.median([10, 20, 30, 40]) == 25)
        // 1, 2 -> (1 + 2) / 2 = 1 (integer truncation)
        #expect(Valuation.median([1, 2]) == 1)
        // duplicates survive
        #expect(Valuation.median([100, 100, 200, 300]) == 150)
    }

    @Test("median ignores input ordering")
    func medianIgnoresInputOrder() {
        #expect(Valuation.median([9, 2, 7, 4]) == Valuation.median([2, 4, 7, 9]))
    }

    // MARK: - estimatedValue

    @Test("no observations yields no estimate")
    func estimatedValueWithNoObservationsIsNil() {
        let item = CollectibleItem(title: "Black Lotus")
        #expect(Valuation.estimatedValue(for: item, observations: []) == nil)
    }

    @Test("observations for other items are ignored")
    func estimatedValueIgnoresObservationsForOtherItems() {
        let item = CollectibleItem(title: "Mox Sapphire")
        let other = PriceObservation(itemId: UUID(), sourceLabel: "eBay", valueCents: 999_999)
        #expect(Valuation.estimatedValue(for: item, observations: [other]) == nil)
    }

    @Test("only the last five observations by observedAt are used")
    func estimatedValueUsesOnlyLastFiveObservations() throws {
        let itemId = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        var observations: [PriceObservation] = []
        // Older, wildly expensive observations must be excluded from the window.
        for (index, cents) in [1_000_000, 2_000_000, 3_000_000].enumerated() {
            observations.append(
                PriceObservation(
                    itemId: itemId,
                    sourceLabel: "old",
                    valueCents: cents,
                    observedAt: base.addingTimeInterval(Double(index))
                )
            )
        }
        for (index, cents) in [100, 200, 300, 400, 500].enumerated() {
            observations.append(
                PriceObservation(
                    itemId: itemId,
                    sourceLabel: "recent",
                    valueCents: cents,
                    observedAt: base.addingTimeInterval(100 + Double(index))
                )
            )
        }

        let item = CollectibleItem(id: itemId, title: "Sol Ring", conditionGrade: .nearMint)
        let valuation = try #require(Valuation.estimatedValue(for: item, observations: observations))

        #expect(valuation.rawMedianCents == 300)  // median of 100...500
        #expect(valuation.sampleCount == 5)
        #expect(valuation.adjustedCents == 300)  // nearMint multiplier is 1.0
        #expect(valuation.usedObservations.count == 5)
    }

    @Test(
        "grade multipliers scale the raw median",
        arguments: [
            (ConditionGrade.mint, 12_500),
            (ConditionGrade.nearMint, 10_000),
            (ConditionGrade.excellent, 8_500),
            (ConditionGrade.good, 6_500),
            (ConditionGrade.poor, 4_000),
        ])
    func estimatedValueAppliesGradeMultipliers(grade: ConditionGrade, expectedCents: Int) throws {
        let itemId = UUID()
        let observations = [PriceObservation(itemId: itemId, sourceLabel: "eBay", valueCents: 10_000)]
        let item = CollectibleItem(id: itemId, title: "Charizard", conditionGrade: grade)
        let valuation = try #require(Valuation.estimatedValue(for: item, observations: observations))
        #expect(valuation.adjustedCents == expectedCents)
    }

    @Test("grades are ordered so better condition is worth more")
    func gradeMultiplierTableIsMonotonic() {
        let grades = ConditionGrade.allCases.sorted { $0.rank > $1.rank }
        let multipliers = grades.map(\.multiplier)
        #expect(multipliers == multipliers.sorted(by: >))
    }

    @Test("adjusted value rounds to the nearest cent")
    func estimatedValueRoundsToNearestCent() {
        let itemId = UUID()
        // 101 * 0.85 = 85.85 -> 86
        let observations = [PriceObservation(itemId: itemId, sourceLabel: "eBay", valueCents: 101)]
        let item = CollectibleItem(id: itemId, title: "Rounder", conditionGrade: .excellent)
        #expect(Valuation.estimatedValueCents(for: item, observations: observations) == 86)
    }

    @Test("an even-sized window averages its central pair")
    func evenCountWindowAveragesCentralPair() throws {
        let itemId = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let observations = [100, 300].enumerated().map { index, cents in
            PriceObservation(
                itemId: itemId,
                sourceLabel: "eBay",
                valueCents: cents,
                observedAt: base.addingTimeInterval(Double(index))
            )
        }
        let item = CollectibleItem(id: itemId, title: "Even Window", conditionGrade: .nearMint)
        let valuation = try #require(Valuation.estimatedValue(for: item, observations: observations))
        #expect(valuation.rawMedianCents == 200)
    }

    // MARK: - Portfolio summary

    @Test("an empty collection has zero totals and no percentage")
    func portfolioSummaryEmptyCollection() {
        let summary = Valuation.portfolioSummary(items: [])
        #expect(summary.itemCount == 0)
        #expect(summary.totalCostCents == 0)
        #expect(summary.totalEstimatedValueCents == 0)
        #expect(summary.unrealizedGainCents == 0)
        #expect(summary.byCategory.isEmpty)
        #expect(summary.unrealizedGainPercent == nil)
    }

    @Test("portfolio totals, gain and percentage")
    func portfolioSummaryTotalsAndGain() throws {
        let items = [
            TestFixtures.item(category: .card, cost: 1_000, value: 2_500),
            TestFixtures.item(category: .card, cost: 4_000, value: 3_000),
            TestFixtures.item(category: .figure, cost: 5_000, value: 5_000),
        ]

        let summary = Valuation.portfolioSummary(items: items)

        #expect(summary.itemCount == 3)
        #expect(summary.totalCostCents == 10_000)
        #expect(summary.totalEstimatedValueCents == 10_500)
        #expect(summary.unrealizedGainCents == 500)
        let percent = try #require(summary.unrealizedGainPercent)
        #expect(abs(percent - 5.0) < 0.0001)
    }

    @Test("a losing portfolio reports a negative gain")
    func portfolioSummaryNegativeGain() throws {
        let items = [TestFixtures.item(category: .vinyl, cost: 20_000, value: 5_000)]
        let summary = Valuation.portfolioSummary(items: items)
        #expect(summary.unrealizedGainCents == -15_000)
        let percent = try #require(summary.unrealizedGainPercent)
        #expect(abs(percent - (-75.0)) < 0.0001)
    }

    @Test("per-category breakdown sums match the buckets")
    func portfolioSummaryBreaksDownPerCategory() throws {
        let items = [
            TestFixtures.item(category: .card, cost: 1_000, value: 2_000),
            TestFixtures.item(category: .card, cost: 1_000, value: 3_000),
            TestFixtures.item(category: .vinyl, cost: 10_000, value: 8_000),
            TestFixtures.item(category: .other, cost: 0, value: 0),
        ]

        let summary = Valuation.portfolioSummary(items: items)
        #expect(summary.byCategory.count == 3)  // empty categories are omitted

        let cards = try #require(summary.byCategory.first { $0.category == .card })
        #expect(cards.itemCount == 2)
        #expect(cards.costCents == 2_000)
        #expect(cards.estimatedValueCents == 5_000)
        #expect(cards.unrealizedGainCents == 3_000)

        let vinyl = try #require(summary.byCategory.first { $0.category == .vinyl })
        #expect(vinyl.unrealizedGainCents == -2_000)
    }

    @Test("soft-deleted items are excluded from the portfolio")
    func portfolioSummaryExcludesDeletedItems() {
        let items = [
            TestFixtures.item(category: .card, cost: 1_000, value: 2_000),
            TestFixtures.item(category: .card, cost: 9_000, value: 9_000, isDeleted: true),
        ]
        let summary = Valuation.portfolioSummary(items: items)
        #expect(summary.itemCount == 1)
        #expect(summary.totalCostCents == 1_000)
        #expect(summary.totalEstimatedValueCents == 2_000)
    }

    @Test("category breakdown ordering is stable")
    func portfolioSummaryCategoryOrderIsStable() {
        let items = [
            TestFixtures.item(category: .vinyl, cost: 1, value: 1),
            TestFixtures.item(category: .card, cost: 1, value: 1),
            TestFixtures.item(category: .figure, cost: 1, value: 1),
            TestFixtures.item(category: .other, cost: 1, value: 1),
        ]
        let summary = Valuation.portfolioSummary(items: items)
        #expect(summary.byCategory.map(\.category) == [.card, .figure, .vinyl, .other])
    }

    // MARK: - Codable round trips

    @Test("CollectibleItem round-trips through ISO8601 JSON")
    func collectibleItemRoundTripsThroughISO8601JSON() throws {
        let item = CollectibleItem(
            title: "Glurak",
            setName: "Base Set",
            category: .card,
            conditionGrade: .excellent,
            purchasePriceCents: 12_345,
            estimatedValueCents: 45_678,
            acquiredAt: Date(timeIntervalSince1970: 1_700_000_000),
            notes: "sleeved",
            imageLocalPath: "images/glurak.jpg",
            updatedAt: Date(timeIntervalSince1970: 1_700_000_500),
            version: 7,
            syncState: .pendingUpdate
        )

        let data = try ShelfCaseCoding.makeEncoder().encode(item)
        let decoded = try ShelfCaseCoding.makeDecoder().decode(CollectibleItem.self, from: data)
        #expect(decoded == item)
        #expect(decoded.acquiredAt == item.acquiredAt)
    }

    @Test("Trade round-trips through ISO8601 JSON")
    func tradeRoundTripsThroughISO8601JSON() throws {
        // The wire format carries millisecond resolution (ISO8601 with fractional
        // seconds), so compare against dates already aligned to a millisecond.
        let stamp = Date(timeIntervalSince1970: 1_700_000_000.125)
        let trade = Trade(
            proposerUserId: UUID(),
            receiverUserId: UUID(),
            offeredItemIds: [UUID(), UUID()],
            requestedItemIds: [UUID()],
            status: .accepted,
            createdAt: stamp,
            updatedAt: stamp
        )
        let data = try ShelfCaseCoding.makeEncoder().encode(trade)
        let decoded = try ShelfCaseCoding.makeDecoder().decode(Trade.self, from: data)
        #expect(decoded == trade)
        #expect(decoded.createdAt == stamp)
    }

    @Test("wishlist matches on case-insensitive substring plus price ceiling")
    func wishlistEntryMatchesTitleSubstringAndPriceCeiling() {
        let entry = WishlistEntry(userId: UUID(), titleQuery: "charizard", maxPriceCents: 50_000)
        #expect(entry.matches(title: "Charizard Base Set Holo", valueCents: 49_999))
        #expect(entry.matches(title: "CHARIZARD ex", valueCents: 1))
        #expect(!entry.matches(title: "Blastoise", valueCents: 100))
        #expect(!entry.matches(title: "Charizard", valueCents: 50_001))
    }

    @Test("a blank wishlist query never matches")
    func wishlistEntryWithBlankQueryNeverMatches() {
        let entry = WishlistEntry(userId: UUID(), titleQuery: "   ", maxPriceCents: 1_000)
        #expect(!entry.matches(title: "Anything", valueCents: 0))
    }
}

/// Shared deterministic fixtures for the Kit test suites.
enum TestFixtures {
    static func item(
        title: String = "Item",
        category: ItemCategory,
        grade: ConditionGrade = .nearMint,
        cost: Int,
        value: Int,
        isDeleted: Bool = false
    ) -> CollectibleItem {
        CollectibleItem(
            title: title,
            category: category,
            conditionGrade: grade,
            purchasePriceCents: cost,
            estimatedValueCents: value,
            isDeleted: isDeleted
        )
    }
}
