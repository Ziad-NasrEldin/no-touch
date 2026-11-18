# Repair — WatchCapture (R1 findings) Briefing

## Assignment Identity
- **Role**: Repair worker for the `WatchCapture` lane — fixing four R1 review findings
- **Model**: `acpRegistry_devin` / `swe-2-high` (`thought_level: "max"`, `mode: "accept-edits"`, `speed: "standard"`)
- **Client Request ID**: `awr-repair-watch-01`
- **Isolation**: `shared` — sole writer of `Sources/WatchCapture/` (a sibling repair task concurrently owns `Sources/PhoneIntegration/` + `Sources/PhoneAI/`; do not touch those, `Apps/`, `Sources/PhoneStorage/`, `Sources/RecorderContracts/`, `Package.swift`, xcodeproj, spec.md, or `.agents/` outside your state dir). Expect sibling uncommitted files.
- **Base Checkpoint**: `6bda965` on `main` (integrated checkpoint, verified).
- **Do NOT run any git write op.** Leave output uncommitted; parent commits after verification.

## Findings to repair (from `R1-review/handoff.md` — read it, esp. the finding sections)

### R1-2 (major) — manifested-but-unqueued chunks strand forever
`WatchCaptureService.sealChunk` persists to the manifest, then enqueues in a detached `Task` (`WatchCaptureService.swift:501-525`). Crash or enqueue-throw in that window → chunk never transfers, invisible to `chunksAwaitingAcknowledgment`, kept-but-ignored by orphan cleanup, and `WatchTransferService.activate()` never reconciles.
**Fix**: on `WatchTransferService.activate()` (and/or a periodic reconcile), load manifests for all persisted session dirs and enqueue any manifested chunk that has no outbox row and no acked/deleted state (dedup guard already exists in `enqueueForTransfer`). Reconcile must be idempotent, cheap (O(manifest) once per activation), and emit a diagnostic event per recovered chunk (`transfer` subsystem). Also make the seal→enqueue path itself failure-safe (e.g., enqueue failure must not strand the chunk — reconcile covers it, but keep the immediate path honest).

### R1-3 (major) — rotate-start-failure never auto-recovers
`WatchCaptureService.swift:419-430`: `next.start()` throws → seal old chunk, clear engine, `beginInterruption(.unknown)`, `return` — no `scheduleAutoRecovery`, tick loop halted → `.interrupted` until manual resume. Sibling paths (`encodeError`, `handleUnexpectedCaptureLoss`) both call `scheduleAutoRecovery`.
**Fix**: add `scheduleAutoRecovery(via: "rotate-retry")` after `beginInterruption` in that branch — matching the existing one-shot bounded pattern exactly (2 s delay, resumes only if still `.interrupted`, user pause/stop cancels). If free space is the cause, follow the encodeError precedent (`lowStorage` → no retry).

### R1-6 (minor) — permanently-rejected chunks resend forever
`WatchTransferService.swift:199-204`: a `.failed` `TransferAcknowledgment` is ignored → entry stays `.awaitingAcknowledgment` → `ackTimeout` requeues → resent ~144×/day forever.
**Fix**: count `.failed` acks against the entry (e.g. consecutive-failed-ack counter or fold into `attemptCount`); after a small bound (match existing `maxAttempts` posture), mark the entry `.failed` (parked, surfaced honestly to UI/diagnostics). Keep self-healing for transient failures — only permanent rejection parks. Update the maxAttempts doc comment if semantics change.

### R1-8 (info) — filename sequence prefix lags metadata by one
`WatchCaptureService.swift:326,394`: `fileName(sequence: nextSequence)` evaluated before `sealChunk` assigns+increments. Ordering uses metadata (no functional impact) but filenames mislead inspection.
**Fix**: align filename prefix with the chunk's assigned `sequenceNumber` (cheapest correct fix — e.g., evaluate the name at seal time or pass the assigned sequence).

## Constraints
- NO tests of any kind; build-only verification: `swift build --scratch-path .build/rw --target WatchCapture` and `xcodebuild -scheme WatchRecorderApp -destination "generic/platform=watchOS Simulator" -derivedDataPath .build/DerivedData-rw -skipPackagePluginValidation -skipMacroValidation build`.
- No delegation/subagents. Keep changes surgical — this is repair, not redesign. Do not change `WatchCaptureServiceProtocol`/`WatchTransferServiceProtocol` signatures or `RecorderContracts`.
- Preserve every spec invariant R1 verified clean: verified-ack-only deletion, honest gap bookkeeping, no silent audio loss, durable outbox.
- Devices/simulators unavailable — compile-verify + code-trace; document what stays unexercised.

## State Folder
`.agents/teamwork/orchestrator_swe2max_plan/repair-watch/` — `progress.md` + `handoff.md` (five-part structure + per-finding fix description with file:line evidence + remaining unexercised paths).
