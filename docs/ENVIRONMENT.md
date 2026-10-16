# ENVIRONMENT — verified tooling on this machine

Captured: 2026-10-15 (macOS 27.0.1, Apple silicon `arm64`, Apple M2).

## Raw version output

```
$ uname -a
Darwin Abhirams-MacBook-Air.local 27.0.0 Darwin Kernel Version 27.0.0: Tue Aug 11 21:05:41 PDT 2026; root:xnu-13432.1.9~1/RELEASE_ARM64_T8122 arm64

$ sw_vers
ProductName:		macOS
ProductVersion:		27.0.1
BuildVersion:		26A434

$ swift --version
swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)
Target: arm64-apple-macosx27.0.0

$ xcodebuild -version
xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance

$ xcode-select -p
/Library/Developer/CommandLineTools

$ node --version
v25.8.1

$ npm --version
11.11.0

$ psql --version
psql (PostgreSQL) 16.15 (Homebrew)

$ docker --version
Docker version 29.8.2, build 7fc2dff

$ docker compose version
Docker Compose version v5.6.0

$ xcodegen --version
Version: 2.46.0

$ brew --version
Homebrew 7.0.9

$ git --version
git version 2.54.0 (Apple Git-157)
```

## Tool availability summary

| Tool | Status | Notes |
|------|--------|-------|
| Swift toolchain | ✅ 6.4 | CLT toolchain, `arm64-apple-macosx27.0.0` |
| `xcodegen` | ✅ 2.46.0 | Installed during setup via `brew install xcodegen` |
| Node.js / npm | ✅ v25.8.1 / 11.11.0 | |
| PostgreSQL client | ✅ 16.15 | Homebrew; server provided by Docker |
| Docker + Compose | ✅ 29.8.2 / v5.6.0 | Daemon running; used for `postgres:16` |
| Homebrew | ✅ 7.0.9 | |
| **Xcode (full IDE)** | ❌ **not installed** | Only `/Library/Developer/CommandLineTools` |
| **`xcodebuild`** | ❌ fails | Requires full Xcode |
| **iOS Simulator** | ⚠️ `CoreSimulator` present, **no runtimes usable without Xcode** | `xcrun simctl` cannot boot a device without an Xcode-supplied runtime |

## What that means for this repository

### ✅ Verified to run on this machine

| Command | Verified |
|---------|----------|
| `./scripts/swift-test.sh` (→ `swift test` on `ShelfCaseKit`) | ✅ Step 1 — 21 tests, all passing |
| `swift build` (ShelfCaseKit, macOS 14 target) | ✅ |
| `docker compose up -d` / `psql` against `localhost:55432` | ✅ |
| `npm ci`, `npm run lint`, `npm test` (server) | ✅ Steps 2 & 6 |
| `scripts/sync-soak.sh`, `scripts/repro.sh` | ✅ Steps 3 & 5 |
| `xcodegen generate` | ✅ generates `ShelfCase.xcodeproj` with no errors |

### ❌ Cannot run on this machine (documented, not faked)

| Command | Blocker |
|---------|---------|
| `xcodebuild -project ShelfCase.xcodeproj -scheme ShelfCase -destination 'platform=iOS Simulator,name=iPhone 15' build` | No full Xcode |
| `xcodebuild -scheme ShelfCase -destination 'generic/platform=iOS' build` | No full Xcode |
| `xcodebuild archive` / `-exportArchive` (`scripts/release.sh`) | No full Xcode, no signing identity |
| App-target XCTest/XCUITest, `simctl` screenshots | No Xcode + no simulator runtime |

**Nothing in `docs/RESULTS.md` or `README.md` reports a result for any command in
the second table.** Where an iOS build is discussed, the README states it was
generated and reviewed but not compiled here, and that CI on `macos-14` performs
the real build.

### Swift Testing vs XCTest — an important deviation

The stack request names **XCTest**. This machine has **Command Line Tools only**,
and Apple's CLT no longer ships `XCTest.framework`; it ships `Testing.framework`
(Swift Testing) instead:

```
$ ls /Library/Developer/CommandLineTools/Library/Developer/Frameworks/
Testing.framework      _Testing_AppKit.framework        _Testing_CoreImage.framework
_Testing_CoreGraphics.framework  _Testing_CoreTransferable.framework
_Testing_Foundation.framework    _Testing_UIKit.framework

$ find /Library/Developer -maxdepth 6 -iname "XCTest.framework"
(no results)
```

So `import XCTest` cannot compile here — it fails with
`unable to resolve module dependency: 'XCTest'`. Rather than ship tests that
cannot run (and therefore produce no real numbers), **all `ShelfCaseKit` tests
are written with Swift Testing** (`import Testing`, `@Test`, `#expect`), which
runs under the same `swift test` command and is the framework Apple ships for
the Swift 6 toolchain. The suites, coverage and assertions are equivalent; only
the assertion macro differs.

On CI (`macos-14` runners) full Xcode is present, so XCTest *and* Swift Testing
both work there — CI runs the same `swift test` invocation.

### Second CLT quirk: Swift Testing macro plugin path

`swift test` alone fails on this machine even for Swift Testing:

```
error: external macro implementation type 'TestingMacros.TestDeclarationMacro'
could not be found for macro 'Test'; plugin for module 'TestingMacros' not found
```

because the CLT installs the plugin one directory deeper than the driver scans:

```
$ ls /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/
libObservationMacros.dylib   libSwiftMacros.dylib   testing/
$ ls /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/
libTestingMacros.dylib
```

`scripts/swift-test.sh` detects the plugin directory and forwards it as
`-Xswiftc -plugin-path <dir>`, which makes `swift test` succeed. On a machine
with full Xcode the script skips the flag. **Always use `./scripts/swift-test.sh`
rather than bare `swift test` locally.**
