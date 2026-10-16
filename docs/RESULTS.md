# RESULTS — raw measured output

Every number in `README.md` must appear in this file first. Entries are appended
step by step as the work actually runs; nothing is estimated or back-filled.

Environment: macOS 27.0.1 / arm64 (Apple M2), Swift 6.4 (Command Line Tools
only), Node v25.8.1, PostgreSQL 16.15 client, Docker 29.8.2.
See `docs/ENVIRONMENT.md` for the full report, including which commands cannot
run on this machine.

---

## Step 1 — Monorepo scaffold, domain model, environment report

### Toolchain versions

| Tool | Version |
|------|---------|
| Swift | 6.4 (`swiftlang-6.4.0.34.1`), target `arm64-apple-macosx27.0.0` |
| Node.js | v25.8.1 |
| npm | 11.11.0 |
| PostgreSQL (client) | 16.15 |
| Docker / Compose | 29.8.2 / v5.6.0 |
| XcodeGen | 2.46.0 |
| Xcode | **not installed** (Command Line Tools only) |

### `scripts/swift-test.sh` — first full run (final, passing)

Command: `./scripts/swift-test.sh`

```
Building for debugging...
[1/1] Build complete! (0.33 sec)
Test run started.
↳ Testing Library Version: 2084
↳ Target Platform: arm64e-apple-macos14.0
✔ Suite "Valuation" passed after 0.002 seconds.
✔ Test run with 21 tests in 1 suite passed after 0.002 seconds.
```

| Metric | Value |
|--------|-------|
| Test functions | **21** (20 `@Test` + 1 parameterised `@Test` with **5 cases**) |
| Suites | 1 (`Valuation`) |
| Passed | **21 / 21** |
| Failed | 0 |
| Test execution time | 0.002 s |
| Incremental build time | 0.33 s |
| Full clean wall time | 19.50 s (first build) / 0.99 s (warm) |

### Defect found and fixed during Step 1 (real, from a failing test run)

The first `swift test` run **failed 1 of 21 tests**:

```
✘ Test "Trade round-trips through ISO8601 JSON" recorded an issue at ValuationTests.swift:259:9:
  Expectation failed: decoded == trade
↳   trade     createdAt → timeIntervalSinceReferenceDate → 813826347.875882
↳   decoded   createdAt → timeIntervalSinceReferenceDate → 813826347.0
✘ Test run with 21 tests in 1 suite failed after 0.008 seconds with 1 issue.
```

Cause: `ShelfCaseCoding` encoded dates with `ISO8601DateFormatter` using only
`[.withInternetDateTime]`, i.e. **whole-second precision**, which discarded the
fractional part and broke round-trips (and would later make last-writer-wins
conflict resolution tie on timestamps that are actually distinct). Fixed by
encoding with `[.withInternetDateTime, .withFractionalSeconds]`; decoding already
accepted both forms. The wire format is therefore **millisecond-resolution ISO8601
with a `Z` suffix**.

Post-fix: 21/21 passing.

### Repository layout created

```
ShelfCase/
├── ShelfCaseKit/           Swift package (library + tests)
│   ├── Package.swift       iOS 17 / macOS 14
│   ├── Sources/ShelfCaseKit/
│   │   └── Models/         Core.swift, CollectibleItem.swift, PriceObservation.swift,
│   │                       Trade.swift, WishlistEntry.swift, Valuation.swift
│   └── Tests/ShelfCaseKitTests/ValuationTests.swift
├── apps/ios/               SwiftUI app sources + project.yml
├── server/                 TypeScript Express API
├── docs/                   RESULTS.md, ENVIRONMENT.md, DEBUGGING.md, ADR notes
├── scripts/                swift-test.sh, ...
└── docker-compose.yml      postgres:16 on port 55432
```

---

## Step 2 — TypeScript + Express + PostgreSQL API

### Infrastructure

`docker compose up -d` brought up `postgres:16` on host port **55432**:

```
$ docker exec shelfcase-postgres psql -U shelfcase -d shelfcase -c "select version();"
PostgreSQL 16.15 (Debian 16.15-1.pgdg13+2) on aarch64-unknown-linux-gnu, compiled by gcc (Debian 14.2.0-19), 64-bit
$ scripts/test-db.sh   # readiness probe
READY after 1s
```

`npm run migrate` (idempotent `CREATE ... IF NOT EXISTS`):

```
{"ts":"2026-10-16T06:56:24.676Z","level":"info","event":"db.migrated","file":"001_init.sql"}
{"ts":"2026-10-16T06:56:24.677Z","level":"info","event":"migrate.done"}
```

### `npm test` — Supertest against a real PostgreSQL

`scripts/test-db.sh reset` drops and recreates `shelfcase_test` per run, then the
suite migrates it. 75 tests across 5 files:

```
 ✓ test/items.test.ts (25 tests) 725ms
 ✓ test/trades.test.ts (19 tests) 509ms
 ✓ test/sync.test.ts (15 tests) 457ms
 ✓ test/idempotency.test.ts (8 tests) 225ms
 ✓ test/wishlist.test.ts (8 tests) 198ms

 Test Files  5 passed (5)
      Tests  75 passed (75)
   Duration  3.60s (transform 111ms, setup 0ms, collect 409ms, tests 2.11s, prepare 135ms)
```

| Metric | Value |
|--------|-------|
| Test files | **5 passed / 5** |
| Tests | **75 passed / 75**, 0 failed |
| Duration (with coverage instrumentation) | **4.20 s** |
| Duration (plain `npm test`) | **3.60 s** |

### `npm run test:coverage` — v8 coverage

```
 Test Files  5 passed (5)
      Tests  75 passed (75)
   Duration  4.20s
-------------------|---------|----------|---------|---------|-------------------
File               | % Stmts | % Branch | % Funcs | % Lines | Uncovered Line #s
-------------------|---------|----------|---------|---------|-------------------
All files          |   90.51 |    81.67 |   82.69 |   90.51 |
 src               |   88.69 |    80.35 |   72.41 |   88.69 |
  app.ts           |   85.71 |       80 |     100 |   85.71 |
  config.ts        |     100 |       50 |     100 |     100 |
  cursor.ts        |   94.73 |     91.3 |     100 |   94.73 |
  db.ts            |   57.44 |    66.66 |      20 |   57.44 |
  errors.ts        |   93.33 |      100 |    87.5 |   93.33 |
  logger.ts        |   54.54 |       50 |      40 |   54.54 |
  mappers.ts       |     100 |     62.5 |     100 |     100 |
  schemas.ts       |     100 |      100 |     100 |     100 |
 src/middleware    |   84.79 |    77.08 |    87.5 |   84.79 |
  auth.ts          |     100 |      100 |     100 |     100 |
  error.ts         |     100 |       80 |     100 |     100 |
  idempotency.ts   |   72.34 |     62.5 |      75 |   72.34 |
  requestContext.ts|     100 |      100 |     100 |     100 |
 src/routes        |    92.3 |    84.74 |     100 |    92.3 |
  items.ts         |   97.08 |    82.22 |     100 |   97.08 |
  sync.ts          |   83.79 |       80 |     100 |   83.79 |
  trades.ts        |   95.85 |    90.14 |     100 |   95.85 |
  wishlist.ts      |   93.58 |    81.25 |     100 |   93.58 |
 src/services      |   94.53 |     75.6 |     100 |   94.53 |
  items.ts         |   96.05 |    77.14 |     100 |   96.05 |
  telemetry.ts     |   88.23 |       50 |     100 |   88.23 |
  wishlist.ts      |     100 |      100 |     100 |     100 |
-------------------|---------|----------|---------|---------|-------------------
```

| Scope | Lines | Branch |
|-------|-------|--------|
| **All files** | **90.51 %** | 81.67 % |
| `src/routes` | **92.30 %** | 84.74 % |
| `src/middleware` | **84.79 %** | 77.08 % |
| `src/services` | 94.53 % | 75.60 % |

(Step 6 target was ≥ 80 % lines on `src/routes` and `src/middleware`; both are
already above it.)

### `npm run lint` / `npx tsc --noEmit`

```
$ npm run lint            → 0 errors, 0 warnings
$ npx tsc --noEmit        → (no output)
```

### `npm run seed` — deterministic demo dataset

Seeded from `SEED = 0x5eed1234` with fixed row ids, so repeated runs converge.

```
seeded row counts:
  users                3
  items                48
  price_observations   215
  trades               5
  trade_items          11
  wishlist_entries     6
```

| Table | Rows |
|-------|------|
| users | 3 |
| **items** | **48** (brief required ≥ 40) |
| **price_observations** | **215** (brief required ≥ 150) |
| **trades** | **5** |
| trade_items | 11 |
| wishlist_entries | 6 |

### Defects found and fixed during Step 2

1. **`GET /sync/pull` returned 500 for every un-cursored request.** The generated
   SQL always referenced `LIMIT $2`, but the no-cursor branch bound only one
   parameter, so PostgreSQL rejected it with "there is no parameter $2". Fixed by
   binding the limit as the last parameter of whichever branch was built and
   interpolating that index. Caught by `test/sync.test.ts` (5 failures) and then
   verified green.
2. **Failed requests were cached by the idempotency middleware.** The middleware
   patched `res.json`, and the error handler writes through `res.json` too — so a
   `422` was stored as the canonical response for that key and the client could
   never retry with a corrected body. Fixed by only storing responses with status
   `< 400` and deleting the claim otherwise (`test/idempotency.test.ts →
   "errors are not cached"`).

---

## Step 3 — Offline-first sync engine

New targets in `ShelfCaseKit`:

| Path | What it is |
|------|------------|
| `Sources/ShelfCaseKit/Networking/APIClient.swift` | `ShelfCaseAPI`, `HTTPPerforming`, `URLSessionTransport`, `URLSessionAPIClient` (typed errors, bearer auth, `Idempotency-Key`, capped exponential backoff + jitter) |
| `Sources/ShelfCaseKit/Storage/LocalStore.swift` | `LocalStore` protocol, `ConflictRecord`, `InMemoryLocalStore`, `ShelfCaseDigest` |
| `Sources/ShelfCaseKit/Sync/SyncEngine.swift` | `sync() -> SyncReport`, `ConflictResolution` policy |
| `Sources/ShelfCaseKit/Testing/FaultInjectingAPIClient.swift` | seeded fault injector (latency / timeout / **dropped response** / 5xx) |
| `Sources/ShelfCaseKit/Testing/SimulatedServer.swift` | in-process server speaking the real API's JSON, `Idempotency-Key` and `change_seq` cursor |
| `Sources/ShelfCaseSyncSoak/main.swift` | the headless soak harness executable |
| `scripts/sync-soak.sh` | repeatable wrapper around it |

### `./scripts/swift-test.sh`

```
Build complete! (8.00 sec)
✔ Suite "Valuation" passed after 0.013 seconds.
✔ Suite "URLSessionAPIClient" passed after 0.020 seconds.
✔ Suite "SyncEngine" passed after 0.159 seconds.
✔ Test run with 43 tests in 3 suites passed after 0.160 seconds.
```

| Metric | Value |
|--------|-------|
| Tests | **43 passed / 43**, 0 failed |
| Suites | 3 (`Valuation`, `SyncEngine`, `URLSessionAPIClient`) |
| Test execution time | 0.160 s |
| Build + test wall time | 10.04 s (incremental) |

Coverage of the Step 3 requirements: offline-queue replay in `updatedAt` order
(asserted against the recorded request bodies), dropped-response retry with a
stable `Idempotency-Key`, conflict policy (both branches), monotonic cursor
including across a simulated app restart, 200-change batch, pagination, and the
typed-error / backoff matrix.

### `scripts/sync-soak.sh` — N=200 randomized offline/online cycles (seed 20261016)

```
==> .../ShelfCaseSyncSoak --scenario soak --cycles 200 --seed 20261016

scenario: soak
cycles: 200 (seed 20261016); flaky/offline cycles: 133
mutations: 39 local creates, 51 local edits, 54 remote edits, 51 remote deletes
drain passes: 1
pushed: 89  pulled: 109  conflicts: 21  retries: 115  errors: 0
conflict archive entries: 21
injected: 52 dropped responses, 41 timeouts, 22 5xx
sync duration p50: 187 ms   p95: 723 ms   (n=201)
live items   — local: 19   server: 12
total rows   — local: 39  server: 39
local checksum:  ada0b1f4868b6647
server checksum: bf11dd1e15b56176
ghost rows (deleted on the server, still live locally): 7
divergence: live items -7 (server − local), checksum MISMATCH
```

| Metric | Value |
|--------|-------|
| Cycles | **200** (133 of them on a degraded link), seed `20261016` |
| Mutations | 39 local creates, 51 local edits, 54 remote edits, 51 remote deletes |
| Pushed / pulled | 89 / 109 |
| Conflicts (auto-resolved) | 21 |
| Retries | 115 |
| Errors | 0 |
| Injected faults | 52 dropped responses, 41 timeouts, 22 × 5xx |
| Sync duration | **p50 187 ms, p95 723 ms** (n = 201) |
| Divergence | **7 ghost rows**; checksums **MISMATCH** |
| Determinism | 3 consecutive runs report identical counts (only latency varies) |

### Baseline anomalies this harness surfaced (investigated in Step 5)

The harness was written to *measure*, not to pass, and it found two divergences
between the client and the server at the end of a soak. Both are recorded here as
the honest pre-fix baseline for `docs/DEBUGGING.md`.

**Anomaly A — duplicate item creation after a lost response.**

```
$ scripts/sync-soak.sh --scenario duplicates --runs 100
runs ending with MORE THAN ONE server row: 39 / 100  [39.0%]
runs ending with MORE THAN ONE local row:  34 / 100  [34.0%]
server rows: 169   local rows: 159   (both should be 100)
first duplicate: run 3: server=3 local=1
```

**Anomaly B — tombstones never reach the device.**

```
$ scripts/sync-soak.sh --scenario tombstones --runs 100
deletes performed on the server: 200
deletes that never reached the client: 200  [100.0%]
runs affected: 100 / 100
rows still believed live locally (resurrection risk): 200
```

**Instrumentation added** so both can be traced: `FaultMetrics` (attempts,
timeouts, dropped responses, 5xx, injected latency), `SimulatedServer` counters
(`itemRowsInserted`, `duplicateIdRejections`, `idempotentReplays`,
`tombstonesServed`), `APIClientMetrics` (requests, retries, conflicts, decode
failures) and `SyncReport` (pushed / pulled / conflicts / retries / errors /
durationMs / cursor).

---

## Step 4 — SwiftUI app

### `xcodegen generate` — ✅ ran

```
$ cd apps/ios && xcodegen generate
⚙️  Generating plists...
⚙️  Generating project...
⚙️  Writing project...
Created project at /Users/abhiramkasireddi/ShelfCase/apps/ios/ShelfCase.xcodeproj
```

Targets present in the generated `project.pbxproj`:
`ShelfCase`, `ShelfCaseTests`, and the local `ShelfCaseKit` package.

### `xcodebuild … build` — ❌ **could not run on this machine**

```
$ xcodebuild -project ShelfCase.xcodeproj -scheme ShelfCase \
    -destination 'platform=iOS Simulator,name=iPhone 15' build
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer
directory '/Library/Developer/CommandLineTools' is a command line tools instance
```

Same result for `-destination 'generic/platform=iOS'`. Xcode is not installed, so
**no iOS build, no simulator run and no screenshots were produced here.** The
screenshot shot-list is in `docs/screenshots/README.md`; CI
(`.github/workflows/ci.yml`, `macos-14`) performs the real build.

### `scripts/ios-parse-check.sh` — ✅ ran (the strongest check available here)

Command Line Tools ship neither the iOS SDK nor `SwiftDataMacros`, so the app
cannot be type-checked locally. `swiftc -parse` needs no macro plugins, and it
does catch syntax errors across every source file:

```
$ ./scripts/ios-parse-check.sh
==> swift-frontend -parse over 14 app source file(s)
==> SDK: /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk

✔ all 14 app source file(s) parse cleanly
```

For reference, type-checking stops immediately at the first SwiftData macro:

```
error: external macro implementation type 'SwiftDataMacros.PersistentModelMacro'
could not be found for macro 'Model()'; plugin for module 'SwiftDataMacros' not found
```

| Target | Status on this machine |
|--------|------------------------|
| `ShelfCaseKit` (`swift build` / `swift test`) | ✅ builds and tests |
| `ShelfCaseSyncSoak` (release) | ✅ builds and runs |
| `ShelfCase.xcodeproj` generation | ✅ `xcodegen generate` |
| iOS app source syntax | ✅ 14/14 files parse |
| iOS app build / simulator run / screenshots | ❌ requires Xcode |
| `ShelfCaseTests` (XCTest) | ❌ requires Xcode |

### App sources written

| File | Purpose |
|------|---------|
| `ShelfCaseApp.swift` | `@main` App, SwiftData `ModelContainer`, tab root, offline banner, `DiagnosticsView` |
| `App/AppEnvironment.swift` | DI container; `NetworkMonitor` built on `NWPathMonitor`; `syncNow()` |
| `App/AppConfiguration.swift` | base URL / token resolution, `APIClientFactory` |
| `Persistence/SwiftDataModels.swift` | `@Model` entities mirroring the Kit models + the conflict archive |
| `Persistence/SwiftDataLocalStore.swift` | `SwiftDataLocalStore: LocalStore` (an actor) |
| `Persistence/LocalImageStore.swift` | container-relative image writes with a low-disk guard |
| `Views/CollectionGridView.swift` | lazy grid, search, category/grade filters, pull-to-refresh |
| `Views/ItemDetailView.swift` | photo, editable grade/notes, sparkline, wishlist + trade actions |
| `Views/CaptureView.swift` | `AVCaptureSession` (device) with a `PhotosPicker` fallback (Simulator) |
| `Views/PortfolioView.swift` | `Valuation.portfolioSummary` totals + per-category bars |
| `Views/TradesView.swift` | incoming/outgoing, propose sheet, optimistic accept/decline with rollback |
| `Notifications/PushRegistrar.swift` | `UNUserNotificationCenter` registration + local notifications |
| `Instrumentation/Telemetry.swift` | OSLog signposts, rotating JSONL, optional `POST /telemetry` |
| `Networking/TradeService.swift` | `/trades` and `/wishlist` client |

APNs payload shapes are documented in `docs/APNS.md`.
