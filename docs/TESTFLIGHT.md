# TESTFLIGHT — release pipeline

`scripts/release.sh` executes the archive/export/upload steps. It prints
`✔` for a step that ran, `⊘ SKIPPED (reason)` for one that could not, and `✘`
for a preflight failure. It never reports a step it did not perform.

## Status on the machine this repository was built on

| Step | Status here | Why |
|------|-------------|-----|
| `xcodegen generate` | ✅ executed | XcodeGen 2.46.0 installed |
| `xcodebuild archive` | ⊘ skipped | no full Xcode (`xcodebuild` requires Xcode; only Command Line Tools are installed) |
| `xcodebuild -exportArchive` | ⊘ skipped | depends on the archive |
| `xcrun altool --upload-app` | ⊘ skipped | no archive, and no App Store Connect key |
| dSYM upload | ⊘ skipped | no archive |
| Simulator screenshots | ⊘ skipped | no Xcode, no simulator runtime |

The real archive/export/upload run is performed by CI on `macos-14`, which has
full Xcode — except the upload, which additionally needs App Store Connect
credentials and is therefore gated behind `--upload`.

## Identity

| Field | Value |
|-------|-------|
| Bundle id | `com.shelfcase.app` |
| Test bundle id | `com.shelfcase.app.tests` |
| Scheme | `ShelfCase` |
| SKU (suggested) | `shelfcase-ios` |
| Primary language | English (US) |
| Team | set via `DEVELOPMENT_TEAM`; no team id is committed |

## Version and build numbers

Two numbers, both in `apps/ios/project.yml`, which XcodeGen copies into the
generated `Info.plist`:

| Key | `project.yml` | Meaning |
|-----|---------------|---------|
| `MARKETING_VERSION` | `1.0.0` | user-visible version |
| `CURRENT_PROJECT_VERSION` | `1` | build number, must strictly increase per upload |

```bash
scripts/release.sh --bump build     # 1 -> 2
scripts/release.sh --bump patch     # 1.0.0 -> 1.0.1
```

`--bump` edits `project.yml`; you must `xcodegen generate` afterwards (the script
does that for you, but it is an explicit step in the runbook below). Never reuse a
build number for the same marketing version — App Store Connect rejects it.

## Runbook

```bash
# 0. one-time, in Xcode: sign in with the Apple ID that owns the team
export DEVELOPMENT_TEAM=ABCDE12345

# 1. bump the build number and regenerate
scripts/release.sh --bump build

# 2. archive + export
scripts/release.sh

# 3. upload (needs an App Store Connect API key)
export ASC_KEY_ID=XXXXXXXXXX
export ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000
export ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8
scripts/release.sh --upload
```

Alternatively, upload from Xcode's Organizer (Window ▸ Organizer ▸ Distribute
App) after step 2 — it does the same thing with a GUI.

### What `release.sh` does, in order

1. **Preflight** — `xcodebuild -version`, `xcodegen --version`, `DEVELOPMENT_TEAM`,
   `security find-identity -v -p codesigning` for an Apple Distribution
   certificate, and (for `--upload`) the three `ASC_*` variables.
2. **Version** — reads the current numbers out of `ShelfCase/Info.plist` and
   optionally bumps them.
3. **`xcodegen generate`** — regenerates `ShelfCase.xcodeproj` from `project.yml`.
4. **`xcodebuild archive`** — `-configuration Release`,
   `-destination 'generic/platform=iOS'`, `-allowProvisioningUpdates`.
5. **`xcodebuild -exportArchive`** — with the committed
   `apps/ios/ExportOptions.plist` (`method: app-store`, `destination: upload`,
   `signingStyle: automatic`, `uploadSymbols: true`).
6. **`xcrun altool --upload-app`** — only with `--upload`.
7. **dSYM report** — lists the dSYM bundles inside the archive so they can be
   checked before the build expires off TestFlight.

### TestFlight specifics

| Item | Setting |
|------|---------|
| Internal tester group | `ShelfCase Internal` — up to 100 members, no App Review needed, builds available within minutes |
| External tester group | `ShelfCase Beta` — needs a build for App Review (usually < 24 h for a first submission), up to 10 000 testers |
| Export compliance | declared in `project.yml` as `ITSAppUsesNonExemptEncryption: false`; the app uses only HTTPS/TLS, so no CCATS is required |
| What to tell testers | test offline: turn on Airplane Mode, catalogue three items, force-quit, turn the network back on, reopen. The banner should drain the queue and the Diagnostics tab should end at `Queued changes: 0`. |
| Feedback | ask for the Diagnostics tab screenshot — it carries the cursor, retry count and conflict decisions from the device that saw the problem |

## Instrumentation that ships in the build

| Surface | Where | What it captures |
|---------|-------|------------------|
| OSLog signposts | `Instrumentation/Telemetry.swift` (`com.shelfcase.app` subsystem, `telemetry` + `sync` categories) | sync interval with `durationMs`, `retries`, `conflicts` |
| Rotating JSONL | Application Support `ShelfCase/telemetry.jsonl`, rolls at 1 MiB into `telemetry.1.jsonl` | every event plus session id, device model, OS version and app version; survives an app kill |
| Crash-adjacent errors | `Telemetry.record(name:errorMessage:)` on the store-open, image-write, trade and sync failure paths | the error string, next to the event that was in flight |
| Server sink | `POST /telemetry` (Express, NDJSON append) | optional; the client only uploads when a base URL is configured |
| Diagnostics screen | `DiagnosticsView` | the same data, on-device, screenshot-friendly |

`Telemetry` deliberately does **not** attach a third-party crash reporter; adding
one (Crashlytics/Sentry) is a one-line change at the `AppEnvironment.start()`
call site, and the JSONL sink already provides the breadcrumb trail.

## Steps that require an Apple Developer account

These cannot be executed here and are documented, not run:

1. Creating the App Store Connect record and reserving the bundle id.
2. Creating the Apple Distribution certificate and the App Store provisioning
   profile (or letting `-allowProvisioningUpdates` create them).
3. Generating an App Store Connect API key (`.p8`) for `altool`, or signing in
   with an Apple ID in Xcode.
4. Registering an APNs key and attaching it to the app id — required for real
   pushes; the payload contract is in `docs/APNS.md`. The local-notification
   paths work without it.
5. Enrolling the app in TestFlight and inviting testers.
6. Answering App Review's export-compliance and content questions.
