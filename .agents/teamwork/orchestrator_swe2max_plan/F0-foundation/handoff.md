# F0 — Foundation handoff

Role: `F0 — Foundation worker` (Phase 0) · Client request ID `awr-f0-foundation-01`
Base commit `349d58285edfbb12986539ac6d10fe7c4ffd3489` → output commit: the single Phase 0 commit on `main` whose parent is `349d582` (`git log -1 --format=%H` at HEAD; a commit cannot embed its own SHA).

## 1. Observations with exact evidence

**Created files** (all under `/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec/`):

- `Package.swift` — swift-tools-version 6.0; platforms iOS 17 / watchOS 10 / macOS 14; five library products; **zero test targets, zero remote dependencies**.
- `Sources/RecorderContracts/` — `Session.swift` (`RecordingSession`, `SessionState`, `FailureReason`, `InterruptionInterval`), `Chunks.swift` (`AudioChunkMetadata`, `ChunkIntegrity`, `AudioChunkFormat`, `VoiceActivitySummary`), `Transfer.swift` (`TransferAcknowledgment`, `TransferStatus`), `Analysis.swift` (`AnalysisJob`, `AnalysisJobState`, `AnalysisJobKind`, `ModelReadinessState`), `Transcripts.swift` (`TranscriptSegment`, `LanguageSpan`, `ConversationGroup`, `GeneratedConversationMetadata`, `DecisionItem`, `ActionItem`, `SourcePassageReference`), `Policy.swift` (`UserOverrideRecord`, `DeletionIntent`, `RetentionPolicy`, `AudioAvailabilityState`), `Diagnostics.swift` (`DiagnosticsEvent`, `DiagnosticsSubsystem`, `DiagnosticsSeverity`, `DiagnosticsReport`), `RecorderError.swift`, `ServiceProtocols.swift` (all six lane protocols).
- `Sources/WatchCapture/` — `PlaceholderCaptureService.swift`, `PlaceholderTransferService.swift`.
- `Sources/PhoneAI/` — `PlaceholderAdapters.swift`, `ModelCandidates.swift` (candidate IDs only, no vendored models).
- `Sources/PhoneStorage/` — `PlaceholderReceiveService.swift` (real SHA-256 verification via CryptoKit, in-memory store), `PlaceholderArchiveStore.swift` (in-memory archive + job queue honoring deletion intents).
- `Sources/PhoneIntegration/` — `SessionCoordinator.swift` (receive → enqueue transcription seam).
- `Apps/PhoneRecorderApp/` — `PhoneRecorderApp.swift`, `ContentView.swift`, `Info.plist` (no mic key; `WKWatchCompanionAppBundleIdentifier` pairing key).
- `Apps/WatchRecorderApp/` — `WatchRecorderApp.swift`, `ContentView.swift`, `Info.plist` (`NSMicrophoneUsageDescription`, `UIBackgroundModes`+`WKBackgroundModes` audio, `WKApplication`, `WKCompanionAppBundleIdentifier`).
- `WatchRecorder.xcodeproj/project.pbxproj` — targets `PhoneRecorderApp` (iOS, SDKROOT iphoneos, bundle id `com.placeholder.PhoneRecorder`) and `WatchRecorderApp` (watchOS, bundle id `com.placeholder.PhoneRecorder.watchkitapp`); `XCLocalSwiftPackageReference "."` resolves repo-root package products; `CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM = ""` (empty placeholder).
- `WatchRecorder.xcodeproj/xcshareddata/xcschemes/{PhoneRecorderApp,WatchRecorderApp}.xcscheme` — build-only shared schemes; **no `<TestAction>` element**.

**Build evidence** (verbatim tails; full logs in `.build/` during the run):

```text
$ swift build --package-path … --scratch-path …/.build/f0
[13/13] PhoneIntegration-product
Build complete! (1.07 secs)

$ xcodebuild -project …/WatchRecorder.xcodeproj -scheme PhoneRecorderApp \
    -destination "generic/platform=iOS Simulator" -derivedDataPath …/.build/DerivedData-f0 build
** BUILD SUCCEEDED **

$ xcodebuild -project …/WatchRecorder.xcodeproj -scheme WatchRecorderApp \
    -destination "generic/platform=watchOS Simulator" -derivedDataPath …/.build/DerivedData-f0 build
** BUILD SUCCEEDED **
```

First `swift build` failed with `invalid redeclaration of 'archive()'` in `SessionCoordinator.swift`; fixed by renaming the accessor to `archiveStore()`. iOS build was re-run after removing `NSMicrophoneUsageDescription` from the phone `Info.plist` and still succeeded.

**Output commit**: the Phase 0 commit at `main` HEAD, parent `349d582` — 28 files, all Phase 0 deliverables including this handoff. (Pre-amend SHA was `1ef9ffb31c9e552f19244ac1f3c3292c1f245250`; amended only to add this line, so verify the final SHA with `git log -1 --format=%H`.)

**No tests**: `Package.swift` declares no `testTarget`s; neither scheme contains a `<TestAction>`; `swift test` / `xcodebuild test` were never invoked.

## 2. Reasoning tied to those observations

- **Contracts are pure value types** (`Codable`, `Sendable`, `Equatable`, `Hashable` where useful) so every lane serializes the same boundary types across WatchConnectivity, JSON diagnostics, and future SQLite rows without conversion layers.
- **Sequence number lives inside `ChunkIntegrity`** per the briefing's field list; `AudioChunkMetadata` carries identity (`id`, `sessionID`, `fileName`, `format`) and embeds `integrity`. Monotonic seconds order chunks across wall-clock corrections; wall dates anchor playback.
- **Acknowledgment contract is strict**: `PhoneReceiveServiceProtocol.storeReceivedChunk` returns `TransferAcknowledgment` only after digest+size verification (the placeholder already enforces this with CryptoKit), matching the spec's "ack only after durable, verified storage."
- **Placeholders are actors** — free `Sendable` correctness under Swift 6 strict concurrency, and they exercise every protocol method so Phase 1 lanes bind against real signatures, not stubs that compile but mislead.
- **`AnalysisJobKind` = `transcription` | `intelligence`** — the briefing's "grouping/intelligence" is one lane (`A1` text model), so grouping, categorization, and summarization share the `intelligence` kind.
- **Local package reference `relativePath = .`** works because `Package.swift` sits at the repo root beside `WatchRecorder.xcodeproj`; both builds resolved all five products with no project-level package resolution errors.
- **No embedded Watch app inside the iOS app**: standalone watchOS app keeps Phase 0 minimal; embedding (if desired for distribution pairing) is a Phase 2 integration decision, not a foundation requirement. Bundle IDs already follow the `watchkitapp` companion convention and the pairing plist keys are set.
- **Ownership partition avoids Phase 1 file conflicts**: contracts are frozen by F0 (changes require parent sign-off via handoff requests), each lane owns a disjoint directory (map below).

### Lane ownership map (Phase 1+)

| Lane | Owns (sole writer) | May read/consume | Shared files — propose in handoff, do NOT edit |
| --- | --- | --- | --- |
| `C1` watch capture | `Sources/WatchCapture/`, `Apps/WatchRecorderApp/` | `Sources/RecorderContracts/` | `Package.swift`, `project.pbxproj`, entitlements, watch `Info.plist` additions |
| `A1` local AI | `Sources/PhoneAI/` | `Sources/RecorderContracts/` | `Package.swift` (model deps — see below), `project.pbxproj` |
| `S1` transfer/storage | `Sources/PhoneStorage/` | `Sources/RecorderContracts/` | `Package.swift`, `project.pbxproj`, phone `Info.plist` (`BGTaskScheduler` ids) |
| `I1` integration | `Sources/PhoneIntegration/`, `WatchRecorder.xcodeproj/`, `Apps/*/Info.plist`, `Package.swift` | everything | merges lane handoffs; sole writer of shared config after Phase 1 |
| `U1` product UI | `Apps/PhoneRecorderApp/` (post-I1), `Apps/WatchRecorderApp/` UI | `Sources/PhoneIntegration/` APIs | shared config via handoff |

Notes: `RecorderContracts/` is owned by F0 and frozen at Phase 0 close; any lane needing a contract change lists it in its handoff for I1/parent to apply — Phase 1 lanes do not edit it. The `WatchTransferServiceProtocol` implementation lives inside `Sources/WatchCapture/` (`C1`'s directory) even though S1 owns the contract's consumer side; this keeps file ownership disjoint while honoring the briefing's protocol assignments.

### Dependency decisions for `A1` (deliberately left open)

`Package.swift` has **no remote dependencies** by design — none were added speculatively. `A1` should register, only after on-device measurement:

- **Speech**: `argmaxinc/WhisperKit` (SPM, on-device Whisper). Evaluate compressed `large-v3-turbo` vs smaller multilingual model (`AIModelCandidateCatalog` has placeholder IDs). Must run transcription (not translation), preserve `ar`/`en` spans, avoid English-only variants.
- **Text intelligence**: `Qwen3 1.7B` (or equivalent small multilingual) via an iOS-capable runtime — candidates: `mlx-swift` (`ml-explore/mlx-swift-examples`) or `llama.cpp`/`llama.swiftui`. Runtime choice is A1's call after memory/thermal measurement on iPhone 14 Pro Max.
- **Constraint**: nothing requiring Apple Intelligence / Foundation Models; no cloud AI. Model downloads at install time only; inference fully local.

### Signing / provisioning state

`CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM = ""` → builds to generic simulator destinations with no team configured (verified). Physical-device builds will need a real team ID + registered devices — recorded open finding `ENV-05`.

## 3. Caveats and unverified areas

- **Simulator runtimes absent**: `xcrun simctl` reports zero installed simulator runtimes (`ENV-03`), so builds targeted `generic/platform=… Simulator` destinations only — compile/codesign/validate verified, launch not exercised. No runtime, UI, audio, or WatchConnectivity behavior was observed.
- **Physical devices unverified**: Apple Watch model/OS, iPhone install route, mic-permission flows, background-audio entitlement behavior, and `WKCompanionApp` pairing are all unverified (`ENV-02`, `ENV-05`).
- **Signing placeholders**: `DEVELOPMENT_TEAM = ""` and `com.placeholder.*` bundle IDs must be replaced before device installs; watch `audio` background mode will need the entitlement-capability flow confirmed on a real team.
- **Deployment targets are placeholders**: iOS 17 / watchOS 10 chosen as safe floors before the Watch's exact model/OS is known (`ENV-02`); lower if Series 6 needs it once verified.
- **`Info.plist` gap for Phase 1**: phone `BGTaskSchedulerPermittedIdentifiers`, watch/phone `NSFileProtection` policy, and app-group/backup-exclusion decisions are deferred to S1/I1 per spec privacy section.
- **Placeholder services are in-memory**: state does not survive relaunch; `PlaceholderCaptureService.stateUpdates()` returns an empty stream; `audioAvailability` always reports `.pending`. These are compile-seam stubs, not behavior.
- **`XCLocalSwiftPackageReference "."` was hand-written** — verified by two clean `xcodebuild` runs, but lane workers regenerating the project file (e.g., via Xcode UI) should preserve this reference.
- **Swift 6 mode**: `SWIFT_VERSION = 6.0`, tools-version 6.0 — strict concurrency on. Contract types are `Sendable`; lane code should keep that discipline.
- **Not verified**: no device trials, no audio, no transfer, no model runs — per Phase 0 scope.

## 4. Conclusion

Phase 0 foundation is complete: the modular package (`RecorderContracts`, `WatchCapture`, `PhoneAI`, `PhoneStorage`, `PhoneIntegration`), both app targets, build-only schemes, signing placeholders, and the full contract surface for lanes C1/A1/S1 all compile cleanly on `main`. Lane boundaries are disjoint at directory granularity; contracts are frozen pending lane-change requests. Phase 1 (C1, A1, S1) can start in parallel from this checkpoint. Remaining risk concentrates in unverified hardware, signing, and runtime behavior — all explicitly open findings, none blocking Phase 1 coding.

## 5. Independent verification instructions

From the repo root (`/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec`), Xcode 27.2 / Swift 6.4.2:

```sh
# 1. Package build (all 5 targets, host platform)
swift build --package-path . --scratch-path .build/f0

# 2. iOS app
xcodebuild -project WatchRecorder.xcodeproj -scheme PhoneRecorderApp \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath .build/DerivedData-f0 build

# 3. watchOS app
xcodebuild -project WatchRecorder.xcodeproj -scheme WatchRecorderApp \
  -destination "generic/platform=watchOS Simulator" \
  -derivedDataPath .build/DerivedData-f0 build
```

Expected: `Build complete!` / `** BUILD SUCCEEDED **` ×3. Confirm no test surface: `grep -c testTarget Package.swift` → `0`, and `grep -c TestAction WatchRecorder.xcodeproj/xcshareddata/xcschemes/*.xcscheme` → `0` per file. Never run `swift test`, `xcodebuild test`, or `test-without-building`.
