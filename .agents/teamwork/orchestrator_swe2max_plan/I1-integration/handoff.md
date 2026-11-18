# I1 — Integration worker — handoff

**Final output commit (integrated tree): `6bda965`** — `feat: integrate Phase 2 — real capture→transfer→archive→analysis pipeline` on `main`, 49 files, +8639/−294. Tree clean after commit. (This handoff lands as a follow-up docs commit on top.)

## 1. Observations

**Environment / deps**
- Xcode 27.2 (27B52), Swift 6.4.2. **Metal Toolchain 27B47 confirmed installed** via `xcodebuild -showComponent MetalToolchain` → `Status: installed` — the mlx-swift Metal compilation requirement is met on this machine.
- `Package.resolved` records `argmax-oss-swift 1.1.1` (rev 1bbc57c) and `mlx-swift-lm 2.31.3` (rev 25b00d4) exactly as A1 requested, plus transitives (mlx-swift 0.31.6, swift-transformers 1.2.1, swift-huggingface 0.13.0, swift-jinja 2.5.2, EventSource, swift-numerics, swift-crypto, swift-asn1, swift-collections, swift-argument-parser, yyjson). Both products are bound to the `PhoneAI` target only; no watch target pulls them.
- `import Hub`/`HubApi` in `MLXIntegration.swift` compiled cleanly — the `Hub` module is still present via the swift-transformers/swift-huggingface transitive pair at these pins.

**Builds (all green, build-only verification — no tests run)**
- `swift build --scratch-path .build/i1` → `Build complete!` (all 5 library targets + real deps, macOS). Zero warnings in project sources; one benign upstream llbuild note (`missing creator for mutated node: mlx-swift_Cmlx.bundle`) and one AppIntents metadata note in xcodebuild — neither ours.
- `xcodebuild -scheme PhoneRecorderApp -destination "generic/platform=iOS Simulator" -derivedDataPath .build/DerivedData-i1 -skipPackagePluginValidation -skipMacroValidation build` → **BUILD SUCCEEDED** (real WhisperKit+MLXLLM compiled for arm64/x86_64 iOS simulator SDK).
- `xcodebuild -scheme WatchRecorderApp -destination "generic/platform=watchOS Simulator" -derivedDataPath .build/DerivedData-i1 -skipPackagePluginValidation -skipMacroValidation build` → **BUILD SUCCEEDED**.
- The `-skipPackagePluginValidation`/`-skipMacroValidation` flags were REQUIRED: mlx-swift ships a `CudaBuild` build-tool plugin that fails Xcode's package-plugin trust validation on non-interactive builds. First run without the flags failed with `Validate plug-in "CudaBuild" in package "mlx-swift"`. The plugin is unused by our products; skipping validation is the standard CLI remedy and does not affect compiled output.
- Two real integration errors were caught and fixed during xcodebuild: `BGProcessingTask` non-Sendable capture in a `sending` Task closure (fixed via documented-thread-safe `@unchecked Sendable` box), and an `await` placement error in the app model.
- No simulator runtimes installed; no devices. Nothing was run — compile + code inspection only.

**Lane API drift found**
- A1 handoff §4.2 names `PhoneAI.makeAnalysisJobRunner` and `PhoneAI.defaultModelsRoot` — neither exists. Actual surface: `PhoneAI.modelsRootDirectory()` + `AnalysisJobRunner(dependencies:)` with `audioFileResolver`/`chunkMetadataResolver` closures. Wired directly; handoff doc is stale, code is correct.
- `ModelInstallSnapshot` exposes `progress` (0…1) + `expectedBytes`, not `totalBytes` — app observer uses `progress`.
- `xcodebuild` option is `-showComponent` (singular), not `-showComponents`.

## 2. Reasoning

**Session truth (S1's flagged gap).** Nothing fed `upsertSession` — the frozen contracts carry no watch→phone session state. Chosen minimal honest path: the watch app relays each `stateUpdates()` `RecordingSession` as `WCSession.updateApplicationContext(["type":"session","session":Data(JSON)])`. applicationContext's latest-value semantics match a sessions *mirror* (latest snapshot always wins; delivery is queued when unreachable). The phone transport gained `didReceiveApplicationContext`/`didReceiveUserInfo` decoders → `upsertSession`. Chosen over alternatives: piggybacking state into every chunk's transfer metadata (stale, redundant, rewrites C1's sender) or a new pull channel (no pull primitive exists). Sender lives in the watch app shell (`SessionSyncRelay`) — app-level wiring, not lane logic; no lane file needed behavioral changes.

**Ingest→enqueue seam.** The WC transport calls `PhoneReceiveService.ingestReceivedFile` directly, bypassing the coordinator — nothing enqueued transcription on the real file path. Added `onChunkStored` hook to `PhoneReceiveService` (fires once per fresh durable store, after registry insert, before the ack; never on tombstone drops, dedup re-acks, quarantine, or failure). One hook covers both the file path and the `storeReceivedChunk` data seam. Guarded by the store's new `hasAnalysisJob` (any-state) check so expiry redeliveries can't re-mint transcription.

**Cross-chunk grouping.** The frozen surface had no way to list all segments of a session — regrouping across chunk boundaries was impossible. Added `transcriptSegments(sessionID:)` (chunk-sequence-ordered, chunk-tombstone filtered). `ConversationRegrouping.plan` reconciles fresh proposals (heuristic emits new UUIDs each run) onto persisted groups by max segment overlap → stable ids → **user overrides survive regrouping** (overrides key on conversation id; verbatim generated rows stay; `effectiveMetadata` resolves user fields at read — the per-field honor mechanism S1 built). Obsoleted groups are removed via `disbandConversationGroup` — deliberately *not* a tombstone: regroup bookkeeping must not suppress legitimate future proposals, and must never erase user data (orphaned override rows stay inert — documented conservative choice).

**Drain shape.** `processAnalysisQueue` = bounded 3-phase pass: transcription drain (speech engine) → regroup dirty + ungrouped-segment sessions → intelligence drain (text engine). Kind-ordered phases keep speech/text inference sequential, matching `ModelExecutionGate`'s memory cap on the 6 GB device. `sessionIDsWithUngroupedSegments` makes regroup convergent: any crash between phases is found next pass. `.cancelled` jobs are revived only for live targets (`audioFileURL`/`transcriptSegments` checks) — a BG expiration can't orphan work. `.failed` jobs stay terminal until `requeueFailedJobs` runs (post-install or explicit) — permanently-broken input can't spin.

**BG draining.** Implemented `BGProcessingTask` (`com.placeholder.PhoneRecorder.processing`, `requiresExternalPower=false`, `requiresNetworkConnectivity=false`, reschedule-while-work-remains) — so the plist identifier is justified, not speculative. Expiration cancels the drain task; revival path handles the in-flight job. Foreground drain on `activate`/`.active` remains primary per spec's OS-scheduling allowance.

**Wire contract (item 5).** Verified both directions by inspection — no fixes needed: sender metadata keys `chunkID/sessionID/sequenceNumber/fileName/chunk` match the receiver decoder (+`chunkMetadata` alt); ack shape `["type":"ack","ack":Data]` matches `InboundCommandDecoder`'s `payload/ack/acknowledgment` probe (default JSON decoder handles `timeIntervalSince1970` dates); `["type":"discard","chunkID":String]` matches the discard case; tombstone acks echo the *received* digest (lines 137/229 of `PhoneReceiveService.swift`) so the watch verifies-and-discards correctly.

**Deletion/lifecycle.** `applyDeletion` → store cascade (tombstones + job cancellation) → `flushDeletionIntents` → `transferUserInfo` discard per chunk tombstone → watch `discardChunk` removes file+entry. Tombstoned redeliveries ack `.tombstoned` + echoed digest → no resurrection. `enqueueAnalysisJob`, `upsertConversationGroup`, `upsertGeneratedMetadata`, `upsertTranscriptSegments` all suppress on tombstones — verified in S1's code.

## 3. Decision tables

### S1 contract requests (App. D)
| # | Request | Decision | Reason |
|---|---------|----------|--------|
| 1 | Promote concrete-store APIs into a protocol | **ACCEPT** — `ExtendedArchiveStoreProtocol` (RecorderContracts/ServiceProtocols.swift) | App/integration binds a protocol not a concrete; all promoted methods already exist on `SQLiteArchiveStore`. Includes integration reads it couldn't foresee: `transcriptSegments(sessionID:)`, `chunkMetadata(id:)`, `sessionIDsWithStoredChunks()`, `sessionIDsWithUngroupedSegments()`, `disbandConversationGroup`. `TranscriptSearchHit` moved into contracts to keep the protocol module-clean. |
| 2 | Per-span audio availability | **DEFER** (not implemented) | Conversation-level `audioAvailability` rollup satisfies the spec's expired-audio distinction; per-span needs segment→chunk joins with no current consumer — U1 can request when it binds playback. |
| 3 | `.dropped` TransferStatus for deletion acks | **REJECT** | Echoed-digest `.tombstoned` acks are load-bearing (watch verifies digest before discarding); a distinct status adds a wire case the watch already handles via `discard` commands. No behavior gap. |
| 4 | Watch→phone session-state channel | **ACCEPT** — applicationContext relay (see §2) | Only missing truth path; implemented end-to-end with latest-value semantics. |
| 5 | Formalize `ingestReceivedFile` on `PhoneReceiveServiceProtocol` | **ACCEPT** — `PhoneFileIngestProtocol` | Cheap additive seam; `PhoneReceiveService` conforms explicitly. The existing WC transport stays concrete-bound (it also needs `archiveStore`); protocol benefits alternate transports. |

### A1 dependency requests
| Request | Decision | Reason |
|---------|----------|--------|
| WhisperKit `argmax-oss-swift` from 1.1.1 on PhoneAI | **ACCEPT** — registered exactly | Validated by A1 at these pins (real-model smoke on macOS). |
| mlx-swift-lm upToNextMinor 2.31.3 (MLXLLM+MLXLMCommon) on PhoneAI | **ACCEPT** — registered exactly | Same. |
| Metal Toolchain present | **VERIFIED** — 27B47 installed | `xcodebuild -showComponent MetalToolchain`. |

### C1 configuration requests
None outstanding — C1's app shell + Info.plist posture were already correct (mic permission + audio background modes present). I added `.completeUntilFirstUserAuthentication` to the watch capture root for privacy parity with the phone archive (config-level hardening, not lane-logic change).

### Integration choices
| Choice | Decision | Reason |
|--------|----------|--------|
| Session-truth path | applicationContext `["type":"session","session":Data]` | Latest-value = mirror semantics; no lane rewrites. |
| Enqueue seam | `PhoneReceiveService.onChunkStored` | One hook covers file + data paths; fires inside durable path pre-ack. |
| Regroup identity | overlap-adopt existing ids | Preserves overrides; stable across drains. |
| BG draining | implemented `BGProcessingTask` + plist id | Spec-allowed OS scheduling; supplements foreground drain. |
| Signing | untouched placeholders (`com.placeholder.*`, empty team) | ENV-05 — no team id available. |
| Placeholder aliases | kept (`PlaceholderCompatibility.swift`, `PlaceholderAdapters.swift`) | Nothing references them now; kept as scaffolding — U1 may delete when it owns the app layer. |

## 4. Caveats / unverified

- **Nothing ran.** No simulators, no devices. The whole pipeline is compile-verified and code-traced only.
- **Unexercised workflow paths (exact):** WCSession file delivery end-to-end; `applicationContext` session relay delivery; `didReceiveUserInfo`/`sendMessage`/`transferUserInfo` channel behavior under reachability transitions; `transferFile` metadata round-trip on hardware; `BGProcessingTask` scheduling/expiration on device; model download/install on iOS (A1 validated on macOS only — 625 MB Whisper + ~937 MB MLX download paths unexercised on target); WhisperKit transcription on iPhone 14 Pro Max (accuracy, RTF, memory, thermal all unmeasured on-device); MLX generation on-device; `ModelExecutionGate` under real memory pressure; audio decode of real watch `.m4a` on-device; extended-runtime capture (all-day endurance unknown — ENV-04: duration/gap/charging/quality targets unspecified); watchOS battery/thermal behavior; retention sweep over days of chunks; `diagnosticsReport` export on device; Arabic mixed-language accuracy on real consented speech (no corpus exists — Gate A input).
- **Known residual edges (documented, not silently "fixed"):**
  - A transcription job in-flight when its chunk is deleted lands `.failed` (not `.cancelled`) — the cascade cancels queued/running rows but the runner rewrites the terminal state at completion. Cosmetic; no resurrection.
  - Redelivery of a chunk whose file was retention-expired re-stores it and the `hasAnalysisJob` guard prevents re-transcription — segments for it persist as before; audio replays only if still referenced. Edge consistent with S1's redelivery design.
  - A `.failed` transcription job (e.g. pre-install `modelNotReady`) is revived only via `requeueFailedJobs` — currently wired into the post-install path and available as a public API; there is no automatic retry.
  - Session mirror is a *mirror*: groups/segments don't require a session row; sessions that never relay (context lost) still process fully — `sessionIDsWithStoredChunks` drives regroup independently.
  - `disbandConversationGroup` leaves user overrides for disbanded ids inert-but-present (conservative keep; no consumer reads them).
  - F-01 span-level redaction: intentionally left as documented pending product decision — shared audio lives until all referencing conversations are deleted.
  - Orphaned empty groups after deletion cascades aren't pruned (no API existed; harmless rows). U1 may want `pruneEmptyGroups` promoted.
- **A1 handoff drift** (§4.2 factory names, `totalBytes` field) recorded for the orchestrator — doc-level only; code verified directly against A1's real APIs.

## 5. Gate A readiness

**Still needed from hardware/user:**
- Real iPhone 14 Pro Max + paired Apple Watch (model/watchOS unverified — ENV-02).
- Signing team/profile (ENV-05; bundle ids still `com.placeholder.*`).
- Desired endurance duration, acceptable gap policy, charging routine, quality thresholds (ENV-04).
- Consented Saudi/Gulf-Arabic + English code-switching corpus for accuracy measurement.

**Diagnostics posture for Gate A:**
- Phone-side events land queryable via `SessionCoordinator.diagnosticsReport(limit:)` → `store.diagnosticsReport(deviceModel:osVersion:)` — capture/transfer/storage/lifecycle/AI events, metadata-only payloads (ids, counts, state, error classes; no content).
- Watch-side events land in `diagnostics/events.jsonl` under the `WatchCapture` app-support root (2 MB roll) — export path documented in C1's handoff.
- Integration events added: `integration.drain_completed` (counts), `integration.regroup_error`, `integration.drain_error`, `integration.reconcile_error`, `integration.enqueue_failed`, `integration.bg_schedule_failed`, `transfer.session_received`, `storage.group_disbanded`.

**Independent verification (reproduce I1's claims):**
```sh
cd /Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec
swift build --scratch-path .build/i1                          # → Build complete
xcodebuild -project WatchRecorder.xcodeproj -scheme PhoneRecorderApp \
  -destination "generic/platform=iOS Simulator" -derivedDataPath .build/DerivedData-i1 \
  -skipPackagePluginValidation -skipMacroValidation build     # → BUILD SUCCEEDED
xcodebuild -project WatchRecorder.xcodeproj -scheme WatchRecorderApp \
  -destination "generic/platform=watchOS Simulator" -derivedDataPath .build/DerivedData-i1 \
  -skipPackagePluginValidation -skipMacroValidation build     # → BUILD SUCCEEDED
xcodebuild -showComponent MetalToolchain                      # → Status: installed
git show --stat 6bda965                                        # → the integrated tree
```

**First-boot code path to trace on hardware:** `PhoneRecorderModel.init` → `SessionCoordinator.makeDefault` → `activate` → `receiveService.prepare` → WC `activate` → `flushDeletionIntents` → `reconcilePendingTranscriptions` → drain; watch `RecorderModel` → `transfer.activate` + `stateUpdates` → `SessionSyncRelay` → phone `didReceiveApplicationContext` → `upsertSession`; `transferFile` → `ingestReceivedFile` → verify→register→`onChunkStored`→enqueue→ack; drain → `transcribe` → segments → `regroup` → groups+intelligence jobs → `generateMetadata` → `effectiveMetadata` (user overrides win); deletion → `applyDeletion` → tombstone cascade → discard propagation.
