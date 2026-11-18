# Global Task Roster

Model for all workers: `acpRegistry_devin` / `swe-2-high` (`thought_level: "max"`, `mode: "accept-edits"`, `speed: "standard"`).
Maximum concurrent workers: `3`.

| Role | Title | Task ID | Thread Link | Base Commit | Output Commit | Status | Handoff / State Dir | Next Instruction |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `F0` | F0 — Foundation and shared contracts | `awr-f0-foundation-01` | [F0 thread](t3-thread://v2/59505559-2c07-4bec-b08d-645e76a9750b/thread:delegated-task:command%3Amcp%3Ae0bcbc84-724b-453a-8c40-226f5bf42b80%3Adelegate-task%3Aawr-f0-foundation-01) | `349d582` | `4e36a08` | Completed — parent-verified (build ×3, no test surface) | `F0-foundation/` | Done; baseline for Phase 1 |
| `C1` | C1 — Watch capture worker | `awr-c1-capture-01` | [C1 thread](t3-thread://v2/59505559-2c07-4bec-b08d-645e76a9750b/thread:delegated-task:command%3Amcp%3Ad8491e92-80be-484b-a0e7-c09c830b6868%3Adelegate-task%3Aawr-c1-capture-01) | `4e36a08` | Pending (uncommitted output) | Running (async) | `C1-watch-capture/` | Await completion wake |
| `A1` | A1 — Local Arabic AI worker | `awr-a1-arabic-ai-01` | [A1 thread](t3-thread://v2/59505559-2c07-4bec-b08d-645e76a9750b/thread:delegated-task:command%3Amcp%3Ad8491e92-80be-484b-a0e7-c09c830b6868%3Adelegate-task%3Aawr-a1-arabic-ai-01) | `4e36a08` | Pending (uncommitted output) | Running (async) | `A1-arabic-ai/` | Await completion wake |
| `S1` | S1 — Phone transfer and archive worker | `awr-s1-storage-01` | [S1 thread](t3-thread://v2/59505559-2c07-4bec-b08d-645e76a9750b/thread:delegated-task:command%3Amcp%3Ad8491e92-80be-484b-a0e7-c09c830b6868%3Adelegate-task%3Aawr-s1-storage-01) | `4e36a08` | Pending (uncommitted output) | Running (async) | `S1-transfer-storage/` | Await completion wake |
| `I1` | I1 — Integration worker | — | — | — | — | Blocked on `C1`, `A1`, `S1` | `I1-integration/` | Wait for Phase 1 |
| `U1` | U1 — Product experience worker | — | — | — | — | Blocked on Gate A | `U1-product-ui/` | Wait for `I1` + Gate A |
| `R1` | R1 — Independent reviewer | — | — | — | — | Blocked on `U1` | `R1-review/` | Wait for `U1` |
| `R2` | R2 — Final verifier | — | — | — | — | Blocked on `R1` / repairs | `R2-final-verify/` | Wait for `R1` |
