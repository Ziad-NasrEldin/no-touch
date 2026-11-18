# I1 — Integration worker — progress

## Status: in progress — implementation landed, package build green, xcodebuilds running

## Done so far
- Read BRIEFING.md + all four lane handoffs (F0, C1, A1, S1) fully + spec.md + master plan + findings ledger.
- Environment: Xcode 27.2 (27B52); **Metal Toolchain 27B47 confirmed installed** via `xcodebuild -showComponent MetalToolchain` — mlx-swift Metal compilation unblocked.
- Wire contract verified by inspection both directions — no decoder mismatches; tombstone acks echo delivered digest → watch discards correctly.
- API drift vs A1 handoff §4.2 recorded: `PhoneAI.makeAnalysisJobRunner`/`defaultModelsRoot` don't exist — actual surface is `PhoneAI.modelsRootDirectory()` + `AnalysisJobRunner(dependencies:)` (wired directly).

## Landed
1. **Package.swift**: `argmax-oss-swift` from 1.1.1 (product WhisperKit) + `mlx-swift-lm` upToNextMinor 2.31.3 (MLXLLM+MLXLMCommon) on PhoneAI only. Resolved: argmax-oss-swift 1.1.1, mlx-swift-lm 2.31.3, transitives pinned.
2. **RecorderContracts**: `ExtendedArchiveStoreProtocol` (S1 App.D-1 + integration reads), `PhoneFileIngestProtocol` (App.D-5), `TranscriptSearchHit` moved in from PhoneStorage.
3. **SQLiteArchiveStore**: conforms to ExtendedArchiveStoreProtocol; added `transcriptSegments(sessionID:)`, `chunkMetadata(id:)`, `sessionIDsWithStoredChunks()`, `sessionIDsWithUngroupedSegments()`, `hasAnalysisJob(kind:chunkID:)`, `disbandConversationGroup(conversationID:)` (non-tombstone regroup bookkeeping).
4. **PhoneReceiveService**: `onChunkStored` hook (fresh durable store only, after registry insert, before ack); conforms to PhoneFileIngestProtocol.
5. **WatchConnectivityReceiveTransport**: `didReceiveApplicationContext` + `didReceiveUserInfo` → `handleSessionPayload` → `upsertSession`; wire contract doc updated.
6. **PhoneIntegration**: `SessionCoordinator` rewritten — real services, ingest→enqueue via hook, 3-phase drain (transcription → regroup → intelligence), overlap-adopting regroup (`ConversationRegrouping.swift`), reconcile (missing jobs + cancelled revival), `requeueFailedJobs`, `applyDeletion`+flush, `diagnosticsReport`; `BackgroundAnalysisScheduler` (BGProcessingTask).
7. **Apps/PhoneRecorderApp**: real `PhoneRecorderModel` + status UI; scenePhase → activate/BG-schedule; install flows with progress.
8. **Apps/WatchRecorderApp**: `SessionSyncRelay` forwards `stateUpdates()` → `updateApplicationContext(["type":"session","session":Data])`.
9. **Info.plist (phone)**: `BGTaskSchedulerPermittedIdentifiers` = `com.placeholder.PhoneRecorder.processing` (BG draining implemented).
10. **CapturePaths**: `.completeUntilFirstUserAuthentication` on watch capture root (privacy parity with phone archive).

## Builds
- `swift build --scratch-path .build/i1` → **Build complete** (all targets + real deps, macOS).
- `xcodebuild PhoneRecorderApp (iOS Simulator generic)` → running.
- `xcodebuild WatchRecorderApp (watchOS Simulator generic)` → pending.

## Decisions (recording for handoff)
- S1 App.D-1 promote store APIs → **ACCEPT** (`ExtendedArchiveStoreProtocol`).
- App.D-2 per-span availability → **DEFER** (rollup suffices; no consumer).
- App.D-3 `.dropped` TransferStatus → **REJECT** (digest acks load-bearing; discard carries signal).
- App.D-4 session-truth channel → **ACCEPT** (applicationContext relay).
- App.D-5 formalize ingest seam → **ACCEPT** (`PhoneFileIngestProtocol`).

## Next
- Watch-scheme xcodebuild; fix any errors; commit; handoff.md.
