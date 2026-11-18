# Repair — WatchCapture lane — R1 findings handoff

**Worker:** repair-watch (`awr-repair-watch-01`)
**Base:** `6bda965` on `main` (worked at `c217d0a`; output left uncommitted — parent commits after verification)
**Scope:** `Sources/WatchCapture/WatchCaptureService.swift`, `Sources/WatchCapture/WatchTransferService.swift` only. No contract/protocol changes, no `OutboxEntry` schema change, no tests, no git writes. Sibling-owned files (`PhoneIntegration/`, `PhoneAI/`) untouched.

---

## Part 1 — Observations and exact evidence

### Files modified

- `Sources/WatchCapture/WatchCaptureService.swift` — R1-3, R1-8, R1-2 immediate-path comment.
- `Sources/WatchCapture/WatchTransferService.swift` — R1-2 reconcile, R1-6 bound.

### Per-finding fix evidence (file:line on the edited tree)

**R1-2 — manifested-but-unqueued chunks strand forever.** `WatchTransferService.swift:153` — `activate()` now calls `reconcileManifestsWithOutbox()` after the `.failed` reset and before `pump()`. The helper at `WatchTransferService.swift:380-421` scans `manifests/*.json` (covers manifests that outlive their chunk dirs), loads each manifest via `CaptureSessionStore.loadManifest`, and appends a `.queued` `OutboxEntry` for every manifested chunk that (a) has no outbox row (`tracked` Set of chunk ids) and (b) still has its file on disk. Verified-ack deletion removes row+file together (`apply` → `removeChunkFile` + `entries.remove`, `WatchTransferService.swift:259-261`), so file-presence is the honest discriminator: manifested + file-missing = already retired or explicitly discarded → skipped rather than surfaced as a false failure. Per-chunk `transfer`/`reconcile-recovered-chunk` diagnostic + `manifest-reconcile` summary; `persist()` only when something was recovered. A second trigger at `drainOnce` `WatchTransferService.swift:320-322` gates the same reconcile to `reconcileInterval = 10 min` (`:313`) so a missed enqueue during uninterrupted background capture self-heals without waiting for an app foreground; `activate()` is still the primary hook (`WatchRecorderApp.swift:47,66`). Immediate path: `WatchCaptureService.swift:541-557` keeps the detached `Task` enqueue (a `sync`→`async` actor hop is unavoidable in `sealChunk`); a comment now states the manifest row is the durable record and reconcile is the guaranteed backstop; the `enqueue-failed` diagnostic stays.

**R1-3 — rotate-start-failure stalls capture.** `WatchCaptureService.swift:420-437` — the `next.start()` catch now derives `reason = freeSpaceIsLow() ? .lowStorage : failureReason(for: error)` (previously hardcoded `.unknown`), passes it to `beginInterruption`, then `guard reason != .lowStorage else { return }` before `scheduleAutoRecovery(via: "rotate-retry")` — the same one-shot 2 s bounded pattern as `encodeError` (`:618`) and `handleUnexpectedCaptureLoss` (`:626`). `autoRecoverIfInterrupted` resumes only while still `.interrupted`; a user stop or manual resume in the window cancels it.

**R1-6 — permanently-rejected chunks resend forever.** `WatchTransferService.swift:205-236` — a `.failed` `TransferAcknowledgment` now looks up the entry (unknown chunk → `ack-unknown-chunk`), increments `attemptCount`, sets `lastError = "ack-rejected"`, and at `attemptCount >= maxAttempts` (12) marks the entry `.failed` + emits `chunk-parked-rejected` (`.error`); below the bound it emits `ack-rejected` (`.warning`) and persists. Because `attemptCount` shares the send budget, the parked entry is excluded from `due` (`:336` filter: `.failed && attemptCount < maxAttempts`) and revives only via `activate()`'s existing reset — bounded 12-attempt windows per activation, matching the documented posture. Transient rejection still self-heals: the entry stays `.awaitingAcknowledgment` → `ackTimeout` requeues → resend → a later `.acknowledged` retires it through the unchanged verified-ack path. Non-`.failed` non-ack statuses keep the original warn-and-return. `maxAttempts` doc updated (`:49-52`). Deliberately **no** new `OutboxEntry` field — an added non-optional key would break decoding of pre-existing `outbox.json` rows (`load()` `?? []` would silently drop the whole queue).

**R1-8 — filename sequence prefix off-by-one.** `WatchCaptureService.swift:484-505` — `sealChunk` renames the file to `fileName(sequence: nextSequence)` immediately before hashing/metadata, so the `chunk-NNNNNN` prefix always equals the `sequenceNumber` the seal assigns (`:510`). Naming at seal time is ordering-immune: correct for `beginChunk` chunks, rotated chunks, and the edge where a preceding seal failed and never consumed its sequence. Rename failure → keep the original name + `chunk-rename-failed` warning; `metadata.fileName` (`:523`) and `sha256Hex` (`:507`) always track the real on-disk URL. Creation-site names at `:326` and `:394` are now provisional only.

### Build evidence (final runs, this exact tree)

| Command | Result |
|---|---|
| `swift build --scratch-path .build/rw --target WatchCapture` | **Build complete!** (15.40 s) |
| `xcodebuild -scheme WatchRecorderApp -destination "generic/platform=watchOS Simulator" -derivedDataPath .build/DerivedData-rw -skipPackagePluginValidation -skipMacroValidation build` | **BUILD SUCCEEDED** |

---

## Part 2 — Reasoning tied to observations

- **Reconcile is atomic w.r.t. the detached enqueue.** `reconcileManifestsWithOutbox` is synchronous on the actor; a seal-triggered `enqueueForTransfer` arriving between scan and append is impossible (actor serializes), and one arriving *after* a recovery hits the existing `chunk.id` dedup guard (`:166`). Either ordering converges to exactly one row.
- **Re-enqueue safety after a partial ack.** If the phone acked and the row was removed but file deletion failed (`try?` in `removeChunkFile`), reconcile re-queues the file → the phone dedups on chunk id and re-acks → the file is deleted. This is the same dedupe-safe resend contract the restart demotion already relies on.
- **`activate()` before `pump()` ordering.** The `.failed` reset runs first so its rows populate `tracked`; recovered entries land before `drainOnce` computes `due`, so they send in the same pass.
- **R1-3 reason mapping.** `AVChunkRecorder.start()` throws only `RecorderError.storageFailure` today; `freeSpaceIsLow()` is therefore the real low-storage discriminator (the `encodeError` precedent), while `failureReason(for:)` honestly maps any future `.lowStorage`/`.microphoneDenied` throw instead of flattening to `.unknown`.
- **R1-8 chosen over reserve-at-creation.** Reserving sequence numbers at file creation would burn numbers on failed prepares/empty drops (manifest holes) and need extra state; renaming at seal binds name↔metadata at assignment time with no sequencing change.
- **Invariant preservation.** Verified-ack-only deletion untouched (`apply` `.acknowledged` path unchanged); honest gaps unchanged (`beginInterruption` still opens an interval, auto-recovery closes it only when capture is confirmed); durable outbox unchanged (reconcile only *adds* rows, never removes); no silent audio loss (stranded chunks are now transferred, never dropped).

## Part 3 — Caveats and unverified areas

- **Everything runtime is unexercised** — no devices/simulators. Specifically: a real `AVAudioRecorder.record()` failure → `rotate-retry` recovery; real WC `.failed` acks → park at 12 → reset on next `activate()`; reconcile against real manifest/outbox fixtures on disk.
- **Reconcile assumes shared root.** It scans `paths.root/manifests/` — correct for the app's wiring (both services use `CapturePaths.makeDefault()`). A hypothetical future caller passing different `directory:` roots to capture vs transfer would see a no-op reconcile (no false recoveries) — the seal→enqueue fast path still works.
- **Seal-time rename** uses `FileManager.moveItem` in the same directory; all `sealChunk` callers stop the recorder first (`old.stop()` / `engine.stop()`), so no open-handle hazard. If a `chunk-seal-failed` ever lands *after* a successful rename (e.g. hash read fails mid-seal), the diagnostic logs the creation-time name while the file on disk carries the sealed name — orphan cleanup still removes it; correlation is one grep away.
- **Adjacent observation, not fixed (out of scope):** wire-level `fileFinished` errors requeue `.queued` and `.queued` entries drain regardless of `attemptCount` — a pathological transport could still resend without bound. Pre-existing, not one of my four findings; noting for the ledger.
- `.failed` acks against `.queued`/`.inFlight`/already-`.failed` entries also increment `attemptCount` — slightly conservative, still bounded.

## Part 4 — Conclusion

All four assigned findings are repaired surgically with no contract or persisted-format changes and no invariant regressions I can identify by trace. Both mandated builds are green. The majors (R1-2, R1-3) now have durable backstops where the reviewed code had silent holes; the minors are bounded and honestly surfaced. Ready for the parent verifier; runtime confirmation remains Gate A work.

## Part 5 — Independent verification

```bash
cd /Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec
swift build --scratch-path .build/rw --target WatchCapture            # expect: Build complete!
xcodebuild -scheme WatchRecorderApp -destination "generic/platform=watchOS Simulator" \
  -derivedDataPath .build/DerivedData-rw -skipPackagePluginValidation \
  -skipMacroValidation build                                         # expect: BUILD SUCCEEDED
git diff Sources/WatchCapture/                                       # surgical diff, 2 files
```

Device checks for Gate A: force `record()` to fail at a rotation boundary → `interruption-began` + `rotate-retry` recovery in diagnostics; force repeated `.failed` acks → `ack-rejected` ×N → `chunk-parked-rejected` → parked until next `activate()`; kill the app between manifest-persist and enqueue → next launch logs `reconcile-recovered-chunk` and the chunk transfers.
