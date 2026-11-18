# C1 — Watch Capture Worker Briefing

## Assignment Identity
- **Role**: `C1 — Watch capture worker` (Phase 1, lane 1 of 3 running concurrently)
- **Model**: `acpRegistry_devin` / `swe-2-high` (`thought_level: "max"`, `mode: "accept-edits"`, `speed: "standard"`)
- **Client Request ID**: `awr-c1-capture-01`
- **Isolation**: `shared` — same working tree as sibling lanes A1 and S1. You are the sole writer of your owned directories only. Expect uncommitted changes from siblings elsewhere in the tree; do not touch, revert, or commit them.
- **Base Commit**: `4e36a081194841ab1321214c2cd940f42158fee3` (`main`, F0 output). Coordination-only commits may land on `main` while you work; that does not change your code base.
- **Do NOT run `git commit`, `git add`, or any git write operation.** Your output is uncommitted changes in your owned directories plus your state files; the integration worker I1 commits everything later.

## Original Request & Confirmed Constraints
- User prompt: *"I wanna build an all day apple watch recorder / Should use an on device or on iphone AI model to sort and categorize conversations / How do we do it"* -> *"Start the orchestra"*.
- Hardware: iPhone 14 Pro Max (no Apple Intelligence) + Apple Watch believed Series 6 (unverified).
- Language: Saudi/Gulf Arabic with occasional English. Local AI only — no cloud, no Apple Intelligence.
- Experience: start once on the Watch, capture conversations all day, survive quiet periods and phone disconnection.
- **PROHIBITION**: Do not write or run any unit or integration tests. Do not introduce an automated harness as a substitute. Build-only and manual device checks are allowed.

## Input Artifacts (absolute paths)
- Repo root: `/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec`
- Spec: `spec.md`
- Master plan: `.agents/teamwork/orchestrator_swe2max_plan/BRIEFING.md`
- F0 handoff (ownership map, caveats): `.agents/teamwork/orchestrator_swe2max_plan/F0-foundation/handoff.md`
- Contracts (frozen, read-only for you): `Sources/RecorderContracts/`
- Your placeholders to replace: `Sources/WatchCapture/PlaceholderCaptureService.swift`, `Sources/WatchCapture/PlaceholderTransferService.swift`
- Your app shell: `Apps/WatchRecorderApp/` (you own it, including `ContentView.swift`, `WatchRecorderApp.swift`, `Info.plist`)

## Ownership
- **Sole writer**: `Sources/WatchCapture/` and `Apps/WatchRecorderApp/`.
- **Read-only**: `Sources/RecorderContracts/` (frozen — list any needed contract change in handoff.md for I1; do NOT edit).
- **Do NOT edit**: `Package.swift`, `WatchRecorder.xcodeproj/`, `Apps/PhoneRecorderApp/`, `Sources/PhoneAI/`, `Sources/PhoneStorage/`, `Sources/PhoneIntegration/`, `spec.md`, and anything under `.agents/` except your own state dir.
- Note: `WatchTransferServiceProtocol` (contract in RecorderContracts) is implemented by you inside `Sources/WatchCapture/` — the watch-side transfer-queue implementation is yours even though S1 owns the phone receive side.

## Objective (from master plan)
Own Watch audio capture, start/pause/resume/stop behavior, recoverable chunk persistence, interruption bookkeeping, and recording diagnostics.

- Implement `WatchCaptureServiceProtocol` for real: an actor (or equivalent `Sendable` design under Swift 6 strict concurrency) driving `AVAudioSession`/`AVAudioRecorder` (or `AVAudioEngine`) to capture mono audio into chunked files in app-owned storage.
- Chunk rotation: write short chunks (propose and justify a duration, e.g. 30–120 s) each producing `AudioChunkMetadata` with `ChunkIntegrity` (real SHA-256 via CryptoKit, byte count, duration, sequence number, monotonic + wall timestamps, silence/VAD summary if implemented). Never lose committed chunks when rotating.
- Interruption bookkeeping: record `InterruptionInterval`s for audio-session interruptions, app backgrounding, and post-relaunch gaps; distinguish confirmed-captured vs unknown/missing audio. A gap after a crash is "unknown/missing", not silence.
- Implement `WatchTransferServiceProtocol`: a persistent, restart-safe outgoing queue that enqueues finalized chunks, tracks `inFlight` vs awaiting-ack state, applies `TransferAcknowledgment`, and deletes the Watch copy only after a durable ack. Wire it to `WCSession` file transfer (`transferFile`) with retry — but keep the WCSession transport behind a small internal seam so S1's phone side can be integrated by I1. Persist queue state so app/Watch restart loses nothing.
- Diagnostics: emit `DiagnosticsEvent`s (subsystem `.capture`, `.transfer`, `.lifecycle`) and persist them so Gate A can pull real evidence (chunk counts, gaps, interruption intervals, timestamps). No content-bearing telemetry.
- Watch app shell: you may wire `Apps/WatchRecorderApp` minimally (record/pause/resume/stop controls + honest state display from `stateUpdates()`) so the capture path is manually exercisable. This is not the final UI — U1 owns that later — but the controls must drive the real service, not mocks.
- Keep capture time trustworthy through chunk rotation and quiet periods. VAD may annotate or trim persisted silence but must never gate whether the mic is capturing.

## Hard Rules
- Supported background audio only (`AVAudioSession` + `UIBackgroundModes`/`WKBackgroundModes` audio). NO workout sessions, silent playback, health-kit tricks, or unrelated execution modes to stay alive.
- No AI on the Watch. No claim of automatic restart after force quit or reboot — report the state honestly instead.
- No `git` write operations. No edits outside your owned dirs + your state dir.
- `Info.plist` additions beyond what exists (e.g. extra background modes) may be made inside `Apps/WatchRecorderApp/Info.plist` since you own that file; anything needed in the phone plist or project config goes in handoff.md as a request for I1.
- Never run `swift test`, `xcodebuild test`, or `test-without-building`. Build-only verification.
- Devices/simulators are currently unavailable (ENV-02/03): no physical Watch or iPhone is connected and zero simulator runtimes are installed. Do NOT fabricate runtime evidence — document manual-exercise steps you could not run and provide a written protocol for the 1-hour and full-day trials in handoff.md.

## Build-Only Verification (use YOUR scratch paths)
```sh
cd /Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec
swift build --scratch-path .build/c1 --target WatchCapture
xcodebuild -project WatchRecorder.xcodeproj -scheme WatchRecorderApp \
  -destination "generic/platform=watchOS Simulator" \
  -derivedDataPath .build/DerivedData-c1 build
```
Sibling lanes may leave their directories mid-edit; if a build failure's errors are all outside `Sources/WatchCapture/` or `Apps/WatchRecorderApp/`, note it and retry — do not fix siblings' code.

## State Folder
`/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec/.agents/teamwork/orchestrator_swe2max_plan/C1-watch-capture/` — write `progress.md` (as you go) and `handoff.md` (at the end) here only.

## Exit Criteria & Handoff
- `WatchCapture` target and `WatchRecorderApp` scheme build cleanly via your commands; no tests exist or run.
- Real capture/queue/persistence code replaces placeholders; contract-frozen APIs implemented against real signatures.
- `handoff.md` follows the five-part structure: (1) observations with exact evidence (commands+outputs, files created), (2) reasoning tied to observations, (3) caveats & unverified areas — including device/simulator unavailability and any contract changes requested, (4) conclusion, (5) independent verification instructions. Also include: permissions/Info.plist/project-config requests for I1, and the manual 1-hour + full-day trial protocol for Gate A.
