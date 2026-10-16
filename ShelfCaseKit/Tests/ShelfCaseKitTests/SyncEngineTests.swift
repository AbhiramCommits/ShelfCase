import Foundation
import Testing
@testable import ShelfCaseKit

// MARK: - Deterministic transports used by the sync tests

/// Replays a fixed script of faults, then passes through. Lets a test say
/// exactly "the first attempt commits on the server and loses the reply".
final class ScriptedHTTPTransport: HTTPPerforming, @unchecked Sendable {
    enum Behavior {
        /// Forward the request and return the response normally.
        case pass
        /// Forward the request (the server *commits*), then throw as if the
        /// reply never arrived.
        case dropResponse
        /// Never reaches the server.
        case timeout
        /// Clean server-side failure, no side effect.
        case serverError(status: Int)
    }

    private let inner: HTTPPerforming
    private let lock = NSLock()
    private var script: [Behavior]
    private var fallback: Behavior
    /// When set, faults only apply to requests the filter accepts; everything
    /// else passes straight through without consuming the script.
    private let faultFilter: (@Sendable (HTTPRequest) -> Bool)?

    init(
        wrapping inner: HTTPPerforming,
        script: [Behavior],
        fallback: Behavior = .pass,
        faultFilter: (@Sendable (HTTPRequest) -> Bool)? = nil
    ) {
        self.inner = inner
        self.script = script
        self.fallback = fallback
        self.faultFilter = faultFilter
    }

    func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        if let faultFilter, !faultFilter(request) {
            return try await inner.perform(request)
        }

        lock.lock()
        let behavior = script.isEmpty ? fallback : script.removeFirst()
        lock.unlock()

        switch behavior {
        case .pass:
            return try await inner.perform(request)
        case .dropResponse:
            _ = try await inner.perform(request)
            throw APIClientError.transport("response lost after the server committed")
        case .timeout:
            throw APIClientError.timeout
        case .serverError(let status):
            throw APIClientError.http(status: status, body: "{\"error\":{\"code\":\"INJECTED\"}}")
        }
    }
}

/// Records every request that reaches it, in order.
final class RecordingHTTPTransport: HTTPPerforming, @unchecked Sendable {
    private let inner: HTTPPerforming
    private let lock = NSLock()
    private var recorded: [HTTPRequest] = []

    init(wrapping inner: HTTPPerforming) {
        self.inner = inner
    }

    var requests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func perform(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.lock()
        recorded.append(request)
        lock.unlock()
        return try await inner.perform(request)
    }
}

// MARK: - Fixtures

enum SyncFixtures {
    static func makeStack(
        createSemantics: CreateSemantics = .replayExistingRow,
        script: [ScriptedHTTPTransport.Behavior] = [],
        retryPolicy: RetryPolicy = .immediate,
        faultFilter: (@Sendable (HTTPRequest) -> Bool)? = nil
    ) -> (server: SimulatedServer, store: InMemoryLocalStore, engine: SyncEngine, transport: ScriptedHTTPTransport) {
        let server = SimulatedServer(options: .init(createSemantics: createSemantics))
        let scripted = ScriptedHTTPTransport(
            wrapping: InMemoryHTTPTransport(server: server),
            script: script,
            faultFilter: faultFilter
        )
        let client = URLSessionAPIClient(
            transport: scripted,
            tokenProvider: { "dev-alice" },
            retryPolicy: retryPolicy
        )
        let store = InMemoryLocalStore()
        let engine = SyncEngine(api: client, store: store)
        return (server, store, engine, scripted)
    }

    static func item(
        title: String,
        value: Int = 1_000,
        updatedAt: Date = Date(),
        state: SyncState = .pendingCreate,
        version: Int = 1
    ) -> CollectibleItem {
        CollectibleItem(
            title: title,
            setName: "Test Set",
            category: .card,
            conditionGrade: .nearMint,
            purchasePriceCents: value / 2,
            estimatedValueCents: value,
            updatedAt: updatedAt,
            version: version,
            syncState: state
        )
    }
}

// MARK: - Suite

@Suite("SyncEngine")
struct SyncEngineTests {

    // MARK: 1. Offline queue replays in order

    @Test("an offline queue replays in updatedAt order once the link returns")
    func offlineQueueReplaysInOrder() async throws {
        let server = SimulatedServer()
        let recorder = RecordingHTTPTransport(wrapping: InMemoryHTTPTransport(server: server))
        let client = URLSessionAPIClient(
            transport: recorder,
            tokenProvider: { "dev-alice" },
            retryPolicy: .immediate
        )
        let store = InMemoryLocalStore()
        let engine = SyncEngine(api: client, store: store)

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // Deliberately inserted out of order.
        let third = SyncFixtures.item(title: "Third", updatedAt: base.addingTimeInterval(30))
        let first = SyncFixtures.item(title: "First", updatedAt: base.addingTimeInterval(10))
        let second = SyncFixtures.item(title: "Second", updatedAt: base.addingTimeInterval(20))
        for item in [third, first, second] {
            try await store.upsert(item)
        }

        let pendingBefore = try await store.fetchPending()
        #expect(pendingBefore.map(\.title) == ["First", "Second", "Third"])

        let report = await engine.sync()

        #expect(report.pushed == 3)
        #expect(report.errors == 0)
        #expect(await store.pendingCount() == 0)
        #expect(await server.itemCount() == 3)

        let payloadTitles = recorder.requests
            .filter { $0.method == "POST" && $0.path == "/items" }
            .compactMap { request -> String? in
                guard let body = request.body,
                    let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
                else { return nil }
                return object["title"] as? String
            }
        #expect(payloadTitles == ["First", "Second", "Third"], "the outbox must replay oldest-first")
    }

    // MARK: 2. Dropped response + retry

    @Test("a dropped response is retried with the same Idempotency-Key and creates exactly one item")
    func droppedResponseDoesNotDuplicate() async throws {
        // Attempt 1 commits on the server and loses the reply; attempt 2 succeeds.
        let stack = SyncFixtures.makeStack(script: [.dropResponse, .pass])
        let item = SyncFixtures.item(title: "Lost Reply")
        try await stack.store.upsert(item)

        let report = await stack.engine.sync()

        #expect(report.pushed == 1)
        #expect(report.errors == 0)
        #expect(report.retries == 1)
        #expect(await stack.server.itemCount() == 1, "the retry must not create a second row")
        #expect(await stack.server.itemRowsInserted == 1)
        #expect(await stack.store.itemCount() == 1)
        #expect(await stack.store.pendingCount() == 0)
    }

    @Test("retries reuse one Idempotency-Key, and GETs never carry one")
    func idempotencyKeyIsStableAcrossRetries() async throws {
        let server = SimulatedServer()
        // The recorder sits *outside* the fault injector so it sees every attempt.
        let scripted = ScriptedHTTPTransport(
            wrapping: InMemoryHTTPTransport(server: server),
            script: [.serverError(status: 503), .serverError(status: 503), .pass]
        )
        let recorder = RecordingHTTPTransport(wrapping: scripted)
        let client = URLSessionAPIClient(
            transport: recorder,
            tokenProvider: { "dev-alice" },
            retryPolicy: .immediate
        )
        let store = InMemoryLocalStore()
        let engine = SyncEngine(api: client, store: store)
        try await store.upsert(SyncFixtures.item(title: "Retry Key"))

        _ = await engine.sync()

        let keys = recorder.requests
            .filter { $0.method == "POST" }
            .compactMap { $0.headers["Idempotency-Key"] }
        #expect(keys.count == 3, "one request plus two retries")
        #expect(Set(keys).count == 1, "every attempt must reuse the same key")

        let getKeys = recorder.requests
            .filter { $0.method == "GET" }
            .compactMap { $0.headers["Idempotency-Key"] }
        #expect(getKeys.isEmpty)
    }

    // MARK: 3. Conflict resolution

    @Test("a concurrent edit yields exactly one conflict, resolved by the documented policy")
    func concurrentEditYieldsOneConflictResolved() async throws {
        let stack = SyncFixtures.makeStack()

        // Establish a synced row.
        var item = SyncFixtures.item(title: "Contested Card", value: 10_000)
        try await stack.store.upsert(item)
        _ = await stack.engine.sync()
        let serverId = try #require(await stack.server.allItems().first?.id)
        item = try #require(await stack.store.item(id: serverId))

        // Another device changes the *server-authoritative* field and bumps the version.
        _ = await stack.server.remoteUpdate(id: serverId, notes: "server note", estimatedValueCents: 42_000)

        // We edit the user-authored field locally, strictly later in time.
        let localEdit = Date(timeIntervalSinceNow: 60)
        item.notes = "my note"
        item.conditionGrade = .mint
        item.updatedAt = localEdit
        item.syncState = .pendingUpdate
        try await stack.store.upsert(item)

        let first = await stack.engine.sync()
        #expect(first.conflicts == 1)
        #expect(first.conflictsAutoResolved == 1)

        let archive = try await stack.store.conflictArchive()
        #expect(archive.count == 1)
        let record = try #require(archive.first)
        #expect(record.policy == "client-newer:user-authored-fields")

        // Client wins the user-authored fields…
        #expect(record.merged.notes == "my note")
        #expect(record.merged.conditionGrade == .mint)
        // …and the server keeps ownership and price.
        #expect(record.merged.estimatedValueCents == 42_000)
        // The loser is preserved.
        #expect(record.server.estimatedValueCents == 42_000)
        #expect(record.local.notes == "my note")

        // The merged copy is queued back up, and the next pass applies it with no new conflict.
        let second = await stack.engine.sync()
        #expect(second.conflicts == 0)
        let archiveAfter = try await stack.store.conflictArchive()
        #expect(archiveAfter.count == 1, "exactly one conflict, not one per pass")
        #expect(await stack.store.pendingCount() == 0)
    }

    @Test("a server-newer edit wins the whole record (last-writer-wins)")
    func serverNewerEditWinsWholeRecord() async throws {
        let stack = SyncFixtures.makeStack()
        var item = SyncFixtures.item(title: "LWW Card")
        try await stack.store.upsert(item)
        _ = await stack.engine.sync()
        let serverId = try #require(await stack.server.allItems().first?.id)
        item = try #require(await stack.store.item(id: serverId))

        // Server edit that is *later* than ours.
        _ = await stack.server.remoteUpdate(id: serverId, notes: "server wins")

        item.notes = "stale local note"
        item.updatedAt = Date(timeIntervalSinceNow: -600)
        item.syncState = .pendingUpdate
        try await stack.store.upsert(item)

        _ = await stack.engine.sync()

        let record = try #require(try await stack.store.conflictArchive().first)
        #expect(record.policy == "server-newer:last-writer-wins")
        #expect(record.merged.notes == "server wins")
    }

    // MARK: 4. Cursor

    @Test("the delta cursor advances monotonically and never rewinds")
    func cursorAdvancesMonotonically() async throws {
        let stack = SyncFixtures.makeStack()

        try await stack.store.upsert(SyncFixtures.item(title: "One"))
        let first = await stack.engine.sync()
        let cursor1 = try #require(first.cursor)

        let idle = await stack.engine.sync()
        let cursor2 = try #require(idle.cursor)
        #expect(SyncEngine.sequence(of: cursor2)! >= SyncEngine.sequence(of: cursor1)!)

        try await stack.store.upsert(SyncFixtures.item(title: "Two"))
        let third = await stack.engine.sync()
        let cursor3 = try #require(third.cursor)
        #expect(SyncEngine.sequence(of: cursor3)! > SyncEngine.sequence(of: cursor1)!)

        // A second pull with the stored cursor returns nothing new.
        let repeatPass = await stack.engine.sync()
        #expect(repeatPass.pulled == 0)
        #expect(SyncEngine.sequence(of: try #require(repeatPass.cursor))! == SyncEngine.sequence(of: cursor3)!)
    }

    @Test("the cursor is persisted so a fresh engine resumes where the last one stopped")
    func cursorSurvivesRestart() async throws {
        let server = SimulatedServer()
        let store = InMemoryLocalStore()
        let makeEngine = {
            SyncEngine(
                api: URLSessionAPIClient(
                    transport: InMemoryHTTPTransport(server: server),
                    tokenProvider: { "dev-alice" },
                    retryPolicy: .immediate
                ),
                store: store
            )
        }

        try await store.upsert(SyncFixtures.item(title: "Restart"))
        let engineA = makeEngine()
        _ = await engineA.sync()
        let stored = try #require(try await store.cursor())
        #expect(SyncEngine.sequence(of: stored)! > 0)

        let engineB = makeEngine()
        let report = await engineB.sync()
        #expect(report.pulled == 0, "nothing changed while we were 'closed'")
    }

    // MARK: 5. Batch

    @Test("a 200-change batch syncs completely and reports correct counts")
    func twoHundredChangeBatch() async throws {
        let stack = SyncFixtures.makeStack()
        let count = 200

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<count {
            try await stack.store.upsert(
                SyncFixtures.item(
                    title: "Batch \(index)", value: 1_000 + index, updatedAt: base.addingTimeInterval(Double(index)))
            )
        }
        #expect(await stack.store.pendingCount() == count)

        let report = await stack.engine.sync()

        #expect(report.pushed == count)
        #expect(report.errors == 0)
        #expect(await stack.store.pendingCount() == 0)
        #expect(await stack.server.itemCount() == count)
        #expect(await stack.server.itemRowsInserted == count)
        #expect(report.pulled == count, "the same rows come back on the delta pull")

        // And a follow-up pass is a no-op.
        let idle = await stack.engine.sync()
        #expect(idle.pushed == 0)
        #expect(idle.pulled == 0)
    }

    @Test("pagination drains a delta larger than one page")
    func paginatedPullDrains() async throws {
        let server = SimulatedServer()
        let store = InMemoryLocalStore()
        let engine = SyncEngine(
            api: URLSessionAPIClient(
                transport: InMemoryHTTPTransport(server: server),
                tokenProvider: { "dev-alice" },
                retryPolicy: .immediate
            ),
            store: store,
            configuration: .tinyPages
        )

        for index in 0..<7 {
            try await store.upsert(SyncFixtures.item(title: "Paged \(index)"))
        }
        let report = await engine.sync()
        #expect(report.pushed == 7)
        #expect(report.pulled == 7)
        #expect(await store.itemCount() == 7)
    }

    // MARK: Errors

    @Test("a permanent server failure is reported as an error and leaves the item pending")
    func permanentFailureStaysPending() async throws {
        // Faults are scoped to the write path so the pull still succeeds and the
        // error/retry accounting is unambiguous.
        let stack = SyncFixtures.makeStack(
            script: Array(repeating: .serverError(status: 503), count: 32),
            retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(1), jitterRatio: 0),
            faultFilter: { $0.method == "POST" }
        )
        try await stack.store.upsert(SyncFixtures.item(title: "Doomed"))

        let report = await stack.engine.sync()

        #expect(report.pushed == 0)
        #expect(report.errors == 1, "one failed push, and the pull still ran")
        #expect(report.retries == 2, "maxAttempts 3 => two retries, all on the POST")
        #expect(await stack.store.pendingCount() == 1, "the outbox keeps the change for the next pass")
    }

    @Test("updates and deletes round-trip through the engine")
    func updateAndDeleteRoundTrip() async throws {
        let stack = SyncFixtures.makeStack()
        try await stack.store.upsert(SyncFixtures.item(title: "Lifecycle"))
        _ = await stack.engine.sync()

        let id = try #require(await stack.server.allItems().first?.id)
        var item = try #require(await stack.store.item(id: id))
        let originalVersion = item.version

        item.notes = "updated"
        item.version = originalVersion
        item.updatedAt = Date(timeIntervalSinceNow: 1)
        item.syncState = .pendingUpdate
        try await stack.store.upsert(item)

        let updateReport = await stack.engine.sync()
        #expect(updateReport.pushed == 1)
        #expect(await stack.server.item(id: id)?.notes == "updated")

        var afterUpdate = try #require(await stack.store.item(id: id))
        #expect(afterUpdate.version > originalVersion)

        afterUpdate.syncState = .pendingDelete
        try await stack.store.upsert(afterUpdate)

        let deleteReport = await stack.engine.sync()
        #expect(deleteReport.pushed == 1)
        #expect(await stack.server.item(id: id)?.isDeleted == true)
        #expect(await stack.store.pendingCount() == 0)
    }
}

// MARK: - API client suite

@Suite("URLSessionAPIClient")
struct URLSessionAPIClientTests {

    @Test("retries a 5xx with backoff and eventually succeeds")
    func retriesServerErrors() async throws {
        let server = SimulatedServer()
        let scripted = ScriptedHTTPTransport(
            wrapping: InMemoryHTTPTransport(server: server),
            script: [.serverError(status: 500), .serverError(status: 502), .pass]
        )
        let client = URLSessionAPIClient(
            transport: scripted,
            tokenProvider: { "dev-alice" },
            retryPolicy: .immediate
        )

        let response = try await client.createItem(SyncFixtures.item(title: "Eventually"), idempotencyKey: "k")
        #expect(response.item.title == "Eventually")
        #expect(client.metrics.requestsSent == 3)
        #expect(client.metrics.retries == 2)
    }

    @Test("gives up after maxAttempts and surfaces the last typed error")
    func givesUpAfterMaxAttempts() async throws {
        let server = SimulatedServer()
        let scripted = ScriptedHTTPTransport(
            wrapping: InMemoryHTTPTransport(server: server),
            script: Array(repeating: .serverError(status: 503), count: 10)
        )
        let client = URLSessionAPIClient(
            transport: scripted,
            tokenProvider: { "dev-alice" },
            retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(1), jitterRatio: 0)
        )

        await #expect(throws: APIClientError.http(status: 503, body: "{\"error\":{\"code\":\"INJECTED\"}}")) {
            _ = try await client.createItem(SyncFixtures.item(title: "Never"), idempotencyKey: "k")
        }
        #expect(client.metrics.requestsSent == 3)
        #expect(client.metrics.retries == 2)
    }

    @Test("maps a 409 into .conflict carrying the server copy")
    func mapsConflict() async throws {
        let stack = SyncFixtures.makeStack()
        _ = stack

        let server = SimulatedServer()
        let item = SyncFixtures.item(title: "Conflicted")
        let client = URLSessionAPIClient(
            transport: InMemoryHTTPTransport(server: server),
            tokenProvider: { "dev-alice" },
            retryPolicy: .immediate
        )
        let created = try await client.createItem(item, idempotencyKey: "create")
        let serverId = created.item.id

        _ = await server.remoteUpdate(id: serverId, notes: "moved on")

        var stale = item
        stale.id = serverId
        stale.notes = "stale"
        stale.version = 1

        do {
            _ = try await client.updateItem(stale, idempotencyKey: "update")
            Issue.record("expected a conflict")
        } catch let error as APIClientError {
            guard case .conflict(let serverItem) = error else {
                Issue.record("expected .conflict, got \(error)")
                return
            }
            #expect(serverItem.notes == "moved on")
            #expect(serverItem.version == 2)
        }
        #expect(client.metrics.conflicts == 1)
    }

    @Test("a 409 is not retried")
    func conflictIsNotRetried() async throws {
        let server = SimulatedServer()
        let client = URLSessionAPIClient(
            transport: InMemoryHTTPTransport(server: server),
            tokenProvider: { "dev-alice" },
            retryPolicy: .immediate
        )
        let created = try await client.createItem(SyncFixtures.item(title: "Once"), idempotencyKey: "a")

        // Another writer moves the row on; our base version is now stale.
        _ = await server.remoteUpdate(id: created.item.id, notes: "moved on")

        var stale = created.item
        stale.notes = "stale"
        stale.version = 1

        do {
            _ = try await client.updateItem(stale, idempotencyKey: "b")
            Issue.record("expected a conflict")
        } catch let error as APIClientError {
            guard case .conflict = error else {
                Issue.record("expected .conflict, got \(error)")
                return
            }
        }
        #expect(client.metrics.requestsSent == 2)
        #expect(client.metrics.retries == 0, "a 409 is a decision, not a transient failure")
    }

    @Test("maps timeouts and transport failures to retryable typed errors")
    func mapsTransportAndTimeout() async throws {
        let server = SimulatedServer()
        let scripted = ScriptedHTTPTransport(
            wrapping: InMemoryHTTPTransport(server: server),
            script: [.timeout, .timeout, .timeout, .timeout]
        )
        let client = URLSessionAPIClient(
            transport: scripted,
            tokenProvider: { "dev-alice" },
            retryPolicy: RetryPolicy(maxAttempts: 4, baseDelay: .milliseconds(1), jitterRatio: 0)
        )

        do {
            _ = try await client.pull(since: nil)
            Issue.record("expected a timeout")
        } catch let error as APIClientError {
            #expect(error == .timeout)
            #expect(error.isRetryable)
        }
        #expect(client.metrics.retries == 3)
    }

    @Test("maps an unauthorised response and does not retry it")
    func mapsUnauthorized() async throws {
        let unauthorised = StaticTransport(
            response: HTTPResponse(statusCode: 401, body: Data(#"{"error":{"code":"UNAUTHORIZED"}}"#.utf8))
        )
        let client = URLSessionAPIClient(
            transport: unauthorised,
            tokenProvider: { nil },
            retryPolicy: .immediate
        )

        do {
            _ = try await client.pull(since: nil)
            Issue.record("expected unauthorized")
        } catch let error as APIClientError {
            #expect(error == .unauthorized)
            #expect(!error.isRetryable)
        }
        #expect(client.metrics.retries == 0)
    }

    @Test("maps malformed JSON to .decoding")
    func mapsDecodingFailure() async throws {
        let broken = StaticTransport(response: HTTPResponse(statusCode: 200, body: Data("not json".utf8)))
        let client = URLSessionAPIClient(
            transport: broken,
            tokenProvider: { "dev-alice" },
            retryPolicy: .immediate
        )

        do {
            _ = try await client.pull(since: nil)
            Issue.record("expected a decoding failure")
        } catch let error as APIClientError {
            guard case .decoding = error else {
                Issue.record("expected .decoding, got \(error)")
                return
            }
        }
        #expect(client.metrics.decodeFailures == 1)
    }

    @Test("error classification drives the retry decision")
    func errorClassification() {
        #expect(APIClientError.transport("x").isRetryable)
        #expect(APIClientError.timeout.isRetryable)
        #expect(APIClientError.http(status: 500, body: nil).isRetryable)
        #expect(APIClientError.http(status: 429, body: nil).isRetryable)
        #expect(APIClientError.http(status: 408, body: nil).isRetryable)
        #expect(!APIClientError.http(status: 404, body: nil).isRetryable)
        #expect(!APIClientError.http(status: 422, body: nil).isRetryable)
        #expect(!APIClientError.unauthorized.isRetryable)
        #expect(!APIClientError.decoding("x").isRetryable)
    }

    @Test("backoff grows exponentially and is capped")
    func backoffShape() {
        let policy = RetryPolicy(
            maxAttempts: 8, baseDelay: .milliseconds(100), maxDelay: .milliseconds(800), jitterRatio: 0)
        var generator = SeededGenerator(seed: 1)
        #expect(policy.delay(forAttempt: 1, using: &generator) == .milliseconds(100))
        #expect(policy.delay(forAttempt: 2, using: &generator) == .milliseconds(200))
        #expect(policy.delay(forAttempt: 3, using: &generator) == .milliseconds(400))
        #expect(policy.delay(forAttempt: 4, using: &generator) == .milliseconds(800))
        #expect(policy.delay(forAttempt: 5, using: &generator) == .milliseconds(800), "capped")
    }

    @Test("jitter keeps the delay inside the expected band")
    func backoffJitterBand() {
        let policy = RetryPolicy(
            maxAttempts: 8, baseDelay: .milliseconds(1000), maxDelay: .seconds(1), jitterRatio: 0.5)
        var generator = SeededGenerator(seed: 42)
        for _ in 0..<200 {
            let delay = policy.delay(forAttempt: 1, using: &generator)
            let milliseconds = SyncEngine.milliseconds(delay)
            #expect(milliseconds >= 750 && milliseconds <= 1250, "got \(milliseconds) ms")
        }
    }

    @Test("a shorter retry budget means fewer attempts")
    func cappedAttempts() async throws {
        let server = SimulatedServer()
        let scripted = ScriptedHTTPTransport(
            wrapping: InMemoryHTTPTransport(server: server),
            script: Array(repeating: .serverError(status: 500), count: 20)
        )
        let client = URLSessionAPIClient(
            transport: scripted,
            tokenProvider: { "dev-alice" },
            retryPolicy: RetryPolicy(maxAttempts: 1, baseDelay: .milliseconds(1), jitterRatio: 0)
        )
        do {
            _ = try await client.pull(since: nil)
        } catch {
            // expected
        }
        #expect(client.metrics.requestsSent == 1)
        #expect(client.metrics.retries == 0)
    }
}

/// Always returns the same canned response.
struct StaticTransport: HTTPPerforming {
    let response: HTTPResponse
    func perform(_ request: HTTPRequest) async throws -> HTTPResponse { response }
}

/// Reproducible `RandomNumberGenerator` for backoff assertions.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }
}
