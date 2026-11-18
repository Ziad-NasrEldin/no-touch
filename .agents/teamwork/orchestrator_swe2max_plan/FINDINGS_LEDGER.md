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
| `F-01` | low | Span-level audio redaction unimplemented: a chunk shared by several conversations keeps the deleted conversation's audio until every referencing conversation is deleted (spec permits either option; product decision needed) | `I1` / User | — | `S1-transfer-storage/handoff.md` §3 | open |
| `F-02` | info | `ConversationArchiveStoreProtocol` narrower than delivered store — S1 requested 5 contract promotions (search, effectiveMetadata/override checks, audioFileURL, session upserts, retention/diagnostics propagation) for `I1` sign-off | `I1` | — | `S1-transfer-storage/handoff.md` App. D | open |
| `F-03` | info | `PhoneRecorderApp` shell still calls `Placeholder*` typealiases over real stores — must be rewired explicitly | `I1` | — | `S1-transfer-storage/handoff.md` §3 | open |
