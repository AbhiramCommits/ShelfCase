# DEBUGGING — instrumented bug investigations

This document records real, reproducible defects found under flaky-network and
device-class conditions, with measurements taken from actual runs.

> **Status: IN PROGRESS.** Step 1 established the harness hooks this document
> depends on (`FaultInjectingAPIClient`, telemetry JSONL, `scripts/repro.sh`).
> Full write-ups for both defects land in Step 5.

Planned investigations:

| # | Defect | Class | Repro tool |
|---|--------|-------|------------|
| a | Duplicate item creation when a `POST /items` response is lost after the server commits | Lost response + retry | `FaultInjectingAPIClient` `dropResponse` rate, `scripts/repro.sh duplication` |
| b | *(to be confirmed by measurement)* — candidate: delta-sync cursor regression losing tombstones | Cursor/ordering | `FaultInjectingAPIClient` out-of-order + `scripts/repro.sh cursor` |

Each entry will carry: symptom, deterministic reproduction (seed, fault rates,
NLC profile), instrumented trace (real log lines with request ids and retry
counts), root cause, fix, before/after measurement, and regression tests in both
`ShelfCaseKit` and `server/test`.
