# S1 — Phone transfer & archive handoff

Role: `S1 — Phone transfer and archive worker` · Client request ID `awr-s1-storage-01`
Base commit: `4e36a081194841ab1321214c2cd940f42158fee3` (`main`, F0 output)
Output: uncommitted changes in `Sources/PhoneStorage/` only (no git writes performed, per dispatch).

## 1. Observations with exact evidence

### Files delivered (all inside `Sources/PhoneStorage/`)

| File | Contents |
| --- | --- |
| `ArchivePaths.swift` | `ArchiveFileLayout` — single app-owned root `Application Support/RecorderArchive/` with `archive.sqlite3`, `incoming/` (temp landing), `chunks/<sessionID>/` (durable verified files), `quarantine/` (unaccounted/corrupt files). File-protection + backup-exclusion helpers, `RECORDER_ARCHIVE_DIR` env override for manual exercise. |
| `SQLiteDatabase.swift` | Internal `ArchiveDatabase` — system `SQLite3` (WAL, `busy_timeout=5000`, `synchronous=NORMAL`, FULLMUTEX), synchronous API owned by the store actor; schema v1 + `PRAGMA user_version` migration seam. |
| `SQLiteArchiveStore.swift` | `SQLiteArchiveStore` — real `ConversationArchiveStoreProtocol` + `DiagnosticsSink`: sessions, chunk registry (dedup index), transcript segments, conversation groups + membership, generated metadata, overrides, tombstones, jobs, retention, search, diagnostics ring. |
| `TranscriptSearch.swift` | `TranscriptNormalizer` (Arabic+Latin normalization) + tokenizer + `TranscriptSearchHit`. |
| `PhoneReceiveService.swift` | `PhoneReceiveService` — real `PhoneReceiveServiceProtocol` + `ingestReceivedFile` (transport seam) + crash-repair sweep. |
| `WatchConnectivityTransport.swift` | `WatchConnectivityReceiveTransport` — iOS-only `WCSession` adapter (`#if os(iOS) && canImport(WatchConnectivity)`); absent from the macOS build. |
| `PlaceholderCompatibility.swift` | `PlaceholderReceiveService`/`PlaceholderArchiveStore` typealiases over the real types. |
| — deleted — | `PlaceholderReceiveService.swift`, `PlaceholderArchiveStore.swift` (in-memory stubs removed; the F0 app shell compiles via the aliases). |

### Build evidence (verbatim tails)

```text
$ swift build --scratch-path .build/s1 --target PhoneStorage
Build complete! (1.28 secs)

$ swift build --scratch-path .build/s1
Build complete! (12.98 secs)

$ xcodebuild -project WatchRecorder.xcodeproj -scheme PhoneRecorderApp \
    -destination "generic/platform=iOS Simulator" \
    -derivedDataPath .build/DerivedData-s1 build
** BUILD SUCCEEDED **
```

`PhoneStorage.swiftmodule` + `WatchConnectivityTransport.o` exist for both `arm64` and `x86_64` under `.build/DerivedData-s1/.../Debug-iphonesimulator/` — the iOS-gated WCSession code compiles.

### Manual exercise evidence (scratch driver, not a test target)

`/tmp/s1_driver.swift` (kept outside the repo) was compiled against `.build/s1` products (`swiftc … PhoneStorage.o RecorderContracts.o -lsqlite3`) and run twice in sequence against `/tmp/s1-archive-scratch` — first instance builds state, second instance is a relaunch. **34/34 checks PASS**, covering: ack fields (status/digest/byteCount), duplicate delivery re-ack with a single registry row, integrity-mismatch throw, user override surviving regenerated metadata, Arabic/English/diacritic-variant/prefix search hits with conversationIDs, job enqueue dedup + `nextAnalysisJob`, session upsert/read, `audioFileURL`, relaunch persistence of chunks/groups/overrides/search index, stale `.running` job recovered to `.queued`, conversation deletion → `.deleted` availability + group removal + orphaned chunk file removal + tombstoned redelivery that acks without resurrecting + chunk removed from search, conversation+cascaded-chunk intents queued for Watch propagation, and presence of `transfer.chunk_stored`/`transfer.dedup_hit`/`storage.deletion_applied` diagnostics events.

### Receive pipeline (exact order)

`WCSession didReceive file` → metadata decode (`"chunk"` key, JSON `Data`) → **synchronous copy into `incoming/`** (WCSession's `fileURL` is only valid inside the callback) → `ingestReceivedFile`: tombstone check → dedup check → land → streaming SHA-256 + byte-count verify → atomic `moveItem` into `chunks/<sessionID>/` → protection+backup attributes → dedup-index insert → `TransferAcknowledgment`. The Data-path `storeReceivedChunk` shares the same tail (`commitVerifiedDelivery`). Acks go back `["type":"ack","ack":Data]` via `sendMessage` when reachable, else `transferUserInfo`. `.failed` acks are returned for integrity/storage failures when the metadata decodes; undecodable deliveries are quarantined with no ack (the sender retries).

## 2. Reasoning tied to those observations

- **System `SQLite3`, zero new dependencies.** The briefing preferred zero-dep storage; `import SQLite3` uses the platform library, so `Package.swift` is untouched. One database file carries every durable structure with real transactions — a flat-file/append-store alternative would have re-implemented atomicity poorly.
- **Sync `ArchiveDatabase` owned by the store actor** (not an actor itself): store methods never suspend between DB calls, so multi-statement transactions can't be interleaved by another task — actor reentrancy can't corrupt `BEGIN…COMMIT`.
- **Dedup index = `chunks` table PRIMARY KEY + file-presence check**, consulted before any byte work and again before commit (a deletion racing a transfer still wins). `deletion_intents` is checked on every ingest AND every upsert, so delayed transfers, retries, or late AI output cannot resurrect deleted content — the spec's hard rule.
- **Tombstoned deliveries return `.acknowledged` echoing the metadata's declared digest/byteCount.** Verified against C1's `WatchTransferService.apply`: the Watch verifies the ack against its own metadata and only then discards its copy. A zero/honest `storedByteCount` would fail that check and *retain deleted audio* — the opposite of the deletion contract. The durable tombstone is the accounting; the Watch-side `discard` commands (sent via `transferUserInfo`) provide belt-and-braces cleanup.
- **Overrides are enforced at the storage boundary, not by convention.** `generated_metadata` rows store model output verbatim (versioned); `effectiveMetadata` swaps in the latest user override per field, and `hasUserOverride` is the explicit check A1/I1 must consult before writing regenerated output.
- **Conversation deletion cascades to orphaned chunk files only.** A chunk still referenced by live segments keeps its file (spec option: leave other transcripts intact); span-level audio redaction inside a still-shared file is a documented gap below. Implicit chunk tombstones are created so redelivery can't resurrect the audio and the Watch drops its copy.
- **Maintained inverted index over FTS5.** `TranscriptNormalizer` gives deterministic Arabic normalization (tashkeel/tatweel strip; أإآٱ→ا; ى→ي; ة→ه; ؤ→و; ئ→ي; Latin case/diacritic fold) identical at index and query time — diacritic-insensitive matching comes free, and nothing depends on Apple's SQLite compile flags or FTS tokenizer behavior. AND-semantics token matching with prefix ranges; one hit per (segment, conversation) pair.
- **`.completeUntilFirstUserAuthentication` protection class.** `.complete`/`.completeUnlessOpen` would block *creating* new chunk files while the phone is locked — exactly when background `WCSession` delivery happens for an all-day recorder. The chosen class keeps content unreadable before first unlock after boot while allowing locked-device ingest; it is applied to the root and every stored file. Tradeoff documented for I1: raw audio is readable while the device is unlocked-or-later; upgrading to `.completeUnlessOpen` would need ingest-time file pre-opening and is not compatible with background delivery.
- **Backup posture:** `chunks/`, `incoming/`, `quarantine/` are `isExcludedFromBackup` unconditionally (spec: exclude raw recordings). `excludeDerivedDataFromBackup` (default `true`) additionally excludes the DB/derived data — privacy-maximal default meaning a restored phone loses the archive; set it `false` if product wants transcript backup (audio still excluded).
- **Ack idempotence through the registry:** a crash between move and ack leaves an unregistered file → restart sweep quarantines it → the Watch's retry re-stores and gets a fresh ack. A crash after the registry insert re-acks via the dedup hit path. No window exists where the Watch deletes its copy without the phone holding durable state.

## 3. Caveats and unverified areas

- **No device exercise (ENV-02/03).** Everything below §Manual-verification gaps is unexercised; `WCSession` behavior on real paired hardware (queue ordering, `transferFile` timing, reachability semantics while the phone is locked) is compile-verified only.
- **Wire format is aligned by inspection, not by a live pairing.** I read C1's `WCSessionTransport`/`InboundCommandDecoder`/`WatchTransferService.apply` and adapted my transport to their on-the-wire shapes (see §Wire contract). Differences I could not have honored in the other direction were absorbed on my side; I1 should sanity-check the end-to-end loop on devices.
- **Span-level audio redaction is not implemented** (spec allows either removing the deleted conversation's audio spans or keeping shared files; I keep shared files and report `.deleted` for the deleted conversation). A shared chunk file still physically contains the deleted conversation's audio until every referencing conversation is deleted — flag for product decision.
- **`audioAvailability` is a per-conversation rollup** (`available`/`pending`/`expired`/`deleted`), not per-span; mixed states collapse (see contract-change request 3).
- **File protection was not runtime-verified** (no device); the attribute is applied at store/move time on iOS and is a no-op on macOS.
- **The F0 app shell** (`Apps/PhoneRecorderApp/ContentView.swift`) still calls the `Placeholder*` names — now typealiases over the real implementations at the default Application Support location. It will open a real archive on launch; I1 should rewire explicitly.
- **Simulator-runtime absence (ENV-03)** means `PhoneRecorderApp` was built, never launched.
- **One transient sibling build failure** (`PhoneAI/ModelInstallController.swift`) was observed mid-run and resolved by the A1 lane; not my code, untouched.

## 4. Conclusion

The S1 lane is complete to the buildable, manually-exercised boundary: a real `PhoneReceiveServiceProtocol` (land→verify→atomic move→dedup→ack), a durable `ConversationArchiveStoreProtocol` on system SQLite, tombstone-guarded writes everywhere, override-protected generated metadata, job queue with restart recovery, retention expiry, ar+en local search, diagnostics evidence, privacy attributes, and an iOS-gated WCSession transport aligned with C1's wire format. Hard rules hold by construction: no ack precedes durable verified storage, the Watch's copy is never invalidated without an ack it can verify, and no delivery path can resurrect deleted content. Both the `PhoneStorage` target and the `PhoneRecorderApp` scheme build cleanly; no tests exist or were run.

## 5. Independent verification instructions

```sh
cd /Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec
swift build --scratch-path .build/s1 --target PhoneStorage        # → Build complete!
swift build --scratch-path .build/s1                              # → Build complete!
xcodebuild -project WatchRecorder.xcodeproj -scheme PhoneRecorderApp \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath .build/DerivedData-s1 build                    # → ** BUILD SUCCEEDED **
```

Manual store exercise (allowed: scratch entry point, not a test target): save `/tmp/s1_driver.swift` content (reproducible from this repo's history of the run; also summarized in `progress.md`), compile against `.build/s1` products as in §1, run `/tmp/s1driver <scratchdir>`. Expected: `ALL CHECKS PASSED` (34 checks). Never run `swift test`/`xcodebuild test`.

---

## Appendix A — Storage schema & migration posture

`archive.sqlite3`, `PRAGMA user_version = 1`, WAL journal. Tables: `sessions`, `chunks` (dedup index; `state` ∈ `stored|expired|deleted`, rows never removed), `segments` (+ `normalized_text`), `search_terms` (inverted-index postings), `groups`, `group_membership`, `generated_metadata`, `overrides`, `deletion_intents` (tombstones + `propagated_to_watch`), `jobs`, `diagnostics` (5k-row ring). Migration posture: additive steps only under version bumps, run in one transaction at open; content-bearing tables are never dropped in place — destructive change requires a copy-forward migration step. No migration has shipped beyond v1.

## Appendix B — Wire contract (verified against C1 source, 2026-11-18)

- **Watch→Phone:** `WCSession.transferFile` + metadata `["chunkID": String, "sessionID": String, "sequenceNumber": Int, "fileName": String, "chunk": Data(JSON AudioChunkMetadata)]`. My decoder also accepts `"chunkMetadata"` (Data or String).
- **Phone→Watch ack:** `["type":"ack", "ack": Data(JSON TransferAcknowledgment)]` via `sendMessage` (reachable) or `transferUserInfo` (queued). The Watch verifies `verifiedSHA256Hex`/`storedByteCount` against its own metadata before discarding — hence the echoed tombstone ack.
- **Phone→Watch deletion:** `["type":"discard", "chunkID": "<uuid>"]` per chunk tombstone via `transferUserInfo`; session/conversation deletions propagate through their cascaded chunk tombstones. `unpropagatedDeletionIntents()`/`markDeletionIntentsPropagated` drive `flushDeletionIntents()` on activation + reachability changes; the app should also call it after recording deletions.

## Appendix C — Info.plist / project-config requests for I1

- `BGTaskSchedulerPermittedIdentifiers`: add `com.placeholder.PhoneRecorder.processing` if I1 drains the analysis queue via `BGProcessingTask` (recommended; spec tolerates foreground-only processing but background draining matches "transfers and analysis may be delayed by OS scheduling"). Register/schedule in `Sources/PhoneIntegration/` or app code — no S1 plist edits were permitted.
- No App Group needed: the archive lives in the phone app's own Application Support; Watch↔Phone sharing goes through WCSession only.
- No plist key needed for file protection or backup exclusion — both applied programmatically at `ArchiveFileLayout.prepare()`/file move.
- No new SPM dependencies, no xcodeproj changes required (SwiftPM target picks up the new files).
- `WKCompanionAppBundleIdentifier` pairing keys already present from F0.

## Appendix D — Contract changes requested (for I1/parent sign-off)

1. **Promote concrete-store APIs into `ConversationArchiveStoreProtocol`** (or a second protocol): `searchTranscripts`, `effectiveMetadata`/`hasUserOverride`/`userOverrides`, `audioFileURL(chunkID:)`, `upsertSession`/`session`/`sessions`, `enforceRetention`, `unpropagatedDeletionIntents`/`markDeletionIntentsPropagated`, `analysisJobs`, `diagnosticsReport`. Today A1/I1/U1 would bind against `SQLiteArchiveStore` concretely.
2. **`AudioAvailabilityState` per span** — the spec's "retained text distinguished from expired audio" maps more faithfully to per-segment/per-chunk availability than a conversation rollup; suggest `audioAvailability(segmentID:)` or returning per-chunk states.
3. **`TransferStatus` case for deletion-acks** (e.g. `.dropped`) would let the Watch distinguish "stored" from "tombstoned-acknowledged" — cosmetic today since `discard` commands carry the real signal; optional.
4. **Watch→Phone session-state channel** — `RecordingSession` truth has no contract path to the phone (`upsertSession` exists but nothing feeds it); suggest an `applicationContext`/`userInfo` payload shape via the existing wire or a new contract method.
5. **`PhoneReceiveServiceProtocol` could expose the transport seam formally** (`ingestReceivedFile`) so I1 doesn't depend on the concrete type for the WCSession path — optional.

## Appendix E — Manual-verification gaps & Gate A protocol

Not performed (devices/simulators unavailable — ENV-02/03); evidence must be gathered on hardware, not fabricated:

- **Disconnect/reconnect:** start capture on the Watch, disable/enable the phone connection (airplane mode / move out of range), confirm queued `transferFile`s drain in order, dedup index holds under redelivery, and `transfer.ack_sent`/`dedup_hit` diagnostics reflect the retry burst. Check a phone reboot mid-queue and a Watch reboot mid-queue: outbox + dedup must lose nothing.
- **Deletion during transfer:** delete a conversation while one of its chunks is still in the Watch outbox; verify the next delivery gets a tombstone ack + `discard` command, the Watch drops its copy and outbox entry, and the phone archives nothing.
- **Delayed delivery after session deletion:** tombstone a session, then let a stale queued chunk arrive; confirm ack-and-drop with no row/file resurrection.
- **Locked-device ingest:** verify chunk files land while the phone is locked (exercises the `.completeUntilFirstUserAuthentication` choice) — record whether iOS delivers `transferFile` to a locked device in this app's configuration.
- **Low storage:** fill the device near capacity; confirm `storage.*` error diagnostics and no silent replacement of untransferred audio.
- **Gate A protocol (manual, on the real iPhone 14 Pro Max + paired Watch):** (1) install via Xcode with a real team/profile (ENV-05); (2) start a day session on the Watch; (3) record ≥1 h across silence, wrist-down, app switching, and one forced phone disconnect; (4) inspect the archive on-device or via a pulled container: chunk files present + verified (`chunks` row digest vs file hash), sequence gaps shown as gaps not silence, no duplicated timelines after retries; (5) pull `diagnosticsReport` — expect `transfer.*`/`storage.*` events only, no content-bearing payloads; (6) confirm `quarantine/` empty or explain every entry; (7) delete a conversation mid-transfer and verify both sides clean up. Record measured durations/byte counts — do not characterize endurance beyond them.
