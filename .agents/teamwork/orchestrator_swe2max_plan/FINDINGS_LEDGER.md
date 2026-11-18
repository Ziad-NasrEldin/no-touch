# Global Findings Ledger & Hardware/Environment Dependencies

## Hardware & Environment Dependencies

| ID | Category | Description | Current State | Owner | Evidence |
| --- | --- | --- | --- | --- | --- |
| `ENV-01` | Toolchain | Xcode `27.2` (Build `27B52`) with `iphoneos27.2`, `iphonesimulator27.2`, `watchos27.2`, `watchsimulator27.2` SDKs installed on `Ziad’s Mac mini` | `available` | Coordinator | `xcodebuild -version`, `xcodebuild -showsdks` |
| `ENV-02` | Physical Devices | `Ziad’s iPhone (27.0.1)` (`00008120-000E6564023B401E`) is paired but currently offline; physical Apple Watch (believed Series 6), exact watchOS version, and battery health are not yet connected/verified | `open` | User / Gate A | `xcrun xctrace list devices` |
| `ENV-03` | Simulators | `mcp_t3-code_device_list` returned `devices: []` and `agentDeviceInstalled: false`; `xcrun simctl list devices available`, `xcrun simctl list runtimes`, and `xcrun simctl runtime list` returned 0 simulator disk images (`0.0G`). Generic Xcode SDK destinations (`generic/platform=iOS Simulator`, `generic/platform=watchOS Simulator`) and `swift build` remain available for build-only checks. | `open` | Coordinator / `F0` | `mcp_t3-code_device_list`, `xcrun simctl list`, `xcrun simctl runtime list` |
| `ENV-04` | Product Thresholds | Representative consented Gulf Arabic + English evaluation sample, intended daily duration, acceptable recording gaps, charging routine, and numeric quality thresholds are unspecified by user | `open` | User / Gate A | [spec.md](/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec/spec.md) |
| `ENV-05` | Signing | Personal/team code signing identity & bundle identifiers for physical iPhone/Watch installation are unconfigured pending device connection | `open` | `F0` / User | — |

## Code & Verification Findings

| ID | Severity | Observable Failure / Gap | Owner | Repair Checkpoint | Evidence | Status |
| --- | --- | --- | --- | --- | --- | --- |
| `F-01` | low | Span-level audio redaction unimplemented: a chunk shared by several conversations keeps the deleted conversation's audio until every referencing conversation is deleted (spec permits either option; product decision needed) | `I1` / User | — | `S1-transfer-storage/handoff.md` §3 | open — pending user product decision |
| `F-02` | info | `ConversationArchiveStoreProtocol` narrower than delivered store — S1's 5 requests decided by `I1`: ACCEPT store-API promotion (`ExtendedArchiveStoreProtocol`), session channel (applicationContext relay), ingest seam (`PhoneFileIngestProtocol`); DEFER per-span availability; REJECT `.dropped` status | `I1` | `6bda965` | `I1-integration/handoff.md` §3 | resolved |
| `F-03` | info | `PhoneRecorderApp` shell still calls `Placeholder*` typealiases over real stores — must be rewired explicitly | `I1` | `6bda965` | `I1-integration/handoff.md` (app rewired to real services; aliases kept as inert scaffolding for U1 to delete) | resolved |
| `F-04` | low | Residual edges documented by `I1` (cosmetic/no data loss): in-flight transcription job→`.failed` (not `.cancelled`) on chunk deletion; `.failed` jobs revive only via `requeueFailedJobs`; orphaned empty groups not pruned; inert override rows on disbanded groups | `U1` / repair | — | `I1-integration/handoff.md` §4 | open — cosmetic, review at U1/R1 |
| `F-05` | info | A1 handoff API drift: `PhoneAI.makeAnalysisJobRunner`/`defaultModelsRoot`/`totalBytes` named in doc don't exist (actual: `modelsRootDirectory()`, `AnalysisJobRunner(dependencies:)`, `progress`) — doc-level only, code wired correctly | — | `6bda965` | `I1-integration/handoff.md` §1 | resolved |
