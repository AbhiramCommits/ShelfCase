# Architecture Decision Notes

Short, additive notes. Each records the decision, the alternatives considered
and the consequences. Full investigations live in `docs/DEBUGGING.md`.

---

## ADR-001 — Test framework: Swift Testing instead of XCTest

**Date:** 2026-10-15
**Status:** Accepted (environment-forced)

**Context.** The project brief specifies XCTest. The build machine has Command
Line Tools only — no full Xcode. Apple's CLT no longer ships `XCTest.framework`
and instead ships `Testing.framework` (Swift Testing). `import XCTest` fails to
resolve, so any XCTest suite would compile nowhere and produce zero real numbers.

**Decision.** Write `ShelfCaseKit` tests with Swift Testing (`import Testing`,
`@Test`, `#expect`, `@Suite`). Keep the same coverage: valuation maths, portfolio
totals, Codable round-trips and the full sync/conflict suite.

**Consequences.**

* `swift test` genuinely runs here and its output is recorded in
  `docs/RESULTS.md`; no result is fabricated.
* CI on `macos-14` has full Xcode, so both frameworks are available there; the
  same `swift test` invocation works unchanged.
* A second CLT quirk requires `-Xswiftc -plugin-path …/host/plugins/testing`
  for the Swift Testing macro plugin. `scripts/swift-test.sh` encapsulates this
  so callers never need to know.

---

## ADR-002 — Dates on the wire are millisecond ISO8601

**Date:** 2026-10-15
**Status:** Accepted

**Context.** A round-trip test failed: `Date` has sub-millisecond resolution, but
`ISO8601DateFormatter` with `[.withInternetDateTime]` truncates to whole seconds.

**Decision.** Encode with `[.withInternetDateTime, .withFractionalSeconds]`
(three decimal places). Decoding accepts both the fractional and non-fractional
forms so older/other clients keep working.

**Consequences.**

* Round-trips are stable, and `updatedAt`-based last-writer-wins can distinguish
  two edits inside the same second.
* Timestamps are compared at millisecond granularity; tests must build dates that
  are already millisecond-aligned.

---

## ADR-003 — PostgreSQL 16 on port 55432, provided by Docker Compose

**Date:** 2026-10-15
**Status:** Accepted

**Context.** A system Homebrew PostgreSQL may already occupy 5432.

**Decision.** Run `postgres:16` via `docker compose` bound to **host port 55432**,
database/user/password all `shelfcase`, with a named volume and a healthcheck.

**Consequences.**

* No collision with a locally installed Postgres.
* Tests use a *separate* database (`shelfcase_test`) created and dropped per run by
  `scripts/test-db.sh`, so the dev database survives test runs.
