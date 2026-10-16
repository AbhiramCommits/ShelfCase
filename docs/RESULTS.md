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
