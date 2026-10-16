#!/usr/bin/env bash
#
# Reproduces the two defects documented in docs/DEBUGGING.md and prints the
# measured before/after numbers.
#
#   ./scripts/repro.sh                # 100 runs per scenario
#   ./scripts/repro.sh --runs 250
#   ./scripts/repro.sh --skip-baseline   # "after" numbers only
#
# HOW THE "BEFORE" COLUMN IS PRODUCED
# -----------------------------------
# The pre-fix code is not simulated. It is checked out from git at the tag
# `baseline/pre-step5` (the commit that landed Step 4, before any Step 5 change)
# into a throwaway `git worktree`, the *same* regression tests are copied in, and
# everything is rebuilt and re-run there. If the tag is missing, the script says
# so and prints the "after" column only — it never invents a "before" number.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE_TAG="${BASELINE_TAG:-baseline/pre-step5}"
RUNS=100
SKIP_BASELINE=0
WORKTREE="${REPRO_WORKTREE:-${TMPDIR:-/tmp}/shelfcase-repro-baseline}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="$2"; shift 2 ;;
    --skip-baseline) SKIP_BASELINE=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

rule() { printf '\n%s\n' "----------------------------------------------------------------"; }
section() { rule; printf '== %s\n' "$1"; rule; }

cleanup() {
  if [[ -d "$WORKTREE" ]]; then
    git -C "$REPO_ROOT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || rm -rf "$WORKTREE"
  fi
}
trap cleanup EXIT

# --------------------------------------------------------------- baseline ---
BASELINE_READY=0
setup_baseline() {
  [[ "$SKIP_BASELINE" == "1" ]] && return
  if ! git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/${BASELINE_TAG}" >/dev/null; then
    echo "!! git tag '${BASELINE_TAG}' not found — printing the AFTER column only."
    echo "   (the tag is created by the Step 5 commit; see docs/DEBUGGING.md)"
    return
  fi

  rm -rf "$WORKTREE"
  git -C "$REPO_ROOT" worktree add --detach "$WORKTREE" "$BASELINE_TAG" >/dev/null 2>&1 || {
    echo "!! could not create a worktree at $WORKTREE"; return; }

  # Reuse the already-installed dependencies instead of a fresh npm ci.
  ln -sfn "$REPO_ROOT/server/node_modules" "$WORKTREE/server/node_modules"
  [[ -f "$REPO_ROOT/server/.env" ]] && cp "$REPO_ROOT/server/.env" "$WORKTREE/server/.env"

  # Drop today's regression tests into the old tree. They are written against the
  # pre-fix public API on purpose, so they compile there unchanged.
  cp "$REPO_ROOT/ShelfCaseKit/Tests/ShelfCaseKitTests/RegressionTests.swift" \
     "$WORKTREE/ShelfCaseKit/Tests/ShelfCaseKitTests/"
  cp "$REPO_ROOT/server/test/regression.test.ts" "$WORKTREE/server/test/"

  BASELINE_READY=1
}

# ------------------------------------------------------------------- kit ---
run_kit_regression() {
  local where="$1" label="$2"
  local log="/tmp/repro-kit-${label}.log"
  ( cd "$where" && ./scripts/swift-test.sh 2>&1 ) > "$log" 2>&1
  local passed failed
  passed=$(grep -c '✔ Test "' "$log" 2>/dev/null | head -1)
  failed=$(grep -c '✘ Test ".*" failed after' "$log" 2>/dev/null | head -1)
  passed=${passed:-0}; failed=${failed:-0}
  {
    echo ""
    echo "failing test methods: $failed"
    echo "passing test methods: $passed"
    grep -o '✘ Test "[^"]*" failed after' "$log" 2>/dev/null \
      | sed 's/✘ Test "//; s/" failed after//' | sort -u | sed 's/^/FAIL: /'
  } >> "$log"
  echo "  ShelfCaseKit tests passed: $passed   failing test methods: $failed"
  grep '^FAIL: ' "$log" | sed 's/^/    /'
}

# ---------------------------------------------------------------- server ---
run_server_regression() {
  local where="$1" label="$2"
  ( cd "$where/server" && npx vitest run test/regression.test.ts 2>&1 ) > /tmp/repro-server-"$label".log 2>&1
  local summary
  summary=$(grep -E "^ +Tests +" /tmp/repro-server-"$label".log | tail -1)
  echo "  server regression:${summary:- (no summary)}"
  grep -E "^ +→ " /tmp/repro-server-"$label".log | sort -u | sed 's/^/    /' | head -4
}

# Real HTTP against both revisions, to show the exact status codes.
run_http_demo() {
  local where="$1" port="$2" label="$3"
  ( cd "$where/server" && set -a && source .env && set +a && \
    PORT="$port" LOG_LEVEL=info npx tsx src/server.ts > /tmp/repro-http-"$label".log 2>&1 & )

  for _ in $(seq 1 40); do
    curl -fsS "http://localhost:${port}/health" >/dev/null 2>&1 && break
    sleep 0.5
  done

  local id first second
  id=$(uuidgen | tr 'A-Z' 'a-z')
  first=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:${port}/items" \
    -H "Authorization: Bearer dev-alice" -H "Content-Type: application/json" \
    -H "Idempotency-Key: repro-a-${id}" -H "X-Request-Id: repro-${label}-1" \
    -d "{\"id\":\"${id}\",\"title\":\"Repro Card\",\"estimatedValueCents\":12000}")
  second=$(curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:${port}/items" \
    -H "Authorization: Bearer dev-alice" -H "Content-Type: application/json" \
    -H "Idempotency-Key: repro-b-${id}" -H "X-Request-Id: repro-${label}-2" \
    -d "{\"id\":\"${id}\",\"title\":\"Repro Card\",\"estimatedValueCents\":12000}")

  local rows
  rows=$(docker exec shelfcase-postgres psql -U shelfcase -d shelfcase -tAc \
    "select count(*) from items where id='${id}'" 2>/dev/null | tr -d '[:space:]')

  echo "  POST #1 (fresh)                -> HTTP ${first}"
  echo "  POST #2 (retry, new key, same id) -> HTTP ${second}"
  echo "  rows in items for that id      -> ${rows:-?}"
  grep -E "unhandled_error" /tmp/repro-http-"$label".log | tail -1 | sed 's/^/    /'

  pkill -f "tsx src/server.ts" >/dev/null 2>&1
  sleep 1
}

# ------------------------------------------------------------------ soak ---
build_soak() {
  ( cd "$1/ShelfCaseKit" && swift build -c release --product ShelfCaseSyncSoak 2>&1 | tail -1 )
}

run_soak() {
  local where="$1" scenario="$2"
  "$where/ShelfCaseKit/.build/release/ShelfCaseSyncSoak" --scenario "$scenario" --runs "$RUNS" \
    --seed 20261016 2>&1
}

report_soak() {
  local file="$1" pattern="$2"
  grep -E "$pattern" "$file" | sed 's/^/    /'
}

# ==========================================================================

echo "ShelfCase reproduction harness"
echo "  runs per scenario: $RUNS"
echo "  baseline tag:      $BASELINE_TAG"

setup_baseline

# ---------------------------------------------------------------- SOAK A ---
section "DEFECT A — duplicate item creation after a lost POST response"

if [[ "$BASELINE_READY" == "1" ]]; then
  echo ">> building the PRE-FIX harness…"
  build_soak "$WORKTREE" >/dev/null
  run_soak "$WORKTREE" duplicates > /tmp/repro-dup-before.txt 2>&1
  echo "BEFORE (baseline ${BASELINE_TAG}):"
  report_soak /tmp/repro-dup-before.txt "runs ending with MORE THAN|server rows:|dropped responses"
else
  echo "BEFORE: unavailable (no baseline tag)"
fi

echo
echo ">> building the CURRENT harness…"
build_soak "$REPO_ROOT" >/dev/null
run_soak "$REPO_ROOT" duplicates > /tmp/repro-dup-after.txt 2>&1
echo "AFTER (working tree):"
report_soak /tmp/repro-dup-after.txt "runs ending with MORE THAN|server rows:|dropped responses"

# ---------------------------------------------------------------- SOAK B ---
section "DEFECT B — tombstones lost on the delta pull"

if [[ "$BASELINE_READY" == "1" ]]; then
  run_soak "$WORKTREE" tombstones > /tmp/repro-tomb-before.txt 2>&1
  echo "BEFORE (baseline ${BASELINE_TAG}):"
  report_soak /tmp/repro-tomb-before.txt "deletes that never reached|deletes performed|rows still believed"
fi

echo
run_soak "$REPO_ROOT" tombstones > /tmp/repro-tomb-after.txt 2>&1
echo "AFTER (working tree):"
report_soak /tmp/repro-tomb-after.txt "deletes that never reached|deletes performed|rows still believed"

# ------------------------------------------------------- REGRESSION TESTS ---
section "REGRESSION TESTS — ShelfCaseKit"

if [[ "$BASELINE_READY" == "1" ]]; then
  echo "BEFORE (baseline ${BASELINE_TAG}):"
  run_kit_regression "$WORKTREE" before
  echo
fi
echo "AFTER (working tree):"
run_kit_regression "$REPO_ROOT" after

section "REGRESSION TESTS — server"
if [[ "$BASELINE_READY" == "1" ]]; then
  echo "BEFORE (baseline ${BASELINE_TAG}):"
  run_server_regression "$WORKTREE" before
  echo
fi
echo "AFTER (working tree):"
run_server_regression "$REPO_ROOT" after

# ------------------------------------------------------------- REAL HTTP ---
if docker info >/dev/null 2>&1 && docker exec shelfcase-postgres pg_isready -U shelfcase >/dev/null 2>&1; then
  section "REAL HTTP — POST /items twice with the same client id"
  if [[ "$BASELINE_READY" == "1" ]]; then
    echo "BEFORE (baseline ${BASELINE_TAG}):"
    run_http_demo "$WORKTREE" 4402 baseline
    echo
  fi
  echo "AFTER (working tree):"
  run_http_demo "$REPO_ROOT" 4401 fixed
else
  section "REAL HTTP — skipped (PostgreSQL container not reachable)"
  echo "  start it with: docker compose up -d"
fi

# ---------------------------------------------------------------- SUMMARY ---
section "SUMMARY"
python3 - "$RUNS" <<'PY'
import re, sys, pathlib

runs = sys.argv[1]

def grab(path, pattern):
    try:
        text = pathlib.Path(path).read_text()
    except OSError:
        return None
    match = re.search(pattern, text)
    return match.group(1).strip() if match else None

def line(label, before, after):
    print(f"  {label:<46} before: {str(before):>14}   after: {str(after):>14}")

line(
    "runs with duplicate server rows (of %s)" % runs,
    grab("/tmp/repro-dup-before.txt", r"MORE THAN ONE server row: (\d+ / \d+)"),
    grab("/tmp/repro-dup-after.txt", r"MORE THAN ONE server row: (\d+ / \d+)"),
)
line(
    "server rows created (expected %s)" % runs,
    grab("/tmp/repro-dup-before.txt", r"server rows: (\d+)"),
    grab("/tmp/repro-dup-after.txt", r"server rows: (\d+)"),
)
line(
    "deletes lost on the delta pull",
    grab("/tmp/repro-tomb-before.txt", r"never reached the client: (\d+)"),
    grab("/tmp/repro-tomb-after.txt", r"never reached the client: (\d+)"),
)
def failing(path, pattern_failed, pattern_passed):
    """Return the number of failing tests, 0 when the suite reported none."""
    try:
        text = pathlib.Path(path).read_text()
    except OSError:
        return None
    failed = re.search(pattern_failed, text)
    if failed:
        return failed.group(1).strip()
    passed = re.search(pattern_passed, text)
    return "0" if passed else None

line(
    "Kit regression test methods failing",
    grab("/tmp/repro-kit-before.log", r"failing test methods: (\d+)"),
    grab("/tmp/repro-kit-after.log", r"failing test methods: (\d+)"),
)
line(
    "server regression tests failing",
    failing("/tmp/repro-server-before.log", r"Tests\s+(\d+) failed", r"Tests\s+(\d+) passed"),
    failing("/tmp/repro-server-after.log", r"Tests\s+(\d+) failed", r"Tests\s+(\d+) passed"),
)
PY
echo
echo "raw logs: /tmp/repro-*.txt, /tmp/repro-*.log"
