# R1 — Independent review of integrated checkpoint `6bda965`

**Reviewer:** R1 (read-only, independent of F0/C1/A1/S1/I1)
**Target:** `6bda965` "feat: integrate Phase 2 — real capture→transfer→archive→analysis pipeline" (`git diff 4e36a08..6bda965`, 65 files, +9,569/−300)
**Method:** full line-level read of all five targets + both app shells + package/project config, against spec.md and the five lane handoffs. Build-only verification in dedicated scratch paths. No product code touched, no git writes, no tests written or run, no delegation.

---

## Verdict

**Proceed to Gate A — conditional on four small repairs landing first.** The integrated core is architecturally sound and the spec-critical invariants (ack-after-verified-store, tombstone non-resurrection, Arabic preservation, source grounding, serial inference, honest states) hold in every path I could verify statically. The four majors below are each a narrow, well-located defect — none invalidate the design — but each would produce a *known* failure during Gate A device exercise, so fixing them first avoids burning verification time on predictable outcomes:

- R1-1: any BG-task expiration permanently disables all analysis until app relaunch.
- R1-2: manifested-but-unqueued chunks strand on the watch forever (silent transfer hole in a narrow crash window).
- R1-3: a transient rotation-start failure stalls capture indefinitely.
- R1-4: speech + text engines never unload — unbounded co-residency on a 6 GB device, no memory-pressure path.

R1-1, R1-3 and R1-4 are small code changes (reset/scope the cancel flag, add the same `scheduleAutoRecovery` call the other failure paths already use, wire the existing `unload()` at pipeline phase boundaries / memory warning). R1-2 needs a manifest↔outbox reconcile pass on transfer-service activation. U1 product UI may proceed in parallel — no finding touches UI-facing contracts.

---

## Findings (severity-ranked)

### R1-1 — major — BG expiration permanently kills the analysis runner

- **Observable failure:** when iOS expires a `BGProcessingTask`, `task.expirationHandler` calls `drain.cancel()` **and** `coordinator.cancelProcessing()` → `runner.cancel()` sets `cancelled = true` — a flag that is never reset and documented as "process-lifetime". Every subsequent drain (`runNextQueuedJob` → `guard !cancelled`) returns nil. All analysis — foreground kicks, `activate()`, later BG windows — no-ops until process relaunch. Queued jobs also re-schedule a new BG window each expiration (`remaining > 0` → `schedule(+15min)`), so the app burns repeated OS windows doing nothing.
- **Location:** `Sources/PhoneIntegration/BackgroundAnalysisScheduler.swift:89-92`; `Sources/PhoneAI/AnalysisJobRunner.swift:54,62-64,70`; `Sources/PhoneIntegration/SessionCoordinator.swift:147-150` (docstring acknowledges the flag is process-lifetime yet exposes it to the expiration path).
- **Repro/verification:** static — flag has no reset path anywhere (grepped). On device: launch → background → let the BG task expire (or simulate) → foreground → "Process now" → `queuedJobs` never decreases.
- **Expected vs observed:** expected — expiration pauses work and resumes at the next opportunity; observed — one expiration disables all analysis for the app's lifetime.
- **Spec clause:** "Interrupted work resumes after relaunch or reconnect" / processing must continue on app open. A routine OS event silently disables the feature.

### R1-2 — major — manifested chunks can strand on the watch forever

- **Observable failure:** `sealChunk` persists the chunk into the manifest (durable), then enqueues to the outbox inside a detached `Task` (`Task { try await outbox.enqueueForTransfer(metadata) }`). Two loss windows: (a) process death between manifest persist and outbox persist; (b) `enqueueForTransfer` throwing (outbox persist failure) — logged only. The chunk is then: never transferred, never eligible for orphan cleanup (`discardOrphanedChunks` *keeps* manifested files), invisible to `chunksAwaitingAcknowledgment`, and never reconciled at relaunch — `WatchTransferService.activate()` only demotes/resets existing outbox rows; nothing anywhere scans manifest-vs-outbox (`enqueueForTransfer`'s only call site is line 517).
- **Location:** `Sources/WatchCapture/WatchCaptureService.swift:501-525` (manifest append+persist at 501-506, async enqueue at 514-525); `Sources/WatchCapture/WatchTransferService.swift:133-149` (activate performs no reconcile); `Sources/WatchCapture/WatchCaptureService.swift:641-702` (recovery scans orphans only).
- **Repro/verification:** static — no reconcile path exists. On device: kill the watch app in the manifest→enqueue window (or make the outbox write fail) → chunk never arrives at the phone; nothing ever retries it.
- **Expected vs observed:** expected — every manifested chunk eventually transfers or is accounted; observed — a crash/IO-error window produces permanently stranded audio with zero signals beyond one diagnostic line.
- **Spec clause:** "files kept on the Watch until the phone has durably received them" + transfer must not silently lose audio.

### R1-3 — major — rotation start-failure stalls capture until manual resume

- **Observable failure:** in `rotateChunk`, if `next.start()` throws, the old chunk is sealed, `engine` cleared, and `beginInterruption(.unknown)` runs — but **no `scheduleAutoRecovery` is invoked**, and `beginInterruption` halts the tick loop. The session stays `.interrupted` until the user manually resumes (or a coincidental system interruption-ended event arrives with `shouldResume`). A single transient `AVAudioRecorder.start()` failure — momentary session contention — turns into an unbounded capture gap during unattended all-day use. The sibling failure paths (`encodeError`, `handleUnexpectedCaptureLoss`) both schedule a bounded auto-retry; this one was missed.
- **Location:** `Sources/WatchCapture/WatchCaptureService.swift:419-430` (missing retry, contrast 583-586 and 590-595); `Sources/WatchCapture/WatchCaptureService.swift:600-610` (the existing one-shot recovery helper).
- **Repro/verification:** static — code path contains no recovery call. On device: force `start()` to fail at a rotation boundary → session shows `interrupted`, never self-recovers.
- **Expected vs observed:** expected — bounded automatic recovery "when the system allows", consistent with the other failure paths; observed — permanent stall on a transient error. State display is honest (gap is recorded truthfully), so this is an availability defect, not a truthfulness one.
- **Spec clause:** "The recorder may pause/resume around interruptions and should resume when the system allows it" — resilience for all-day unattended recording.

### R1-4 — major — model engines never unload; co-resident memory is unbounded

- **Observable failure:** both engines implement `unload()` (`pipe.unloadModels()` / `container = nil`) and nothing calls it — zero call sites in the tree. Once the first transcription and first intelligence job run, WhisperKit (~0.6-1+ GB working set) and the MLX model (~1.1 GB) stay co-resident for the process lifetime. `ModelExecutionGate` serializes *execution* but not *residency* — the documented "sequential use … to limit peak memory" posture is not realized in RAM. There is also no memory-warning handling anywhere; a `DidReceiveMemoryWarning` never reaches the engines. The pipeline's own phase ordering (transcription drain → regroup → intelligence drain) provides a natural unload seam that isn't used.
- **Location:** `Sources/PhoneAI/MLXIntegration.swift:22,48-50`; `Sources/PhoneAI/WhisperKitIntegration.swift:22,51-56`; no `unload()` call sites anywhere (`grep unload` → implementations only). `Sources/PhoneIntegration/SessionCoordinator.swift:176-236` (phase boundaries where unloads could sit).
- **Repro/verification:** static — no call sites. On device (Gate A): run a mixed transcription+intelligence drain under memory instrumentation → both models remain resident; add app-memory pressure → no mitigation path exists.
- **Expected vs observed:** expected — sequential model use limits peak memory; observed — peak memory = sum of both models + runtime, indefinitely.
- **Spec clause:** "Prefer sequential use of speech and text models to limit peak memory" / local-AI resource budget on iPhone 14 Pro Max.

### R1-5 — minor — title/summary survive ungrounded when all refs fail

- **Observable failure:** the parser drops unresolvable refs via `compactMap` but keeps `title`/`summary` unconditionally. A model emitting `{"title": "…", "title_refs": ["S99"]}` yields a stored title with zero source refs — a field-level grounding gap. Decisions and action items *are* correctly dropped when their refs don't resolve, so the inconsistency is only for the two free-text fields.
- **Location:** `Sources/PhoneAI/MetadataPrompting.swift:178-188` (refs silently dropped), `240-261` (title/summary emitted without ref requirement).
- **Repro/verification:** parser-level — feed output whose title_refs are all invalid → title retained with no evidence.
- **Expected vs observed:** expected — "source-grounded metadata" per field; observed — free-text fields can float ungrounded.
- **Spec clause:** generated metadata must stay grounded in source passages.

### R1-6 — minor — permanently-rejected chunks resend forever at 10-min cadence

- **Observable failure:** a `.failed` ack (phone repeatedly rejects bytes — e.g. permanently corrupt transfer) is ignored by `apply` (non-`.acknowledged` → warn+return). Entry stays `.awaitingAcknowledgment` → `ackTimeout` requeues to `.queued` → resent. `maxAttempts` only gates `.failed`-*status* entries; `.queued` entries send regardless of `attemptCount` — so the retry is unbounded (~144 transfers/day of a dead chunk). Self-healing for transient corruption is fine and intended; the hole is that *permanent* rejection never parks.
- **Location:** `Sources/WatchCapture/WatchTransferService.swift:199-204` (non-ack ignored), `276-296` (timeout requeue + `due` filter), `50-51` (maxAttempts doc claims parking that doesn't cover this path).
- **Repro/verification:** static state-machine trace. Device: force repeated `.failed` acks → endless resend cycles.
- **Expected vs observed:** expected — bounded retry then parked `.failed`; observed — infinite low-rate retry for a permanently-rejected chunk.
- **Spec clause:** honest transfer accounting; bounded background work.

### R1-7 — minor — ingest never kicks the drain; foreground passes cap at 24/kind

- **Observable failure:** `onChunkStored` enqueues a transcription job but nothing schedules a drain — `kickProcessing`'s only call site is `installModels()`; the transport has no coordinator reference. Chunks arriving while the app is foregrounded wait for a scene-phase `.active`, a deletion, an install, "Process now", or a BG window. Additionally `scheduleDrain` runs at most one pass (`drainAgain` is only set by *another* `scheduleDrain` call mid-pass — the enqueue hook doesn't make one), so each trigger drains ≤24 transcription + ≤24 intelligence jobs; a day-scale backlog needs repeated triggers (the BG path does loop to empty — asymmetry is only in the foreground path).
- **Location:** `Sources/PhoneIntegration/SessionCoordinator.swift:61-73` (hook enqueues only), `176-236` (bounded pass), `327-340` (single-pass loop); `Apps/PhoneRecorderApp/PhoneRecorderApp.swift:104` (sole kickProcessing caller).
- **Repro/verification:** static — no ingest→drain signal exists. On device: foreground the app, deliver chunks, watch `queuedJobs` grow without draining.
- **Expected vs observed:** expected — fresh durable work drains promptly in foreground; observed — deferred to the next lifecycle event. Spec-tolerable (processing may be deferred; it resumes on open) but a UX wart U1 must wire around.
- **Spec clause:** "opening the app must allow pending processing to continue" — satisfied at the letter; prompt progress is the gap.

### R1-8 — info — chunk filename sequence lags metadata sequence by one

- **Observable:** every rotated chunk's filename prefix is `fileName(sequence: nextSequence)` evaluated *before* `sealChunk` increments, so file `chunk-000000-<uuid>.m4a` can carry `sequenceNumber: 1`. Ordering is always taken from metadata (never filenames), so no functional impact; it misleads human inspection and naive filename sorts (the two `chunk-000000-*` files order by UUID suffix).
- **Location:** `Sources/WatchCapture/WatchCaptureService.swift:326,394` (name from `nextSequence`), `340-342`, `483,500` (sequence assigned + incremented at seal).

### R1-9 — info — manifest rewrite is O(n) per persist → ~O(n²) writes/day

- **Observable:** `persist()` writes `session.json` **and** the full `manifest.json` on every heartbeat (~10 s during recording) and every state change. At 1,440 chunks/day the tail-end manifest (~200 B × n) is rewritten ~8,640×/day → ~200 MB of writes/day — modest flash wear, fine functionally, worth a batched/appended format later.
- **Location:** `Sources/WatchCapture/WatchCaptureService.swift:374-381` (10-tick heartbeat→persist), `711-720`; `CaptureSessionStore.swift:44-47`.

### R1-10 — info — model downloader verification is presence-only

- **Observable:** both repository downloaders verify by file-type presence (any `.safetensors` + `config.json`; any `.mlmodelc` + `config.json`) — no checksums or signature validation. Corrupt/partial snapshots surface later as engine load failures (honest `.failed` jobs), not at install. The `.files` method *does* verify byte count + optional SHA-256 — the asymmetry is only for repo installs where the hub owns layout.
- **Location:** `Sources/PhoneAI/MLXIntegration.swift:99-111`; `Sources/PhoneAI/WhisperKitIntegration.swift:157-170` (contrast `ModelInstallController.swift:385-405` `.files` verify).

### R1-11 — info — no auto-resume after crash relaunch

- **Observable:** `recoverAfterRelaunch` correctly marks the relaunch gap (`unrecoverableTermination`, bounded by `lastConfirmedCaptureAt`) and leaves the session `.interrupted` — but nothing attempts `activateAndRecord` on launch; the user must reopen the app and tap Resume/Start-day. Honest bookkeeping is right; the product question is whether reopen should auto-attempt resume (spec: "resume when the system allows" — watchOS can't relaunch the process, but the reopened app could resume itself).
- **Location:** `Sources/WatchCapture/WatchCaptureService.swift:641-679`; `Apps/WatchRecorderApp/WatchRecorderApp.swift:40-60` (no resume attempt on launch).

### R1-12 — info — `install()` early-returns on `.ready` without re-verifying bytes

- **Observable:** if the model directory is damaged/deleted externally after a successful install, `install()` returns success on the persisted `.ready` state and `engine.load` fails later at job time. Self-healing exists (failed job → reinstall), but readiness can briefly lie. Edge-case.
- **Location:** `Sources/PhoneAI/ModelInstallController.swift:181-187`.

---

## Findings summary table

| ID | Severity | Area | One-line summary | Gate A blocking? |
|----|----------|------|------------------|------------------|
| R1-1 | major | PhoneIntegration | BG expiration permanently disables the runner until relaunch | yes — fix first |
| R1-2 | major | WatchCapture→transfer | manifested-but-unqueued chunks strand forever | yes — fix first |
| R1-3 | major | WatchCapture | rotate start-failure never auto-recovers | yes — fix first |
| R1-4 | major | PhoneAI memory | `unload()` dead code; both models co-resident for process life | fix first; Gate A measures the rest |
| R1-5 | minor | source grounding | title/summary kept with zero resolved refs | no |
| R1-6 | minor | transfer | permanently-rejected chunks resend forever | no |
| R1-7 | minor | PhoneIntegration | ingest doesn't kick drain; 24/kind per foreground pass | no — U1 wiring note |
| R1-8 | info | WatchCapture | filename seq prefix off-by-one vs metadata | no |
| R1-9 | info | WatchCapture | manifest O(n) rewrite per heartbeat | no |
| R1-10 | info | model install | repo-install verify is presence-only | no |
| R1-11 | info | WatchCapture | no auto-resume after relaunch | no — product decision |
| R1-12 | info | model install | `.ready` skips re-verify | no |

**Ledger interplay:** F-05 confirmed (A1 handoff API names stale; actual `AnalysisJobRunner(dependencies:)`, `modelsRootDirectory()`, `progress` verified). F-01 posture matches code (shared-chunk audio kept — spec-permitted option; product decision still open). F-04 edges confirmed as documented; `pruneEmptyGroups` *does* exist on the chunk-delete path (the conversation-delete path skips it — only matters if a segment ever holds multi-group membership). F-03 compatibility aliases confirmed as typealiases-to-real.

---

## Areas verified clean (with the evidence checked)

- **Background-capture correctness.** `AVAudioSession` `.record` + `AVAudioRecorder` (16 kHz mono AAC `.m4a`), `UIBackgroundModes`/`WKBackgroundModes` audio, standard `interruptionNotification` handling — no workout/silent-playback tricks (`CaptureEngine.swift:88-98`, plists). Non-watchOS stub honestly refuses (`CaptureEngine.swift:201-221`). Gaps are `InterruptionInterval`s — never implied silence (`WatchCaptureService.swift:557-560` comment honored: interval measures missing audio). Rotation prepares the next recorder while the old runs; old audio is sealed with real stamps; prepare-failure keeps the current chunk and retries (`rotateChunk`, `CaptureEngine.prepare`). Empty files dropped with warning — never presented as captured audio.
- **Chunk integrity.** Real SHA-256 streaming (`WatchCaptureService.swift:770-778`), byte count, duration, sequence, `systemUptime` monotonic + wall stamps (uptime-sleep semantics documented at `WatchCaptureService.swift:5-9`). Crash: manifested files kept, unmanifested files discarded-as-unknown at relaunch (`recoverAfterRelaunch` + `discardOrphanedChunks`), gap bounded by the 10 s `lastConfirmedCaptureAt` heartbeat. Declared loss bound: ≤60 s open chunk + ≤~10 s truth lag — consistent with the spec's crash-loss allowance.
- **Transfer acknowledgment.** Phone acks only after land→stream-verify→atomic rename→registry insert (`PhoneReceiveService.commitVerifiedDelivery`); tombstone checked before byte work and re-checked at commit (`:119-140,217-232`); dedup re-acks from registry; quarantine on any verification/registry failure; crash debris quarantined-not-deleted at restart (`:323-371`). WC callback copies synchronously inside `didReceive` (`WatchConnectivityTransport.swift:147-163`). Ack travels reachable `sendMessage` + durable `transferUserInfo` fallback (`:93-105`). Watch deletes its copy only on `.acknowledged` whose digest+bytes+session re-verify against local metadata (`WatchTransferService.swift:198-235`); restart demotes in-flight→queued (dedup-safe resend).
- **Deletion & non-resurrection.** Tombstone + cascade in one transaction (`applyDeletionIntent`); every write path suppresses tombstoned targets (segments `:160-174`, sessions `:468-472`, jobs `:360-370`, groups read `:317-318`); cascades cancel queued+running jobs; session/conversation deletion emits per-chunk tombstones → watch `discard` via `transferUserInfo` (`WatchConnectivityTransport.flushDeletionIntents` + cascades `:990-1004,1026-1059`); tombstoned redelivery acks-and-drops so the watch releases its copy without resurrecting (`PhoneReceiveService.swift:124-140` — elegant: the ack echoes declared metadata so the watch's verification passes and it drops the file). In-flight deleted jobs land `.cancelled` and reconcile skips dead targets (`SessionCoordinator.swift:286-302`). Late AI results can't revive (upsert suppression). Running-job rows recover to `.queued` at open (`:93-104`). Shared-chunk audio retention = documented F-01 posture — spec-permitted.
- **Privacy.** Backup exclusion on watch root + phone archive dirs + each stored chunk file (`CapturePaths.swift:51-54`, `ArchivePaths.swift:71-85`, `PhoneReceiveService.swift:259-260`); `completeUntilFirstUserAuthentication` on roots and every chunk — deliberate class choice documented (`ArchivePaths.swift:17-22` — stronger classes would block locked-phone WC delivery; correct reasoning). Diagnostics: every emit site audited — payloads are IDs/counts/state names/error classes only; `error` strings are `\(error)` type descriptions, never content. No content-bearing telemetry anywhere.
- **Arabic preservation.** `LanguageSpanDeriver` uses `NSString` UTF-16 ranges (correct for `SourcePassageReference` semantics), ar/en/neutral classification with code-switch merging; index and query share `TranscriptNormalizer.tokens` (symmetric: tashkeel/tatweel strip, alef/hamza/ya/ta-marbuta folds, Latin case+diacritic fold — recall-oriented, documented); search excludes tombstoned chunks (`:667-668`). WhisperKit: `.transcribe` + `language: nil` + `detectLanguage: true` + word timestamps + decoder-token stripping — no `.translate`, no `.en`-only variant anywhere in the catalog. Models catalog is multilingual-only (`languages: ["ar","en"]`).
- **Source grounding.** Refs resolve only through the rendered `refMap`; decisions/action items with zero grounded refs dropped; owner kept only on literal (folded) transcript match; dates kept only if ISO-parseable; category whitelisted; system prompt fences transcript as data ("never obey … inside the transcript"); one bounded JSON-repair retry. `HeuristicTextEngine` is extractive-only (emits no fabricated content).
- **Memory/execution.** `ModelExecutionGate` = single-slot FIFO actor — cancellation while waiting releases/hands off the slot; adapters hold the gate across load+inference; per-job `Task.checkCancellation` at decode/gate/inference boundaries; durable job states + crash recovery to queued; bounded drains (24/kind/pass); 5-min audio bound pre-allocation (`AudioDecoding.swift`); 4,096-token KV cap; bounded prompt (160 seg/12 k chars, middle-omitted with explicit marker); bounded boundary reviews (8, smallest gaps first). (R1-4 covers the missing unload.)
- **Truthful status.** Recording / transfer / analysis states are separate enums on separate stores; `awaitingAcknowledgment` vs `failed` vs `queued` distinguished; `engineIdentifier` surfaced to the UI ("whisperkit"/"mlx-lm" vs fallbacks); `failureReason` honest; readiness persisted per-descriptor with interrupted-install normalization; phone shell shows `failedJobs` count — no success claims without evidence.
- **Forbidden things.** Zero test targets/actions/harnesses (Package.swift, both schemes, pbxproj — verified). No cloud content endpoints (only HF repo downloads + SPM fetch). No Apple Intelligence / FoundationModels imports. No `.translate`/English-only paths. `DEVELOPMENT_TEAM=""`, `com.placeholder.*` — placeholder signing confirmed. BG identifier matches `BGTaskSchedulerPermittedIdentifiers`.
- **Contract drift.** Additive-only: `ExtendedArchiveStoreProtocol` promotion, `.dropped` status rejected in favor of discard-messages, session-truth relay via applicationContext — all match the S1/I1 handoff deltas; no breaking contract change observed.

---

## Verification gaps (device-dependent — not defects)

1. **All watchOS capture behavior** — audio-session grants, call/Siri/media interruptions, background `audio` mode endurance, watch sleep, battery/thermal over a day — unexercised (no simulators/devices on this machine).
2. **On-device model reality** — WhisperKit and MLX compiled and link, but no model bytes were installed and no inference ran; memory, speed, thermals, and Gulf-Arabic WER are exactly what Gate A exists to measure.
3. **WatchConnectivity end-to-end** — pairing, `transferFile` delivery, ack round-trips, `updateApplicationContext` session mirror, discard delivery — unexercised.
4. **`BGProcessingTask` scheduling** — registration compiled; actual OS scheduling/expiration behavior unexercised (R1-1 will be observable there).
5. **Endurance/storage** — 1,440-chunk/day watch storage, outbox growth, flash wear, phone archive growth — unmeasured.
6. **Install flow** — model downloads (network), resume, verification, post-install `requeueFailedJobs` path — compiled but unexercised.
7. **Signing/installation** — placeholder; device install path unverified (tracked as ENV-01).

---

## Confirmations

- **No tests:** no unit/integration tests, test targets, test actions, or harnesses were added or run by this review (build-only checks as permitted: `swift build --scratch-path .build/r1`, `xcodebuild … -derivedDataPath .build/DerivedData-r1{,-watch}`).
- **No cloud:** no content was sent to any network service; all analysis ran on this machine.
- **Read-only:** no product code, git state, or lane files were modified; writes were confined to this directory's `progress.md`/`handoff.md`.

## Build verification record

| Command | Result |
|---|---|
| `swift build --scratch-path .build/r1` | **BUILD SUCCEEDED** (135.9 s) — real WhisperKit + MLX compiled |
| `xcodebuild -scheme PhoneRecorderApp -destination 'generic/platform=iOS' -derivedDataPath .build/DerivedData-r1 -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO build` | **BUILD SUCCEEDED** |
| `xcodebuild -scheme WatchRecorderApp -destination 'generic/platform=watchOS' -derivedDataPath .build/DerivedData-r1-watch -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO build` | **BUILD SUCCEEDED** |

## Suggested repair task shapes (for the orchestrator — repair ownership is outside R1's scope)

1. **R1-1:** remove `cancelProcessing()` from the BG expiration path (the `drain.cancel()` Task-cancellation already covers it) *or* add a reset at the top of each new drain pass; keep per-task cancellation semantics.
2. **R1-2:** on `WatchTransferService.activate()`, load manifests for all session dirs and enqueue any manifested chunk with no outbox row and no acked/deleted state (dedup guard already exists in `enqueueForTransfer`).
3. **R1-3:** add `scheduleAutoRecovery(via: "rotate-retry")` after the `beginInterruption` in the rotate-start-failure branch (matches encodeError/capture-loss pattern).
4. **R1-4:** call `unload()` on the *other* engine at the transcription↔intelligence phase boundary inside `processAnalysisQueue`, plus `didReceiveMemoryWarning` → unload both; keep gate serialization.
5. **R1-5:** drop `title`/`summary` when the model supplies refs but none resolve (or keep field only if refs unspecified or ≥1 resolves — product call).
6. **R1-6:** count `.failed` acks against `attemptCount` or mark entry `.failed` after N consecutive rejections.
7. **R1-7:** have `onChunkStored` (or the transport) call `kickProcessing()` — one-line seam already exists.
