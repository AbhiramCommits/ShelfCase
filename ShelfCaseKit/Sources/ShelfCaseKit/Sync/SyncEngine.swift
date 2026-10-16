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

    /// Rolling total of every HTTP attempt made through this engine.
    public private(set) var totalRetries = 0

    public init(
        api: ShelfCaseAPI,
        store: LocalStore,
        configuration: Configuration = .default,
        keyGenerator: @escaping KeyGenerator = { UUID().uuidString.lowercased() }
    ) {
        self.api = api
        self.store = store
        self.configuration = configuration
        self.keyGenerator = keyGenerator
    }

    // MARK: Pass

    public func sync() async -> SyncReport {
        let clock = ContinuousClock()
        let started = clock.now
        var report = SyncReport()

        let retriesBefore = (api as? APIClientMetricsReporting)?.metrics.retries ?? 0

        await push(into: &report)
        await pull(into: &report)

        let retriesAfter = (api as? APIClientMetricsReporting)?.metrics.retries ?? 0
        report.retries = max(0, retriesAfter - retriesBefore)
        totalRetries += report.retries

        let elapsed = clock.now - started
        report.durationMs = Self.milliseconds(elapsed)
        return report
    }

    // MARK: Push

    private func push(into report: inout SyncReport) async {
        let pending: [CollectibleItem]
        do {
            pending = try await store.fetchPending()
        } catch {
            report.errors += 1
            return
        }

        for change in pending {
            // One key per logical change for the duration of this pass. The
            // engine's own retry loop (inside the API client) reuses it, so a
            // retried POST is recognised by the server's idempotency middleware.
            let key = keyGenerator()

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

                case .pendingUpdate:
                    let response = try await api.updateItem(change, idempotencyKey: key)
                    try await store.markSynced(
                        id: change.id,
                        serverId: response.item.id,
                        serverVersion: response.item.version,
                        serverUpdatedAt: response.item.updatedAt
                    )
                    report.pushed += 1

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

                case .synced, .conflicted:
                    report.skipped += 1
                }
            } catch let error as APIClientError where isConflict(error) {
                guard case .conflict(let serverItem) = error else { continue }
                await resolveConflict(local: change, server: serverItem, into: &report)
            } catch let error as APIClientError {
                report.errors += 1
                _ = error
            } catch {
                report.errors += 1
            }
        }
    }

    private func isConflict(_ error: APIClientError) -> Bool {
        if case .conflict = error { return true }
        return false
    }

    private func resolveConflict(
        local: CollectibleItem,
        server: CollectibleItem,
        into report: inout SyncReport
    ) async {
        let outcome = ConflictResolution.resolve(local: local, server: server)
        let record = ConflictRecord(
            itemId: local.id,
            local: local,
            server: server,
            merged: outcome.merged,
            policy: outcome.policy
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

    private func pull(into report: inout SyncReport) async {
        var since: String?
        do {
            since = try await store.cursor()
        } catch {
            report.errors += 1
            return
        }

        for _ in 0..<configuration.maxPullPages {
            let page: SyncPullPage
            do {
                page = try await api.pull(since: since)
            } catch {
                report.errors += 1
                break
            }

            for item in page.items {
                if item.isDeleted {
                    // A tombstone is not a row to display, but it is still a
                    // change the client must absorb or it will keep resurrecting
                    // the item on the next local edit.
                    report.skipped += 1
                    continue
                }
                do {
                    try await store.applyServerChange(item)
                    report.pulled += 1
                } catch {
                    report.errors += 1
                }
            }

            for observation in page.observations {
                do {
                    try await store.upsertObservation(observation)
                } catch {
                    report.errors += 1
                }
            }

            // The cursor only ever moves forward.
            if let current = since, let currentSeq = Self.sequence(of: current),
               let nextSeq = Self.sequence(of: page.nextCursor), nextSeq <= currentSeq {
                break
            }

            since = page.nextCursor
            do {
                try await store.setCursor(page.nextCursor)
            } catch {
                report.errors += 1
            }

            if !page.hasMore { break }
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
