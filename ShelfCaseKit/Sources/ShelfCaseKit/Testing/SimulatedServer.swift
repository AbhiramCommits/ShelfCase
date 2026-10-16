import Foundation

/// How the simulated server behaves when a `POST /items` arrives with an id that
/// already exists. This models the two states of the real Express route.
public enum CreateSemantics: String, Sendable, Codable {
    /// Pre-fix Express: `INSERT` with no `ON CONFLICT`, so a retried create
    /// explodes with a unique-violation `500`.
    case rejectDuplicateId
    /// Post-fix Express: `ON CONFLICT (id) DO NOTHING` then return the winner, so
    /// a retried create is a `200` replay of the original row.
    case replayExistingRow
}

/// A faithful, in-process model of the ShelfCase API.
///
/// It speaks the same JSON as the Express server, honours `Idempotency-Key`, and
/// maintains the same `change_seq` cursor, so the client under test in the soak
/// harness exercises its real request-building, retry and conflict code paths —
/// only the socket is fake.
public actor SimulatedServer {
    public struct Options: Sendable {
        public var createSemantics: CreateSemantics
        /// Artificial clock skew applied to server timestamps, in seconds.
        public var clockSkew: TimeInterval

        public init(createSemantics: CreateSemantics = .replayExistingRow, clockSkew: TimeInterval = 0) {
            self.createSemantics = createSemantics
            self.clockSkew = clockSkew
        }
    }

    private struct Row {
        var item: CollectibleItem
        var changeSeq: Int
    }

    private var rows: [UUID: Row] = [:]
    private var sequence = 0
    private var idempotencyLog: [String: (status: Int, body: Data)] = [:]
    private let options: Options

    // MARK: Counters (read by the harness)

    /// Item rows actually persisted, across all requests. The duplicate-creation
    /// defect shows up here as a number larger than the client's own count.
    public private(set) var itemRowsInserted = 0
    public private(set) var duplicateIdRejections = 0
    public private(set) var idempotentReplays = 0
    public private(set) var tombstonesServed = 0
    public private(set) var requestsByRoute: [String: Int] = [:]

    public init(options: Options = Options()) {
        self.options = options
    }

    // MARK: Introspection

    public func itemCount(includeDeleted: Bool = true) -> Int {
        rows.values.filter { includeDeleted || !$0.item.isDeleted }.count
    }

    public func allItems(includeDeleted: Bool = true) -> [CollectibleItem] {
        rows.values
            .filter { includeDeleted || !$0.item.isDeleted }
            .map(\.item)
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func item(id: UUID) -> CollectibleItem? {
        rows[id]?.item
    }

    /// Order-independent digest of server state, matching
    /// `InMemoryLocalStore.checksum()`'s field selection.
    public func checksum() -> String {
        let material = rows.values
            .map { "\($0.item.id.uuidString)|\($0.item.title)|\($0.item.conditionGrade.rawValue)|\($0.item.estimatedValueCents)|\($0.item.isDeleted)" }
            .sorted()
            .joined(separator: "\n")
        return ShelfCaseDigest.hex(material)
    }

    public func nextSequence() -> Int {
        sequence += 1
        return sequence
    }

    // MARK: Routing

    public func handle(_ request: HTTPRequest) async throws -> HTTPResponse {
        requestsByRoute[request.routeKey, default: 0] += 1

        switch (request.method, request.path) {
        case ("POST", "/items"):
            return try await createItem(request)
        case ("GET", let path) where path.hasPrefix("/items/"):
            return try itemGet(request, path: path)
        case ("PATCH", let path) where path.hasPrefix("/items/"):
            return try await itemPatch(request, path: path)
        case ("DELETE", let path) where path.hasPrefix("/items/"):
            return try await itemDelete(request, path: path)
        case ("GET", "/sync/pull"):
            return try await syncPull(request)
        default:
            return json(404, ["error": ["code": "NOT_FOUND", "message": "No route for \(request.routeKey)"]])
        }
    }

    // MARK: Handlers

    private func createItem(_ request: HTTPRequest) async throws -> HTTPResponse {
        // Idempotency-Key replay, exactly like the Express middleware.
        if let key = request.headers["Idempotency-Key"], let stored = idempotencyLog[key] {
            idempotentReplays += 1
            var headers = ["Idempotency-Replayed": "true"]
            headers["Content-Type"] = "application/json"
            return HTTPResponse(statusCode: stored.status, headers: headers, body: stored.body)
        }

        let decoder = ShelfCaseCoding.makeDecoder()
        guard let body = request.body,
              let payload = try? decoder.decode(CreatePayload.self, from: body) else {
            return json(422, ["error": ["code": "VALIDATION_ERROR", "message": "Bad create body"]])
        }

        if let requested = payload.id, rows[requested] != nil {
            switch options.createSemantics {
            case .rejectDuplicateId:
                duplicateIdRejections += 1
                let response = json(500, [
                    "error": [
                        "code": "INTERNAL_ERROR",
                        "message": "duplicate key value violates unique constraint \"items_pkey\"",
                    ],
                ])
                store(key: request.headers["Idempotency-Key"], response: response)
                return response
            case .replayExistingRow:
                let existing = rows[requested]!.item
                let response = json(200, ["item": existing])
                store(key: request.headers["Idempotency-Key"], response: response)
                return response
            }
        }

        let now = Date().addingTimeInterval(options.clockSkew)
        let item = CollectibleItem(
            id: payload.id ?? UUID(),
            title: payload.title,
            setName: payload.setName,
            category: payload.category,
            conditionGrade: payload.conditionGrade,
            purchasePriceCents: payload.purchasePriceCents,
            estimatedValueCents: payload.estimatedValueCents,
            acquiredAt: payload.acquiredAt,
            notes: payload.notes,
            imageLocalPath: payload.imageLocalPath,
            updatedAt: now,
            version: 1,
            isDeleted: false,
            syncState: .synced,
            ownerUserId: Self.ownerId
        )

        rows[item.id] = Row(item: item, changeSeq: nextSequence())
        itemRowsInserted += 1

        let response = json(201, ItemEnvelope(item: item, wishlistMatches: []))
        store(key: request.headers["Idempotency-Key"], response: response)
        return response
    }

    private func itemGet(_ request: HTTPRequest, path: String) throws -> HTTPResponse {
        guard let id = uuid(fromPath: path), let row = rows[id] else {
            return json(404, ["error": ["code": "NOT_FOUND", "message": "No item"]])
        }
        return json(200, ItemEnvelope(item: row.item, wishlistMatches: nil))
    }

    private func itemPatch(_ request: HTTPRequest, path: String) async throws -> HTTPResponse {
        guard let id = uuid(fromPath: path), var row = rows[id] else {
            return json(404, ["error": ["code": "NOT_FOUND", "message": "No item"]])
        }

        let decoder = ShelfCaseCoding.makeDecoder()
        guard let body = request.body, let payload = try? decoder.decode(UpdatePayload.self, from: body) else {
            return json(422, ["error": ["code": "VALIDATION_ERROR", "message": "Bad patch body"]])
        }

        if payload.version < row.item.version {
            return conflictResponse(serverItem: row.item, message: "Stale version")
        }

        row.item.title = payload.title
        row.item.setName = payload.setName
        row.item.category = payload.category
        row.item.conditionGrade = payload.conditionGrade
        row.item.purchasePriceCents = payload.purchasePriceCents
        row.item.estimatedValueCents = payload.estimatedValueCents
        row.item.notes = payload.notes
        row.item.imageLocalPath = payload.imageLocalPath
        row.item.version += 1
        row.item.updatedAt = Date().addingTimeInterval(options.clockSkew)
        row.changeSeq = nextSequence()
        rows[id] = row

        return json(200, ItemEnvelope(item: row.item, wishlistMatches: nil))
    }

    private func itemDelete(_ request: HTTPRequest, path: String) async throws -> HTTPResponse {
        guard let id = uuid(fromPath: path), var row = rows[id] else {
            return json(404, ["error": ["code": "NOT_FOUND", "message": "No item"]])
        }

        if let raw = request.query["version"], let version = Int(raw), version < row.item.version {
            return conflictResponse(serverItem: row.item, message: "Stale version on delete")
        }

        row.item.isDeleted = true
        row.item.version += 1
        row.item.updatedAt = Date().addingTimeInterval(options.clockSkew)
        row.changeSeq = nextSequence()
        rows[id] = row

        return json(200, ItemEnvelope(item: row.item, wishlistMatches: nil))
    }

    private func syncPull(_ request: HTTPRequest) async throws -> HTTPResponse {
        let since = Int(request.query["since"]?.split(separator: "|").last.map(String.init) ?? "0") ?? 0
        let limit = Int(request.query["limit"] ?? "200") ?? 200

        let changed = rows.values
            .filter { $0.changeSeq > since }
            .sorted { $0.changeSeq < $1.changeSeq }

        let page = Array(changed.prefix(limit))
        tombstonesServed += page.filter { $0.item.isDeleted }.count
        let hasMore = changed.count > page.count
        let maxSeq = page.map(\.changeSeq).max() ?? since

        let payload = PullEnvelope(
            items: page.map(\.item),
            observations: [],
            trades: [],
            wishlistEntries: [],
            nextCursor: "1970-01-01T00:00:00.000Z|\(maxSeq)",
            hasMore: hasMore
        )
        return json(200, payload)
    }

    // MARK: Server-side mutations used by the harness

    /// Simulate another device (or the user on the web) editing a row.
    @discardableResult
    public func remoteUpdate(id: UUID, notes: String, estimatedValueCents: Int? = nil) -> CollectibleItem? {
        guard var row = rows[id] else { return nil }
        row.item.notes = notes
        if let estimatedValueCents { row.item.estimatedValueCents = estimatedValueCents }
        row.item.version += 1
        row.item.updatedAt = Date().addingTimeInterval(options.clockSkew)
        row.changeSeq = nextSequence()
        rows[id] = row
        return row.item
    }

    /// Simulate a delete performed elsewhere.
    @discardableResult
    public func remoteDelete(id: UUID) -> CollectibleItem? {
        guard var row = rows[id] else { return nil }
        row.item.isDeleted = true
        row.item.version += 1
        row.item.updatedAt = Date().addingTimeInterval(options.clockSkew)
        row.changeSeq = nextSequence()
        rows[id] = row
        return row.item
    }

    // MARK: Plumbing

    private func store(key: String?, response: HTTPResponse) {
        guard let key else { return }
        idempotencyLog[key] = (response.statusCode, response.body)
    }

    private func uuid(fromPath path: String) -> UUID? {
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return UUID(uuidString: String(parts[1]))
    }

    private func conflictResponse(serverItem: CollectibleItem, message: String) -> HTTPResponse {
        let body = ConflictBody(error: .init(
            code: "VERSION_CONFLICT",
            message: message,
            details: .init(serverItem: serverItem)
        ))
        return json(409, body)
    }

    private func json(_ status: Int, _ value: some Encodable) -> HTTPResponse {
        let data = (try? ShelfCaseCoding.makeEncoder().encode(value)) ?? Data()
        return HTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: data)
    }

    static let ownerId = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!

    // MARK: Wire shapes

    private struct ItemEnvelope: Encodable {
        let item: CollectibleItem
        let wishlistMatches: [WishlistMatch]?
    }

    private struct PullEnvelope: Encodable {
        let items: [CollectibleItem]
        let observations: [PriceObservation]
        let trades: [Trade]
        let wishlistEntries: [WishlistEntry]
        let nextCursor: String
        let hasMore: Bool
    }

    private struct ConflictBody: Encodable {
        struct Payload: Encodable {
            struct Details: Encodable { let serverItem: CollectibleItem }
            let code: String
            let message: String
            let details: Details
        }
        let error: Payload
    }

    private struct CreatePayload: Decodable {
        let id: UUID?
        let title: String
        let setName: String
        let category: ItemCategory
        let conditionGrade: ConditionGrade
        let purchasePriceCents: Int
        let estimatedValueCents: Int
        let acquiredAt: Date
        let notes: String
        let imageLocalPath: String?
    }

    private struct UpdatePayload: Decodable {
        let title: String
        let setName: String
        let category: ItemCategory
        let conditionGrade: ConditionGrade
        let purchasePriceCents: Int
        let estimatedValueCents: Int
        let notes: String
        let imageLocalPath: String?
        let version: Int
    }
}

// MARK: - In-memory transport

/// Routes `HTTPRequest`s straight into a `SimulatedServer` — no sockets, no
/// ports, fully deterministic.
public struct InMemoryHTTPTransport: HTTPPerforming {
    private let server: SimulatedServer

    public init(server: SimulatedServer) {
        self.server = server
    }

    public func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await server.handle(request)
    }
}
