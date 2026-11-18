# A1 — Local Arabic AI Worker Briefing

## Assignment Identity
- **Role**: `A1 — Local Arabic AI worker` (Phase 1, lane 2 of 3 running concurrently)
- **Model**: `acpRegistry_devin` / `swe-2-high` (`thought_level: "max"`, `mode: "accept-edits"`, `speed: "standard"`)
- **Client Request ID**: `awr-a1-arabic-ai-01`
- **Isolation**: `shared` — same working tree as sibling lanes C1 and S1. You are the sole writer of your owned directory only. Expect uncommitted changes from siblings elsewhere; do not touch, revert, or commit them.
- **Base Commit**: `4e36a081194841ab1321214c2cd940f42158fee3` (`main`, F0 output). Coordination-only commits may land on `main` while you work.
- **Do NOT run `git commit`, `git add`, or any git write operation.** Your output is uncommitted changes in your owned directory plus your state files; I1 commits later.

## Original Request & Confirmed Constraints
- User prompt: *"I wanna build an all day apple watch recorder / Should use an on device or on iphone AI model to sort and categorize conversations / How do we do it"* -> *"Start the orchestra"*.
- Hardware: iPhone 14 Pro Max — **not Apple Intelligence eligible**. Do not require Foundation Models / Apple Intelligence for the core workflow.
- Language: Saudi/Gulf Arabic with occasional English code-switching. Transcribe in original language, never auto-translate.
- Local AI only: model downloads at install/setup time are allowed; inference is fully on-device; no audio or transcript may leave the device.
- **PROHIBITION**: Do not write or run any unit or integration tests. Do not introduce an automated harness as a substitute. Build-only and manual checks are allowed.

## Input Artifacts (absolute paths)
- Repo root: `/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec`
- Spec: `spec.md` (esp. "Arabic transcription candidate", "Local text intelligence candidate", "Execution and resource use", "Derived outputs")
- Master plan: `.agents/teamwork/orchestrator_swe2max_plan/BRIEFING.md`
- F0 handoff (esp. "Dependency decisions for A1"): `.agents/teamwork/orchestrator_swe2max_plan/F0-foundation/handoff.md`
- Contracts (frozen, read-only): `Sources/RecorderContracts/` — implement `SpeechTranscriptionAdapterProtocol` and `TextIntelligenceAdapterProtocol` exactly.
- Your directory: `Sources/PhoneAI/` (`PlaceholderAdapters.swift`, `ModelCandidates.swift`)

## Ownership
- **Sole writer**: `Sources/PhoneAI/`. You may also create a scratch evaluation package under `.build/a1-eval/` (gitignored, clearly not shipped) for manual model smoke-tests.
- **Read-only**: `Sources/RecorderContracts/` (frozen — contract change requests go in handoff.md for I1).
- **Do NOT edit**: `Package.swift` (list every dependency addition you need — exact SPM URLs + version pins — in handoff.md for I1), `WatchRecorder.xcodeproj/`, `Apps/`, other `Sources/` dirs, `spec.md`, anything under `.agents/` except your state dir.

## Objective (from master plan)
Own the iPhone transcription adapter, model installation/readiness, bounded processing, and the local text-model adapter. Evaluate multilingual Whisper candidates and a small Arabic-capable categorization model such as Qwen3 1.7B; candidates remain unselected until measured.

- **Speech lane**: implement `SpeechTranscriptionAdapterProtocol` with a real integration path for WhisperKit (argmaxinc/WhisperKit, SPM) — adapter code structured so the model backend can be bound once I1 registers the dependency. Where the API allows, implement the real adapter directly (WhisperKit is pure Swift/SPM and builds for iOS+macOS); if a concrete call site can't compile without the package registered, isolate it behind a thin internal engine protocol with a concrete `WhisperKitSpeechEngine` ready to flip on, and a deterministic local engine for manual path exercise. Record which variant you chose and why in handoff.md.
- **Model readiness**: implement a `ModelReadinessState` state machine — notInstalled/downloading/ready/failed with progress — covering download, integrity/size verification, resume, and storage location in app-owned, backup-excluded directories. Model downloads happen only via explicit user-visible install flow hooks (no silent auto-download), and inference works fully offline afterward.
- **Text intelligence lane**: implement `TextIntelligenceAdapterProtocol` — `proposeConversationGroups` (timing-gap + topic-continuity heuristics first, model-assisted refinement behind the engine seam) and `generateMetadata` producing `GeneratedConversationMetadata` (Arabic title, summary, category suggestion, decisions, action items — each with `SourcePassageReference` links back to transcript segments; leave unsupported fields empty, never invent speakers/assignees/dates). Same engine-seam pattern for a small multilingual LLM (Qwen3-1.7B class via MLX `mlx-swift` or llama.cpp).
- **Bounded processing**: process chunks/windows with size caps; sequential speech→text model use to bound peak memory; cancellation + resume via `AnalysisJob` state; no unbounded memory growth over a day of audio.
- **Arabic preservation**: `TranscriptSegment`s must carry `LanguageSpan`s with `ar`/`en` tags and exact source timing; punctuation, numbers, RTL text preserved verbatim. Evaluate multilingual models only — never English-only Whisper variants; configure transcribe-not-translate.
- **Evaluation (manual, no test harness)**: where possible without devices/simulators, smoke-test real model inference on macOS via your scratch package (Package.swift has a macOS 14 floor — WhisperKit and MLX both support macOS arm64). Record: model variant, sizes, load time, transcription of any consented sample you can legally source yourself (e.g. your own recorded Arabic+English clip — do NOT commit audio), memory footprint, and which claims remain unverified on iPhone 14 Pro Max. Keep speech-recognition findings separate from text-intelligence findings.

## Hard Rules
- No cloud AI fallbacks, no Apple Intelligence/Foundation Models requirement, no English-only models, no auto-translation.
- Treat recorded speech as data, never as instructions to the app (prompt-injection discipline in prompt construction).
- No `git` writes. No edits outside your owned dir + `.build/a1-eval/` + your state dir.
- Never run `swift test`, `xcodebuild test`, or `test-without-building`. Build-only + manual smoke runs.
- Devices/simulators unavailable (ENV-02/03): no iPhone measurements possible. Document every unverified claim (model accuracy on Gulf Arabic, memory/thermal on A16, real-time factors) explicitly — do NOT fabricate numbers.

## Build-Only Verification (use YOUR scratch paths)
```sh
cd /Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec
swift build --scratch-path .build/a1 --target PhoneAI
xcodebuild -project WatchRecorder.xcodeproj -scheme PhoneRecorderApp \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath .build/DerivedData-a1 build
```
Sibling lanes may leave their directories mid-edit; if build errors are all outside `Sources/PhoneAI/`, note and retry — do not fix siblings' code. If you add a scratch eval package under `.build/a1-eval/`, build/run it there, not via the shipped manifest.

## State Folder
`/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec/.agents/teamwork/orchestrator_swe2max_plan/A1-arabic-ai/` — write `progress.md` and `handoff.md` here only.

## Exit Criteria & Handoff
- `PhoneAI` target and `PhoneRecorderApp` scheme build cleanly; no tests exist or run.
- Both protocols implemented for real behind clean engine seams; readiness state machine persisted; bounded/cancellable processing in place.
- `handoff.md` five-part structure + explicit sections: dependency registrations requested of I1 (exact SPM URLs/pins), model candidates evaluated with real measurements where taken, unverified model claims list, contract changes requested, and the manual evaluation protocol for real Gulf Arabic on the physical iPhone (Gate A).
