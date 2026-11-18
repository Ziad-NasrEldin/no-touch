# I1 — Integration Worker Briefing

## Assignment Identity
- **Role**: `I1 — Integration worker` (Phase 2, runs ALONE — sole writer in the repo now)
- **Model**: `acpRegistry_devin` / `swe-2-high` (`thought_level: "max"`, `mode: "accept-edits"`, `speed: "standard"`)
- **Client Request ID**: `awr-i1-integration-01`
- **Isolation**: `shared` — you are now the only writer. All three Phase 1 lanes' work sits **uncommitted** in the working tree; you merge, integrate, and commit it.
- **Base state**: `main` HEAD plus the uncommitted lane output in `Sources/WatchCapture/`, `Sources/PhoneAI/`, `Sources/PhoneStorage/`, `Apps/WatchRecorderApp/`.
- **You ARE permitted and required to run `git add` / `git commit`** on `main` — you own the integrated checkpoint. Commit early enough that the final state is one clean tree; keep commits clean and scoped (e.g. lane merge, deps, integration).

## Original Request & Confirmed Constraints
- User prompt: *"I wanna build an all day apple watch recorder / Should use an on device or on iphone AI model to sort and categorize conversations / How do we do it"* -> *"Start the orchestra"*.
- Hardware: iPhone 14 Pro Max (no Apple Intelligence) + Apple Watch believed Series 6. Saudi/Gulf Arabic + English. Local AI only — no cloud, no Apple Intelligence.
- **PROHIBITION**: Do not write or run any unit or integration tests. Do not introduce an automated harness as a substitute. Build-only and manual checks are allowed. Never `swift test` / `xcodebuild test` / `test-without-building`; keep schemes test-free.

## Input Artifacts (absolute paths)
- Repo root: `/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec`
- Spec: `spec.md` · Master plan: `.agents/teamwork/orchestrator_swe2max_plan/BRIEFING.md` · Ledger: `.agents/teamwork/orchestrator_swe2max_plan/FINDINGS_LEDGER.md`
- **Lane handoffs (read ALL of them fully before editing):**
  - `F0-foundation/handoff.md` — ownership map; contracts were frozen for lanes, YOU now own them
  - `C1-watch-capture/handoff.md` — esp. §Part 3 caveats + "Requests for I1" (signing/bundle IDs, wire contract, backup-exclusion check)
  - `A1-arabic-ai/handoff.md` — esp. §4.1 dependency registrations (EXACT SPM URLs+pins), §4.2 wiring snippet, §4.4 candidate table, Metal Toolchain note
  - `S1-transfer-storage/handoff.md` — esp. App. B wire contract, App. C plist/config requests, App. D five contract-change requests, App. E gaps
- Lane source now in tree: `Sources/WatchCapture/` (C1), `Sources/PhoneAI/` (A1), `Sources/PhoneStorage/` (S1), `Sources/PhoneIntegration/` (yours), `Sources/RecorderContracts/` (frozen for lanes, editable by you for approved requests), `Apps/`

## Ownership
- **Sole writer**: everything — but treat lane implementations as inputs. Fix integration seams and shared config yourself; do NOT rewrite lane logic. If you find a substantive defect inside a lane's logic, document it in handoff.md (goes to the findings ledger) rather than silently redesigning — small mechanical fixes are yours.
- **Do NOT edit**: `spec.md`, anything under `.agents/` except your own state dir (`I1-integration/`).

## Objective (from master plan)
Apply F0/C1/A1/S1 outputs, resolve shared configuration and dependency changes, and connect capture through transfer to the persistent local analysis queue. Implement conversation assembly across chunk boundaries, source-linked generated results, and preservation of user overrides. Reconcile the privacy and deletion lifecycle.

### Concrete work items
1. **Register dependencies** (from A1 §4.1 — exact):
   - `Package.swift`: `.package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.1")` and `.package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMinor(from: "2.31.3"))`; add `.product(name: "WhisperKit", package: "argmax-oss-swift")`, `.product(name: "MLXLLM", package: "mlx-swift-lm")`, `.product(name: "MLXLMCommon", package: "mlx-swift-lm")` to the `PhoneAI` target only. Watch targets must NOT pull these (iOS-only). Resolve and build. Note: Xcode 27 requires the Metal Toolchain component for mlx-swift (`xcodebuild -downloadComponent MetalToolchain`) — A1 already used MLX on this machine so it is likely installed; verify and record.
2. **Decide S1's five contract requests** (App. D): apply the ones you adopt into `Sources/RecorderContracts/` (you own it now — bump nothing else; keep types additive/back-compatible where lanes already bind). Recommended: promote store APIs into a second protocol or extend `ConversationArchiveStoreProtocol` so app/integration code doesn't bind `SQLiteArchiveStore` concretely; decide per-request, record accept/reject + reason per item in handoff.md. Keep `PhoneReceiveServiceProtocol`'s transport seam formalization optional.
3. **Wire the real pipeline in `Sources/PhoneIntegration/`**:
   - `SessionCoordinator` gets the real `PhoneReceiveService` + `SQLiteArchiveStore` + adapters built via `PhoneAI.makeSpeechAdapter/makeTextAdapter` (A1 §4.2 snippet), all sharing the `ModelExecutionGate`.
   - Chunk arrival → verified store → enqueue `AnalysisJob(.transcription)`; `AnalysisJobRunner` drains: transcribe → persist `TranscriptSegment`s → then `.intelligence` jobs: `proposeConversationGroups` across chunk boundaries → upsert groups → `generateMetadata` → persist **only where `hasUserOverride` does not protect the field** (check per field via the store's override APIs — S1 built these; generated rows stay versioned verbatim, effective view swaps in overrides).
   - Session truth channel: S1 flagged no contract path feeds `upsertSession` — decide and implement a minimal honest path (e.g. coordinator accepts session snapshots over the existing wire or app-driven upsert); document what you chose.
   - `flushDeletionIntents()` after deletions + on activation/reachability (S1 App. B).
   - Keep `PlaceholderCompatibility` aliases or remove once nothing references them — your call; app shell must bind real services regardless (F-03).
4. **App shells + config**:
   - Rewire `Apps/PhoneRecorderApp/` off `Placeholder*` typealiases onto the real coordinator/store (minimal honest UI is fine — U1 owns the real product UI later; the app must exercise real services, not mocks).
   - `Info.plist` (phone): add `BGTaskSchedulerPermittedIdentifiers` (`com.placeholder.PhoneRecorder.processing`) ONLY if you implement BG processing-task draining of the analysis queue (S1 recommends it; spec tolerates foreground-only — your call, document the decision). Wire `flushDeletionIntents` on app lifecycle.
   - Signing stays placeholder (ENV-05 — no team ID available); keep `CODE_SIGN_STYLE=Automatic`, `DEVELOPMENT_TEAM=""` and record the gap.
   - Verify `isExcludedFromBackup` on `Application Support/WatchCapture/` (C1 request 5) and `RecorderArchive/` roots at first-real-write paths; file-protection class stays `.completeUntilFirstUserAuthentication` (S1's locked-ingest reasoning).
5. **Wire-contract sanity check by inspection**: C1 sender (`WCSessionTransport`/`WatchTransferService.apply`/`InboundCommandDecoder`) ↔ S1 receiver (`WatchConnectivityReceiveTransport` incl. tombstone echoed-digest acks + `discard` propagation). Confirm shapes match on both directions; fix decoding mismatches on the receiver/decoder side, not by redesigning either lane.
6. **Deletion/lifecycle reconciliation**: delayed transfers must not resurrect tombstoned content (S1 already enforces — verify the paths are wired end-to-end, incl. `discard` reaching the watch transport seam); deletion during queued analysis cancels/invalidates the right jobs; late chunks update provisional groups without overwriting user overrides.
7. **Diagnostics**: ensure `DiagnosticsEvent`s from capture/transfer/storage/ai land queryable for Gate A (S1's `diagnosticsReport` + watch `events.jsonl` export path documented); no content-bearing payloads anywhere.
8. **F-01 span-level redaction**: spec permits the shared-file option S1 chose — leave as-is, mark finding as "product decision pending" in your handoff; do NOT silently implement span redaction.
9. **Build + commit**: `swift build --scratch-path .build/i1` (all targets incl. real deps), `xcodebuild` both schemes with `-derivedDataPath .build/DerivedData-i1` — then `git add`/`git commit` the merged tree on `main` (one or a few clean commits; `.build/` is gitignored). Record the final output SHA.
10. **Manual e2e status**: no devices/simulators exist (ENV-02/03) — you cannot run the recording session. Instead: compile-verify everything, trace the public workflow in code (start → chunk → transfer → ingest → transcribe → group → metadata → archive), and document precisely which observable steps remain unexercised. Do NOT fabricate a manual run.

## Hard Rules
- No tests of any kind; no test targets/actions/harness.
- No delegation/subagents — do the work yourself.
- No cloud AI, no Apple Intelligence requirement, no English-only models.
- Files only inside the repo + your state dir. `spec.md` and `.agents/` coordination files (except your own state dir) are parent-owned — read-only.
- Keep `Package.swift` honest: only the two A1 dependencies with the exact pins above; nothing else speculative.

## Build-Only Verification
```sh
cd /Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec
swift build --scratch-path .build/i1
xcodebuild -project WatchRecorder.xcodeproj -scheme PhoneRecorderApp \
  -destination "generic/platform=iOS Simulator" -derivedDataPath .build/DerivedData-i1 build
xcodebuild -project WatchRecorder.xcodeproj -scheme WatchRecorderApp \
  -destination "generic/platform=watchOS Simulator" -derivedDataPath .build/DerivedData-i1 build
```

## State Folder
`/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec/.agents/teamwork/orchestrator_swe2max_plan/I1-integration/` — write `progress.md` and `handoff.md` here only.

## Exit Criteria & Handoff
- All targets + both app schemes build cleanly **with real dependencies registered**; working tree committed on `main` and clean; no tests anywhere.
- `handoff.md` five-part structure + explicit sections: per-request accept/reject table for S1's 5 contract asks + C1's config asks + A1's dep asks; what remains unexercised without devices; any lane-internal defects found (→ ledger); final output commit SHA; Gate A readiness summary (what hardware/user inputs are still needed).
