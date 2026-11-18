# R1 — Independent Reviewer Briefing (early review, integrated core)

## Assignment Identity
- **Role**: `R1 — Independent reviewer` — running EARLY on the integrated core (pre-U1) at user direction. A later full-product review may follow after U1.
- **Model**: `acpRegistry_devin` / `swe-2-high` (`thought_level: "max"`, `mode: "accept-edits"`, `speed: "standard"`)
- **Client Request ID**: `awr-r1-review-01`
- **Isolation**: `shared` — same working tree. **You are read-only on all product code and git.** Your only writes: your state dir. No `git add/commit/checkout` or any git write op — review the tree as it stands.
- **Review target**: integrated checkpoint `6bda965` on `main` (+ docs `0758abf`, `e3d3f4c`). Implementation diff = `git diff 4e36a08..6bda965` (all Phase 1 lanes + Phase 2 integration over the F0 foundation).

## Original Request & Confirmed Constraints
- User prompt: *"I wanna build an all day apple watch recorder / Should use an on device or on iphone AI model to sort and categorize conversations / How do we do it"* -> *"Start the orchestra"*.
- Hardware: iPhone 14 Pro Max (no Apple Intelligence) + Apple Watch believed Series 6. Saudi/Gulf Arabic + English. **Local AI only — no cloud transcription/summarization, no Apple Intelligence.**
- Experience: start once on the Watch, capture all day, survive quiet periods + phone disconnection + restarts; conversations grouped/categorized on the phone with editable, source-grounded Arabic metadata; deletion honored end-to-end.
- **PROHIBITION** (applies to you too): no unit or integration tests exist or may be created/run. Verification = build-only + manual + code inspection. Never `swift test`/`xcodebuild test`.

## Input Artifacts (absolute paths — read spec FIRST, then handoffs, then diff)
- Repo root: `/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec`
- `spec.md` — the requirements authority; the review measures the code against it
- `.agents/teamwork/orchestrator_swe2max_plan/BRIEFING.md` — master plan
- `.agents/teamwork/orchestrator_swe2max_plan/FINDINGS_LEDGER.md` — open findings F-01 (product decision pending), F-04 (documented cosmetic edges), ENV-01..05
- Lane handoffs to weigh claims against code: `F0-foundation/`, `C1-watch-capture/`, `A1-arabic-ai/`, `S1-transfer-storage/`, `I1-integration/` — each `handoff.md` in that dir
- Code: `Sources/{RecorderContracts,WatchCapture,PhoneAI,PhoneStorage,PhoneIntegration}/`, `Apps/{WatchRecorderApp,PhoneRecorderApp}/`, `Package.swift`, `Package.resolved`, `WatchRecorder.xcodeproj/`

## Review Mandate (from master plan, scoped to integrated core)
Review the combined diff and actual commands/evidence for:
1. **Background capture correctness** — supported audio-session path only (no workout/silent-playback tricks); honest state (never claims recording when it isn't); chunk rotation without silent audio loss; interruption-interval bookkeeping truthfulness (gaps marked unknown/missing, not silence).
2. **Chunk continuity & integrity** — real SHA-256 + byte/duration/sequence per chunk; monotonic vs wall timestamps handled correctly; orphan/crash paths lose ≤ declared bounds.
3. **Transfer acknowledgment** — no ack before durable verified storage; dedup under redelivery; Watch copy deleted only on verified ack; restart/retry durability of both outbox and receiver; tombstone redelivery behavior.
4. **Deletion races & privacy** — tombstoned content cannot resurrect via delayed transfers, retries, regroup, or late AI output; deletion during queued/in-flight analysis; shared-audio behavior matches documented F-01 posture; backup exclusions + file protection classes coherent; no content-bearing telemetry anywhere (diagnostics = ids/counts/states only).
5. **Arabic preservation** — `LanguageSpan` ar/en tagging correctness through transcribe→store→search; normalizer symmetry (index==query); RTL/UTF-16 range correctness; no translate-anywhere; no English-only model paths.
6. **Source grounding** — `SourcePassageReference`s resolve; strict parser drops ungrounded/near-miss output; recorded speech treated as data not instructions (prompt-injection posture); no invented speakers/dates.
7. **Memory/execution limits** — serialized speech→text via `ModelExecutionGate`; bounded job draining; cancellation/resume semantics; BG task expiration handling.
8. **Truthful status** — recording vs transfer vs analysis states separate; failed/unavailable/pending shown distinctly; no success claimed where unexercised.
9. **Forbidden-thing check** — zero test targets/actions/harness; no cloud endpoints for content (model-repo downloads only); no Apple Intelligence/Foundation Models requirement; no English-only models; signing still placeholder.
10. **Lane-boundary & doc drift** — handoff claims vs actual code (e.g., I1 already found A1 API drift); contracts additive vs breaking.

## Method
- Read spec → handoffs → diff. Trace the end-to-end path I1 documented (`I1-integration/handoff.md` bottom: first-boot code path) and check each hop in real code.
- You may rerun build-only verification in YOUR scratch paths: `swift build --scratch-path .build/r1` and xcodebuild with `-derivedDataPath .build/DerivedData-r1 -skipPackagePluginValidation -skipMacroValidation`. Do not run anything else.
- Devices/simulators unavailable — mark device-dependent checks as verification gaps, not passes or failures.
- Do NOT fix anything. Findings only — repairs go to fresh tasks.
- Do NOT invent defects to fill a quota. If an area is clean, say so with the evidence you checked.

## Output — severity-ranked findings report (in handoff.md)
For every finding: `ID (R1-N)`, severity (critical/major/minor/info), observable failure or gap, exact source location (file:line), reproduction/verification path (manual steps or the unexercised scenario), expected vs observed, and which spec clause it violates. End with: findings summary table, verification-gap list (device-dependent), explicit confirmation no tests/cloud deps exist, and your overall verdict on whether the integrated core supports proceeding to Gate A → U1.

## State Folder
`/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec/.agents/teamwork/orchestrator_swe2max_plan/R1-review/` — write `progress.md` and `handoff.md` (the review report) here only. Use the five-part structure where it fits (observations/evidence → reasoning → caveats → conclusion → verification instructions) plus the findings table.
