# I1 — Dispatch Record

- **Role**: `I1 — Integration worker`
- **Client Request ID**: `awr-i1-integration-01`
- **Target**: `providerInstanceId: "acpRegistry_devin"`, `model: "swe-2-high"`, `options: {"thought_level": "max", "mode": "accept-edits", "speed": "standard"}`
- **Mode**: `async` · **Isolation**: `shared` (sole writer; commits the integrated checkpoint on `main`)
- **Base State**: `main` HEAD + uncommitted lane output (C1/A1/S1) in the working tree
- **Task ID**: `node:delegated-task:command%3Amcp%3Ad8491e92-80be-484b-a0e7-c09c830b6868%3Adelegate-task%3Aawr-i1-integration-01`
- **Thread Link**: `t3-thread://v2/59505559-2c07-4bec-b08d-645e76a9750b/thread:delegated-task:command%3Amcp%3Ad8491e92-80be-484b-a0e7-c09c830b6868%3Adelegate-task%3Aawr-i1-integration-01`
- **Status**: `dispatched` — `starting` / `working` at 2026-11-18
