# C1 — Watch capture worker progress

Role: `C1 — Watch capture worker` (Phase 1, lane 1 of 3) · Client request ID `awr-c1-capture-01`
Base commit: `4e36a081194841ab1321214c2cd940f42158fee3` (main, F0 output). HEAD at start: `7b54ace`; a sibling commit `6e3e1e5` landed mid-work — all C1 work left uncommitted for I1.
Owned dirs: `Sources/WatchCapture/`, `Apps/WatchRecorderApp/` only.

## Status: COMPLETE — both required builds pass; handoff written

## Status log

- Read BRIEFING.md, master BRIEFING, F0 handoff, all frozen contracts, spec capture/transfer sections, pbxproj.
- Confirmed facts driving design:
  - `swift build --target WatchCapture` compiles for **macOS host** → watchOS-only API (AVAudioSession, WatchConnectivity) lives behind `#if os(watchOS)` / `#if canImport(WatchConnectivity)` with honest stubs; all persistence/queue/integrity code platform-neutral.
  - `WatchRecorderApp` target has exactly 2 source files wired in pbxproj (explicit refs) → app wiring confined to `WatchRecorderApp.swift` + `ContentView.swift`.
  - Watch Info.plist already carries `NSMicrophoneUsageDescription`, `UIBackgroundModes=audio`, `WKBackgroundModes=audio`.
  - `WatchRecorderApp` links `RecorderContracts` + `WatchCapture` products.
- Implemented `Sources/WatchCapture/` (8 files, ~1,930 lines):
  - `CapturePaths.swift` — app-owned root `Application Support/WatchCapture/` (excluded from backup); session.json / outbox.json / chunks/<sid>/ / manifests/<sid>.json / diagnostics/events.jsonl.
  - `WatchDiagnostics.swift` — `@unchecked Sendable` lock-guarded JSONL sink, rolls at 2 MB, decodable for Gate A export; non-content-bearing payloads.
  - `CaptureEngine.swift` — `#if os(watchOS)` real AVAudioSession+AVAudioRecorder engine (AAC .m4a, mono, 16 kHz / 32 kbps settings); permission via `AVAudioApplication.shared` (watchOS 10+); interruption events bridged from NotificationCenter; macOS branch = honest `isSupported=false` stub.
  - `CaptureSessionStore.swift` — atomic JSON session + per-session chunk manifest persistence.
  - `WatchCaptureService.swift` (779 lines) — actor implementing `WatchCaptureServiceProtocol`: start/pause/resume/stop, 60 s prepare-ahead chunk rotation, SHA-256 + byte/duration/seq/monotonic+wall integrity, VAD power-meter annotation (never gates capture), 10 s confirmed-capture heartbeats, interruption bookkeeping (intervals open until capture confirmed again), relaunch-gap recovery with `.unrecoverableTermination`, orphan-chunk cleanup, ≥32 MB free-space gate.
  - `TransferTransport.swift` — internal `WatchChunkTransport` seam + `TransportEvent`s + liberal `InboundCommandDecoder` (wire contract documented in file for S1/I1).
  - `WCSessionTransport.swift` — `transferFile` sends chunk + metadata (incl. JSON `AudioChunkMetadata`); delegate → transport events; inbound ack/discard decoding on all WC channels; `UnavailableChunkTransport` stub elsewhere.
  - `WatchTransferService.swift` (382 lines) — durable outbox actor: queued→inFlight→awaitingAck→retired; demote-on-relaunch; ack verified (sha256 + bytes + sessionID) before deleting watch copy; 10 min ack-timeout requeue; `.failed` parked after 12 attempts, reset on `activate()`; explicit `discardChunk` path; re-entrancy-safe pump.
- Deleted `PlaceholderCaptureService.swift`, `PlaceholderTransferService.swift`.
- Rewired `Apps/WatchRecorderApp/WatchRecorderApp.swift` (`RecorderModel`: real services, stateUpdates, lifecycle forwarding, outbox activation) + `ContentView.swift` (Start/Pause/Resume/Stop, state, finalized + awaiting-ack counts, last capture time, error surface).
- Fix log (build-driven): `[String: Any]` static → computed (Sendable); `AVAudioApplication.shared.recordPermission`; `volumeAvailableCapacityKey` (important-usage key unavailable on watchOS); removed `setPreferredSampleRate` (iOS/tvOS only); `transferFile` nonnull return; `for-where` multi-clause → guard; `import RecorderContracts` in app file.
- Verified `WCSessionDelegate` method signatures against `WatchOS.sdk .../Headers/WCSession.h` (activation, reachability, `didFinishFileTransfer`, didReceive* family) — all match.
- Final builds:
  - `swift build --scratch-path .build/c1 --target WatchCapture` → `Build complete! (4.45 secs)`
  - `xcodebuild -project WatchRecorder.xcodeproj -scheme WatchRecorderApp -destination "generic/platform=watchOS Simulator" -derivedDataPath .build/DerivedData-c1 build` → `** BUILD SUCCEEDED **`
- No unit/integration tests written or run (per lane rule). No git write ops. Frozen files (RecorderContracts, Package.swift, xcodeproj, spec.md) verified untouched via `git diff --stat`.
- Wrote `handoff.md` (five-part) with I1 config requests + Gate A manual trial protocols.
