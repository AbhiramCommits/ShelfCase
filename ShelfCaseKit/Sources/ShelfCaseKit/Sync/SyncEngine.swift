import Foundation

// MARK: - Report

/// What one `sync()` pass did. Every field is measured, not estimated.
public struct SyncReport: Equatable, Sendable {
    public var pushed: Int = 0
    public var pulled: Int = 0
    public var conflicts: Int = 0
    public var conflictsAutoResolved: Int = 0
    public var retries: Int = 0
    public var errors: Int = 0
    public var skipped: Int = 0
    /// Server-side deletes that were absorbed into the local store. Counted
    /// separately from `pulled` because a tombstone is not a row to display.
    public var tombstonesApplied: Int = 0
    public var durationMs: Int = 0
    /// Cursor the engine is holding when the pass ends.
    public var cursor: String?

    public init() {}
}

// MARK: - Conflict policy

/// Field-level merge policy. Documented in README §Architecture; implemented
/// here and nowhere else.
public enum ConflictResolution {
    public struct Outcome: Equatable, Sendable {
        public let merged: CollectibleItem
        public let policy: String
    }

    /// Fields the *client* may win when its mutation is strictly newer than the
    /// server's `updatedAt`. Everything else is server-authoritative.
    public static let userAuthoredFields = ["notes", "conditionGrade"]

    /// Fields the server always wins, regardless of timestamps: prices are
    /// derived from market data the server owns, and ownership only ever changes
    /// through an accepted trade.
    public static let serverAuthoritativeFields = ["estimatedValueCents", "ownerUserId", "isDeleted", "version"]

    public static func resolve(local: CollectibleItem, server: CollectibleItem) -> Outcome {
        var merged = server
        let clientIsNewer = local.updatedAt > server.updatedAt
        let policy: String

        if clientIsNewer {
            // Field-level merge: only the user-authored fields cross over.
            merged.notes = local.notes
            merged.conditionGrade = local.conditionGrade
            policy = "client-newer:user-authored-fields"
        } else {
            policy = "server-newer:last-writer-wins"
        }

        // Server-authoritative fields are re-asserted after any overlay.
        merged.estimatedValueCents = server.estimatedValueCents
        merged.ownerUserId = server.ownerUserId
        merged.isDeleted = server.isDeleted
        merged.version = server.version
        merged.updatedAt = max(local.updatedAt, server.updatedAt)
        merged.syncState = .pendingUpdate

        return Outcome(merged: merged, policy: policy)
    }
}

// MARK: - Engine

/// Offline-first sync engine.
///
/// One `sync()` pass:
///  1. **push** every locally-pending item, oldest first, each with its own
///     `Idempotency-Key`;
///  2. resolve any `409` through `ConflictResolution` and archive the loser;
///  3. **pull** deltas from the stored cursor, advancing it monotonically.
public final class SyncEngine: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// How many rows to request per pull page.
        public var pullPageLimit: Int
        /// Safety valve so a misbehaving server cannot spin the loop forever.
        public var maxPullPages: Int

        public init(pullPageLimit: Int = 200, maxPullPages: Int = 50) {
            self.pullPageLimit = pullPageLimit
            self.maxPullPages = maxPullPages
        }

        public static let `default` = Configuration()
        /// Small pages, to exercise pagination in tests.
        public static let tinyPages = Configuration(pullPageLimit: 2, maxPullPages: 500)
    }

    public typealias KeyGenerator = @Sendable () -> String

    private let api: ShelfCaseAPI
    private let store: LocalStore
    private let configuration: Configuration
    private let keyGenerator: KeyGenerator
    private let trace: TraceSink?

    /// Rolling total of every HTTP attempt made through this engine.
    public private(set) var totalRetries = 0

    public init(
        api: ShelfCaseAPI,
        store: LocalStore,
        configuration: Configuration = .default,
        keyGenerator: @escaping KeyGenerator = { UUID().uuidString.lowercased() },
        trace: TraceSink? = nil
    ) {
        self.api = api
        self.store = store
        self.configuration = configuration
        self.keyGenerator = keyGenerator
        self.trace = trace
    }

    // MARK: Pass

    public func sync() async -> SyncReport {
        let clock = ContinuousClock()
        let started = clock.now
        var report = SyncReport()

        let passId = TraceIdentifiers.next(prefix: "sync")
        trace?.emit(requestId: passId, "sync.start")

        let retriesBefore = (api as? APIClientMetricsReporting)?.metrics.retries ?? 0

        await push(into: &report, passId: passId)
        await pull(into: &report, passId: passId)

        let retriesAfter = (api as? APIClientMetricsReporting)?.metrics.retries ?? 0
        report.retries = max(0, retriesAfter - retriesBefore)
        totalRetries += report.retries

        let elapsed = clock.now - started
        report.durationMs = Self.milliseconds(elapsed)

        trace?.emit(
            requestId: passId,
            "sync.end",
            [
                "pushed": "\(report.pushed)",
                "pulled": "\(report.pulled)",
                "tombstonesApplied": "\(report.tombstonesApplied)",
                "conflicts": "\(report.conflicts)",
                "retries": "\(report.retries)",
                "errors": "\(report.errors)",
                "durationMs": "\(report.durationMs)",
                "cursor": report.cursor ?? "-",
            ]
        )
        return report
    }

    // MARK: Push

    private func push(into report: inout SyncReport, passId: String) async {
        let pending: [CollectibleItem]
        do {
            pending = try await store.fetchPending()
        } catch {
            report.errors += 1
            return
        }

        for change in pending {
            // The key is *persisted with the outbox entry*, not minted per pass.
            // A create whose reply was lost and which is retried after the app is
            // relaunched must present the same key again, or the server sees a
            // brand-new request. See docs/DEBUGGING.md §A.
            let key: String
            do {
                key = try await idempotencyKey(for: change)
            } catch {
                report.errors += 1
                continue
            }

            trace?.emit(
                requestId: passId,
                "push.change",
                [
                    "itemId": change.id.uuidString.lowercased(),
                    "state": change.syncState.rawValue,
                    "version": "\(change.version)",
                    "updatedAt": ISO8601DateFormatter.shelfCaseWithFractional.string(from: change.updatedAt),
                    "idempotencyKey": key,
                ]
            )

            do {
                switch change.syncState {
                case .pendingCreate:
                    let response = try await api.createItem(change, idempotencyKey: key)
                    try await store.markSynced(
                        id: change.id,
                        serverId: response.item.id,
                        serverVersion: response.item.version,
                        serverUpdatedAt: response.item.updatedAt
                    )
                    report.pushed += 1
                    trace?.emit(
                        requestId: passId,
                        "push.applied",
                        [
                            "itemId": change.id.uuidString.lowercased(),
                            "op": "create",
                            "serverId": response.item.id.uuidString.lowercased(),
                            "serverVersion": "\(response.item.version)",
                            "identityPreserved": "\(response.item.id == change.id)",
                        ]
                    )

                case .pendingUpdate:
                    let response = try await api.updateItem(change, idempotencyKey: key)
                    try await store.markSynced(
                        id: change.id,
                        serverId: response.item.id,
                        serverVersion: response.item.version,
                        serverUpdatedAt: response.item.updatedAt
                    )
                    report.pushed += 1
                    trace?.emit(
                        requestId: passId,
                        "push.applied",
                        [
                            "itemId": change.id.uuidString.lowercased(),
                            "op": "update",
                            "serverVersion": "\(response.item.version)",
                        ]
                    )

                case .pendingDelete:
                    let response = try await api.deleteItem(
                        id: change.id,
                        version: change.version,
                        idempotencyKey: key
                    )
                    try await store.markSynced(
                        id: change.id,
                        serverId: response.item.id,
                        serverVersion: response.item.version,
                        serverUpdatedAt: response.item.updatedAt
                    )
                    report.pushed += 1
                    trace?.emit(
                        requestId: passId,
                        "push.applied",
                        ["itemId": change.id.uuidString.lowercased(), "op": "delete"]
                    )

                case .synced, .conflicted:
                    report.skipped += 1
                }
            } catch let error as APIClientError where isConflict(error) {
                guard case .conflict(let serverItem) = error else { continue }
                await resolveConflict(local: change, server: serverItem, into: &report, passId: passId)
            } catch let error as APIClientError {
                report.errors += 1
                trace?.emit(
                    requestId: passId,
                    "push.failed",
                    level: .error,
                    [
                        "itemId": change.id.uuidString.lowercased(),
                        "state": change.syncState.rawValue,
                        "reason": error.describingForTelemetry,
                        "idempotencyKey": key,
                        "stillPending": "true",
                    ]
                )
            } catch {
                report.errors += 1
            }
        }
    }

    /// Fetch the pinned key for a pending change, minting and persisting one the
    /// first time the change is pushed.
    private func idempotencyKey(for change: CollectibleItem) async throws -> String {
        if let existing = try await store.pendingIdempotencyKey(forItem: change.id), !existing.isEmpty {
            return existing
        }
        let generated = keyGenerator()
        try await store.setPendingIdempotencyKey(generated, forItem: change.id)
        return generated
    }

    private func isConflict(_ error: APIClientError) -> Bool {
        if case .conflict = error { return true }
        return false
    }

    private func resolveConflict(
        local: CollectibleItem,
        server: CollectibleItem,
        into report: inout SyncReport,
        passId: String
    ) async {
        let outcome = ConflictResolution.resolve(local: local, server: server)
        let record = ConflictRecord(
            itemId: local.id,
            local: local,
            server: server,
            merged: outcome.merged,
            policy: outcome.policy
        )

        trace?.emit(
            requestId: passId,
            "push.conflict",
            level: .warn,
            [
                "itemId": local.id.uuidString.lowercased(),
                "policy": outcome.policy,
                "localUpdatedAt": ISO8601DateFormatter.shelfCaseWithFractional.string(from: local.updatedAt),
                "serverUpdatedAt": ISO8601DateFormatter.shelfCaseWithFractional.string(from: server.updatedAt),
                "clientNewer": "\(local.updatedAt > server.updatedAt)",
                "serverVersion": "\(server.version)",
            ]
        )

        do {
            try await store.recordConflict(record)
            // Keep the local store consistent with what was decided: the merged
            // copy is held as a pending update, keyed to the server's version, so
            // the next pass writes it back with optimistic concurrency.
            try await store.upsert(outcome.merged)
            report.conflicts += 1
            report.conflictsAutoResolved += 1
        } catch {
            report.errors += 1
        }
    }

    // MARK: Pull

    private func pull(into report: inout SyncReport, passId: String) async {
        var since: String?
        do {
            since = try await store.cursor()
        } catch {
            report.errors += 1
            return
        }

        for page in 0..<configuration.maxPullPages {
            let response: SyncPullPage
            do {
                response = try await api.pull(since: since)
            } catch {
                report.errors += 1
                break
            }

            var applied = 0
            var tombstones = 0

            for item in response.items {
                do {
                    // A tombstone is not a row to display, but it absolutely is a
                    // change the client must absorb. Skipping it (and then moving
                    // the cursor past it) loses the delete forever, and the next
                    // local edit resurrects the row. See docs/DEBUGGING.md §B.
                    try await store.applyServerChange(item)
                    if item.isDeleted {
                        tombstones += 1
                        report.tombstonesApplied += 1
                        trace?.emit(
                            requestId: passId,
                            "pull.tombstone",
                            ["itemId": item.id.uuidString.lowercased(), "serverVersion": "\(item.version)"]
                        )
                    } else {
                        applied += 1
                        report.pulled += 1
                    }
                } catch {
                    report.errors += 1
                }
            }

            for observation in response.observations {
                do {
                    try await store.upsertObservation(observation)
                } catch {
                    report.errors += 1
                }
            }

            trace?.emit(
                requestId: passId,
                "pull.page",
                [
                    "page": "\(page + 1)",
                    "since": since ?? "root",
                    "rows": "\(response.items.count)",
                    "applied": "\(applied)",
                    "tombstones": "\(tombstones)",
                    "observations": "\(response.observations.count)",
                    "hasMore": "\(response.hasMore)",
                    "nextCursor": response.nextCursor,
                ]
            )

            // The cursor only ever moves forward.
            if let current = since, let currentSeq = Self.sequence(of: current),
                let nextSeq = Self.sequence(of: response.nextCursor), nextSeq <= currentSeq
            {
                break
            }

            since = response.nextCursor
            do {
                try await store.setCursor(response.nextCursor)
            } catch {
                report.errors += 1
            }

            if !response.hasMore { break }
        }

        report.cursor = since
    }

    // MARK: Helpers

    static func sequence(of cursor: String) -> Int? {
        guard let raw = cursor.split(separator: "|").last else { return nil }
        return Int(raw)
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let seconds = duration.components.seconds
        let attoseconds = duration.components.attoseconds
        let total = Double(seconds) * 1000 + Double(attoseconds) / 1e15
        return Int(total.rounded())
    }
}
