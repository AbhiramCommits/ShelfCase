import Foundation
import ShelfCaseKit

// MARK: - Argument parsing

struct Options {
    var scenario = "soak"
    var cycles = 200
    var runs = 100
    var seed: UInt64 = 20_261_016
    var trace = false
    var verbose = false
    /// Server-side create behaviour. `replay` is the fixed Express route,
    /// `reject` is the pre-fix route (raw unique-violation 500).
    var createSemantics: CreateSemantics = .replayExistingRow

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value() -> String? {
                index += 1
                return index < arguments.count ? arguments[index] : nil
            }
            switch argument {
            case "--scenario": options.scenario = value() ?? options.scenario
            case "--cycles": options.cycles = Int(value() ?? "") ?? options.cycles
            case "--runs": options.runs = Int(value() ?? "") ?? options.runs
            case "--seed": options.seed = UInt64(value() ?? "") ?? options.seed
            case "--create-semantics":
                options.createSemantics = (value() == "reject") ? .rejectDuplicateId : .replayExistingRow
            case "--trace": options.trace = true
            case "--verbose": options.verbose = true
            case "--help", "-h":
                print(Options.usage)
                exit(0)
            default:
                FileHandle.standardError.write("unknown argument: \(argument)\n".data(using: .utf8)!)
                exit(2)
            }
            index += 1
        }
        return options
    }

    static let usage = """
    ShelfCaseSyncSoak — reproducible offline-first sync harness

    USAGE:
      ShelfCaseSyncSoak --scenario <soak|duplicates|tombstones> [options]

    OPTIONS:
      --cycles N              soak cycles (default 200)
      --runs N                repetitions for duplicates/tombstones (default 100)
      --seed S                master seed; each run is offset by its index (default 20261016)
      --create-semantics X    reject | replay   (server-side POST /items behaviour)
      --trace                 print the instrumented trace (real log lines)
      --verbose               print per-cycle narration

    SCENARIOS:
      duplicates   "one offline create, reply lost, app retried later".
                   Reports runs that ended with more server rows than local rows.
      tombstones   "row deleted on another device, client comes back online".
                   Reports deletes that never reached the client.
      soak         Randomised offline/online cycles against the real sync engine,
                   then a drain, then divergence + sync latency percentiles.
    """
}

// MARK: - Deterministic RNG

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9e37_79b9_7f4a_7c15 : seed }

    mutating func next() -> UInt64 {
        state = state &+ 0x9e37_79b9_7f4a_7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58_476d_1ce4_e5b9
        z = (z ^ (z >> 27)) &* 0x94d0_49bb_1331_11eb
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(unit() * Double(range.count)) % range.count
    }
}

// MARK: - Stack

/// The app's dependency graph minus the UI: a simulated server behind a
/// fault-injecting transport behind the production `URLSessionAPIClient`.
final class Stack {
    let server: SimulatedServer
    let store: InMemoryLocalStore
    let engine: SyncEngine
    let transport: FaultInjectingAPIClient
    let client: URLSessionAPIClient

    init(
        options: SimulatedServer.Options = .init(),
        profile: FaultProfile = .reliable,
        retryPolicy: RetryPolicy = .immediate,
        trace: TraceSink? = nil
    ) {
        let server = SimulatedServer(options: options)
        let transport = FaultInjectingAPIClient(wrapping: InMemoryHTTPTransport(server: server), profile: profile)
        let client = URLSessionAPIClient(
            transport: transport,
            tokenProvider: { "dev-alice" },
            retryPolicy: retryPolicy,
            trace: trace
        )
        let store = InMemoryLocalStore()

        self.server = server
        self.store = store
        self.client = client
        self.transport = transport
        self.engine = SyncEngine(api: client, store: store, trace: trace)
    }

    func localItem(title: String, value: Int = 1_000) -> CollectibleItem {
        CollectibleItem(
            title: title,
            setName: "Soak",
            category: .card,
            conditionGrade: .nearMint,
            purchasePriceCents: value / 2,
            estimatedValueCents: value,
            updatedAt: Date(),
            version: 1,
            syncState: .pendingCreate
        )
    }

    /// Run sync passes until the outbox drains or the budget is spent.
    func drain(maxPasses: Int = 6) async -> Int {
        var passes = 0
        while passes < maxPasses {
            _ = await engine.sync()
            passes += 1
            if await store.pendingCount() == 0 { break }
        }
        return passes
    }
}

// MARK: - Scenario A: duplicate creation after a lost response

func scenarioDuplicates(options: Options) async -> String {
    var runsWithExtraServerRows = 0
    var runsWithExtraLocalRows = 0
    var lostRuns = 0
    var totalServerRows = 0
    var totalLocalRows = 0
    var totalDrops = 0
    var totalRejections = 0
    var worstRun = ""

    // Two attempts per pass models iOS suspending the app mid-sync: the retry
    // loop rarely gets many shots before the process is frozen.
    let retryPolicy = RetryPolicy(maxAttempts: 2, baseDelay: .milliseconds(1), jitterRatio: 0)

    for run in 0..<options.runs {
        // Offset the fault seed per run so each run sees an independent — but
        // fully reproducible — fault sequence.
        let profile = FaultProfile(
            seed: options.seed &+ UInt64(run) &* 0x9e37_79b9,
            timeoutRate: 0.10,
            dropResponseRate: 0.60,
            serverErrorRate: 0.05
        )
        let stack = Stack(
            options: .init(createSemantics: options.createSemantics),
            profile: profile,
            retryPolicy: retryPolicy,
            trace: globalTrace
        )
        let item = stack.localItem(title: "Card \(run)", value: 10_000 + run)
        try? await stack.store.upsert(item)

        // One card is created. Pass 1 may lose the reply; the following passes
        // are the app's retries.
        _ = await stack.drain(maxPasses: 6)

        let serverCount = await stack.server.itemCount()
        let localCount = await stack.store.itemCount()
        let metrics = await stack.transport.metrics

        totalServerRows += serverCount
        totalLocalRows += localCount
        totalDrops += metrics.droppedResponsesInjected
        totalRejections += await stack.server.duplicateIdRejections

        if serverCount == 0 && localCount == 1 {
            lostRuns += 1
            continue
        }

        // The user created ONE card. Anything above one row is a duplicate —
        // whether the orphan surfaced on the server, in the local store, or both
        // (the delta pull brings the orphaned server row back down).
        if serverCount > 1 { runsWithExtraServerRows += 1 }
        if localCount > 1 { runsWithExtraLocalRows += 1 }
        if serverCount > 1, worstRun.isEmpty {
            worstRun = "run \(run): server=\(serverCount) local=\(localCount)"
        }

        if options.verbose {
            print("  run \(run): server=\(serverCount) local=\(localCount) drops=\(metrics.droppedResponsesInjected)")
        }
    }

    let expected = options.runs - lostRuns
    return """
    scenario: duplicates
    runs: \(options.runs)  (each creates exactly ONE card while offline)
    link: dropResponseRate=0.60 timeoutRate=0.10 serverErrorRate=0.05, maxAttempts=2 (seed \(options.seed), per-run offset)
    server create semantics: \(options.createSemantics.rawValue)
    dropped responses injected: \(totalDrops)
    duplicate-id rejections (HTTP 500): \(totalRejections)
    runs where the create was never confirmed: \(lostRuns)
    runs ending with MORE THAN ONE server row: \(runsWithExtraServerRows) / \(options.runs)  [\(percent(runsWithExtraServerRows, options.runs))]
    runs ending with MORE THAN ONE local row:  \(runsWithExtraLocalRows) / \(options.runs)  [\(percent(runsWithExtraLocalRows, options.runs))]
    server rows: \(totalServerRows)   local rows: \(totalLocalRows)   (both should be \(expected))
    \(worstRun.isEmpty ? "" : "first duplicate: \(worstRun)")
    """
}

// MARK: - Scenario B: tombstones lost on the delta pull

func scenarioTombstones(options: Options) async -> String {
    let perRun = 4
    var lostDeletes = 0
    var totalDeletes = 0
    var runsWithLoss = 0
    var totalResurrected = 0

    for run in 0..<options.runs {
        let stack = Stack(trace: globalTrace)
        var created: [UUID] = []

        for index in 0..<perRun {
            let item = stack.localItem(title: "Run \(run) Item \(index)")
            created.append(item.id)
            try? await stack.store.upsert(item)
        }
        _ = await stack.engine.sync()

        // Another device deletes half of them while we are offline.
        let victims = created.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
        for victim in victims {
            _ = await stack.server.remoteDelete(id: victim)
        }
        totalDeletes += victims.count

        // We come back online.
        _ = await stack.engine.sync()

        var lostThisRun = 0
        for victim in victims {
            let local = try? await stack.store.item(id: victim)
            if local?.isDeleted != true {
                lostThisRun += 1
                // A "resurrected" row is one the client still believes is live
                // and will therefore push back up on the next local edit.
                totalResurrected += 1
            }
        }
        lostDeletes += lostThisRun
        if lostThisRun > 0 { runsWithLoss += 1 }

        if options.verbose, lostThisRun > 0 {
            print("  run \(run): \(lostThisRun)/\(victims.count) deletes never applied locally")
        }
    }

    return """
    scenario: tombstones
    runs: \(options.runs), \(perRun) local items each (half deleted server-side)
    deletes performed on the server: \(totalDeletes)
    deletes that never reached the client: \(lostDeletes)  [\(percent(lostDeletes, totalDeletes))]
    runs affected: \(runsWithLoss) / \(options.runs)
    rows still believed live locally (resurrection risk): \(totalResurrected)
    """
}

// MARK: - Scenario C: randomised offline/online soak

func scenarioSoak(options: Options) async -> String {
    var random = SplitMix64(seed: options.seed)
    let stack = Stack(trace: globalTrace)
    var durations: [Int] = []
    var totalPushed = 0
    var totalPulled = 0
    var totalConflicts = 0
    var totalRetries = 0
    var totalErrors = 0
    var totalTombstones = 0
    var offlineCycles = 0

    var localCreates = 0
    var localEdits = 0
    var remoteEdits = 0
    var remoteDeletes = 0
    var localDeletes = 0
    var concurrentEdits = 0

    for cycle in 0..<options.cycles {
        let roll = random.unit()
        let profile: FaultProfile
        if roll < 0.35 {
            profile = .reliable
        } else if roll < 0.80 {
            profile = .flakyConventionHall
            offlineCycles += 1
        } else {
            profile = .basement
            offlineCycles += 1
        }
        await stack.transport.configure(profile)

        // Ids come from the store, not a side array: a create that the server
        // confirmed may have been re-keyed to the server's identity.
        let known = ((try? await stack.store.allItems()) ?? []).map(\.id)

        switch random.int(0...11) {
        case 0, 1, 2:
            let item = stack.localItem(title: "Cycle \(cycle) Card", value: random.int(500...90_000))
            try? await stack.store.upsert(item)
            localCreates += 1
            if options.verbose { print("  cycle \(cycle): local create") }

        case 3, 4, 5:
            // Concurrent edit: another device changes the row *and* we change it
            // before the next sync, so the push arrives with a stale base version
            // and the engine has to resolve a conflict.
            if !known.isEmpty, let id = known.randomElement(using: &random),
               await stack.server.item(id: id) != nil {
                _ = await stack.server.remoteUpdate(id: id, notes: "remote edit in cycle \(cycle)")
                remoteEdits += 1

                if var existing = try? await stack.store.item(id: id) {
                    existing.notes = "my edit in cycle \(cycle)"
                    existing.updatedAt = Date(timeIntervalSinceNow: 5)
                    existing.syncState = .pendingUpdate
                    try? await stack.store.upsert(existing)
                    concurrentEdits += 1
                    if options.verbose { print("  cycle \(cycle): concurrent edit on \(id)") }
                }
            }

        case 11:
            if !known.isEmpty, let id = known.randomElement(using: &random) {
                if var existing = try? await stack.store.item(id: id) {
                    existing.notes = "edited in cycle \(cycle)"
                    existing.conditionGrade = [ConditionGrade.mint, .good, .excellent, .poor].randomElement(using: &random)!
                    existing.updatedAt = Date()
                    existing.syncState = .pendingUpdate
                    try? await stack.store.upsert(existing)
                    localEdits += 1
                    if options.verbose { print("  cycle \(cycle): local edit") }
                }
            }

        case 6, 7, 8:
            if !known.isEmpty, let id = known.randomElement(using: &random) {
                if await stack.server.item(id: id) != nil {
                    _ = await stack.server.remoteUpdate(id: id, notes: "remote edit in cycle \(cycle)")
                    remoteEdits += 1
                    if options.verbose { print("  cycle \(cycle): remote edit") }
                }
            }

        case 9:
            if !known.isEmpty, let id = known.randomElement(using: &random) {
                if var existing = try? await stack.store.item(id: id) {
                    existing.isDeleted = true
                    existing.updatedAt = Date()
                    existing.syncState = .pendingDelete
                    try? await stack.store.upsert(existing)
                    localDeletes += 1
                    if options.verbose { print("  cycle \(cycle): local delete") }
                }
            }

        default:
            if !known.isEmpty, let id = known.randomElement(using: &random) {
                // Only delete rows that are still live, the way a real "delete
                // from another device" would.
                if let remote = await stack.server.item(id: id), !remote.isDeleted {
                    _ = await stack.server.remoteDelete(id: id)
                    remoteDeletes += 1
                    if options.verbose { print("  cycle \(cycle): remote delete") }
                }
            }
        }

        let report = await stack.engine.sync()
        durations.append(report.durationMs)
        totalPushed += report.pushed
        totalPulled += report.pulled
        totalConflicts += report.conflicts
        totalRetries += report.retries
        totalErrors += report.errors
        totalTombstones += report.tombstonesApplied
    }

    // Drain: reconnect to a perfect link and let the engine converge.
    await stack.transport.configure(.reliable)
    var drainPasses = 0
    while drainPasses < 40 {
        let report = await stack.engine.sync()
        durations.append(report.durationMs)
        totalPushed += report.pushed
        totalPulled += report.pulled
        totalConflicts += report.conflicts
        totalRetries += report.retries
        totalErrors += report.errors
        totalTombstones += report.tombstonesApplied
        drainPasses += 1
        if await stack.store.pendingCount() == 0 { break }
    }

    let localLive = await stack.store.itemCount(includeDeleted: false)
    let localTotal = await stack.store.itemCount(includeDeleted: true)
    let serverLive = await stack.server.itemCount(includeDeleted: false)
    let serverTotal = await stack.server.itemCount(includeDeleted: true)
    let localChecksum = await stack.store.checksum()
    let serverChecksum = await stack.server.checksum()
    let metrics = await stack.transport.metrics
    let conflicts = (try? await stack.store.conflictArchive()) ?? []

    // User-visible symptom of a lost tombstone: the server says the row is gone,
    // the device still shows it in the collection.
    var ghostRows = 0
    for serverItem in await stack.server.allItems(includeDeleted: true) where serverItem.isDeleted {
        if let local = try? await stack.store.item(id: serverItem.id), local.isDeleted == false {
            ghostRows += 1
        }
    }

    durations.sort()
    let p50 = percentile(durations, 0.50)
    let p95 = percentile(durations, 0.95)

    return """
    scenario: soak
    cycles: \(options.cycles) (seed \(options.seed)); flaky/offline cycles: \(offlineCycles)
    mutations: \(localCreates) local creates, \(localEdits) local edits, \(concurrentEdits) concurrent edits, \(localDeletes) local deletes, \(remoteEdits) remote edits, \(remoteDeletes) remote deletes
    drain passes: \(drainPasses)
    pushed: \(totalPushed)  pulled: \(totalPulled)  tombstones: \(totalTombstones)  conflicts: \(totalConflicts)  retries: \(totalRetries)  errors: \(totalErrors)
    conflict archive entries: \(conflicts.count)
    injected: \(metrics.droppedResponsesInjected) dropped responses, \(metrics.timeoutsInjected) timeouts, \(metrics.serverErrorsInjected) 5xx
    sync duration p50: \(p50) ms   p95: \(p95) ms   (n=\(durations.count))
    live items   — local: \(localLive)   server: \(serverLive)
    total rows   — local: \(localTotal)  server: \(serverTotal)
    local checksum:  \(localChecksum)
    server checksum: \(serverChecksum)
    ghost rows (deleted on the server, still live locally): \(ghostRows)
    divergence: live items \(serverLive - localLive >= 0 ? "+" : "")\(serverLive - localLive) (server − local), checksum \(localChecksum == serverChecksum ? "MATCH" : "MISMATCH")
    """
}

// MARK: - Helpers

func percent(_ numerator: Int, _ denominator: Int) -> String {
    guard denominator > 0 else { return "n/a" }
    return String(format: "%.1f%%", Double(numerator) / Double(denominator) * 100)
}

func percentile(_ sorted: [Int], _ fraction: Double) -> Int {
    guard !sorted.isEmpty else { return 0 }
    let index = Int((Double(sorted.count - 1) * fraction).rounded())
    return sorted[min(max(index, 0), sorted.count - 1)]
}

// MARK: - Entry point

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))

/// When `--trace` is passed, every `TraceEvent` from the engine and the API
/// client is printed as a real log line with a timestamp, a request id and a
/// retry count. This is the exact output quoted in docs/DEBUGGING.md.
let globalTrace: TraceSink? = options.trace ? TraceSink { event in
    print(event.consoleLine)
} : nil

print("ShelfCaseSyncSoak — engine: ShelfCaseKit SyncEngine, transport: URLSessionAPIClient")
print("")

let output: String
switch options.scenario {
case "duplicates": output = await scenarioDuplicates(options: options)
case "tombstones": output = await scenarioTombstones(options: options)
case "soak": output = await scenarioSoak(options: options)
default:
    FileHandle.standardError.write("unknown scenario: \(options.scenario)\n".data(using: .utf8)!)
    exit(2)
}

print(output)
