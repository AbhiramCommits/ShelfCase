#!/usr/bin/env bash
#
# Syntax-checks every iOS app source without Xcode.
#
# WHY THIS EXISTS
# ---------------
# This machine has Command Line Tools only. Two things are therefore impossible
# here:
#   1. `xcodebuild` — the iOS SDK is not installed.
#   2. Type-checking the app at all — the CLT toolchain ships `Testing.framework`
#      but *not* `SwiftDataMacros`, so `@Model` cannot be expanded:
#        error: external macro implementation type
#        'SwiftDataMacros.PersistentModelMacro' could not be found for macro 'Model()'
#      (see docs/ENVIRONMENT.md).
#
# `swift-frontend -parse` needs no macro plugins and no SDK modules, so it still
# catches syntax errors, unbalanced braces, bad string interpolation and
# malformed declarations across every app source. That is a real check, and it is
# the strongest one available on this machine. Type-checking and building the app
# happen on CI (macos-14) and in Xcode.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_ROOT/apps/ios/ShelfCase"

SDK_PATH="${SDK_PATH:-$(xcrun --show-sdk-path --sdk macosx 2>/dev/null || true)}"
if [[ -z "$SDK_PATH" || ! -d "$SDK_PATH" ]]; then
  SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
  if [[ ! -d "$SDK_PATH" ]]; then
    SDK_PATH="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | tail -1)"
  fi
fi
if [[ -z "$SDK_PATH" || ! -d "$SDK_PATH" ]]; then
  echo "!! no macOS SDK found" >&2
  exit 1
fi

FILES=()
while IFS= read -r file; do FILES+=("$file"); done < <(find "$APP_DIR" -name "*.swift" | sort)

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "!! no Swift sources under $APP_DIR" >&2
  exit 1
fi

echo "==> swift-frontend -parse over ${#FILES[@]} app source file(s)"
echo "==> SDK: $SDK_PATH"
echo

swiftc -parse -sdk "$SDK_PATH" -target arm64-apple-macos14.0 "${FILES[@]}"

echo "✔ all ${#FILES[@]} app source file(s) parse cleanly"
