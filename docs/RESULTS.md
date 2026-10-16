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

---

## Step 5 — Defect investigation, fixes, and before/after measurements

Full write-ups: **`docs/DEBUGGING.md`**. Reproduction: `./scripts/repro.sh --runs 100`.

The "before" column is **not simulated**. `scripts/repro.sh` checks the pre-fix
revision out of git (`tag: baseline/pre-step5` = `ba7c9b3`, the Step 4 commit) into
a throwaway `git worktree`, copies the identical regression tests in, rebuilds, and
re-runs everything there.

### `scripts/repro.sh --runs 100` — final summary

```
  runs with duplicate server rows (of 100)       before:       39 / 100   after:        0 / 100
  server rows created (expected 100)             before:            169   after:            100
  deletes lost on the delta pull                 before:            200   after:              0
  Kit regression test methods failing            before:              4   after:              0
  server regression tests failing                before:              6   after:              0
```

### Defect A — duplicate creation after a lost response

```
BEFORE (baseline ba7c9b3):
    dropped responses injected: 308
    runs ending with MORE THAN ONE server row: 39 / 100  [39.0%]
    runs ending with MORE THAN ONE local row:  34 / 100  [34.0%]
    server rows: 169   local rows: 159   (both should be 100)

AFTER (working tree):
    dropped responses injected: 308
    runs ending with MORE THAN ONE server row: 0 / 100  [0.0%]
    runs ending with MORE THAN ONE local row:  0 / 100  [0.0%]
    server rows: 100   local rows: 100   (both should be 100)
```

Identical fault injection on both sides (308 dropped responses), so the delta is
the fix. Real HTTP against both Express revisions:

```
BEFORE:
  POST #1 (fresh create)            -> HTTP 201
  POST #2 (retry, new key, same id) -> HTTP 500
  server log: "error":"duplicate key value violates unique constraint \"items_pkey\""
              "requestId":"repro-baseline-2"
AFTER:
  POST #1 (fresh create)            -> HTTP 201
  POST #2 (retry, new key, same id) -> HTTP 200   (X-Idempotent-Replay: true)
  rows in items for that id         -> 1
```

### Defect B — tombstones lost on the delta pull

```
BEFORE:
    deletes performed on the server: 200
    deletes that never reached the client: 200  [100.0%]
    runs affected: 100 / 100
    rows still believed live locally (resurrection risk): 200

AFTER:
    deletes performed on the server: 200
    deletes that never reached the client: 0  [0.0%]
    runs affected: 0 / 100
    rows still believed live locally (resurrection risk): 0
```

### Post-fix soak — 200 cycles, seed 20261016

```
scenario: soak
cycles: 200 (seed 20261016); flaky/offline cycles: 141
mutations: 50 local creates, 16 local edits, 47 concurrent edits, 17 local deletes, 98 remote edits, 13 remote deletes
drain passes: 1
pushed: 127  pulled: 224  tombstones: 30  conflicts: 66  retries: 171  errors: 0
conflict archive entries: 66
injected: 97 dropped responses, 41 timeouts, 33 5xx
sync duration p50: 496 ms   p95: 921 ms   (n=201)
live items   — local: 20   server: 20
total rows   — local: 50  server: 50
local checksum:  47606d128a0cec36
server checksum: 47606d128a0cec36
ghost rows (deleted on the server, still live locally): 0
divergence: live items +0 (server − local), checksum MATCH
```

Three consecutive runs report **identical counts** (127 pushed / 224 pulled / 30
tombstones / 66 conflicts / 171 retries / 0 errors) and `checksum MATCH`. The
surviving-row *digest* differs between runs because remote mutations pick targets
from a list ordered by wall-clock `updatedAt`; the verdict is stable, the digest is
not. `p50` moves by a few milliseconds (494–500 ms) — run-to-run timer noise.

### Test suites after the fix

| Suite | Result |
|-------|--------|
| `scripts/swift-test.sh` | **48 tests in 4 suites passed** (was 43 before the regression tests) |
| `npm test` (server) | **81 tests in 6 files passed** (was 75 before `regression.test.ts`) |

### Instrumentation added for these investigations

`ShelfCaseKit/Instrumentation/Trace.swift` (`TraceEvent` + `TraceSink`) with
`http.attempt` / `http.retry` / `http.ok` / `http.failed` emitters in
`URLSessionAPIClient` and `sync.start` / `push.change` / `push.applied` /
`push.conflict` / `push.failed` / `pull.page` / `pull.tombstone` / `sync.end` in
`SyncEngine`. Every line carries a timestamp, a correlation id and, where relevant,
the attempt number and the `Idempotency-Key`. `ShelfCaseSyncSoak --trace` prints
them; `--verbose` prints per-cycle narration.

---

## Step 6 — Test-suite hardening, CI, and the release pipeline

### Server coverage after hardening

```
 Test Files  6 passed (6)
      Tests  81 passed (81)
   Duration  5.64s
-------------------|---------|----------|---------|---------|-------------------
File               | % Stmts | % Branch | % Funcs | % Lines |
-------------------|---------|----------|---------|---------|-------------------
All files          |   90.29 |    81.51 |   82.69 |   90.29 |
 src               |   88.66 |    80.35 |   72.41 |   88.66 |
 src/middleware    |   84.43 |    77.08 |    87.5 |   84.43 |
 src/routes        |   92.19 |    84.44 |     100 |   92.19 |
 src/services      |   93.28 |    76.08 |     100 |   93.28 |
-------------------|---------|----------|---------|---------|-------------------
```

| Scope | Lines | Target | Met |
|-------|------:|-------:|-----|
| `src/routes` | **92.19 %** | ≥ 80 % | ✅ |
| `src/middleware` | **84.43 %** | ≥ 80 % | ✅ |
| All files | 90.29 % | — | — |

Thresholds are enforced in `server/vitest.config.ts` (`lines 80`, `statements 80`,
`functions 70`, `branches 65`), so the build fails if coverage regresses.

### `scripts/swift-test.sh`

```
✔ Suite "SyncEngine" passed after 0.093 seconds.
✔ Test run with 48 tests in 4 suites passed after 0.093 seconds.
```

48 tests across 4 suites (`Valuation`, `SyncEngine`, `URLSessionAPIClient`,
`Regression: lost responses and lost tombstones`). Covers sync ordering, conflict
resolution, cursor monotonicity, 200-change batches, pagination, the full
typed-error/backoff matrix, and both regression suites.

### `.github/workflows/ci.yml`

Validated with a real YAML parse:

```
YAML OK — jobs: server, ios
  server: 10 steps on ubuntu-22.04
  ios: 13 steps on macos-14
```

| Job | Runner | Services | Steps |
|-----|--------|----------|-------|
| `server` | `ubuntu-22.04` | `postgres:16` on 5432 with a `pg_isready` health gate | `npm ci` (cached on `server/package-lock.json`) → `npm run typecheck` → `npm run lint` → `npm run format:check` → `npm run migrate` ×2 (proves the SQL is idempotent) → `npm test -- --coverage` → `npm run seed` → upload coverage artifact |
| `ios` | `macos-14` | — | cache `.build` + SwiftPM cache → install `xcodegen` → `swift test --enable-code-coverage` → `swift build -c release` → `scripts/sync-soak.sh --cycles 200` → `scripts/repro.sh --runs 50 --skip-baseline` → `xcodegen generate` → `xcodebuild build` (iPhone 15 simulator) → `xcodebuild test` → boot the simulator and capture a screenshot → upload it |

Node is pinned to `22.11.0`; the `.build` and npm caches are keyed on
`Package.swift` / `package-lock.json`.

### `scripts/release.sh --dry-run` — executed here

```
== Preflight
  ✘ xcodebuild is not available — full Xcode is required and is not installed
     xcode-select -p -> /Library/Developer/CommandLineTools
     (dry run: continuing to print the plan)
  ✔ xcodegen: Version: 2.46.0
  ✘ DEVELOPMENT_TEAM is not set — an archive cannot be signed
  ✘ no Apple Distribution identity in the keychain

== Version
  MARKETING_VERSION=1.0.0  CURRENT_PROJECT_VERSION=1

== Generate the Xcode project
  ✔ ShelfCase.xcodeproj generated

== Archive
  ⊘ SKIPPED (requires Xcode and DEVELOPMENT_TEAM)

== ExportOptions.plist
  ✔ using the committed /…/apps/ios/ExportOptions.plist
  method: app-store  teamID: <unset>

== Export the .ipa
  ⊘ SKIPPED (no archive present (archive step must succeed first))

== Upload to App Store Connect
  ⊘ SKIPPED (--upload not passed)

== dSYMs
  ⊘ SKIPPED (no dSYMs (archive step did not run))
```

| Release step | Executed here | Notes |
|--------------|---------------|-------|
| `xcodegen generate` | ✅ | run as part of `release.sh` |
| `xcodebuild archive` | ⊘ | needs Xcode + `DEVELOPMENT_TEAM` |
| `xcodebuild -exportArchive` | ⊘ | needs the archive |
| `xcrun altool --upload-app` | ⊘ | needs the archive + App Store Connect key |
| dSYM inventory | ⊘ | needs the archive |

Full runbook, versioning rules, TestFlight tester groups and the list of steps that
require an Apple Developer account: **`docs/TESTFLIGHT.md`**.

---

## Step 7 — README, polish, and a full re-run of every documented command

The README is assembled only from numbers that already exist in this file.

### Polish applied

| Item | Result |
|------|--------|
| `npm run lint` (ESLint) | `> eslint .` — 0 errors, 0 warnings |
| `npm run format:check` (Prettier) | "All matched files use Prettier code style!" |
| `npm run typecheck` (`tsc --noEmit`) | clean |
| `swift format lint` (Swift 6.4 `swift format`, config in `.swift-format`) | **0 warnings** across `ShelfCaseKit/Sources`, `ShelfCaseKit/Tests`, `apps/ios/ShelfCase`, `apps/ios/ShelfCaseTests` |
| `.gitignore` | covers `node_modules`, `.build`, `DerivedData`, `*.xcodeproj` (generated), `coverage`, `.env`, `server/var`, `apps/ios/ShelfCase/Info.plist` (generated by XcodeGen) |
| `.env.example` | root (Docker Compose) + `server/.env.example` (API) |
| `LICENSE` | MIT |
| `docker-compose.yml` | parameterised via `POSTGRES_*` with working defaults; `docker compose config` validates |

### Seeder made deterministic

`npm run seed` now truncates the demo tables first (refusing to do so when
`NODE_ENV=production` unless `--force`), so the reported counts no longer drift when
someone has `curl`ed extra rows in. Two consecutive runs:

```
cleared existing demo data
seeded row counts:
  users                3
  items                48
  price_observations   215
  trades               5
  trade_items          11
  wishlist_entries     6
```

### Every documented command, re-run end to end

| Command | Result |
|---------|--------|
| `docker compose up -d` | `Container shelfcase-postgres Started` |
| `npm ci` | completes from `package-lock.json` |
| `npm run migrate` | `{"event":"db.migrated","file":"001_init.sql"}` (idempotent) |
| `npm run seed` | 3 users / 48 items / 215 observations / 5 trades / 11 trade_items / 6 wishlist entries |
| `npm run typecheck` | clean |
| `npm run lint` | clean |
| `npm run format:check` | clean |
| `npm run dev` + `curl` | see below |
| `npm test -- --coverage` | 6 files, **81 tests passed**, 3.65 s; all files 90.29 % lines, routes 92.19 %, middleware 84.43 % |
| `./scripts/swift-test.sh` | **48 tests in 4 suites passed** (0.084 s) |
| `./scripts/sync-soak.sh` | 200 cycles, checksum MATCH, divergence `+0`, ghost rows 0 |
| `./scripts/sync-soak.sh --scenario duplicates --runs 100` | `0 / 100` runs with duplicate rows |
| `./scripts/repro.sh --runs 100` | before/after table reproduced (39→0 duplicates, 200→0 lost deletes, 4→0 and 6→0 failing regression tests) |
| `./scripts/ios-parse-check.sh` | `✔ all 14 app source file(s) parse cleanly` |
| `cd apps/ios && xcodegen generate` | `Created project at …/ShelfCase.xcodeproj` |
| `./scripts/release.sh --dry-run` | 10 status lines; every Xcode-dependent step reported as `⊘ SKIPPED` |
| `xcodebuild … build` | ❌ **cannot run** — no Xcode on this machine (documented in `docs/ENVIRONMENT.md`) |

Live API smoke test against the seeded database (`npm run dev` on port 4000):

```
$ curl -s localhost:4000/health
{"status":"ok","service":"shelfcase-api","time":"2026-10-16T07:53:12.751Z"}

$ curl -s "localhost:4000/items?limit=3" -H 'Authorization: Bearer dev-alice'
count: 3 | nextCursor: 2026-10-16T07:53:00.892Z|845
 - Charizard Base Set Holo | poor | 118309 cents
 - Hot Toys Iron Man Mark 85 | good | 251943 cents
 - Kind of Blue — First Press | mint | 148171 cents

$ curl -s "localhost:4000/trades?role=incoming" -H 'Authorization: Bearer dev-bob'
trades: 1

$ curl -s "localhost:4000/sync/pull?limit=5" -H 'Authorization: Bearer dev-alice'
items 5 observations 5 trades 5 wishlist 5 hasMore True
```

and the matching structured server log line:

```
{"ts":"2026-10-16T07:53:12.872Z","level":"info","event":"http.request",
 "requestId":"d80c7faf-13b6-4af2-be0d-b6eeef84f970","method":"GET","path":"/pull",
 "status":200,"durationMs":17.06,"userId":"11111111-1111-4111-8111-111111111111"}
```
