import Foundation

/// A physical collectible owned by a user.
public struct CollectibleItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var setName: String
    public var category: ItemCategory
    public var conditionGrade: ConditionGrade
    public var purchasePriceCents: Int
    public var estimatedValueCents: Int
    public var acquiredAt: Date
    public var notes: String
    public var imageLocalPath: String?
    public var updatedAt: Date
    public var version: Int
    public var isDeleted: Bool
    public var syncState: SyncState

    /// Ownership. Server authoritative — the sync engine never lets the client
    /// win on this field.
    public var ownerUserId: UUID?

    private enum CodingKeys: String, CodingKey {
        case id, title, setName, category, conditionGrade, purchasePriceCents
        case estimatedValueCents, acquiredAt, notes, imageLocalPath, updatedAt
        case version, isDeleted, syncState, ownerUserId
    }

    public init(
        id: UUID = UUID(),
        title: String,
        setName: String = "",
        category: ItemCategory = .card,
        conditionGrade: ConditionGrade = .nearMint,
        purchasePriceCents: Int = 0,
        estimatedValueCents: Int = 0,
        acquiredAt: Date = Date(),
        notes: String = "",
        imageLocalPath: String? = nil,
        updatedAt: Date = Date(),
        version: Int = 1,
        isDeleted: Bool = false,
        syncState: SyncState = .pendingCreate,
        ownerUserId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.setName = setName
        self.category = category
        self.conditionGrade = conditionGrade
        self.purchasePriceCents = purchasePriceCents
        self.estimatedValueCents = estimatedValueCents
        self.acquiredAt = acquiredAt
        self.notes = notes
        self.imageLocalPath = imageLocalPath
        self.updatedAt = updatedAt
        self.version = version
        self.isDeleted = isDeleted
        self.syncState = syncState
        self.ownerUserId = ownerUserId
    }

    /// Convenience initializer from the wire payload where sync state is implied.
    public static func fromServer(_ item: CollectibleItem) -> CollectibleItem {
        var copy = item
        copy.syncState = .synced
        return copy
    }
}
