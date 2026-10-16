import Foundation

/// A proposed swap of items between two users.
public struct Trade: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var proposerUserId: UUID
    public var receiverUserId: UUID
    public var offeredItemIds: [UUID]
    public var requestedItemIds: [UUID]
    public var status: TradeStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var version: Int

    public init(
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
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.version = version
    }
}
