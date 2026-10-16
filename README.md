# ShelfCase

An **offline-first iOS collectibles catalogue** — cards, figures and vinyl — backed
by a **TypeScript + PostgreSQL API**. You photograph an item, grade it, watch its
price history, see what your collection is worth, and trade with other collectors.
Everything works with no signal; the sync engine reconciles later.

Every number in the Results section below is copied from
[`docs/RESULTS.md`](docs/RESULTS.md), where the raw console output is recorded step
by step. Nothing here is estimated.

---

## 1. What it does

| | |
|---|---|
| **Catalogue** | Lazy grid with thumbnails, grade chips and values; search plus category/grade filters; camera capture on device (PhotosPicker in the Simulator) |
| **Grade** | Five-level condition scale (mint → poor) with a multiplier table that scales a market estimate |
| **Value** | Median of the last five price observations per item, grade-adjusted; a portfolio summary with per-category breakdown and unrealised gain/loss; a price-history sparkline per item |
| **Trade** | Propose a swap of offered vs requested items, accept/decline inbound offers, with optimistic UI that rolls back on server rejection and an atomic ownership swap server-side |
| **Wishlist** | Standing "tell me when this shows up cheap" queries; `POST /items` returns matches inline so the client can raise a notification without a second round trip |
| **Offline** | All writes go to a local outbox first. A sync engine pushes them in order, resolves conflicts by a documented policy, and pulls deltas from a monotonic cursor |
| **Diagnostics** | On-device screen showing the sync report, cursor, retry counts, conflict archive and the last N telemetry events |

---

## 2. Architecture

```
┌─────────────────────────── iOS app (SwiftUI, iOS 17) ────────────────────────────┐
│                                                                                  │
│  Views/                     @Query            Persistence/                        │
│  ├ CollectionGridView ──────────────┐         ├ ShelfCaseSchema (@Model)          │
│  ├ ItemDetailView      ┌────────────┴──────┐  ├ SwiftDataLocalStore : LocalStore  │
│  ├ CaptureView         │ SwiftData store   │◄─┤ LocalImageStore (container-rel.)  │
│  ├ PortfolioView       │ (@Model entities) │  └ ConflictEntity (archive)          │
│  └ TradesView          └────────────┬──────┘                                     │
│                                     │ actor-isolated                             │
│                       ┌─────────────▼──────────────┐                             │
│                       │  SyncEngine.sync()         │  ── Instrumentation/        │
│                       │  push outbox → pull delta  │     OSLog signposts +       │
│                       └─────────────┬──────────────┘     rotating JSONL          │
│                                     │                                            │
│                       ┌─────────────▼──────────────┐                             │
│                       │ URLSessionAPIClient        │  bearer auth, typed errors, │
│                       │ (ShelfCaseAPI)             │  Idempotency-Key, retry     │
│                       └─────────────┬──────────────┘  with exp. backoff + jitter │
└─────────────────────────────────────┼────────────────────────────────────────────┘
                                      │ HTTPS / JSON (ISO8601 ms)
┌─────────────────────────────────────▼────────────────────────────────────────────┐
│                         Express 4 API (TypeScript, strict)                       │
│  middleware/   requestContext (X-Request-Id) → auth (bearer) → idempotency →     │
│                error handler (structured JSON)                                   │
│  routes/       /items   /trades   /wishlist   /sync   /telemetry                 │
│  services/     insertItem (ON CONFLICT) · patchItem (optimistic concurrency) ·   │
│                findWishlistMatches · recordTelemetry                             │
│  sql/          one global change_seq → total order for delta sync                │
└─────────────────────────────────────┬────────────────────────────────────────────┘
                                      │ node-postgres (pool)
                               ┌──────▼──────┐
                               │ PostgreSQL 16│
                               └──────────────┘
```

### The sync contract

**Delta cursor.** `updated_at` alone is not a safe cursor — two rows committed in
the same millisecond are indistinguishable, so a paging client can skip a row
forever. Every mutable row also carries `change_seq` from one global sequence, and
the cursor is `<updatedAt ISO8601>|<change_seq>`. A bare ISO8601 string is still
accepted (treated as `change_seq = 0`) for simple clients. Cursors only ever move
forward.

**Idempotency.** Every unsafe request carries an `Idempotency-Key`. The server
claims the key with `INSERT … ON CONFLICT DO NOTHING`, stores the finished response
in `request_log`, and replays it byte-for-byte on a retry (with
`Idempotency-Replayed: true`). A concurrent duplicate polls briefly and gets
`409 IDEMPOTENCY_IN_PROGRESS` rather than double-executing. Failures are never
cached, so a client can fix its body and retry with the same key. The key is
**persisted with the outbox entry**, so it survives an app relaunch.

**Optimistic concurrency.** `PATCH /items/:id` carries the client's `version`. If it
is stale the server answers `409 VERSION_CONFLICT` with its own copy in
`error.details.serverItem` and changes nothing. `POST /items` is idempotent on the
**client-assigned id** (`ON CONFLICT (id) DO NOTHING` → `200` +
`X-Idempotent-Replay: true`), which is what makes a retried create after a lost
response land on the row that already exists.

**Conflict resolution policy.** On a `409` the engine merges field-by-field:

| Field group | Winner |
|-------------|--------|
| `estimatedValueCents`, `ownerUserId`, `isDeleted`, `version` | **Server, always.** Prices come from market data the server owns; ownership only changes through an accepted trade |
| `notes`, `conditionGrade` (user-authored) | **Client**, when `local.updatedAt > server.updatedAt` — policy `client-newer:user-authored-fields` |
| everything else | Last writer wins by `updatedAt` — policy `server-newer:last-writer-wins` |

The losing copy is never discarded: both the local and server versions are written
to a `conflictArchive` (a `ConflictEntity` in SwiftData), surfaced on the
Diagnostics screen. The merged copy is queued back up against the server's version,
so the next pass converges with no new conflict.

**Tombstones.** A server-side delete arrives on the pull as a row with
`isDeleted == true`. It is applied locally like any other change (it is not a row to
*show*, but it is a change to *absorb*) and counted separately as
`SyncReport.tombstonesApplied`. Skipping it — and then advancing the cursor past it —
loses the delete permanently; see the defect write-up below.

---

## 3. How to run

### Prerequisites

Verified on the machine this was built on (macOS 27.0.1, arm64):

| Tool | Version used |
|------|--------------|
| Swift | 6.4 |
| Node.js / npm | v25.8.1 / 11.11.0 |
| Docker / Compose | 29.8.2 / v5.6.0 |
| PostgreSQL client | 16.15 |
| XcodeGen | 2.46.0 |
| **Xcode** | **not installed here** — required for the iOS app only |

### 1. Database

```bash
docker compose up -d          # postgres:16 on host port 55432, db/user/pass = shelfcase
```

### 2. API

```bash
cd server
cp .env.example .env          # DATABASE_URL etc. Use a strong secret in production.
npm ci
npm run migrate               # idempotent; safe to run repeatedly
npm run seed                  # deterministic demo dataset
npm run dev                   # http://localhost:4000
```

Health check and a smoke request:

```bash
curl -s localhost:4000/health
curl -s localhost:4000/items -H 'Authorization: Bearer dev-alice'
```

`dev-alice`, `dev-bob` and `dev-carol` are seeded bearer tokens. A production
deployment replaces `src/middleware/auth.ts` with JWT verification; handlers only
read `req.userId`, so nothing else changes.

### 3. iOS app

```bash
cd apps/ios
xcodegen generate
open ShelfCase.xcodeproj      # then Run, or:
xcodebuild -project ShelfCase.xcodeproj -scheme ShelfCase \
  -destination 'platform=iOS Simulator,name=iPhone 15' build
```

On a device the app uses an `AVCaptureSession` preview; in the Simulator it falls
back to `PhotosPicker`.

**Pointing the app at an API.** Precedence is
`UserDefaults` → `Info.plist` (`ShelfCaseAPIBaseURL`) → `http://localhost:4000`.
The Diagnostics tab shows the resolved base URL and user, and you can change both:

```swift
AppConfiguration.setBaseURL(URL(string: "https://api.example.com"))
AppConfiguration.setBearerToken("…")
```

For a device on your LAN, use your Mac's address (`http://192.168.1.20:4000`) and
set `NSAllowsLocalNetworking` in the generated `Info.plist`.

### 4. Tests and harnesses

```bash
# Swift package — 48 tests. On this machine use the wrapper, see docs/ENVIRONMENT.md.
./scripts/swift-test.sh

# Server — needs the database from step 1. Creates/drops shelfcase_test per run.
cd server && npm test -- --coverage

# 200 randomised offline/online sync cycles, fixed seed, prints divergence.
./scripts/sync-soak.sh

# Reproduces both investigated defects, before and after, in a throwaway worktree.
./scripts/repro.sh --runs 100

# iOS sources: syntax check without Xcode (14 files).
./scripts/ios-parse-check.sh

# Archive/export/upload for TestFlight (see docs/TESTFLIGHT.md).
./scripts/release.sh --dry-run
```

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `DATABASE_URL` | `postgres://shelfcase:shelfcase@localhost:55432/shelfcase` | API connection |
| `TEST_DATABASE_URL` | `…/shelfcase_test` | database recreated per test run |
| `PORT` | `4000` | API port |
| `PG_POOL_MAX` | `10` | pool size |
| `LOG_LEVEL` | `info` | `debug`/`info`/`warn`/`error`/`silent` |
| `TELEMETRY_FILE` | `./var/telemetry.jsonl` | where `POST /telemetry` appends NDJSON |

---

## 4. Results

All figures below are copied from [`docs/RESULTS.md`](docs/RESULTS.md). Build
verification per target is in the table at the end of this section, including what
could not run here.

### Test suites

| Suite | Result | Time |
|-------|--------|------|
| `ShelfCaseKit` (`./scripts/swift-test.sh`) | **48 tests in 4 suites passed** | 0.093 s test time |
| Server (`npm test`) | **81 tests in 6 files passed** | 3.19 s |
| Server with coverage (`npm test -- --coverage`) | **81 passed** | 5.64 s |

### Server coverage (v8)

| Scope | Lines | Branch |
|-------|------:|-------:|
| All files | **90.29 %** | 81.51 % |
| `src/routes` | **92.19 %** | 84.44 % |
| `src/middleware` | **84.43 %** | 77.08 % |
| `src/services` | 93.28 % | 76.08 % |

Coverage thresholds are enforced in `server/vitest.config.ts` (lines 80, statements
80, functions 70, branches 65) so the build fails if this regresses.

### Seeded demo dataset (`npm run seed`, seed `0x5eed1234`)

| Table | Rows |
|-------|-----:|
| users | 3 |
| items | **48** |
| price_observations | **215** |
| trades | 5 |
| trade_items | 11 |
| wishlist_entries | 6 |

### Sync soak — 200 randomised offline/online cycles (seed `20261016`)

```
cycles: 200; flaky/offline cycles: 141
mutations: 50 local creates, 16 local edits, 47 concurrent edits, 17 local deletes,
           98 remote edits, 13 remote deletes
pushed: 127  pulled: 224  tombstones: 30  conflicts: 66  retries: 171  errors: 0
injected: 97 dropped responses, 41 timeouts, 33 5xx
sync duration p50: 496 ms   p95: 921 ms   (n=201)
live items — local: 20   server: 20
divergence: live items +0 (server − local), checksum MATCH
```

Three consecutive runs report identical counts; p50 varies 494–500 ms (timer noise).

### Defect investigations — measured before/after

Both defects, the reproductions and the root causes are written up in
[`docs/DEBUGGING.md`](docs/DEBUGGING.md). The "before" column is the pre-fix
revision checked out of git (`baseline/pre-step5`), rebuilt and re-run with the
identical regression tests — not a simulation.

| Measurement (100 seeded runs each) | Before | After |
|------------------------------------|-------:|------:|
| Runs ending with more than one server row | **39 / 100** | **0 / 100** |
| Runs ending with more than one local row | 34 / 100 | 0 / 100 |
| Server rows created (expected 100) | 169 | **100** |
| Deletes that never reached the client | **200 / 200** | **0 / 200** |
| Ghost rows in the 200-cycle soak | 7 | **0** |
| Local vs server checksum after the soak | MISMATCH | **MATCH** |
| `ShelfCaseKit` regression test methods failing | 4 | **0** |
| Server regression tests failing | 6 | **0** |

Raw HTTP against both Express revisions, retrying a create with a new
`Idempotency-Key` but the same item id:

| | Before | After |
|-|--------|-------|
| `POST /items` #1 | `201` | `201` |
| `POST /items` #2 (retry) | **`500`** `duplicate key value violates unique constraint "items_pkey"` | **`200`** `X-Idempotent-Replay: true` |
| Rows for that id | 1 | 1 |

### Build verification — what actually ran here

| Target | Status | Evidence |
|--------|--------|----------|
| `ShelfCaseKit` (`swift test`) | ✅ | 48 tests, 4 suites |
| `ShelfCaseSyncSoak` (release) | ✅ | builds and runs the soak |
| `ShelfCase.xcodeproj` generation | ✅ | `xcodegen generate` → "Created project at …/ShelfCase.xcodeproj" |
| iOS app sources (syntax) | ✅ | `scripts/ios-parse-check.sh` → 14/14 parse cleanly |
| Postgres 16.15 (Docker) | ✅ | `select version()` on port 55432 |
| **iOS app build (`xcodebuild`)** | ❌ | **Xcode is not installed** — `xcode-select: error: tool 'xcodebuild' requires Xcode`. CI on `macos-14` performs the real build |
| **Simulator run + screenshots** | ❌ | same reason; shot list in [`docs/screenshots/README.md`](docs/screenshots/README.md) |
| **`xcodebuild archive` / TestFlight upload** | ❌ | needs Xcode *and* an Apple Developer account; see [`docs/TESTFLIGHT.md`](docs/TESTFLIGHT.md) |

Two further environment deviations, both documented in
[`docs/ENVIRONMENT.md`](docs/ENVIRONMENT.md):

* **XCTest is unavailable.** Command Line Tools no longer ship
  `XCTest.framework` (they ship `Testing.framework` instead), and
  `import XCTest` fails to resolve. `ShelfCaseKit` tests therefore use **Swift
  Testing** (`@Test` / `#expect`), which runs under the same `swift test`. The
  app-target tests in `apps/ios/ShelfCaseTests` do use XCTest and run on CI.
* **`swift test` needs a plugin path here.** The CLT installs the Swift Testing
  macro plugin one directory deeper than the driver scans, so `scripts/swift-test.sh`
  detects and forwards it. On a machine with full Xcode the flag is omitted.

---

## 5. Documentation

| Document | Contents |
|----------|----------|
| [`docs/DEBUGGING.md`](docs/DEBUGGING.md) | Both defects: symptom, deterministic reproduction, real instrumented traces, root cause, fix, before/after numbers, regression tests |
| [`docs/RESULTS.md`](docs/RESULTS.md) | Every raw console output, in step order — the source of every number in this README |
| [`docs/ENVIRONMENT.md`](docs/ENVIRONMENT.md) | Tool versions and exactly which commands can and cannot run on this machine |
| [`docs/TESTFLIGHT.md`](docs/TESTFLIGHT.md) | Archive/export/upload runbook, versioning, tester groups, and what needs an Apple Developer account |
| [`docs/APNS.md`](docs/APNS.md) | APNs payload shapes and the client's handling contract |
| [`docs/ADR.md`](docs/ADR.md) | Architecture decisions and their consequences |
| [`docs/screenshots/README.md`](docs/screenshots/README.md) | Shot list and the exact `simctl` commands to capture them |

## Repository layout

```
ShelfCase/
├── ShelfCaseKit/           Swift package: domain models, valuation, sync engine
│   ├── Sources/ShelfCaseKit/{Models,Networking,Storage,Sync,Instrumentation,Testing}/
│   ├── Sources/ShelfCaseSyncSoak/    headless soak + reproduction harness
│   └── Tests/ShelfCaseKitTests/
├── apps/ios/               SwiftUI app + XcodeGen project.yml + ExportOptions.plist
├── server/                 Express + PostgreSQL API (src/, sql/, test/, scripts/seed.ts)
├── docs/                   RESULTS, ENVIRONMENT, DEBUGGING, TESTFLIGHT, APNS, ADR
├── scripts/                swift-test · sync-soak · repro · test-db · ios-parse-check · release
└── docker-compose.yml      postgres:16 on port 55432
```

## License

MIT — see [`LICENSE`](LICENSE).
