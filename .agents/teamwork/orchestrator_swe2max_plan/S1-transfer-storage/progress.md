# S1 — Phone transfer & archive worker progress

Role: `S1 — Phone transfer and archive worker` · Client request ID `awr-s1-storage-01`
Base commit: `4e36a081194841ab1321214c2cd940f42158fee3` · Isolation: shared tree, sole writer of `Sources/PhoneStorage/`.

## Status: complete — pending handoff.md

## Delivered files (`Sources/PhoneStorage/`)

- `ArchivePaths.swift` — app-owned layout (`Application Support/RecorderArchive`: `archive.sqlite3`, `incoming/`, `chunks/<sessionID>/`, `quarantine/`); `.completeUntilFirstUserAuthentication` protection + `isExcludedFromBackup` helpers; `RECORDER_ARCHIVE_DIR` env override for manual runs.
- `SQLiteDatabase.swift` — internal `ArchiveDatabase` (system `SQLite3`, WAL, `busy_timeout`, FULLMUTEX; sync API owned by the store actor so transactions are non-interleavable); schema v1 + `PRAGMA user_version` additive-migration posture.
- `SQLiteArchiveStore.swift` — full `ConversationArchiveStoreProtocol` + sessions, chunk registry/dedup index, tombstones (every upsert checks `deletion_intents`), overrides (`effectiveMetadata`/`hasUserOverride`), jobs w/ stale-running recovery + dedup, retention expiry, deletion cascades + watch-propagation queue, `searchTranscripts` (AND-token prefix search over ar+en), diagnostics table (5k ring) + `DiagnosticsSink` protocol.
- `TranscriptSearch.swift` — `TranscriptNormalizer` (tashkeel/tatweel strip, alef/ya/ta-marbuta folding, latin fold) + tokenizer + `TranscriptSearchHit`.
- `PhoneReceiveService.swift` — `PhoneReceiveServiceProtocol` for real: land→verify(SHA-256+size)→atomic rename→registry insert→ack; dedup re-ack; tombstone ack-and-drop; crash-repair sweep (incoming orphans deleted, unregistered/non-stored files quarantined).
- `WatchConnectivityTransport.swift` — iOS-gated `WCSession` transport; C1 wire format aligned (`"chunk"` Data metadata key, `["type":"ack","ack":Data]` acks, `["type":"discard","chunkID":..]` deletion propagation); not compiled on macOS.
- `PlaceholderCompatibility.swift` — `PlaceholderReceiveService`/`PlaceholderArchiveStore` typealiases over real impls (the F0 app shell instantiates these names; `Apps/` is outside my ownership). Deleted the two placeholder files.

## Decisions

- **SQLite (system `SQLite3`)** over file-store: one durable file carries metadata/index/jobs/tombstones/diagnostics with real transactions; zero new deps (Package.swift untouched).
- **Maintained inverted index** over FTS5: deterministic normalization for Arabic (diacritic-insensitive, alef/ya folding) and no dependency on Apple SQLite compile flags.
- **Tombstoned delivery acks echo declared digest/size** so the Watch's ack verification passes and it drops its copy (verified against C1's `WatchTransferService.apply`).
- **`.completeUntilFirstUserAuthentication`** over `.complete`: locked-device ingest must still create files (see handoff tradeoff).

## Build evidence

```text
$ swift build --scratch-path .build/s1 --target PhoneStorage
Build complete! (1.28–2.83 secs)  [multiple runs]

$ swift build --scratch-path .build/s1            # whole package incl. sibling lanes
Build complete! (12.98 secs)

$ xcodebuild -project WatchRecorder.xcodeproj -scheme PhoneRecorderApp \
    -destination "generic/platform=iOS Simulator" -derivedDataPath .build/DerivedData-s1 build
** BUILD SUCCEEDED **
```

Mid-run transient: sibling `PhoneAI/ModelInstallController.swift` errors appeared in one iOS run (their lane, mid-edit); not touched by me; the next run succeeded end-to-end. `PhoneStorage` emitted `swiftmodule`+`.o` for arm64+x86_64 iphonesimulator.

## Manual exercise (scratch driver, NOT a test target)

`/tmp/s1_driver.swift` compiled against `.build/s1` products; exercises public API over two store instances (relaunch): **34/34 checks PASS** — durable ack fields, dedup re-ack, integrity-mismatch throw, override-beats-regeneration, ar+en+diacritic+prefix search, job dedup/recovery, relaunch persistence, conversation deletion (.deleted availability, group removal, orphaned file removal, tombstoned redelivery acks without resurrection, propagation queue entries), diagnostics events present.

## Open items

- `handoff.md` writing (contract requests, plist/config asks, Gate A protocol, verification gaps).
