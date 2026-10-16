# DEBUGGING — instrumented investigations

Two defects that only appear under real network and real-device conditions, plus
the smaller issue found while fixing the second one. Every number below comes from
an actual run; the raw logs are `/tmp/repro-*.txt` and `/tmp/repro-*.log`.

**How to re-measure.** `./scripts/repro.sh --runs 100` is the single entry point.
It does not simulate the pre-fix behaviour: it checks the pre-fix revision out of
git (`tag: baseline/pre-step5` = commit `ba7c9b3`, the last commit before any Step 5
change) into a throwaway `git worktree`, copies the *same* regression tests in,
rebuilds, and re-runs everything. If the tag is missing the script says so and
prints only the "after" column — it never invents a "before" number.

**Instrumentation used by both investigations.**

| Source | Emits |
|--------|-------|
| `ShelfCaseKit/Instrumentation/Trace.swift` | `TraceEvent` (timestamp, `requestId`, level, event, fields) + `TraceSink` |
| `URLSessionAPIClient` | `http.attempt` / `http.retry` / `http.ok` / `http.failed` with attempt count, backoff ms and the `Idempotency-Key` |
| `SyncEngine` | `sync.start` / `push.change` / `push.applied` / `push.conflict` / `push.failed` / `pull.page` / `pull.tombstone` / `sync.end` |
| `FaultInjectingAPIClient` | seeded latency / timeout / **dropped response** / 5xx injection with counters |
| `SimulatedServer` | `itemRowsInserted`, `duplicateIdRejections`, `idempotentReplays`, `tombstonesServed` |
| Express server | one structured `http.request` line per request carrying `requestId`, status and duration |

Correlation ids are minted per logical operation, matching the server's
`X-Request-Id`, so a client retry and the server's line for it can be joined by eye.

---

## Defect A — duplicate item creation when a POST response is lost after the server commits

### Symptom

A user catalogues one card while offline. The phone has one bar; the POST reaches
the server, the row is written, and the reply never makes it back. The user later
reopens the app with signal and **the collection now contains that card twice** —
and so does the server.

### Deterministic reproduction

```bash
./scripts/repro.sh --runs 100          # section "DEFECT A"
```

Reproduction profile, held constant on both sides of the fix:

| Parameter | Value |
|-----------|-------|
| `dropResponseRate` | 0.60 — the server **commits**, then the reply is lost |
| `timeoutRate` | 0.10 |
| `serverErrorRate` | 0.05 |
| retry `maxAttempts` | 2 (`RetryPolicy(maxAttempts: 2, baseDelay: .milliseconds(1), jitterRatio: 0)`) |
| seed | `20261016`, offset per run (`seed + run * 0x9e3779b9`) so each run has an independent but fully reproducible fault sequence |
| shape | one offline create, then sync passes until the outbox drains |

Two attempts per pass models iOS suspending the app mid-sync: the retry loop
rarely gets many shots before the process is frozen. A dropped response is
injected *after* the inner transport has already been called, so the server has
definitely committed.

### Instrumented trace

Reproduced identically in the field by walking into a lift with a queued capture.
Real lines from `ShelfCaseSyncSoak --scenario duplicates --runs 3 --trace`
(abridged to one run):

```
2026-10-16T07:37:32.277Z INFO  [sync-5e43c4b8] sync.start
2026-10-16T07:37:32.277Z INFO  [sync-5e43c4b8] push.change itemId=dae1f9d5-… state=pendingCreate version=1 idempotencyKey=bd7b1de5-…
2026-10-16T07:37:32.277Z INFO  [http-6a7bfa29] http.attempt attempt=1/2 method=POST path=/items subject=dae1f9d5-… idempotencyKey=bd7b1de5-…
2026-10-16T07:37:32.277Z WARN  [http-6a7bfa29] http.retry attempt=1 backoffMs=1 reason=transport:response lost after the server committed
2026-10-16T07:37:32.279Z INFO  [http-6a7bfa29] http.attempt attempt=2/2 method=POST path=/items subject=dae1f9d5-… idempotencyKey=bd7b1de5-…
2026-10-16T07:37:32.280Z INFO  [http-6a7bfa29] http.ok attempt=2 status=201
2026-10-16T07:37:32.280Z INFO  [sync-5e43c4b8] push.applied op=create itemId=dae1f9d5-… serverId=dae1f9d5-… identityPreserved=true
```

`identityPreserved=true` is the line that matters: the row the server returns is
keyed by the id the client sent. Before the fix that line read
`identityPreserved=false` and `serverId` was a different UUID.

The other half of the story is the **server** side. Retrying the same create with a
different `Idempotency-Key` against the pre-fix Express route, captured over real
HTTP with the server's own request-id logs:

```
BEFORE (baseline ba7c9b3):
  POST #1 (fresh create)               -> HTTP 201
  POST #2 (retry, new key, same id)    -> HTTP 500
  rows in items for that id            -> 1
  {"ts":"2026-10-16T07:39:20.376Z","level":"error","event":"http.unhandled_error",
   "requestId":"repro-baseline-2",
   "error":"duplicate key value violates unique constraint \"items_pkey\""}

AFTER (working tree):
  POST #1 (fresh create)               -> HTTP 201
  POST #2 (retry, new key, same id)    -> HTTP 200   (X-Idempotent-Replay: true)
  rows in items for that id            -> 1
```

### Root cause

Three things had to line up, and all three were wrong:

1. **The create payload did not carry the client's id.** `CreateItemPayload`
   encoded the fields but not `id`, because row identity had been modelled as
   server-owned. The server therefore minted a UUID per POST, and a retry was
   indistinguishable from a genuinely new card.
2. **The `Idempotency-Key` was minted per sync pass, not per outbox entry.** The
   engine called `keyGenerator()` inside the `for change in pending` loop, so the
   key protected retries *within* a pass but a retry in the *next* pass (after the
   app was suspended or relaunched) presented a key the server had never seen.
   Nothing persisted the key with the change.
3. **The server had no `ON CONFLICT` handling on `INSERT INTO items`.** Even once
   the client sent a stable id, a second insert with that id died on the primary
   key with a raw `500` (`duplicate key value violates unique constraint
   "items_pkey"`) instead of resolving to the row that already existed.

### Fix

| # | Change | File |
|---|--------|------|
| 1 | `CreateItemPayload` now encodes `id: UUID` | `ShelfCaseKit/Networking/APIClient.swift` |
| 2 | `LocalStore` gains `pendingIdempotencyKey(forItem:)` / `setPendingIdempotencyKey(_:forItem:)`; `SyncEngine` pins one key per change and retires it once the change is resolved | `Storage/LocalStore.swift`, `Sync/SyncEngine.swift` |
| 3 | `InMemoryLocalStore` persists keys in the store; `ItemEntity` gains a persisted `idempotencyKey` column so the key survives an app relaunch | `Storage/LocalStore.swift`, `apps/ios/…/SwiftDataModels.swift` |
| 4 | `insertItem` uses `ON CONFLICT (id) DO NOTHING` and re-reads the winner, returning `{ row, replayed }`; the route answers `200` + `X-Idempotent-Replay: true` on a replay instead of `201` | `server/src/services/items.ts`, `server/src/routes/items.ts` |

### Before / after measurement (actual runs, 100 runs each)

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

**Duplicates in 100 seeded runs: 39 before, 0 after.** The server-side row count
drops from 169 to exactly 100. The fault injection is byte-for-byte identical on
both sides (308 dropped responses), so the difference is the fix and nothing else.

### Regression tests (fail against the pre-fix revision)

`ShelfCaseKit/Tests/ShelfCaseKitTests/RegressionTests.swift`:

| Test | Fails before with |
|------|-------------------|
| `lostResponseAcrossSyncPassesDoesNotDuplicate` | `itemRowsInserted == 1` → **2**; `itemCount() == 1` → **2**; `stored.id == item.id` → **false** |
| `idempotencyKeyIsStableAcrossSyncPasses` | `Set(keys).count == 1` → **2 distinct keys** |

`server/test/regression.test.ts` — all 6 fail before, with
`expected 200 "OK", got 500 "Internal Server Error"`:

```
BEFORE: Tests  6 failed (6)
AFTER:  Tests  6 passed (6)
```

---

## Defect B — deletes never reach the device (lost tombstones)

### Symptom

A row deleted on another device (or on the web) stays in the phone's collection
forever. Worse, the ghost row is still `synced` from the client's point of view, so
the next time the user edits it, the client happily pushes it back up.

### Deterministic reproduction

```bash
./scripts/repro.sh --runs 100          # section "DEFECT B"
```

No faults needed — this one is a pure logic bug, which is why it survived the
offline-first work: the flakiness scenarios all exercised *writes*, and the delete
path was never asserted end to end.

Shape per run: four items are created and synced; half of them are then deleted
directly on the server; the client comes back online and syncs once.

### Instrumented trace

From `ShelfCaseSyncSoak --scenario tombstones --runs 1 --trace`:

```
2026-10-16T07:37:35.437Z INFO [sync-c42e2fbe] pull.page page=1 since=root rows=4 applied=4 tombstones=0 nextCursor=1970-01-01T00:00:00.000Z|4
2026-10-16T07:37:35.438Z INFO [sync-c42e2fbe] sync.end pulled=4 pushed=4 tombstonesApplied=0 cursor=1970-01-01T00:00:00.000Z|4
   … server deletes two rows …
2026-10-16T07:37:35.439Z INFO [sync-3e91de30] pull.tombstone itemId=26affd6c-8388-441e-b272-89a83e289650 serverVersion=2
2026-10-16T07:37:35.439Z INFO [sync-3e91de30] pull.tombstone itemId=53ba43f1-8836-4b15-a529-464da37f184c serverVersion=2
2026-10-16T07:37:35.439Z INFO [sync-3e91de30] pull.page page=1 since=1970-01-01T00:00:00.000Z|4 rows=2 applied=0 tombstones=2 nextCursor=1970-01-01T00:00:00.000Z|6
2026-10-16T07:37:35.439Z INFO [sync-3e91de30] sync.end pulled=0 pushed=0 tombstonesApplied=2 cursor=1970-01-01T00:00:00.000Z|6
```

Before the fix the same page logged `rows=2 applied=0 tombstones=0` and then
`sync.end … skipped=2`, and the cursor still advanced to `…|6` — the deletes were
both ignored *and* stepped over.

Corroborating symptom from the 200-cycle soak recorded in Step 3
(`docs/RESULTS.md`), which was the run that first surfaced this:

```
sync duration p50: 187 ms   p95: 723 ms   (n=201)
live items   — local: 19   server: 12
ghost rows (deleted on the server, still live locally): 7
divergence: live items -7 (server − local), checksum MISMATCH
```

### Root cause

`SyncEngine.pull` treated a tombstone as "not a row to display" and moved on:

```swift
for item in page.items {
    if item.isDeleted {
        report.skipped += 1
        continue          // ← the delete is dropped on the floor
    }
    try await store.applyServerChange(item)
    …
}
// …and then the cursor advances past it
since = page.nextCursor
try await store.setCursor(page.nextCursor)
```

A tombstone is not a row to *show*, but it is absolutely a change the client has to
*absorb*. Because the cursor advanced anyway, the delta was consumed exactly once
and the delete could never be re-delivered: the client's copy stayed live forever,
and any later local edit would push it back to the server as a resurrection. The
same flaw meant `SyncReport` had no way to report tombstones at all, so nothing
about this was visible in telemetry.

### Fix

| # | Change | File |
|---|--------|------|
| 1 | `pull` applies tombstones like any other change and counts them separately in `SyncReport.tombstonesApplied` | `Sync/SyncEngine.swift` |
| 2 | `InMemoryLocalStore.applyServerChange` no longer clobbers a row with unpushed local changes — except for a tombstone, which always wins | `Storage/LocalStore.swift` |

Change 2 was found while writing the regression test for change 1 (see "Issue C").

### Before / after measurement (actual runs, 100 runs each)

```
BEFORE (baseline ba7c9b3):
    deletes performed on the server: 200
    deletes that never reached the client: 200  [100.0%]
    runs affected: 100 / 100
    rows still believed live locally (resurrection risk): 200

AFTER (working tree):
    deletes performed on the server: 200
    deletes that never reached the client: 0  [0.0%]
    runs affected: 0 / 100
    rows still believed live locally (resurrection risk): 0
```

**Deletes lost in 100 seeded runs: 200 of 200 before, 0 of 200 after.**

End-to-end effect on the 200-cycle soak (seed `20261016`):

| Metric | Before | After |
|--------|-------:|------:|
| Ghost rows (deleted server-side, still live locally) | 7 | **0** |
| Local vs server checksum | MISMATCH | **MATCH** |
| Live items, local vs server | 19 vs 12 | 20 vs 20 |

### Regression tests (fail against the pre-fix revision)

`ShelfCaseKit/Tests/ShelfCaseKitTests/RegressionTests.swift`:

| Test | Fails before with |
|------|-------------------|
| `tombstoneIsAppliedToLocalStore` | `local.isDeleted == true` → **false** |
| `deleteIsNotResurrectedByALocalEdit` | `live.isEmpty` → **false** (the ghost is still in the collection) |

`tombstoneDoesNotTriggerAPush` passes on both sides — it is a guard, not a
regression detector, and is kept so the fix cannot regress into "delete locally and
push the tombstone back up".

---

## Issue C — the two `LocalStore` implementations disagreed on pull semantics

Found while writing the Defect B regression test: the test asserted the outbox
still held the change after a failed pass, and it did not.

**Cause.** `InMemoryLocalStore.applyServerChange` was `items[item.id] = item` — a
blind overwrite. `SwiftDataLocalStore.applyServerChange` correctly refused to
clobber a row that still had unpushed local changes. So the in-memory store (used
by the soak harness and the whole `ShelfCaseKit` suite) would silently discard a
user's offline edit the moment a stale server copy arrived on a pull, while the
real app would not. The harness was therefore *more* forgiving than production, in
the one place where it mattered.

**Fix.** Both stores now share one rule: a pulled row never overwrites a row with
unpushed local changes; the conflict path resolves that. The single exception is a
tombstone, which always wins because the row no longer exists server-side.

**Why it is in this document.** It changes the behaviour the Defect A and B
measurements observe, so it is stated explicitly rather than folded silently into
the "after" column. The pre-fix column is unaffected: it is produced from the tag,
where this code does not exist.

---

## Summary of measured before/after

From the final `./scripts/repro.sh --runs 100`:

```
  runs with duplicate server rows (of 100)       before:       39 / 100   after:        0 / 100
  server rows created (expected 100)             before:            169   after:            100
  deletes lost on the delta pull                 before:            200   after:              0
  Kit regression test methods failing            before:              4   after:              0
  server regression tests failing                before:              6   after:              0
```
