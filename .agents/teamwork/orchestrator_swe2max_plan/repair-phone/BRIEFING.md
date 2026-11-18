# Repair — PhoneIntegration + PhoneAI (R1 findings) Briefing

## Assignment Identity
- **Role**: Repair worker for the phone-side lanes — fixing four R1 review findings
- **Model**: `acpRegistry_devin` / `swe-2-high` (`thought_level: "max"`, `mode: "accept-edits"`, `speed: "standard"`)
- **Client Request ID**: `awr-repair-phone-01`
- **Isolation**: `shared` — sole writer of `Sources/PhoneIntegration/` and `Sources/PhoneAI/` (a sibling repair task concurrently owns `Sources/WatchCapture/`; do not touch it, `Apps/`, `Sources/PhoneStorage/`, `Sources/RecorderContracts/`, `Package.swift`, xcodeproj, spec.md, or `.agents/` outside your state dir). Expect sibling uncommitted files.
- **Base Checkpoint**: `6bda965` on `main` (integrated checkpoint, verified).
- **Do NOT run any git write op.** Leave output uncommitted; parent commits after verification.

## Findings to repair (from `R1-review/handoff.md` — read it)

### R1-1 (major) — BG expiration permanently kills the analysis runner
`BackgroundAnalysisScheduler.swift:89-92`: on `BGProcessingTask` expiration → `drain.cancel()` AND `coordinator.cancelProcessing()` → `runner.cancel()` sets `cancelled = true` — **never reset** (`AnalysisJobRunner.swift:54,62-64,70`; the `guard !cancelled` at `runNextQueuedJob` no-ops forever). One routine OS expiration disables all analysis until process relaunch, while the scheduler keeps burning BG windows doing nothing.
**Fix** (choose the minimal honest option, document choice): remove `cancelProcessing()` from the expiration path (Task cancellation already covers it — the runner's cancel exists for real lifecycle shutdown), OR reset the flag at the start of each new drain pass. Ensure a subsequent drain (foreground kick, activate, later BG window) actually processes jobs. Do not break legitimate cancellation semantics — a user/OS shutdown path may still want a real cancel; if the flag stays for that, name the lifecycle clearly.

### R1-7 (minor) — ingest never kicks the drain
`SessionCoordinator.swift:61-73`: `onChunkStored` enqueues a transcription job but nothing schedules a drain (`kickProcessing`'s only caller is the app's `installModels`). Foreground chunks wait for a lifecycle event.
**Fix**: wire `onChunkStored` (or equivalent post-enqueue seam) to schedule a drain — the existing `scheduleDrain`/bounded-pass loop is fine to reuse; ensure enqueue-mid-pass can't strand work (bounded loop must continue while jobs remain — check the `drainAgain` asymmetry R1 noted vs the BG loop). Keep the pass bounded per spec but self-continuing while queued work exists.

### R1-4 (major) — `unload()` is dead code; both models co-resident forever
`MLXIntegration.swift:48` / `WhisperKitIntegration.swift:51`: engines implement `unload()`; zero call sites. Spec: "sequential use of speech and text models to limit peak memory" — residency isn't serialized, only execution. No memory-warning path exists.
**Fix**: expose whatever adapter/engine surface is needed (additive, no contract breakage) so `processAnalysisQueue` unloads the *other* engine at the transcription↔intelligence phase boundary, and wire a memory-warning path (`DidReceiveMemoryWarning` from the app lifecycle seam or an injectable hook — phone app shell binding is PhoneRecorderApp wiring; keep the PhoneAI/PhoneIntegration surface testable without the app). Unload must be safe under `ModelExecutionGate` (no unload while the other engine holds the slot mid-inference — phase boundaries are the safe seam). Engines must lazily reload on next use — verify the existing load paths handle reload-after-unload.

### R1-5 (minor) — title/summary survive ungrounded
`MetadataPrompting.swift:178-188,240-261`: refs that fail to resolve are compactMap-dropped, but `title`/`summary` are kept unconditionally — a field can store with zero source refs while decisions/action items are correctly dropped.
**Fix**: drop `title`/`summary` when the model supplied refs for them but none resolve; keep the field when the model supplied no refs for it at all (unspecified ≠ failed-grounding — leave that honest distinction). Document the rule.

## Constraints
- NO tests of any kind; build-only verification: `swift build --scratch-path .build/rp` (all targets) and `xcodebuild -scheme PhoneRecorderApp -destination "generic/platform=iOS Simulator" -derivedDataPath .build/DerivedData-rp -skipPackagePluginValidation -skipMacroValidation build`.
- No delegation/subagents. Surgical repairs, no redesign. No contract-breaking changes (additive only, and only if required).
- Preserve R1-verified invariants: per-field override protection, tombstone suppression, grounded metadata honesty, serial inference under the gate.
- Devices/simulators unavailable — compile-verify + code-trace; document what stays unexercised.

## State Folder
`.agents/teamwork/orchestrator_swe2max_plan/repair-phone/` — `progress.md` + `handoff.md` (five-part + per-finding fix with file:line evidence + remaining unexercised paths).
