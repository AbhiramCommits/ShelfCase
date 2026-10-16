#!/usr/bin/env bash
#
# Runs the ShelfCaseKit test suite.
#
# This machine has Command Line Tools only (no full Xcode), which supplies the
# bundled Swift Testing library but does not register its macro plugin
# (`libTestingMacros.dylib`) on the default compiler plugin search path. This
# wrapper locates the plugin and forwards it explicitly so `swift test` works
# everywhere: on CI with full Xcode the flag is simply omitted.
#
# Usage: scripts/swift-test.sh [extra swift test args...]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIT_DIR="$REPO_ROOT/ShelfCaseKit"

PLUGIN_CANDIDATES=(
  "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
  "$(xcode-select -p 2>/dev/null || true)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins"
)

PLUGIN_ARGS=()
for candidate in "${PLUGIN_CANDIDATES[@]}"; do
  if [[ -n "$candidate" && -d "$candidate" ]]; then
    PLUGIN_ARGS=(-Xswiftc -plugin-path -Xswiftc "$candidate")
    break
  fi
done

echo "==> swift test in $KIT_DIR"
if [[ ${#PLUGIN_ARGS[@]} -gt 0 ]]; then
  echo "==> using Swift Testing macro plugin path: ${PLUGIN_ARGS[2]}"
else
  echo "==> no explicit plugin path needed (full Xcode toolchain)"
fi

cd "$KIT_DIR"
exec swift test "${PLUGIN_ARGS[@]}" "$@"
