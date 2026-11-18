# S1 — Phone Transfer & Archive Worker Briefing

## Assignment Identity
- **Role**: `S1 — Phone transfer and archive worker` (Phase 1, lane 3 of 3 running concurrently)
- **Model**: `acpRegistry_devin` / `swe-2-high` (`thought_level: "max"`, `mode: "accept-edits"`, `speed: "standard"`)
- **Client Request ID**: `awr-s1-storage-01`
- **Isolation**: `shared` — same working tree as sibling lanes C1 and A1. Sole writer of your owned directory only. Expect uncommitted sibling changes elsewhere; do not touch, revert, or commit them.
- **Base Commit**: `4e36a081194841ab1321214c2cd940f42158fee3` (`main`, F0 output). Coordination-only commits may land on `main` while you work.
- **Do NOT run `git commit`, `git add`, or any git write operation.** Your output is uncommitted changes in your owned directory plus your state files; I1 commits later.

## Original Request & Confirmed Constraints
- User prompt: *"I wanna build an all day apple watch recorder / Should use an on device or on iphone AI model to sort and categorize conversations / How do we do it"* -> *"Start the orchestra"*.
- Hardware: iPhone 14 Pro Max + Apple Watch believed Series 6. Local AI only — nothing content-bearing leaves the devices.
- Transfer contract (spec): asynchronous/delayerable WatchConnectivity delivery; persistent retryable queue; deduplication; **acknowledge only after the iPhone has durably stored a verified file**; Watch copy retained until that ack; received temp files moved into owned storage before reporting receipt; phone/Watch restarts lose no queue state.
- **PROHIBITION**: Do not write or run any unit or integration tests. Do not introduce an automated harness as a substitute. Build-only and manual checks are allowed.

## Input Artifacts (absolute paths)
- Repo root: `/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec`
- Spec: `spec.md` (esp. "Transfer contract", "Data model", "Deletion and retention", "Local privacy and lifecycle", "Presentation and search")
- Master plan: `.agents/teamwork/orchestrator_swe2max_plan/BRIEFING.md`
- F0 handoff: `.agents/teamwork/orchestrator_swe2max_plan/F0-foundation/handoff.md`
- Contracts (frozen, read-only): `Sources/RecorderContracts/` — implement `PhoneReceiveServiceProtocol` and `ConversationArchiveStoreProtocol` exactly.
- Your directory: `Sources/PhoneStorage/` (`PlaceholderReceiveService.swift`, `PlaceholderArchiveStore.swift`)

## Ownership
- **Sole writer**: `Sources/PhoneStorage/`.
- **Read-only**: `Sources/RecorderContracts/` (frozen — contract change requests go in handoff.md for I1).
- **Do NOT edit**: `Package.swift` (no new deps — prefer zero-dependency Foundation/SQLite-via-system-`SQLite3` or durable file-based storage; if you must have a package, justify in handoff.md for I1), `WatchRecorder.xcodeproj/`, `Apps/` (phone `Info.plist` needs like `BGTaskSchedulerPermittedIdentifiers` go in handoff.md), other `Sources/` dirs, `spec.md`, anything under `.agents/` except your state dir.

## Objective (from master plan)
Own Watch Connectivity receive handling, durable phone storage, acknowledgments, deduplication, retry persistence, transcript/conversation storage, and the local search foundation. Honor deletions and user overrides at the storage boundary.

- **Receive path**: implement `PhoneReceiveServiceProtocol` for real — a `WCSession`-activating receive service (behind a thin transport seam so it compiles/behaves on iOS and remains exercisable without a paired Watch): accept incoming `transferFile` deliveries + `transferFile` metadata, write to a temp landing area, verify SHA-256 + byte count against `AudioChunkMetadata`, move into owned durable chunk storage (atomic rename), update dedup index, and only then produce `TransferAcknowledgment` for reply. Duplicate deliveries must not duplicate archive state; out-of-order and redelivered chunks are normal.
- **Durable archive**: implement `ConversationArchiveStoreProtocol` with real persistence surviving relaunch (system `SQLite3` or an append/compaction file store — your call, document the choice): sessions, chunks + integrity, transcript segments with `LanguageSpan`s, conversation groups, generated metadata, analysis jobs with retry state, user overrides, deletion intents.
- **Deletion & overrides at the boundary**: `applyDeletionIntent` persists tombstones so delayed transfers/retries can't resurrect deleted content (dedup index checks deletion intents, not just received IDs); `recordUserOverride` makes user edits win over later generated reprocessing (I1/A1 outputs must not overwrite them — expose the override check clearly); deletion of a conversation invalidates its queued analysis jobs and marks shared-audio spans per `AudioAvailabilityState`/`RetentionPolicy`.
- **Search foundation**: a local search API over transcripts (Arabic + English) returning segment references with conversation IDs — FTS via SQLite FTS5 or a maintained inverted index; Arabic-aware normalization where cheap (diacritic-insensitive match is a plus, not required).
- **Diagnostics**: emit `DiagnosticsEvent`s (`.transfer`, `.storage`) — bytes received, dedup hits, ack latency, retry counts, storage failures — as structured evidence for Gate A. No content-bearing telemetry.
- **Privacy posture in code**: app-owned directories, `.completeFileProtection`-class attributes where compatible with locked-device capture (document the exact policy choice and its tradeoff), and helper that marks raw audio excluded from backup per spec.

## Hard Rules
- Never ack before durable verified storage. Never delete the Watch's only copy before a durable ack. Delayed/duplicate deliveries must not recreate deleted content.
- No `git` writes. No edits outside your owned dir + your state dir.
- Never run `swift test`, `xcodebuild test`, or `test-without-building`. Build-only + manual exercise of the store API from your own scratch entry point if useful (e.g. a small `main.swift` run through your scratch package — not a test target).
- Devices/simulators unavailable (ENV-02/03): no real WCSession or paired-Watch exercise possible. Document manual disconnect/reconnect observations you could not perform and the Gate A protocol for them — do NOT fabricate evidence.
- Keep WCSession code iOS-gated so the `PhoneStorage` target still builds for macOS (the package builds host-side via `swift build`).

## Build-Only Verification (use YOUR scratch paths)
```sh
cd /Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec
swift build --scratch-path .build/s1 --target PhoneStorage
xcodebuild -project WatchRecorder.xcodeproj -scheme PhoneRecorderApp \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath .build/DerivedData-s1 build
```
Sibling lanes may leave their directories mid-edit; if build errors are all outside `Sources/PhoneStorage/`, note and retry — do not fix siblings' code.

## State Folder
`/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec/.agents/teamwork/orchestrator_swe2max_plan/S1-transfer-storage/` — write `progress.md` and `handoff.md` here only.

## Exit Criteria & Handoff
- `PhoneStorage` target and `PhoneRecorderApp` scheme build cleanly; no tests exist or run.
- Real receive + durable archive + dedup + tombstone + search code replaces placeholders, implemented against the frozen contract signatures.
- `handoff.md` five-part structure + explicit sections: storage format/schema choice and migration posture, Info.plist/project-config requests for I1 (BGTaskScheduler ids, app groups, protection classes), manual disconnect/reconnect + deletion-during-transfer observations or documented gaps, contract changes requested, and the Gate A manual trial protocol.
