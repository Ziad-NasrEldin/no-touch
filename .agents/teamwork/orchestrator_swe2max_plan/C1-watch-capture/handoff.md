# C1 — Watch capture worker — handoff

Lane: C1 (Phase 1, lane 1 of 3) · Client request ID `awr-c1-capture-01`
Scope delivered: real `WatchCaptureServiceProtocol` + `WatchTransferServiceProtocol` implementations, watch app shell wired to them, all in `Sources/WatchCapture/` and `Apps/WatchRecorderApp/`. Work left **uncommitted** for I1.

---

## Part 1 — Observations and exact evidence

### Files produced (all uncommitted)

| File | Lines | Role |
|---|---|---|
| `Sources/WatchCapture/CapturePaths.swift` | 57 | On-disk layout; root `Application Support/WatchCapture/` with `isExcludedFromBackup` |
| `Sources/WatchCapture/WatchDiagnostics.swift` | 127 | Durable JSONL diagnostics sink, rolls at 2 MB, decodable for Gate A export |
| `Sources/WatchCapture/CaptureEngine.swift` | 223 | `#if os(watchOS)` AVAudioSession+AVAudioRecorder; macOS honest stub |
| `Sources/WatchCapture/CaptureSessionStore.swift` | 73 | Atomic session + chunk-manifest JSON persistence |
| `Sources/WatchCapture/WatchCaptureService.swift` | 779 | Actor implementing `WatchCaptureServiceProtocol` |
| `Sources/WatchCapture/TransferTransport.swift` | 135 | Internal transport seam, `TransportEvent`, `InboundCommandDecoder` |
| `Sources/WatchCapture/WCSessionTransport.swift` | 154 | `WCSession`/`transferFile` transport + `UnavailableChunkTransport` |
| `Sources/WatchCapture/WatchTransferService.swift` | 382 | Actor implementing `WatchTransferServiceProtocol` (durable outbox) |
| `Apps/WatchRecorderApp/WatchRecorderApp.swift` | 100 | `RecorderModel`: real services, state updates, lifecycle forwarding |
| `Apps/WatchRecorderApp/ContentView.swift` | 88 | Real Start/Pause/Resume/Stop, state + counts + errors |

Deleted: `Sources/WatchCapture/PlaceholderCaptureService.swift`, `Sources/WatchCapture/PlaceholderTransferService.swift`.
Verified untouched: `Sources/RecorderContracts/`, `Package.swift`, `WatchRecorder.xcodeproj`, `spec.md`, sibling lanes' files (`git diff --stat` clean; `git status` shows only my paths plus siblings' untracked work).

### Build evidence (final runs, this exact tree)

```
$ swift build --scratch-path .build/c1 --target WatchCapture
[11/11] WatchCapture
Build complete! (4.45 secs)
```

```
$ xcodebuild -project WatchRecorder.xcodeproj -scheme WatchRecorderApp \
    -destination "generic/platform=watchOS Simulator" \
    -derivedDataPath .build/DerivedData-c1 build
…
Validate …/Debug-watchsimulator/WatchRecorderApp.app … builtin-validationUtility …
** BUILD SUCCEEDED **
```

No compiler warnings remain in C1-owned files on either build (checked via a warning-filtered clean rebuild; the only remaining output is Xcode's generic AppIntents metadata notice). Earlier warnings (deprecated `AVAudioSession` permission API, dead nil-check on `transferFile`) were fixed by adopting `AVAudioApplication.shared` and the nonnull return.

### Delegate signature verification

`WCSessionDelegate` methods are all `optional` — a wrong signature compiles silently and is never invoked. I diffed every implemented method against `/Applications/Xcode.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS.sdk/System/Library/Frameworks/WatchConnectivity.framework/Headers/WCSession.h`:

- `session(_:activationDidCompleteWith:error:)` ✓
- `sessionReachabilityDidChange(_:)` ✓
- `session(_:didFinish:fileTransfer error:)` → Swift `session(_:didFinish fileTransfer: WCSessionFileTransfer, error: Error?)` ✓
- `didReceiveMessage`/`…replyHandler`, `didReceiveMessageData`/`…replyHandler`, `didReceiveUserInfo`, `didReceiveApplicationContext` ✓

### On-disk evidence layout (runtime, for Gate A)

```
Application Support/WatchCapture/
  session.json              # RecordingSession + nextSequence (atomic writes)
  outbox.json               # [OutboxEntry] — chunk metadata + TransferStatus + attempts
  chunks/<sessionID>/chunk-NNNNNN-<uuid8>.m4a   # AAC mono files
  manifests/<sessionID>.json                    # [AudioChunkMetadata] finalized
  diagnostics/events.jsonl  # DiagnosticsEvent JSON lines (roll → events.1.jsonl)
```

### No runtime evidence exists

No device, simulator runtime, or paired phone was available. Everything below the build line is **compile-verified only**; nothing in this handoff claims audio was captured, transferred, or heard.

---

## Part 2 — Reasoning tied to observations

**Chunked capture.** 60 s chunks (`WatchCaptureService.defaultChunkDuration`) bound crash loss to ≤1 min and give `WCSession.transferFile` steady small payloads (~240 KB at 32 kbps). `AVAudioRecorder` was chosen over `AVAudioEngine`: hardware-assisted AAC encode, far less code on a battery-critical path, and native watchOS support. Rotation prepares the *next* recorder before stopping the current one so the real gap is only stop→start latency — and it is measured, not hidden: each chunk carries `monotonicStart/EndSeconds` + `wallStarted/EndedAt`, so a rotation gap shows up truthfully between adjacent chunks' stamps.

**Honest gap semantics.** `InterruptionInterval` = *a gap in confirmed capture*, per the contract — so intervals open on interruption/encode-error/capture-loss and **stay open until capture is confirmed again** (`activateAndRecord` closes them on success; `stopSession` closes at stop). A relaunch finding a persisted `.recording`/`.interrupted` session records `[lastConfirmedCaptureAt ?? startedAt → relaunch]` with `.unrecoverableTermination` and drops to `.interrupted` — no auto-restart, no fabricated coverage. User `pause` is session *state*, not an interval: paused time is intended silence, not missing audio.

**Integrity.** Every sealed chunk gets a real streaming SHA-256 (CryptoKit, 1 MiB reads), byte count from `attributesOfItem`, recorder-reported `duration`, monotonically assigned `sequenceNumber`, and a power-meter VAD summary (`VoiceActivitySummary`, −40 dBFS threshold, 1 s bins) that annotates but never gates capture — quiet speech still records.

**Durability.** `session.json`, manifests, and `outbox.json` all write via `Data.write(atomic:)` — a mid-write crash never tears state. A 10 s heartbeat persists `lastConfirmedCaptureAt` while recording so relaunch gaps bound tightly. Orphan chunk files (written but never manifested — e.g., crash mid-rotation) are deleted at next launch with a `capture` diagnostic.

**Outbox.** `queued → inFlight → awaitingAcknowledgment → retired` persisted per entry. Wire-side state (`inFlight`, `awaitingAck`) is demoted to `queued` at launch — resend is safe because the receive contract requires phone-side dedup on chunk id. An entry delivered but unacked for >10 min (`ackTimeout`) re-queues on the next pump event for the same reason. `.failed` entries park after 12 attempts and are reset by each `activate()` (fresh retry window on foreground). The watch copy is deleted only after `apply(acknowledgment:)` verifies `chunkID` + `sessionID` + `verifiedSHA256Hex` + `storedByteCount` against the outbox record; `discardChunk` is the separate explicit-delete path. The pump is re-entrancy-safe (`pumpAgain` coalescing) so an enqueue landing mid-drain is never stranded.

**Transport seam.** `WatchChunkTransport` is internal to `WatchCapture`; `WCSessionTransport` sends each file via `transferFile` with metadata `{chunkID, sessionID, sequenceNumber, fileName, chunk: <JSON AudioChunkMetadata>}`. `transferFile` is the right API precisely because it queues while the phone is unreachable — watch-initiated delivery with zero polling. Inbound acks/discards are accepted on every WC inbound channel (message, messageData, userInfo, applicationContext) via the liberal `InboundCommandDecoder`, documented in-file for S1/I1.

**Diagnostics.** `WatchDiagnostics` is a lock-guarded `@unchecked Sendable` class (not an actor) because emission must be callable synchronously from `init`, catch blocks, and nonisolated paths. Payloads are strings-only — chunk ids, sequence numbers, byte counts, durations, state names. No audio, transcript, or content-bearing data ever enters the log.

**Platform gating.** `swift build --target WatchCapture` compiles for macOS, so every AVFoundation/WC call lives behind `#if os(watchOS)` / `#if canImport(WatchConnectivity)`. The macOS branches are honest: `PlatformCaptureEngine.isSupported == false`, `startSession()` throws `.notImplemented`, and `UnavailableChunkTransport` throws `.unsupported` — the target builds everywhere but never pretends to capture off-watch.

**API choices forced by watchOS 10+ / SDK reality** (discovered by build failures, verified against SDK headers):
- `AVAudioApplication.shared.recordPermission` / `requestRecordPermission()` — the deprecated `AVAudioSession` permission APIs were replaced.
- `setPreferredSampleRate` does not exist on watchOS — removed; the AAC encoder still receives 16 kHz in its settings, so the *file* format is 16 kHz regardless of hardware rate.
- `volumeAvailableCapacityForImportantUsageKey` does not exist on watchOS — using `volumeAvailableCapacityKey` (a coarser but real floor check, ≥32 MB required before each new chunk).
- `transferFile` returns nonnull `WCSessionFileTransfer` — no send-time failure signal; failures arrive via `didFinish:error:` and feed `fileFinished` → re-queue.

---

## Part 3 — Caveats and unverified areas

1. **Zero runtime verification.** No watchOS simulator runtime or device exists on this machine. Audio capture, permission prompts, interruptions, WC delivery, ack flow, background endurance, and battery cost are all *unproven*. Gate A device trials (protocols in Part 5) are the first real test.
2. **watchOS background audio reality.** `UIBackgroundModes=audio` + `WKBackgroundModes=audio` are in the plist and an active `AVAudioSession` is the supported mechanism — but watchOS can still suspend the app on wrist-down/resource pressure in ways iOS does not. Whether a Series 6 sustains hours of recording is a hardware/OS question only a device answers. **No duration claim is made.**
3. **Auto-resume policy.** On `interruptionEnded(shouldResume:)` the service auto-resumes (plus one bounded 2 s recovery for encode-error/capture-loss). This implements "resume when the system allows" — but if the product wants a stricter user-must-tap-resume policy, that's a one-line policy change, not a contract change.
4. **Monotonic timestamps** use `ProcessInfo.systemUptime` — resets across reboots. Chunk ordering within a session is still correct; wall-clock anchors carry real time. Cross-reboot sequencing relies on `sequenceNumber` + wall dates.
5. **VAD** is average-power metering (cheap, honest), not a DSP/speech model — expect crude speech/silence numbers. It is annotation only.
6. **Outbox growth.** Low-storage is checked only at chunk *start*; an unreachable phone lets `chunks/` grow unboundedly within free space. No eviction policy exists — by design (never silently drop unacked audio) — but Gate A should watch `chunks/` size on a multi-day unreachable scenario.
7. **`.queued` send-failures retry forever** on each pump while the transport is dead (activation failure, no companion). That's honest — a dead transport means *everything* is dead — but the UI surfaces pending counts, not transport health; `transport-activate-failed` events in `events.jsonl` carry the reason.
8. **Contract observations (no changes requested, FYI for I1):**
   - `chunksAwaitingAcknowledgment(sessionID:)` is per-session; there is no "all pending" query, so the app UI counts only the *current* session's outbox rows. Chunks from older sessions still transfer fine — they're just invisible to `refreshCounts()`.
   - `TransferAcknowledgment` has no "reject" status beyond not-acknowledging — a corrupt/mismatched ack currently marks the entry `.failed` (parked), which is the intended visible failure.
   - `finalizedChunks(sessionID:)` reads the manifest for *any* persisted session id, so the contract already supports post-stop inspection.
9. **Wire contract is my proposal.** The metadata keys and inbound shapes are documented in `WCSessionTransport.swift`/`TransferTransport.swift` — S1's `WatchConnectivityTransport` must consume `metadata["chunk"]` (JSON `AudioChunkMetadata`) and reply with a `TransferAcknowledgment` in any decoded shape. If S1 defined a different envelope, align on one — decoder is liberal enough to absorb most.
10. **Signing/identifiers** are still placeholders (`com.placeholder.PhoneRecorder.watchkitapp` ↔ `com.placeholder.PhoneRecorder`). WCSession pairing *requires* these to be real, matching, and provisioned.
11. **Sibling drift.** S1 committed `6e3e1e5` during my work. I verified my lanes' files conflict with nothing, but I1 owns the merge.
12. **No unit or integration tests were written or run** — per the lane's hard rule. `swift test`/`xcodebuild test` were never invoked.

---

## Part 4 — Conclusion

C1 is complete to the limits of build-only verification: both required builds pass clean and warning-free; the capture service records real chunked AAC audio with real integrity data and honest gap bookkeeping; the outbox is durable, restart-safe, verified-ack-gated; the app exercises the real path. The design carries no runtime evidence — everything from "it compiles" to "it works" is Gate A's job on real hardware.

**Requests for I1 (permissions / project config):**

1. **Signing:** assign a development team to both `WatchRecorder` (phone) and `WatchRecorderApp` (watch) targets; replace placeholder bundle IDs in lockstep (`com.placeholder.PhoneRecorder` ↔ `.watchkitapp`) and update `WKCompanionAppBundleIdentifier` in the watch `Info.plist` to match the phone's final ID.
2. **Info.plist (watch):** `NSMicrophoneUsageDescription`, `UIBackgroundModes=audio`, `WKBackgroundModes=audio` already present — verify the description string is shippable App Review text. No new entitlements needed; WCSession needs none.
3. **Phone side (S1 handoff point):** the companion must activate `WCSession`, save incoming `transferFile`s, read `metadata["chunk"]` as JSON `AudioChunkMetadata`, dedupe on `chunk.id`, persist durably, then send back a `TransferAcknowledgment` (chunkID, sessionID, `.acknowledged`, verified SHA-256 hex, stored byte count) on any inbound channel — see `InboundCommandDecoder` for accepted shapes. Explicit deletion propagates as `["type":"discard","chunkID":"<uuid>"]`.
4. **Do not** add test targets or test actions for this lane's verification — Gate A is manual/device-based.
5. Verify `isExcludedFromBackup` on `Application Support/WatchCapture/` survives first install (set at directory creation; a pre-existing dir from an older build may not carry the flag).

---

## Part 5 — Independent verification

### A. Reproduce the builds (what I verified)

```bash
cd /Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec

swift build --scratch-path .build/c1 --target WatchCapture
# expect: Build complete!

xcodebuild -project WatchRecorder.xcodeproj -scheme WatchRecorderApp \
  -destination "generic/platform=watchOS Simulator" \
  -derivedDataPath .build/DerivedData-c1 build
# expect: ** BUILD SUCCEEDED **
```

Confirm frozen scope: `git status --short` must show changes only under `Sources/WatchCapture/`, `Apps/WatchRecorderApp/`, sibling lanes, and `.agents/…/C1-watch-capture/`; `git diff Sources/RecorderContracts Package.swift spec.md WatchRecorder.xcodeproj` must be empty.

### B. Gate A — 1-hour device trial (manual protocol)

Prereqs: provisioned watch+phone apps installed and paired; watch ≥80 % battery; phone app foreground once to activate WC.

1. Launch watch app → grant mic permission. Expect state `idle`, counts 0/0.
2. Tap **Start** → state `recording`. Speak ~2 min, stay silent ~2 min. Watch face may sleep — capture must continue.
3. Trigger a real interruption: take a cellular/phone call routed to the watch (or start/stop Siri). Expect state `interrupted` then auto-resume to `recording`; afterwards `interruptionIntervals` must contain one closed interval matching the call window.
4. **Pause** 3 min → state `paused` (no new chunks, no interval). **Resume** → `recording`, chunks continue with next sequence numbers.
5. Force-quit the watch app mid-recording (dock → swipe up). Relaunch → state must show `interrupted` with failure `unrecoverableTermination` and an open→closed gap covering the dead time. **Resume** manually — capture continues; sequence numbers must not reset.
6. **Stop** → `stopped`; finalized count = number of 60 s chunks minus dropped-empties.
7. With phone reachable: watch outbox drains (`awaitingAck` → 0); `chunks/<sid>/` files disappear as acks land. On phone: verify each file plays and its manifest entry's SHA-256 matches `shasum -a 256 <file>`.
8. With phone app killed/offline for 10 min of recording then restored: chunks queue on watch (`awaitingAck` grows), then drain on restore. Watch copies are deleted *only* after drain.
9. Export `events.jsonl` (Devices & Simulators → container download, or diagnostics copy). Must contain `capture-start`, `chunk-finalized` (seq 0…N, bytes, seconds, sha256 prefix), `interruption-began/ended`, `relaunch-gap`, `transfer-delivered`, `chunk-acknowledged` — all payload-only, no content.

Pass: every gap in the timeline is a recorded `InterruptionInterval`; every finalized chunk is either acked+deleted or still on watch; nothing pretends audio exists where the file is empty/missing.

### C. Gate A — full-day trial (manual protocol)

Same setup; charge watch to 100 %.

1. ~08:00 tap **Start**. Wear normally — commutes, conversations, calls, quiet desk time, workouts (note: do *not* start a workout-app audio session expecting ours to survive it; real interruptions may occur — that's what intervals are for).
2. Glance at the app 3–4× during the day *without touching controls*: state `recording`, finalized count growing ≈60 chunks/hour, `awaitingAck` draining when near the phone.
3. At day's end tap **Stop**. Export `events.jsonl`, `manifests/<sid>.json`, `session.json`, `outbox.json`.
4. Verify: (a) Σ finalized durations ≈ awake-recorded hours minus interval coverage; (b) every `InterruptionInterval` correlates with a real event (call, app kill, charge-removal); (c) `lastConfirmedCaptureAt` heartbeats show ≤10 s staleness during recording spans; (d) all acked chunks have matching on-phone SHA-256; (e) battery drain measured (Settings → Battery) — record it, no claim is made here; (f) `chunks/` on watch contains only unacked files.
5. Overnight/offline case (optional but valuable): airplane-mode the phone for 2 h mid-day → watch `awaitingAck` grows, chunks persist; reconnect → full drain, zero loss.

Pass = Gate A criteria met with measured numbers recorded into the integration report; any interval that can't be explained by a real event is a finding, not noise.
