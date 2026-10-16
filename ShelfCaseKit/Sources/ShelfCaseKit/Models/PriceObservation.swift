import Foundation

/// A single market observation for an item from some source (eBay, TCGPlayer, ...).
public struct PriceObservation: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var itemId: UUID
    public var sourceLabel: String
    public var valueCents: Int
    public var observedAt: Date

    public init(
        id: UUID = UUID(),
        itemId: UUID,
        sourceLabel: String,
        valueCents: Int,
        observedAt: Date = Date()
    ) {
        self.id = id
        self.itemId = itemId
        self.sourceLabel = sourceLabel
        self.valueCents = valueCents
        self.observedAt = observedAt
    }
}
