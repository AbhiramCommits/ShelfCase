import Foundation
import SwiftData
import ShelfCaseKit

/// `LocalStore` backed by SwiftData.
///
/// An `actor` on purpose: the sync engine runs off the main thread, and every
/// SwiftData write goes through this one serial executor, so a background sync
/// can never race a foreground edit on the same `ModelContext`.
public actor SwiftDataLocalStore: LocalStore {
    private let container: ModelContainer
    private let context: ModelContext

    public init(container: ModelContainer) {
        self.container = container
        self.context = ModelContext(container)
        self.context.autosaveEnabled = false
    }

    // MARK: Items

    public func upsert(_ item: CollectibleItem) async throws {
        if let existing = try entity(id: item.id) {
            existing.apply(item)
        } else {
            context.insert(ItemEntity(domain: item))
        }
        try save()
    }

    public func item(id: UUID) async throws -> CollectibleItem? {
        try entity(id: id)?.asDomain
    }

    public func allItems(includeDeleted: Bool = false) async throws -> [CollectibleItem] {
        let descriptor = FetchDescriptor<ItemEntity>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
            .filter { includeDeleted || !$0.isDeleted }
            .map(\.asDomain)
    }

    public func fetchPending() async throws -> [CollectibleItem] {
        let pendingValues = SyncState.allCases.filter(\.isPending).map(\.rawValue)
        let descriptor = FetchDescriptor<ItemEntity>(
            predicate: #Predicate { pendingValues.contains($0.syncStateRaw) },
            sortBy: [SortDescriptor(\.updatedAt, order: .forward)]
        )
        return try context.fetch(descriptor).map(\.asDomain)
    }

    public func applyServerChange(_ item: CollectibleItem) async throws {
        if let existing = try entity(id: item.id) {
            // Never let a pull clobber a local edit that has not been pushed yet:
            // the engine resolves that through a 409, not through a blind write.
            guard !existing.syncState.isPending else { return }
            existing.apply(item)
        } else {
            context.insert(ItemEntity(domain: item))
        }
        try save()
    }

    public func markSynced(
        id: UUID,
        serverId: UUID,
        serverVersion: Int,
        serverUpdatedAt: Date
    ) async throws {
        guard let existing = try entity(id: id) else { return }

        if serverId != id {
            // The server minted the identity: re-key the local row so both sides
            // agree from now on.
            let replacement = ItemEntity(domain: existing.asDomain)
            replacement.id = serverId
            replacement.version = serverVersion
            replacement.updatedAt = serverUpdatedAt
            replacement.syncStateRaw = SyncState.synced.rawValue
            context.delete(existing)
            context.insert(replacement)
        } else {
            existing.version = serverVersion
            existing.updatedAt = serverUpdatedAt
            existing.syncStateRaw = SyncState.synced.rawValue
        }
        try save()
    }

    public func markAllDeletedLocally(id: UUID) async throws {
        guard let existing = try entity(id: id) else { return }
        existing.isDeleted = true
        existing.syncStateRaw = SyncState.synced.rawValue
        try save()
    }

    // MARK: Conflicts

    public func recordConflict(_ record: ConflictRecord) async throws {
        if let existing = try conflictEntity(id: record.id) {
            context.delete(existing)
        }
        context.insert(try ConflictEntity(record: record))
        try save()
    }

    public func conflictArchive() async throws -> [ConflictRecord] {
        let descriptor = FetchDescriptor<ConflictEntity>(
            sortBy: [SortDescriptor(\.detectedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).compactMap(\.asDomain)
    }

    // MARK: Cursor

    public func cursor() async throws -> String? {
        try metadata(key: "sync.cursor")?.value
    }

    public func setCursor(_ value: String) async throws {
        try setMetadata(key: "sync.cursor", value: value)
    }

    // MARK: Observations

    public func upsertObservation(_ observation: PriceObservation) async throws {
        let id = observation.id
        let descriptor = FetchDescriptor<ObservationEntity>(
            predicate: #Predicate { $0.id == id }
        )
        if let existing = try context.fetch(descriptor).first {
            existing.sourceLabel = observation.sourceLabel
            existing.valueCents = observation.valueCents
            existing.observedAt = observation.observedAt
        } else {
            context.insert(ObservationEntity(domain: observation))
        }
        try save()
    }

    public func observations(forItem id: UUID) async throws -> [PriceObservation] {
        let descriptor = FetchDescriptor<ObservationEntity>(
            predicate: #Predicate { $0.itemId == id },
            sortBy: [SortDescriptor(\.observedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).map(\.asDomain)
    }

    // MARK: Trades and wishlist (read paths used by the UI)

    public func upsertTrade(_ trade: Trade) async throws {
        let id = trade.id
        let descriptor = FetchDescriptor<TradeEntity>(predicate: #Predicate { $0.id == id })
        if let existing = try context.fetch(descriptor).first {
            existing.statusRaw = trade.status.rawValue
            existing.updatedAt = trade.updatedAt
            existing.version = trade.version
            existing.offeredItemIds = trade.offeredItemIds
            existing.requestedItemIds = trade.requestedItemIds
        } else {
            context.insert(TradeEntity(domain: trade))
        }
        try save()
    }

    public func allTrades() async throws -> [Trade] {
        let descriptor = FetchDescriptor<TradeEntity>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try context.fetch(descriptor).map(\.asDomain)
    }

    public func upsertWishlist(_ entry: WishlistEntry) async throws {
        let id = entry.id
        let descriptor = FetchDescriptor<WishlistEntity>(predicate: #Predicate { $0.id == id })
        if let existing = try context.fetch(descriptor).first {
            existing.titleQuery = entry.titleQuery
            existing.maxPriceCents = entry.maxPriceCents
        } else {
            context.insert(WishlistEntity(domain: entry))
        }
        try save()
    }

    public func allWishlistEntries() async throws -> [WishlistEntry] {
        let descriptor = FetchDescriptor<WishlistEntity>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor).map(\.asDomain)
    }

    // MARK: Plumbing

    private func entity(id: UUID) throws -> ItemEntity? {
        let descriptor = FetchDescriptor<ItemEntity>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    private func conflictEntity(id: UUID) throws -> ConflictEntity? {
        let descriptor = FetchDescriptor<ConflictEntity>(predicate: #Predicate { $0.id == id })
        return try context.fetch(descriptor).first
    }

    private func metadata(key: String) throws -> SyncMetadataEntity? {
        let descriptor = FetchDescriptor<SyncMetadataEntity>(predicate: #Predicate { $0.key == key })
        return try context.fetch(descriptor).first
    }

    private func setMetadata(key: String, value: String) throws {
        if let existing = try metadata(key: key) {
            existing.value = value
        } else {
            context.insert(SyncMetadataEntity(key: key, value: value))
        }
        try save()
    }

    private func save() throws {
        if context.hasChanges {
            try context.save()
        }
    }
}
