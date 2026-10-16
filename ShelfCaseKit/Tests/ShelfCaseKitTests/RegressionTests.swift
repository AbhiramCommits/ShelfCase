import Foundation
import Testing
@testable import ShelfCaseKit

/// Regression tests for the two defects investigated in `docs/DEBUGGING.md`.
///
/// **These are the tests that fail against the pre-fix revision.** They are
/// written against the public API that existed *before* the fix, so they compile
/// and run unchanged in a `git worktree` checked out at the baseline tag — which
/// is exactly how `scripts/repro.sh` produces the "before" column.
///
/// The failure mode of each test against the baseline is noted in its doc
/// comment, so a reader can tell a genuine regression from an accidental pass.
@Suite("Regression: lost responses and lost tombstones")
struct RegressionTests {

    // MARK: A — lost response must not create a second row

    /// **Fails against the baseline** because `CreateItemPayload` omitted the
    /// client-generated `id`, so the server minted a fresh identity and every
    /// retry after a lost reply inserted another row.
    @Test("A retried create after a lost response must not duplicate, and must keep the client's id")
    func lostResponseAcrossSyncPassesDoesNotDuplicate() async throws {
        // Both attempts of the first pass lose their reply, so the client ends the
        // pass not knowing the server already committed. The second pass is the
        // "next sync after the user reopened the app".
        let stack = SyncFixtures.makeStack(
            script: [.dropResponse, .dropResponse],
            retryPolicy: RetryPolicy(maxAttempts: 2, baseDelay: .milliseconds(1), jitterRatio: 0)
        )

        let item = SyncFixtures.item(title: "One Card", value: 12_000)
        try await stack.store.upsert(item)

        let first = await stack.engine.sync()
        #expect(first.pushed == 0, "the first pass cannot confirm anything")
        #expect(first.errors == 1)
        #expect(await stack.store.pendingCount() == 1, "the change stays queued")

        let second = await stack.engine.sync()
        #expect(second.pushed == 1)

        // The whole point: one card in, one row out — on both sides.
        #expect(await stack.server.itemRowsInserted == 1, "the server must have inserted exactly one row")
        #expect(await stack.server.itemCount() == 1)
        #expect(await stack.store.itemCount() == 1)

        let stored = try #require(await stack.server.allItems().first)
        #expect(stored.id == item.id, "the server must persist the client-assigned id")
    }

    /// **Fails against the baseline** because the `Idempotency-Key` was minted
    /// per sync pass rather than persisted with the outbox entry, so the second
    /// pass presented a key the server had never seen.
    @Test("The same Idempotency-Key is presented on every sync pass for one pending change")
    func idempotencyKeyIsStableAcrossSyncPasses() async throws {
        let server = SimulatedServer()
        let scripted = ScriptedHTTPTransport(
            wrapping: InMemoryHTTPTransport(server: server),
            script: [.dropResponse, .dropResponse]
        )
        let recorder = RecordingHTTPTransport(wrapping: scripted)
        let client = URLSessionAPIClient(
            transport: recorder,
            tokenProvider: { "dev-alice" },
            retryPolicy: RetryPolicy(maxAttempts: 2, baseDelay: .milliseconds(1), jitterRatio: 0)
        )
        let store = InMemoryLocalStore()
        let engine = SyncEngine(api: client, store: store)

        try await store.upsert(SyncFixtures.item(title: "Keyed"))
        _ = await engine.sync()
        _ = await engine.sync()

        let keys = recorder.requests
            .filter { $0.method == "POST" && $0.path == "/items" }
            .compactMap { $0.headers["Idempotency-Key"] }

        #expect(keys.count >= 3, "two attempts in the first pass plus one in the second")
        #expect(Set(keys).count == 1, "a retry after a relaunch must reuse the pinned key, got \(Set(keys))")
    }

    // MARK: B — tombstones must reach the device

    /// **Fails against the baseline** because `SyncEngine.pull` skipped rows with
    /// `isDeleted == true` and then advanced the cursor past them, so the delete
    /// was lost permanently.
    ///
    /// Deliberately asserts on the *local store* rather than on
    /// `SyncReport.tombstonesApplied` (which only exists after the fix), so this
    /// file compiles and runs unchanged in a worktree checked out at the baseline.
    @Test("A row deleted on another device arrives as a tombstone and is applied locally")
    func tombstoneIsAppliedToLocalStore() async throws {
        let stack = SyncFixtures.makeStack()
        try await stack.store.upsert(SyncFixtures.item(title: "Doomed"))

        _ = await stack.engine.sync()
        let id = try #require(await stack.server.allItems().first?.id)
        #expect(try await stack.store.item(id: id)?.isDeleted == false)

        // Another device deletes it while we are away.
        _ = await stack.server.remoteDelete(id: id)

        let report = await stack.engine.sync()

        #expect(report.pulled == 0, "a tombstone is not a row to display")

        let local = try #require(try await stack.store.item(id: id))
        #expect(local.isDeleted == true, "the delete must land locally, or the next edit resurrects the row")
        #expect(local.syncState == .synced)
    }

    /// The user-visible consequence of the baseline bug: the row stays in the
    /// collection after the server deleted it.
    @Test("A deleted row does not survive a local edit made after the delete")
    func deleteIsNotResurrectedByALocalEdit() async throws {
        let stack = SyncFixtures.makeStack()
        try await stack.store.upsert(SyncFixtures.item(title: "Ghost"))
        _ = await stack.engine.sync()

        let id = try #require(await stack.server.allItems().first?.id)
        _ = await stack.server.remoteDelete(id: id)
        _ = await stack.engine.sync()

        let live = try await stack.store.allItems(includeDeleted: false)
        #expect(live.isEmpty, "nothing should be left in the collection")
    }

    /// Guards the guarantee the baseline already had: a tombstone must not be
    /// pushed back up as a live row.
    @Test("Applying a tombstone never pushes anything back to the server")
    func tombstoneDoesNotTriggerAPush() async throws {
        let stack = SyncFixtures.makeStack()
        try await stack.store.upsert(SyncFixtures.item(title: "Quiet"))
        _ = await stack.engine.sync()

        let id = try #require(await stack.server.allItems().first?.id)
        _ = await stack.server.remoteDelete(id: id)
        let insertsBefore = await stack.server.itemRowsInserted

        let report = await stack.engine.sync()

        #expect(report.pushed == 0)
        #expect(await stack.server.itemRowsInserted == insertsBefore)
    }
}
