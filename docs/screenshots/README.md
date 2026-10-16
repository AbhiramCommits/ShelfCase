# Screenshots

**No screenshots could be captured on this machine.** `xcodebuild` and
`xcrun simctl` both require a full Xcode installation, and this machine has only
`/Library/Developer/CommandLineTools`. See `docs/ENVIRONMENT.md`.

The commands that would produce them, once Xcode is installed:

```bash
cd apps/ios
xcodegen generate
xcodebuild -project ShelfCase.xcodeproj -scheme ShelfCase \
  -destination 'platform=iOS Simulator,name=iPhone 15' build

# Boot a simulator and run
xcrun simctl boot "iPhone 15"
open -a Simulator
xcrun simctl install booted "$(xcodebuild -project ShelfCase.xcodeproj -scheme ShelfCase \
  -destination 'platform=iOS Simulator,name=iPhone 15' -showBuildSettings \
  | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/ShelfCase.app"
xcrun simctl launch booted com.shelfcase.app

# Capture
xcrun simctl io booted screenshot docs/screenshots/01-collection.png
```

## Shot list

| File | Screen | What it should show |
|------|--------|---------------------|
| `01-collection.png` | `CollectionGridView` | Lazy grid of cards with thumbnails, grade chips and values; the offline banner visible with a non-zero queued-change count |
| `02-item-detail.png` | `ItemDetailView` | Photo, editable grade/notes, and a price-history sparkline |
| `03-portfolio.png` | `PortfolioView` | Total estimated value, cost, unrealised gain/loss and the per-category breakdown bars |
| `04-trades.png` | `TradesView` | An incoming proposal with Accept/Decline |
| `05-diagnostics.png` | `DiagnosticsView` | Sync report (pushed/pulled, retries, conflicts, cursor) and the conflict archive |

`DiagnosticsView` is the one to ask a tester for when they report a sync bug: it
shows the exact cursor, retry count and conflict decisions the engine made on
their device.
