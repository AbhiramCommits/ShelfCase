#!/usr/bin/env bash
#
# Archive and export ShelfCase for App Store / TestFlight distribution.
#
# Every step below is *executed* by this script. Steps that need credentials or
# a full Xcode installation are detected first and skipped with an explicit
# "SKIPPED (reason)" line — this script never pretends a step ran. See
# docs/TESTFLIGHT.md for the full runbook and for what must be done by hand.
#
# Usage:
#   scripts/release.sh                        # archive + export, fails if Xcode is missing
#   scripts/release.sh --dry-run              # print the plan and every preflight result
#   scripts/release.sh --bump build           # increment CURRENT_PROJECT_VERSION first
#   scripts/release.sh --bump patch           # increment MARKETING_VERSION (patch component)
#   scripts/release.sh --upload               # also run `xcrun altool --upload-app`
#
# Environment (see docs/TESTFLIGHT.md):
#   DEVELOPMENT_TEAM      Apple Developer team id             (required to archive)
#   EXPORT_METHOD         app-store | ad-hoc | development    (default: app-store)
#   ASC_KEY_ID            App Store Connect API key id        (required to upload)
#   ASC_ISSUER_ID         App Store Connect issuer id         (required to upload)
#   ASC_KEY_PATH          path to AuthKey_<id>.p8             (required to upload)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_DIR="$REPO_ROOT/apps/ios"
BUILD_DIR="$IOS_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/ShelfCase.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$IOS_DIR/ExportOptions.plist"
SCHEME="ShelfCase"
PROJECT="$IOS_DIR/ShelfCase.xcodeproj"
BUNDLE_ID="com.shelfcase.app"

DRY_RUN=0
BUMP=""
UPLOAD=0
EXPORT_METHOD="${EXPORT_METHOD:-app-store}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --bump) BUMP="$2"; shift 2 ;;
    --upload) UPLOAD=1; shift ;;
    --export-method) EXPORT_METHOD="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

step()  { printf '\n\033[1m== %s\033[0m\n' "$1"; }
ok()    { printf '  ✔ %s\n' "$1"; }
skip()  { printf '  ⊘ SKIPPED (%s)\n' "$1"; }
fail()  { printf '  ✘ %s\n' "$1"; }

# --------------------------------------------------------------- preflight ---
step "Preflight"

command -v xcodebuild >/dev/null 2>&1
if xcodebuild -version >/dev/null 2>&1; then
  ok "Xcode: $(xcodebuild -version | head -1)"
else
  fail "xcodebuild is not available — full Xcode is required and is not installed"
  echo "     xcode-select -p -> $(xcode-select -p 2>/dev/null || echo 'unknown')"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "     (dry run: continuing to print the plan)"
  else
    echo
    echo "Nothing to do: archiving is impossible without Xcode. Re-run with --dry-run"
    echo "to see the full plan, or install Xcode. See docs/ENVIRONMENT.md."
    exit 1
  fi
fi

command -v xcodegen >/dev/null 2>&1 && ok "xcodegen: $(xcodegen --version)" || fail "xcodegen not installed (brew install xcodegen)"

if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  ok "DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM}"
else
  fail "DEVELOPMENT_TEAM is not set — an archive cannot be signed"
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Distribution\|iPhone Distribution"; then
  ok "a distribution signing identity is present in the keychain"
else
  fail "no Apple Distribution identity in the keychain"
fi

if [[ "$UPLOAD" == "1" ]]; then
  for var in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do
    if [[ -n "${!var:-}" ]]; then ok "$var is set"; else fail "$var is required for --upload"; fi
  done
fi

# --------------------------------------------------------------- versioning ---
step "Version"

CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$IOS_DIR/ShelfCase/Info.plist" 2>/dev/null || echo "1.0.0")
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$IOS_DIR/ShelfCase/Info.plist" 2>/dev/null || echo "1")
echo "  MARKETING_VERSION=$CURRENT_VERSION  CURRENT_PROJECT_VERSION=$CURRENT_BUILD"

case "$BUMP" in
  build)
    NEXT_BUILD=$((CURRENT_BUILD + 1))
    ok "would bump CURRENT_PROJECT_VERSION $CURRENT_BUILD -> $NEXT_BUILD"
    if [[ "$DRY_RUN" != "1" ]]; then
      python3 - "$IOS_DIR/project.yml" "$NEXT_BUILD" <<'PY'
import re, sys, pathlib
path, next_build = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
text = re.sub(r'(CURRENT_PROJECT_VERSION: )"\d+"', rf'\g<1>"{next_build}"', text)
text = re.sub(r'(CFBundleVersion: )"\d+"', rf'\g<1>"{next_build}"', text)
path.write_text(text)
print(f"  wrote {path}")
PY
      touch "$IOS_DIR/ShelfCase/Info.plist"
      ok "bumped the build number in project.yml (regenerate before archiving)"
    fi
    ;;
  patch)
    IFS='.' read -r major minor patch <<< "$CURRENT_VERSION"
    NEXT_VERSION="$major.$minor.$((patch + 1))"
    ok "would bump MARKETING_VERSION $CURRENT_VERSION -> $NEXT_VERSION"
    if [[ "$DRY_RUN" != "1" ]]; then
      python3 - "$IOS_DIR/project.yml" "$NEXT_VERSION" <<'PY'
import re, sys, pathlib
path, next_version = pathlib.Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
text = re.sub(r'(MARKETING_VERSION: )"[^"]+"', rf'\g<1>"{next_version}"', text)
text = re.sub(r'(CFBundleShortVersionString: )"[^"]+"', rf'\g<1>"{next_version}"', text)
path.write_text(text)
print(f"  wrote {path}")
PY
      ok "bumped the marketing version in project.yml"
    fi
    ;;
  "") : ;;
  *) echo "  --bump accepts 'build' or 'patch'" >&2; exit 2 ;;
esac

# ------------------------------------------------------------------ xcodegen ---
step "Generate the Xcode project"
if command -v xcodegen >/dev/null 2>&1; then
  if ( cd "$IOS_DIR" && xcodegen generate ); then ok "ShelfCase.xcodeproj generated"; else fail "xcodegen failed"; fi
else
  skip "xcodegen not installed"
fi

# ------------------------------------------------------------------- archive ---
step "Archive"
echo "  xcodebuild archive \\"
echo "    -project $PROJECT \\"
echo "    -scheme $SCHEME \\"
echo "    -configuration Release \\"
echo "    -destination 'generic/platform=iOS' \\"
echo "    -archivePath $ARCHIVE_PATH \\"
echo "    DEVELOPMENT_TEAM=\${DEVELOPMENT_TEAM}"

if xcodebuild -version >/dev/null 2>&1 && [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
  if [[ "$DRY_RUN" == "1" ]]; then
    skip "dry run"
  else
    mkdir -p "$BUILD_DIR"
    if xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'generic/platform=iOS' \
        -archivePath "$ARCHIVE_PATH" \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"; then
      ok "archived to $ARCHIVE_PATH ($(du -sh "$ARCHIVE_PATH" 2>/dev/null | cut -f1))"
    else
      fail "xcodebuild archive failed — see the log above"
      exit 1
    fi
  fi
else
  skip "requires Xcode and DEVELOPMENT_TEAM"
fi

# --------------------------------------------------------------- export plist ---
step "ExportOptions.plist"
if [[ -f "$EXPORT_OPTIONS" ]]; then
  ok "using the committed $EXPORT_OPTIONS"
else
  fail "$EXPORT_OPTIONS is missing"
fi
echo "  method: $EXPORT_METHOD  teamID: ${DEVELOPMENT_TEAM:-<unset>}"

# -------------------------------------------------------------------- export ---
step "Export the .ipa"
echo "  xcodebuild -exportArchive -archivePath $ARCHIVE_PATH \\"
echo "    -exportOptionsPlist $EXPORT_OPTIONS -exportPath $EXPORT_DIR"

if [[ -d "$ARCHIVE_PATH" && -f "$EXPORT_OPTIONS" && "$DRY_RUN" != "1" ]]; then
  mkdir -p "$EXPORT_DIR"
  if xcodebuild -exportArchive \
      -archivePath "$ARCHIVE_PATH" \
      -exportOptionsPlist "$EXPORT_OPTIONS" \
      -exportPath "$EXPORT_DIR" \
      -allowProvisioningUpdates; then
    ok "exported: $(ls -1 "$EXPORT_DIR" 2>/dev/null | tr '\n' ' ')"
  else
    fail "xcodebuild -exportArchive failed"
    exit 1
  fi
else
  skip "no archive present (archive step must succeed first)"
fi

# -------------------------------------------------------------------- upload ---
step "Upload to App Store Connect"
if [[ "$UPLOAD" != "1" ]]; then
  skip "--upload not passed"
elif [[ "$DRY_RUN" == "1" ]]; then
  skip "dry run"
elif [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_PATH:-}" ]]; then
  IPA=$(find "$EXPORT_DIR" -name '*.ipa' -maxdepth 1 | head -1)
  if [[ -z "$IPA" ]]; then
    fail "no .ipa to upload"
  else
    echo "  xcrun altool --upload-app -f $IPA -t ios --apiKey \$ASC_KEY_ID --apiIssuer \$ASC_ISSUER_ID"
    if xcrun altool --upload-app \
        -f "$IPA" \
        -t ios \
        --apiKey "$ASC_KEY_ID" \
        --apiIssuer "$ASC_ISSUER_ID"; then
      ok "uploaded $(basename "$IPA") — processing usually takes 5–15 minutes"
    else
      fail "altool upload failed"
      exit 1
    fi
  fi
else
  skip "ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_PATH are not all set"
fi

# ------------------------------------------------------------------- symbol upload ---
step "dSYMs"
DSYM_DIR="$ARCHIVE_PATH/dSYMs"
if [[ -d "$DSYM_DIR" ]]; then
  ok "$(ls -1 "$DSYM_DIR" | wc -l | tr -d ' ') dSYM bundle(s) in the archive"
  echo "     upload with: xcrun altool --upload-app ... (or let Xcode's Organizer do it)"
else
  skip "no dSYMs (archive step did not run)"
fi

step "Done"
echo "  Archive: $ARCHIVE_PATH"
echo "  Export:  $EXPORT_DIR"
echo "  Bundle:  $BUNDLE_ID"
