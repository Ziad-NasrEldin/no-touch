# Global Task Roster

Model for all workers: `acpRegistry_devin` / `swe-2-high` (`thought_level: "max"`, `mode: "accept-edits"`, `speed: "standard"`).
Maximum concurrent workers: `3`.

| Role | Title | Task ID | Thread Link | Base Commit | Output Commit | Status | Handoff / State Dir | Next Instruction |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `F0` | F0 — Foundation and shared contracts | Pending | Pending | Pending | Pending | Queued | `F0-foundation/` | Dispatch `F0` |
| `C1` | C1 — Watch capture worker | — | — | — | — | Blocked on `F0` | `C1-watch-capture/` | Wait for `F0` |
| `A1` | A1 — Local Arabic AI worker | — | — | — | — | Blocked on `F0` | `A1-arabic-ai/` | Wait for `F0` |
| `S1` | S1 — Phone transfer and archive worker | — | — | — | — | Blocked on `F0` | `S1-transfer-storage/` | Wait for `F0` |
| `I1` | I1 — Integration worker | — | — | — | — | Blocked on `C1`, `A1`, `S1` | `I1-integration/` | Wait for Phase 1 |
| `U1` | U1 — Product experience worker | — | — | — | — | Blocked on Gate A | `U1-product-ui/` | Wait for `I1` + Gate A |
| `R1` | R1 — Independent reviewer | — | — | — | — | Blocked on `U1` | `R1-review/` | Wait for `U1` |
| `R2` | R2 — Final verifier | — | — | — | — | Blocked on `R1` / repairs | `R2-final-verify/` | Wait for `R1` |
