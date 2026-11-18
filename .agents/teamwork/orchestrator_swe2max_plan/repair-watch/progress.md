# Repair — WatchCapture (R1 findings) — progress

**Worker:** repair-watch (`awr-repair-watch-01`), sole writer of `Sources/WatchCapture/`
**Base:** `6bda965` on `main` (HEAD `c217d0a` = checkpoint + R1 review artifacts)
**Status:** COMPLETE — all four fixes landed, both builds green, handoff written

## What was done

| Finding | File | Fix |
|---------|------|-----|
| R1-2 (major) | `WatchTransferService.swift` | `reconcileManifestsWithOutbox()` — called from `activate()` and gated every 10 min inside `drainOnce`. Manifested + no outbox row + file on disk → re-queue `.queued` with per-chunk `reconcile-recovered-chunk` diagnostic + `manifest-reconcile` summary. File-missing → already retired → skip. |
| R1-2 (immediate path) | `WatchCaptureService.swift` | Detached-Task enqueue kept (actor hop required); comment now documents reconcile as the durable backstop; `enqueue-failed` diagnostic retained. |
| R1-3 (major) | `WatchCaptureService.swift` | rotate `next.start()` catch → reason = `freeSpaceIsLow() ? .lowStorage : failureReason(for: error)`; `beginInterruption` with it; `guard reason != .lowStorage`; `scheduleAutoRecovery(via: "rotate-retry")`. Mirrors `encodeError`. |
| R1-6 (minor) | `WatchTransferService.swift` | `.failed` ack → `attemptCount += 1`, `lastError = "ack-rejected"`; at `maxAttempts` (12) → `.failed` parked + `chunk-parked-rejected` error event. Transient path unchanged (stays `.awaitingAcknowledgment` → ack-timeout requeue → resend → `.acknowledged` retires). Doc comment updated. No `OutboxEntry` schema change. |
| R1-8 (info) | `WatchCaptureService.swift` | `sealChunk` renames file to `fileName(sequence: nextSequence)` before hashing/metadata → prefix always equals assigned `sequenceNumber`. Rename failure → keep original name + `chunk-rename-failed` warning; metadata always reflects real on-disk name. |

## Verification

- [x] `swift build --scratch-path .build/rw --target WatchCapture` → **Build complete! (15.40 s)**
- [x] `xcodebuild -scheme WatchRecorderApp -destination "generic/platform=watchOS Simulator" -derivedDataPath .build/DerivedData-rw -skipPackagePluginValidation -skipMacroValidation build` → **BUILD SUCCEEDED**

## Scope check

`git status` modified: `Sources/WatchCapture/WatchCaptureService.swift`, `Sources/WatchCapture/WatchTransferService.swift` (+ sibling's 5 files under PhoneAI/PhoneIntegration — untouched). No git writes performed.

## Unexercised (devices/simulators unavailable)

- AVAudioRecorder start-failure → `rotate-retry` auto-recovery round trip.
- WC `.failed` ack round trips; parked-entry reset on `activate()`.
- Reconcile against real on-disk manifest/outbox fixtures.
