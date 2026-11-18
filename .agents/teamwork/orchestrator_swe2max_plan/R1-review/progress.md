# R1 — Independent review — progress

Task `awr-r1-review-01`. Target: integrated checkpoint `6bda965` (+docs `0758abf`,`e3d3f4c`). Read-only on product code/git; writes confined to this dir.

## Done
- Read spec.md (all 138 lines — requirements authority).
- Read master BRIEFING.md, FINDINGS_LEDGER.md (open: F-01 span redaction product decision, F-04 cosmetic edges; ENV-01..05), ROSTER.md.
- Read all 5 lane handoffs (F0, C1, A1, S1, I1).
- Tree: ~9,114 LOC Swift; diff 4e36a08..6bda965 = 65 files, +9,569/−300.
- Full line-level read: all RecorderContracts, all WatchCapture (engine, service, store, outbox, WCSession transport, decoder, paths, diagnostics), all PhoneStorage (SQLiteArchiveStore 1,327 lines incl. deletion cascades + tombstone suppression, PhoneReceiveService, WatchConnectivityTransport, TranscriptSearch/Normalizer, ArchivePaths), all PhoneAI (both adapters, both engines, gate, runner, grouping, prompting+parser, install controller, catalog, decoder, deterministic engines, placeholders, factory), all PhoneIntegration (coordinator, BG scheduler, regrouping), both app shells, Package.swift, both plists, pbxproj signing, Package.resolved.
- Forbidden-things scan: no test targets/actions anywhere; no cloud content endpoints (only model-download repos + SPM); no Apple Intelligence/Foundation Models; no translate path (`.transcribe` only); signing placeholder (`DEVELOPMENT_TEAM=""`, `com.placeholder.*`); BG task id matches plist.
- `swift build --scratch-path .build/r1` → **BUILD SUCCEEDED** (135.9s, real WhisperKit+MLX compiled).
- `xcodebuild -scheme PhoneRecorderApp -destination 'generic/platform=iOS' -derivedDataPath .build/DerivedData-r1 -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED**.

## Complete
- `xcodebuild -scheme WatchRecorderApp -destination 'generic/platform=watchOS' -derivedDataPath .build/DerivedData-r1-watch -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO` → **BUILD SUCCEEDED**.
- handoff.md written: 4 major + 3 minor + 5 info findings; verdict = proceed to Gate A conditional on the four majors landing first (all small, well-located repairs); U1 may proceed in parallel.

## Findings scratchpad (verified in code)
- **major**: BG expiration → `coordinator.cancelProcessing()` → `runner.cancelled` is process-lifetime, never reset → all later drains no-op until app relaunch (BackgroundAnalysisScheduler.swift:89-92, AnalysisJobRunner.swift:54,62-64,70, SessionCoordinator.swift:148-150).
- **major**: manifested chunk never reconciled vs outbox — `sealChunk` persists manifest then enqueues in detached Task; crash/failure in between strands chunk forever (never transferred, never cleaned, invisible to counts). WatchCaptureService.swift:501-525; only call site of `enqueueForTransfer`.
- **major**: `rotateChunk` start-failure → `beginInterruption` without `scheduleAutoRecovery` — a transient `next.start()` failure stalls capture until manual resume (contrast encodeError/capture-loss paths which do retry). WatchCaptureService.swift:419-430 vs 583-586,594.
- **major**: `unload()` never called anywhere — Whisper + MLX stay co-resident for process lifetime; gate serializes execution not residency; no memory-pressure handling. MLXIntegration.swift:22,48-50; WhisperKitIntegration.swift:22,51-56.
- **minor**: title/summary kept when their refs are all unresolvable (refs silently dropped → ungrounded text fields survive). MetadataPrompting.swift:178-188,240-261.
- **minor**: `.failed` acks ignored → `.awaitingAcknowledgment`→10-min requeue→resend loop is unbounded (maxAttempts only gates `.failed`-status entries, not requeued `.queued`). WatchTransferService.swift:199-204,276-296,352-367.
- **minor**: foreground drain bounded to 24/kind per pass with no self-continuation; `onChunkStored` enqueues but never kicks → arriving chunks wait for activate/kick/BG. SessionCoordinator.swift:61-73,176-236,327-340.
- **info**: filename seq prefix lags metadata sequenceNumber by one for every rotated chunk (name uses `nextSequence` before increment). WatchCaptureService.swift:326,394,340-342,483,500.
- **info**: manifest.json rewritten O(n) every persist → ~O(n²) write volume/day (~200MB at 1,440 chunks/10s heartbeat). WatchCaptureService.swift:374-381,711-720.
- **info**: model downloader `verify` is presence-only (no checksums) for repo installs — relies on HF transport + load-time failure. MLXIntegration.swift:99-111, WhisperKitIntegration.swift:157-170.
- **info**: no relaunch auto-resume — crash-recovered `.interrupted` session waits for user Start/Resume (honest gap marking is correct). WatchCaptureService.swift:641-679.
- **info**: `install()` early-returns on `.ready` without re-verify — external model-dir deletion leaves stale readiness. ModelInstallController.swift:181-187.
- **info**: F-05 confirmed (A1 API names stale); F-01/F-04 postures match code. `pruneEmptyGroups` exists for chunk-delete path; conversation-delete path doesn't prune (edge only if multi-group membership ever occurs).
