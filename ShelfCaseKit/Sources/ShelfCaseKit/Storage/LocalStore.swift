import Foundation

// MARK: - Conflict archive

/// One resolved (or surrendered) conflict. The losing copy is always preserved
/// here so a user can review what the sync engine discarded.
public struct ConflictRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var itemId: UUID
    /// The local copy at the moment the conflict was detected.
    public var local: CollectibleItem
    /// The server copy returned by the 409.
    public var server: CollectibleItem
    /// What the engine wrote back after applying the merge policy.
    public var merged: CollectibleItem
    /// Short human-readable reason, e.g. `client-newer/user-authored`, `server-newer`.
    public var policy: String
    public var detectedAt: Date

    public init(
        id: UUID = UUID(),
        itemId: UUID,
        local: CollectibleItem,
        server: CollectibleItem,
        merged: CollectibleItem,
        policy: String,
        detectedAt: Date = Date()
    ) {
        self.id = id
        self.itemId = itemId
        self.local = local
        self.server = server
        self.merged = merged
        self.policy = policy
        self.detectedAt = detectedAt
    }
}

// MARK: - Storage protocol

/// Persistence boundary for the sync engine.
///
/// The app backs this with SwiftData; tests and the soak harness use
/// `InMemoryLocalStore`. Keeping it a protocol is what makes the engine testable
/// headlessly with `swift test` on a Mac with no simulator.
public protocol LocalStore: AnyObject, Sendable {
    /// Insert or replace an item by its local id.
    func upsert(_ item: CollectibleItem) async throws
    func item(id: UUID) async throws -> CollectibleItem?
    func allItems(includeDeleted: Bool) async throws -> [CollectibleItem]

    /// Items with a pending create/update/delete, oldest `updatedAt` first.
    /// Order matters: the sync engine replays the outbox in order.
    func fetchPending() async throws -> [CollectibleItem]

    /// Apply a row that came back from the server.
    func applyServerChange(_ item: CollectibleItem) async throws

    /// Mark a local item as fully synchronised.
    ///
    /// `serverId` differs from the local id when the server minted the row
    /// (i.e. the client did not send its own id); in that case the item is
    /// re-keyed to the server identity.
    func markSynced(
        id: UUID,
        serverId: UUID,
        serverVersion: Int,
        serverUpdatedAt: Date
    ) async throws

    func recordConflict(_ record: ConflictRecord) async throws
    func conflictArchive() async throws -> [ConflictRecord]

    func cursor() async throws -> String?
    func setCursor(_ value: String) async throws

    func upsertObservation(_ observation: PriceObservation) async throws
    func observations(forItem id: UUID) async throws -> [PriceObservation]
}

public extension LocalStore {
    /// Convenience for the common case where the server kept the client's id.
    func markSynced(id: UUID, serverVersion: Int, serverUpdatedAt: Date) async throws {
        try await markSynced(id: id, serverId: id, serverVersion: serverVersion, serverUpdatedAt: serverUpdatedAt)
    }
}

// MARK: - In-memory implementation

/// Deterministic, dependency-free `LocalStore` used by tests and the soak
/// harness. An actor so concurrent syncs cannot tear its state.
public actor InMemoryLocalStore: LocalStore {
    private var items: [UUID: CollectibleItem] = [:]
    private var observationsByItem: [UUID: [PriceObservation]] = [:]
    private var conflicts: [ConflictRecord] = []
    private var storedCursor: String?

    /// Every change the engine has pushed, in order. Diagnostics only.
    public private(set) var appliedServerChanges: [UUID] = []

    public init(items: [CollectibleItem] = []) {
        for item in items {
            self.items[item.id] = item
        }
    }

    public func upsert(_ item: CollectibleItem) async throws {
        items[item.id] = item
    }

    public func item(id: UUID) async throws -> CollectibleItem? {
        items[id]
    }

    public func allItems(includeDeleted: Bool = false) async throws -> [CollectibleItem] {
        items.values
            .filter { includeDeleted || !$0.isDeleted }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    public func fetchPending() async throws -> [CollectibleItem] {
        items.values
            .filter { $0.syncState.isPending }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    public func applyServerChange(_ item: CollectibleItem) async throws {
        items[item.id] = item
        appliedServerChanges.append(item.id)
    }

    public func markSynced(
        id: UUID,
        serverId: UUID,
        serverVersion: Int,
        serverUpdatedAt: Date
    ) async throws {
        guard var item = items[id] else { return }
        if serverId != id {
            // The server minted the row: adopt its identity and drop the
            // local placeholder.
            items.removeValue(forKey: id)
            item.id = serverId
        }
        item.version = serverVersion
        item.updatedAt = serverUpdatedAt
        item.syncState = .synced
        items[item.id] = item
    }

    public func recordConflict(_ record: ConflictRecord) async throws {
        conflicts.append(record)
    }

    public func conflictArchive() async throws -> [ConflictRecord] {
        conflicts
    }

    public func cursor() async throws -> String? {
        storedCursor
    }

    public func setCursor(_ value: String) async throws {
        storedCursor = value
    }

    public func upsertObservation(_ observation: PriceObservation) async throws {
        var list = observationsByItem[observation.itemId] ?? []
        list.removeAll { $0.id == observation.id }
        list.append(observation)
        observationsByItem[observation.itemId] = list.sorted { $0.observedAt > $1.observedAt }
    }

    public func observations(forItem id: UUID) async throws -> [PriceObservation] {
        observationsByItem[id] ?? []
    }

    // MARK: Test helpers

    public func itemCount(includeDeleted: Bool = false) -> Int {
        items.values.filter { includeDeleted || !$0.isDeleted }.count
    }

    public func pendingCount() -> Int {
        items.values.filter { $0.syncState.isPending }.count
    }

    /// Stable, order-independent digest of the local state — used by the soak
    /// harness to compare client and server.
    public func checksum() -> String {
        let material = items.values
            .map { "\($0.id.uuidString)|\($0.title)|\($0.conditionGrade.rawValue)|\($0.estimatedValueCents)|\($0.isDeleted)" }
            .sorted()
            .joined(separator: "\n")
        return ShelfCaseDigest.hex(material)
    }
}

// MARK: - Digest

/// Tiny deterministic digest (FNV-1a, 64-bit) so the harness needs no crypto
/// dependency and produces identical output on every platform.
public enum ShelfCaseDigest {
    public static func hex(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
