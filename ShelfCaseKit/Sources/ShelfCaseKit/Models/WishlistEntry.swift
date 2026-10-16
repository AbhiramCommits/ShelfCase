import Foundation

/// A standing "tell me when this shows up cheap" query.
public struct WishlistEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var userId: UUID
    public var titleQuery: String
    public var maxPriceCents: Int
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        userId: UUID,
        titleQuery: String,
        maxPriceCents: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.titleQuery = titleQuery
        self.maxPriceCents = maxPriceCents
        self.createdAt = createdAt
    }

    /// Case-insensitive substring match used for wishlist notification.
    public func matches(title: String, valueCents: Int) -> Bool {
        let query = titleQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return false }
        guard title.lowercased().contains(query) else { return false }
        return valueCents <= maxPriceCents
    }
}
