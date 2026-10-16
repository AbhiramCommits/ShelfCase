#!/usr/bin/env bash
#
# Repeatable sync soak harness.
#
# Drives the real ShelfCaseKit SyncEngine + URLSessionAPIClient against an
# in-process server over a seeded, fault-injecting transport. Every number it
# prints is reproducible from the seed.
#
# Usage:
#   scripts/sync-soak.sh                 # 200 randomised offline/online cycles
#   scripts/sync-soak.sh --cycles 50
#   scripts/sync-soak.sh --scenario duplicates --runs 100
#   scripts/sync-soak.sh --scenario tombstones --runs 100
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIT_DIR="$REPO_ROOT/ShelfCaseKit"
CONFIGURATION="${CONFIGURATION:-release}"

cd "$KIT_DIR"

echo "==> building ShelfCaseSyncSoak ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product ShelfCaseSyncSoak >/dev/null

BINARY="$KIT_DIR/.build/$CONFIGURATION/ShelfCaseSyncSoak"
if [[ ! -x "$BINARY" ]]; then
  echo "!! expected binary at $BINARY" >&2
  exit 1
fi

if [[ $# -eq 0 ]]; then
  set -- --scenario soak --cycles 200 --seed 20261016
fi

echo "==> $BINARY $*"
echo
exec "$BINARY" "$@"
