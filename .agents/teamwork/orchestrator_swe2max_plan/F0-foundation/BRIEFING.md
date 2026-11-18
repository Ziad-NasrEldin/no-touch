# F0 — Foundation Worker Briefing

## Assignment Identity
- **Role**: `F0 — Foundation worker` (Phase 0)
- **Model**: `acpRegistry_devin` / `swe-2-high` (`thought_level: "max"`, `mode: "accept-edits"`, `speed: "standard"`)
- **Client Request ID**: `awr-f0-foundation-01`
- **Isolation**: `shared` (sole writer in `/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec` during Phase 0)
- **Base Commit**: `7ff2d31e69def428aaf16a9142038211a50c9bef` (`main`)

## Original Request & Confirmed Constraints
- User prompt: *"I wanna build an all day apple watch recorder / Should use an on device or on iphone AI model to sort and categorize conversations / How do we do it"* -> *"Start the orchestra"* -> *"No yhere is devin SWE 2 on max effort"*
- Hardware target: iPhone 14 Pro Max (not Apple Intelligence eligible) + Apple Watch (believed Series 6).
- Primary language: Saudi/Gulf Arabic with occasional English code-switching.
- Experience: Start once and capture conversations throughout the day; local AI processing only (no cloud transcription, no cloud summarization, no Apple Intelligence dependency).
- Verification boundary: Recording session and its resulting conversation archive.
- **PROHIBITION**: Do not write or run any unit or integration tests. Do not introduce an automated harness as a substitute. Build-only and manual device checks are allowed.

## Input Artifacts
- Specification: `/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec/spec.md`
- Master Orchestration Plan: `/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec/.agents/teamwork/orchestrator_swe2max_plan/BRIEFING.md`
- Findings Ledger: `/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec/.agents/teamwork/orchestrator_swe2max_plan/FINDINGS_LEDGER.md`
- State Folder (write only `progress.md` and `handoff.md` here): `/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec/.agents/teamwork/orchestrator_swe2max_plan/F0-foundation/`

## Required Architecture & Deliverables
1. **Modular Swift Package (`Package.swift`)**:
   - `RecorderContracts` (`Sources/RecorderContracts/`)
   - `WatchCapture` (`Sources/WatchCapture/`, depends on `RecorderContracts`)
   - `PhoneAI` (`Sources/PhoneAI/`, depends on `RecorderContracts`)
   - `PhoneStorage` (`Sources/PhoneStorage/`, depends on `RecorderContracts`)
   - `PhoneIntegration` (`Sources/PhoneIntegration/`, depends on `RecorderContracts`, `PhoneAI`, `PhoneStorage`)
   - **Zero test targets** in `Package.swift`.
   - Keep `Package.swift` self-contained without speculative remote AI package dependencies (record dependency recommendations for `A1` in `handoff.md`).
2. **Native iOS & watchOS Xcode Project (`WatchRecorder.xcodeproj`)**:
   - `PhoneRecorderApp` (`Apps/PhoneRecorderApp/`, iOS app target, paired with local Swift package targets `RecorderContracts`, `PhoneAI`, `PhoneStorage`, `PhoneIntegration`).
   - `WatchRecorderApp` (`Apps/WatchRecorderApp/`, watchOS app target, paired with local Swift package targets `RecorderContracts`, `WatchCapture`).
   - Build-only shared schemes (`PhoneRecorderApp`, `WatchRecorderApp`) with **no test targets and no test actions**.
   - Signing placeholders (`CODE_SIGN_STYLE = Automatic` or configurable team placeholder) and explicit Info.plist / background modes / microphone usage placeholders as needed, documenting any signing/provisioning gaps as open findings.
3. **Narrow Shared Contracts (`Sources/RecorderContracts/`)**:
   - Recording session lifecycle: `RecordingSession`, `SessionState` (`idle`, `recording`, `paused`, `interrupted`, `stopped`), `FailureReason` (microphone denied, low storage, low battery, audio session interrupted, unrecoverable termination, unknown).
   - Chunk identity, timing & integrity: `AudioChunkMetadata`, `ChunkIntegrity` (SHA-256 hex digest, byte count, duration, sequence number, monotonic/wall timestamps, silence/VAD metadata), `InterruptionInterval`.
   - Durable transfer & acknowledgment: `TransferAcknowledgment`, `TransferStatus`.
   - Local analysis jobs & retry state: `AnalysisJob`, `AnalysisJobState`, `AnalysisJobKind` (transcription, grouping/intelligence), `ModelReadinessState`.
   - Transcripts & conversations: `TranscriptSegment`, `LanguageSpan` (preserving Arabic/English tags and exact source timing), `ConversationGroup`, `GeneratedConversationMetadata`, `DecisionItem`, `ActionItem`, `SourcePassageReference`.
   - User overrides, deletion & retention: `UserOverrideRecord`, `DeletionIntent`, `RetentionPolicy`, `AudioAvailabilityState`.
   - Diagnostic evidence format: `DiagnosticsEvent`, `DiagnosticsSubsystem` (`capture`, `transfer`, `storage`, `ai`, `lifecycle`), `DiagnosticsReport` (structured JSON-codable evidence for Gate A hardware/AI measurements without content-bearing telemetry).
   - Service protocol boundaries for Phase 1 lanes:
     - `WatchCaptureServiceProtocol` (for `C1`)
     - `WatchTransferServiceProtocol` & `PhoneReceiveServiceProtocol` & `ConversationArchiveStoreProtocol` (for `S1`)
     - `SpeechTranscriptionAdapterProtocol` & `TextIntelligenceAdapterProtocol` (for `A1`)
4. **Placeholder Compilable Implementations**:
   - Minimal compilable stubs in `Sources/WatchCapture/`, `Sources/PhoneAI/`, `Sources/PhoneStorage/`, `Sources/PhoneIntegration/`, `Apps/WatchRecorderApp/`, `Apps/PhoneRecorderApp/` so all SPM targets and both Xcode app targets compile cleanly right now.
5. **Lane Ownership Map**:
   - Document exact file/directory ownership boundaries for `C1`, `A1`, `S1`, `I1`, and `U1` in `handoff.md` so Phase 1 can run 3 workers concurrently without conflicts.

## Build-Only Verification Commands
- `swift build --package-path /Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec --scratch-path /Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec/.build/f0`
- `xcodebuild -project /Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec/WatchRecorder.xcodeproj -scheme PhoneRecorderApp -destination "generic/platform=iOS Simulator" -derivedDataPath /Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec/.build/DerivedData-f0 build`
- `xcodebuild -project /Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec/WatchRecorder.xcodeproj -scheme WatchRecorderApp -destination "generic/platform=watchOS Simulator" -derivedDataPath /Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec/.build/DerivedData-f0 build`
- Never run `swift test`, `xcodebuild test`, or `xcodebuild test-without-building`.

## Prohibitions
- Do NOT write or run any unit or integration tests or add any test targets.
- Do NOT delegate or launch subagents.
- Do NOT modify files outside `/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec`.
- Do NOT modify `spec.md` or parent-owned coordination files (`ROSTER.md`, `FINDINGS_LEDGER.md`, `model-selection.json`, root `BRIEFING.md`).
- Do NOT implement full UI, full audio capture, AI model inference, or full WatchConnectivity/SQLite persistence in Phase 0.
- Do NOT add cloud AI fallbacks or require Apple Intelligence.

## Exit Criteria & Handoff
- All Swift Package targets and both `PhoneRecorderApp` and `WatchRecorderApp` Xcode targets build cleanly without tests.
- Commit all Phase 0 deliverables (including `F0-foundation/progress.md` and `F0-foundation/handoff.md`) on `main` in `/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec` (leave working tree clean; `.build/` is gitignored).
- `handoff.md` must follow the five-part structure:
  1. Observations with exact evidence (commands + outputs, commit SHA, created files).
  2. Reasoning tied to those observations.
  3. Caveats and unverified areas (including signing, physical Watch/iPhone OS versions, simulator runtime absence, and dependency choices left open for `A1`).
  4. Conclusion.
  5. Independent verification instructions (build-only commands).
