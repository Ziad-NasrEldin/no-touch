# Repair-Phone — progress

**Role**: repair worker, `Sources/PhoneIntegration/` + `Sources/PhoneAI/` only.
**Base**: `6bda965` on `main`. Build-only verification. No git writes.

## Done
- Read BRIEFING.md, R1-review/handoff.md (R1-1, R1-4, R1-5, R1-7), I1
  handoff drain semantics, and all touch files.
- **R1-1**: removed `coordinator.cancelProcessing()` from the BG
  `expirationHandler` — `drain.cancel()` (Task cancellation) alone lands
  the in-flight job `.cancelled`, revived by
  `reconcilePendingTranscriptions`. `runner.cancelled` stays reserved for
  deliberate process-lifetime shutdown; docstrings updated at
  `BackgroundAnalysisScheduler.swift:18-24,93-100` and
  `SessionCoordinator.swift` `cancelProcessing` doc.
- **R1-7**: `onChunkStored` hook now fires a late-bound `DrainKickRelay`
  → `coordinator.kickProcessing()` after a fresh enqueue
  (`SessionCoordinator.swift` makeDefault). `scheduleDrain` loop
  self-continues while `drainAgain` OR (pass made progress AND `.queued`
  jobs remain) — zero-progress passes stop (error/suppression paths must
  not spin).
- **R1-4**: additive `unloadEngine()` on `SpeechTranscriptionAdapter`
  (`:116-121`) and `TextIntelligenceAdapter` (`:207-212`) — runs under
  `gate.withExclusiveAccess`, so unload can never overlap in-flight
  inference. `processAnalysisQueue` unloads the speech engine after the
  transcription phase and the text engine after the intelligence phase —
  max one model resident at any time. `releaseModelMemory()` on the
  coordinator unloads both + emits `integration.models_unloaded`; bound
  to `UIApplication.didReceiveMemoryWarningNotification` via a lazy
  `ObserverToken` forced in `activate()` (iOS only; injectable seam for
  other embedders). Lazy reload verified: both engines' `load` no-ops
  when resident and rebuilds after `unload()` sets `pipe`/`container`
  nil; adapters load inside the gate on every job.
- **R1-5**: `MetadataResponseParser.parse` now drops `title`/`summary`
  when the model supplied a refs array for the field and zero refs
  resolve; kept when the refs key is absent/null. Resolved refs reused
  for the top-level `sources` list (no behavior change there).
  `MetadataPrompting.swift:248-256`.

## Verification
- `swift build --scratch-path .build/rp` → **Build complete!** (all 5
  targets + deps, macOS).
- `xcodebuild -scheme PhoneRecorderApp -destination "generic/platform=iOS
  Simulator" -derivedDataPath .build/DerivedData-rp
  -skipPackagePluginValidation -skipMacroValidation build` →
  **BUILD SUCCEEDED** (iOS — exercises UIKit/WatchConnectivity-gated
  code).
- Two compile errors hit and fixed during iteration: repeat-while scope
  in `scheduleDrain` (body decls not visible in the while clause →
  restructured to `var again`/`while`), and nonisolated-init `self`
  capture for the observer (→ lazy `memoryWarningToken` forced in
  `activate()`).
- Lane discipline: only `Sources/PhoneIntegration/` + `Sources/PhoneAI/`
  modified; sibling `WatchCapture` edits left untouched; no git writes.

## In progress
- handoff.md.

## Blocked
- none.
