# C1 — Watch capture worker progress

Role: `C1 — Watch capture worker` (Phase 1, lane 1 of 3) · Client request ID `awr-c1-capture-01`
Base commit: `4e36a081194841ab1321214c2cd940f42158fee3` (main, F0 output). HEAD at start: `7b54ace` (coordination commit).
Owned dirs: `Sources/WatchCapture/`, `Apps/WatchRecorderApp/` only.

## Status log

- Read BRIEFING.md, master BRIEFING, F0 handoff, all frozen contracts, spec capture/transfer sections, pbxproj.
- Confirmed facts driving design:
  - `swift build --target WatchCapture` compiles for **macOS host** → watchOS-only API (AVAudioSession, WatchConnectivity) must live behind `#if os(watchOS)` / `#if canImport(WatchConnectivity)` with honest stubs; all persistence/queue/integrity code platform-neutral.
  - `WatchRecorderApp` target has exactly 2 source files wired in pbxproj (explicit refs, not synchronized groups) → app wiring confined to `WatchRecorderApp.swift` + `ContentView.swift`.
  - Watch Info.plist already carries `NSMicrophoneUsageDescription`, `UIBackgroundModes=audio`, `WKBackgroundModes=audio`.
  - `WatchRecorderApp` links `RecorderContracts` + `WatchCapture` products.
- Design decisions (to be justified in handoff):
  - Chunk duration 60 s, AAC `.m4a` mono 16 kHz @ 32 kbps via `AVAudioRecorder` (hardware-assisted encode, native watchOS support); rotation with prepare-ahead next recorder to bound the real gap, measured honestly via monotonic+wall stamps.
  - Durable outbox (`outbox.json`, atomic writes); `inFlight`/`awaitingAcknowledgment` demoted to `queued` on relaunch → resend safe because phone dedupes (contract), prevents stuck chunks when an ack was lost across a crash.
  - WCSession file transfer behind internal `WatchChunkTransport` seam; inbound ack/discard decoding liberal, wire format documented for S1/I1.
  - `InterruptionInterval` recorded only for unintentional gaps (audio-session interruption while recording, encode error, post-relaunch gap); user pause is session state, not missing audio. App backgrounding recorded as `.lifecycle` diagnostics — not a gap when background audio capture continues.
- Next: implement `Sources/WatchCapture/` files.
