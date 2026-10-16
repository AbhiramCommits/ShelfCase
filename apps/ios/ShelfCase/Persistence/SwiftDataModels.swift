import Foundation
import SwiftData
import ShelfCaseKit

// MARK: - SwiftData entities
//
// These mirror the `ShelfCaseKit` domain models. They are intentionally dumb:
// all conversion logic lives in `asDomain` / `apply(_:)` so the sync engine only
// ever sees value types from the Kit, which is what keeps the engine testable
// without a simulator.

@Model
final class ItemEntity {
    @Attribute(.unique) var id: UUID
    var title: String
    var setName: String
    var categoryRaw: String
    var conditionGradeRaw: String
    var purchasePriceCents: Int
    var estimatedValueCents: Int
    var acquiredAt: Date
    var notes: String
    var imageLocalPath: String?
    var updatedAt: Date
    var version: Int
    var isDeleted: Bool
    var syncStateRaw: String
    var ownerUserId: UUID?
    /// `Idempotency-Key` pinned to this row while it has an unpushed change.
    /// Persisted so a retry after an app relaunch presents the same key.
    var idempotencyKey: String?

    init(
        id: UUID = UUID(),
        title: String,
        setName: String = "",
        category: ItemCategory = .other,
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
        ownerUserId: UUID? = nil,
        idempotencyKey: String? = nil
    ) {
        self.id = id
        self.title = title
        self.setName = setName
        self.categoryRaw = category.rawValue
        self.conditionGradeRaw = conditionGrade.rawValue
        self.purchasePriceCents = purchasePriceCents
        self.estimatedValueCents = estimatedValueCents
        self.acquiredAt = acquiredAt
        self.notes = notes
        self.imageLocalPath = imageLocalPath
        self.updatedAt = updatedAt
        self.version = version
        self.isDeleted = isDeleted
        self.syncStateRaw = syncState.rawValue
        self.ownerUserId = ownerUserId
        self.idempotencyKey = idempotencyKey
    }

    convenience init(domain: CollectibleItem) {
        self.init(id: domain.id)
        apply(domain)
    }

    var category: ItemCategory { ItemCategory(rawValue: categoryRaw) ?? .other }
    var conditionGrade: ConditionGrade { ConditionGrade(rawValue: conditionGradeRaw) ?? .nearMint }
    var syncState: SyncState { SyncState(rawValue: syncStateRaw) ?? .synced }

    /// Project back into the Kit's value type.
    var asDomain: CollectibleItem {
        CollectibleItem(
            id: id,
            title: title,
            setName: setName,
            category: category,
            conditionGrade: conditionGrade,
            purchasePriceCents: purchasePriceCents,
            estimatedValueCents: estimatedValueCents,
            acquiredAt: acquiredAt,
            notes: notes,
            imageLocalPath: imageLocalPath,
            updatedAt: updatedAt,
            version: version,
            isDeleted: isDeleted,
            syncState: syncState,
            ownerUserId: ownerUserId
        )
    }

    func apply(_ domain: CollectibleItem) {
        id = domain.id
        title = domain.title
        setName = domain.setName
        categoryRaw = domain.category.rawValue
        conditionGradeRaw = domain.conditionGrade.rawValue
        purchasePriceCents = domain.purchasePriceCents
        estimatedValueCents = domain.estimatedValueCents
        acquiredAt = domain.acquiredAt
        notes = domain.notes
        imageLocalPath = domain.imageLocalPath
        updatedAt = domain.updatedAt
        version = domain.version
        isDeleted = domain.isDeleted
        syncStateRaw = domain.syncState.rawValue
        ownerUserId = domain.ownerUserId
    }
}

@Model
final class ObservationEntity {
    @Attribute(.unique) var id: UUID
    var itemId: UUID
    var sourceLabel: String
    var valueCents: Int
    var observedAt: Date

    init(id: UUID = UUID(), itemId: UUID, sourceLabel: String, valueCents: Int, observedAt: Date = Date()) {
        self.id = id
        self.itemId = itemId
        self.sourceLabel = sourceLabel
        self.valueCents = valueCents
        self.observedAt = observedAt
    }

    convenience init(domain: PriceObservation) {
        self.init(
            id: domain.id,
            itemId: domain.itemId,
            sourceLabel: domain.sourceLabel,
            valueCents: domain.valueCents,
            observedAt: domain.observedAt
        )
    }

    var asDomain: PriceObservation {
        PriceObservation(
            id: id,
            itemId: itemId,
            sourceLabel: sourceLabel,
            valueCents: valueCents,
            observedAt: observedAt
        )
    }
}

@Model
final class TradeEntity {
    @Attribute(.unique) var id: UUID
    var proposerUserId: UUID
    var receiverUserId: UUID
    var offeredItemIds: [UUID]
    var requestedItemIds: [UUID]
    var statusRaw: String
    var createdAt: Date
    var updatedAt: Date
    var version: Int

    init(
        id: UUID = UUID(),
        proposerUserId: UUID,
        receiverUserId: UUID,
        offeredItemIds: [UUID],
        requestedItemIds: [UUID],
        status: TradeStatus = .proposed,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        version: Int = 1
    ) {
        self.id = id
        self.proposerUserId = proposerUserId
        self.receiverUserId = receiverUserId
        self.offeredItemIds = offeredItemIds
        self.requestedItemIds = requestedItemIds
        self.statusRaw = status.rawValue
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
    }

    convenience init(domain: Trade) {
        self.init(
            id: domain.id,
            proposerUserId: domain.proposerUserId,
            receiverUserId: domain.receiverUserId,
            offeredItemIds: domain.offeredItemIds,
            requestedItemIds: domain.requestedItemIds,
            status: domain.status,
            createdAt: domain.createdAt,
            updatedAt: domain.updatedAt,
            version: domain.version
        )
    }

    var status: TradeStatus { TradeStatus(rawValue: statusRaw) ?? .proposed }

    var asDomain: Trade {
        Trade(
            id: id,
            proposerUserId: proposerUserId,
            receiverUserId: receiverUserId,
            offeredItemIds: offeredItemIds,
            requestedItemIds: requestedItemIds,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt,
            version: version
        )
    }
}

@Model
final class WishlistEntity {
    @Attribute(.unique) var id: UUID
    var userId: UUID
    var titleQuery: String
    var maxPriceCents: Int
    var createdAt: Date

    init(id: UUID = UUID(), userId: UUID, titleQuery: String, maxPriceCents: Int, createdAt: Date = Date()) {
        self.id = id
        self.userId = userId
        self.titleQuery = titleQuery
        self.maxPriceCents = maxPriceCents
        self.createdAt = createdAt
    }

    convenience init(domain: WishlistEntry) {
        self.init(
            id: domain.id,
            userId: domain.userId,
            titleQuery: domain.titleQuery,
            maxPriceCents: domain.maxPriceCents,
            createdAt: domain.createdAt
        )
    }

    var asDomain: WishlistEntry {
        WishlistEntry(
            id: id,
            userId: userId,
            titleQuery: titleQuery,
            maxPriceCents: maxPriceCents,
            createdAt: createdAt
        )
    }
}

/// Local archive of every conflict the engine resolved. The losing copy is kept
/// verbatim so it can be shown, exported or restored.
@Model
final class ConflictEntity {
    @Attribute(.unique) var id: UUID
    var itemId: UUID
    var policy: String
    var detectedAt: Date
    var localJSON: Data
    var serverJSON: Data
    var mergedJSON: Data

    init(
        id: UUID = UUID(),
        itemId: UUID,
        policy: String,
        detectedAt: Date,
        localJSON: Data,
        serverJSON: Data,
        mergedJSON: Data
    ) {
        self.id = id
        self.itemId = itemId
        self.policy = policy
        self.detectedAt = detectedAt
        self.localJSON = localJSON
        self.serverJSON = serverJSON
        self.mergedJSON = mergedJSON
    }

    convenience init(record: ConflictRecord) throws {
        let encoder = ShelfCaseCoding.makeEncoder()
        self.init(
            id: record.id,
            itemId: record.itemId,
            policy: record.policy,
            detectedAt: record.detectedAt,
            localJSON: try encoder.encode(record.local),
            serverJSON: try encoder.encode(record.server),
            mergedJSON: try encoder.encode(record.merged)
        )
    }

    var asDomain: ConflictRecord? {
        let decoder = ShelfCaseCoding.makeDecoder()
        guard let local = try? decoder.decode(CollectibleItem.self, from: localJSON),
            let server = try? decoder.decode(CollectibleItem.self, from: serverJSON),
            let merged = try? decoder.decode(CollectibleItem.self, from: mergedJSON)
        else { return nil }
        return ConflictRecord(
            id: id,
            itemId: itemId,
            local: local,
            server: server,
            merged: merged,
            policy: policy,
            detectedAt: detectedAt
        )
    }
}

/// Key/value blob for the sync cursor and other engine bookkeeping.
@Model
final class SyncMetadataEntity {
    @Attribute(.unique) var key: String
    var value: String

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

// MARK: - Schema

enum ShelfCaseSchema {
    static let models: [any PersistentModel.Type] = [
        ItemEntity.self,
        ObservationEntity.self,
        TradeEntity.self,
        WishlistEntity.self,
        ConflictEntity.self,
        SyncMetadataEntity.self,
    ]

    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: Schema(models), configurations: configuration)
    }
}
