# SWE 2 Max orchestration plan

## Status and authority

Active execution run. Model selection is verified (`acpRegistry_devin` / `swe-2-high` with `thought_level: "max"`, `mode: "accept-edits"`, `speed: "standard"`), and the dedicated Git repository and T3 project context are being initialized to dispatch Phase 0 (`F0`). No unit or integration tests have been written or run, and none are permitted.

Original request: “Prepare an orchestration plan that utlizes SWE 2 Max workers”, followed by “Start the orchestra” and “No yhere is devin SWE 2 on max effort”.

The input is the adjacent all-day Apple Watch recorder specification. Confirmed product constraints are iPhone 14 Pro Max, Apple Watch believed to be Series 6, Saudi/Gulf Arabic with occasional English, start once and capture conversations throughout the day, and local AI processing. The accepted verification boundary is the recording session and its resulting conversation archive. The user explicitly prohibits writing or running unit or integration tests.

The plan uses one coordinating parent and SWE 2 Max (`acpRegistry_devin` / `swe-2-high` / `thought_level: "max"`) workers for implementation, integration, and review. Maximum concurrency is three workers plus the parent. Eight worker tasks are planned across the pipeline; repair tasks are conditional. Roles are not persistent agents: every assignment or re-review is a new task with a new identifier and a complete brief.

## Model selection and launch prerequisites

The requested worker model is SWE 2 Max, confirmed per user direction and live `orchestrator_capabilities` lookup:
- `providerInstanceId`: `"acpRegistry_devin"` (Devin)
- `model`: `"swe-2-high"` (`"SWE-2"`)
- `options`: `{"thought_level": "max", "mode": "accept-edits", "speed": "standard"}`

Fusion models and `codex_hub` are not substituted. Do not repeatedly query capabilities unless a tool error or user-named provider change warrants it.

Because this parent thread is bound to `/Users/ziadnasreldin/Work/GitHub` (which is not a Git repository), workers are dispatched with `isolation: "shared"` inside `/Users/ziadnasreldin/Work/GitHub/apple-watch-recorder-spec`, using strictly disjoint owned module directories (`Sources/WatchCapture/`, `Sources/PhoneAI/`, `Sources/PhoneStorage/`), disjoint state directories, and per-task `.build/<task-slug>` scratch paths during concurrent Phase 1 execution. Phase 1 workers do not run `git commit` or modify shared manifests.

Before implementation starts, the coordinator must establish:

- A dedicated project directory and Git repository. The current folder contains specification artifacts and is not an application repository. Do not launch implementation in the parent directory containing unrelated projects.
- A registered project context and a clean integration branch from which delegated worktrees can be prepared. Carry the spec and this plan into that context as worker inputs.
- Access to the actual Watch and iPhone, their model and OS versions, signing prerequisites, and a practical route for installing development builds. Simulator success is not evidence of Watch battery endurance or phone model performance.
- A short, consented sample of representative Gulf Arabic and Arabic/English conversation for local evaluation. Workers must not upload audio or transcripts for AI processing or place recordings in Git.
- A record of the desired daily duration and acceptable charging routine before accepting an all-day endurance claim. These are currently unspecified; no invented duration is a shipping threshold.

Issue-tracker setup is required only for issue publication. It does not block drafting or local implementation once an appropriate repository exists. Deployment and public publishing are outside this plan.

## Coordination rules

- The parent routes work, maintains task state and the unresolved-findings ledger, reads diffs and evidence, and reports to the user. Implementation and substantive repairs belong to workers. The parent may fix a small review finding directly if appropriate, but does not take over an implementation lane.
- Delegate through T3 Code with the exact resolved SWE 2 Max target. Use explicit worker options rather than inheriting Codex-specific reasoning or service-tier settings. Do not invent a “Max” option independently of the requested model's catalog entry.
- Use async delegates for concurrent lanes. Follow each delegate's returned next instruction and completion notification. Do not poll running tasks, sleep to monitor them, or create monitoring threads.
- No child may delegate. Each worker receives a complete objective, boundaries, spec snapshot, source checkpoint, owner map, evidence requirements, and state folder. They cannot assume access to the parent's conversation.
- Keep a maximum of three workers active. Give the same physical device to only one driver at a time. Architecture, model evaluation, and device captures must not compete for that device session.
- Build commands are allowed. Never invoke unit or integration tests, test targets, test runners, CI jobs that run tests, or an automated workflow harness replacing those tests. Check project scripts and schemes before using convenience commands. For Xcode, build-only actions are permitted; test and test-without-building are prohibited.
- Keep report files outside application source. Each worker writes only its own progress and handoff files. The parent alone updates the global roster and findings ledger.
- Retire completed tasks. A new review, re-check, or repair assignment gets a fresh delegate task. Cancel a replaced or unnecessary running task; do not leave duplicate assignments active.
- If a future worker creates or pushes a PR, the parent links its full URL immediately. Children do not watch PRs. The default execution plan uses local checkpoints; creating PRs is not necessary to prove the prototype.

## Worktree and ownership strategy

The foundation worker establishes the baseline in the target project checkout as the only writer. Its local checkpoint becomes the parent commit for the three independent implementation worktrees. Use the delegation tool's worktree isolation; never prepare a child's checkout in shell commands or in the worker prompt.

Keep the parent integration checkout stable while capture, AI, and storage workers run. All three start from the same foundation checkpoint. They own disjoint source areas and list any required project/configuration changes in their handoffs rather than competing over the project file, dependency manifest, entitlements, shared types, or build settings.

The integration worker is the sole writer in the parent checkout after those lanes finish. It applies the selected commits, resolves conflicts, registers source additions, updates shared configuration, and commits the integrated checkpoint. UI and review tasks start only after their required commits are present in the parent checkout. A completed worktree with unpublished dependencies is never replaced by a new branch from an older remote default.

Record the actual base commit and output commit for every task. Do not infer integration from the existence of a worker branch; inspect the resulting diff and build evidence.

## Phase 0: Foundation and shared contracts

**F0 — Foundation worker.** Runs alone. Establish the native iOS/watchOS project, build-only schemes, local archive foundation, diagnostic evidence format, and shared contracts. Own project configuration, signing placeholders, dependency registration, and shared domain types for this phase. Do not implement the full interface or choose an AI model from unsupported performance assumptions.

Define the narrow contracts needed by later lanes: recording session states; chunk identity, timing, and integrity metadata; durable receive acknowledgment; analysis job identity and retry state; timestamped transcript segments; conversation membership; generated metadata versus user overrides; and deletion intent.

Deliver a buildable baseline, ownership map, dependency decisions, local checkpoint, and commands actually used. Any signing or device-access limitation is an explicit open finding. Exit when both app targets build for an available appropriate destination without running tests and the three lane boundaries are stable.

## Phase 1: Three parallel implementation lanes

**C1 — Watch capture worker.** Own Watch audio capture, start/pause/resume/stop behavior, recoverable chunk persistence, interruption bookkeeping, and recording diagnostics. Use supported background audio recording only. Do not add workout or silent-playback execution tricks, AI on the Watch, or a claim of automatic restart after force quit. Keep capture time trustworthy through chunk rotation and quiet periods. Deliver build evidence, a manually exercised capture path where device access permits it, and a protocol for the one-hour and full-day trials. Report required permissions and project changes to the integration worker.

**A1 — Local Arabic AI worker.** Own the iPhone transcription adapter, model installation/readiness, bounded processing, and local text-model adapter. Evaluate multilingual Whisper candidates and a small Arabic-capable categorization model such as Qwen3 1.7B; candidates remain unselected until measured. Preserve Arabic/English switching, use transcription rather than translation, and produce timestamped outputs and structured grounded metadata. Do not add cloud AI fallbacks or require Apple Intelligence. Deliver separate speech-recognition and text-intelligence findings, real-device measurements if available, and an explicit list of unverified model claims. A local build and manual sample run are allowed; a unit or integration test harness is not.

**S1 — Phone transfer and archive worker.** Own Watch Connectivity receive handling, durable phone storage, acknowledgments, deduplication, retry persistence, transcript/conversation storage, and the local search foundation. Honor deletions and user overrides at the storage boundary. Do not acknowledge receipt before moving a temporary file into owned durable storage. Do not delete the Watch's only copy before durable acknowledgment. Deliver archive and transfer build evidence plus manual disconnect/reconnect observations where devices are available.

These workers may run together because they consume the same contracts and own separate areas. Their reports must distinguish code complete, build verified, manually exercised, and device measurement unavailable. Parent completion notifications trigger handoff inspection; elapsed time alone never advances the phase.

## Phase 2: One integrated recording session

**I1 — Integration worker.** Runs alone in the parent integration checkout. Apply F0/C1/A1/S1 outputs, resolve shared configuration and dependency changes, and connect capture through transfer to the persistent local analysis queue. Implement conversation assembly across chunk boundaries, source-linked generated results, and preservation of user overrides. Reconcile the privacy and deletion lifecycle: protected storage, backup exclusions, no content-bearing telemetry, deletion during queued jobs, delayed transfers not resurrecting deleted content, and shared-audio removal behavior.

Build both targets without running tests. Manually exercise the accepted public workflow: start a session, capture speech and silence, disconnect/reconnect the phone, stop capture, process locally, and inspect archived conversations and source audio. Verify that recording, transfer, and analysis states remain separate. Document any scenario that cannot be reproduced instead of fabricating evidence.

Exit when a real captured conversation reaches the phone archive and can produce locally generated results, or when a concrete hardware/tooling blocker is documented. A blocked measurement does not count as a pass.

## Gate A: Recording endurance and Arabic feasibility

Use the integrated prototype on the actual devices. Delegate a fresh repair/evaluation task to the owner of the failing area if implementation work is needed; the parent does not turn a completed worker into a new assignment through a thread message.

Run manual trials progressively, beginning with one hour and then the user's intended daily duration. Record the Watch identity, OS, battery health, charge change, missing-audio intervals, captured/transferred bytes, phone disconnection behavior, processing backlog, analysis time relative to speech duration, peak memory, and thermal interruptions. Include normal wrist-down and app-switching behavior. A simulator or plugged-in foreground session is insufficient.

Evaluate real Gulf Arabic and mixed English samples for names, numbers, dates, background noise, silence, and unsupported generated claims. Keep transcription quality separate from category and summary quality. Use human reference transcripts and review notes, not an automated unit or integration suite.

Advance to the full product interface only after the prototype demonstrates useful capture and local Arabic processing on the user's devices. Numeric acceptance thresholds and intended duration require the user's product judgment; do not invent pass criteria. If the Watch cannot support the intended routine or the phone cannot produce usable Arabic results, stop further product buildout and present the measured limitation and concrete options. Do not silently change the capture device or add cloud processing.

## Phase 3: Product interface and complete lifecycle

**U1 — Product experience worker.** Own the final Watch controls and the iPhone daily timeline, Arabic titles and summaries, category editing, transcript review, search, source-linked playback, retention controls, and deletion states. Reuse verified core services; do not replace them with previews or mock recordings in the shipped flow. Distinguish active capture, interruptions, queued transfer, model readiness, pending analysis, and unavailable expired audio. Protect user edits during reprocessing.

Perform manual visual and interaction review with real Arabic/English content, including bidirectional punctuation, numbers, timestamps, text scaling, empty states, and interruption/error states. Follow applicable UI/design and visual-proof skills. For iOS Simulator or Android Emulator interaction, use T3 device tools: device_list, device_open with host and device identifiers, the returned agent-device command, and device_screenshot. Use device-specific signing/install tools only within their supported purpose. Never substitute simulator results for physical Watch endurance.

Exit when the complete user-facing workflow uses integrated data and its observable behavior is documented. Deliver source changes, screenshots, build evidence, and the remaining limitations without writing or running unit or integration tests.

## Phase 4: Independent review and final verification

**R1 — Independent reviewer.** Read the original spec and user constraints before implementation handoffs. Review the combined diff and actual commands/evidence for background capture, chunk continuity, transfer acknowledgment, restart/retry durability, deletion races, Arabic preservation, source grounding, memory limits, and truthful status. Inspect the UI evidence and rerun appropriate build-only or manual checks where possible. Verify that no tests or cloud dependencies were introduced. Produce severity-ranked findings with source locations, reproduction steps, expected versus observed behavior, and verification gaps. Do not invent defects to satisfy a review quota.

**Repair task, conditional.** Substantive findings go to a fresh SWE 2 Max task assigned to the relevant owner, with the exact finding, integrated source checkpoint, reproduction steps, and current unresolved ledger. Avoid launching several repair workers that touch the same shared area. Minor corrections may be handled directly by the parent when appropriate. Every repair updates evidence for the affected behavior without invoking tests.

**R2 — Final verifier.** A new independent SWE 2 Max task checks the final integrated checkpoint, not a retired R1 session. Read the original requirements, final diff, outstanding findings, and device reports. Confirm repaired findings through allowed observable checks and report unresolved or unexercised scenarios as such. Build-only verification and manual/device checks are allowed. Final verification is not a guarantee of all-day performance beyond the actual measured duration and conditions.

Exit when the critical workflow has supporting evidence, there are no unresolved findings that invalidate it, and the parent has independently inspected the diff, build output, screenshots, and device measurements. If required evidence is missing, hand back a precise remaining-work report rather than marking the product complete.

## Reusable worker dispatch brief

Each future delegate task must include:

1. Original user request and confirmed constraints, verbatim where provided.
2. Objective and one bounded role from this plan.
3. Absolute input artifact paths, target project context, exact base checkpoint, and dependency outputs. Resolve these at dispatch rather than assuming a relative path in a worktree.
4. Owned source areas; shared configuration ownership; prohibited changes; explicit instruction that the child may not delegate.
5. Exact resolved SWE 2 Max provider/model/options, inherited permission ceiling, a fresh clientRequestId, and worktree or shared isolation as specified above.
6. “Do not write or run any unit or integration tests. Do not introduce an automated harness as a substitute. Build-only and manual device checks are allowed.” Include this in every implementation, review, repair, and final-verification brief.
7. Required outputs: diff and commit identifiers; commands and actual outputs; manual reproduction steps and observed results; any measured hardware/model conditions; unresolved findings; and the worker's five-part handoff.
8. Done criteria from the relevant phase. If a device, signing prerequisite, or model is unavailable, report it explicitly and continue only independent work that remains meaningful.
9. A unique state folder under the target project's .agents/teamwork directory. Create per-task BRIEFING.md, DISPATCH.md, progress.md, and handoff.md as metadata only. Keep application source and private recordings out of the coordination folder.

The five-part handoff is: observations with exact evidence; reasoning tied to those observations; caveats and unverified areas; conclusion; and independent verification instructions. PR-bearing workers end with the PR URL, head SHA, and checks/reviews state as required by the host workflow.

## Parent state and completion report

Track each task's role, exact model, task identifier, thread link, source checkpoint, worktree, output checkpoint, status, handoff artifact, and next instruction. Read a child thread before describing its contents to the user and reference it by the returned link. No task records exist yet because this request is for the plan.

Maintain one findings ledger with identifier, severity, observable failure, owner, repair checkpoint, evidence, and open/resolved/unverified state. Silence in a later report never resolves a finding. Track hardware access, intended duration, model availability, and model quality thresholds as dependencies rather than pretending they are code defects.

The execution handoff should include installable build locations, final source checkpoint, measured device endurance and Arabic results, screenshots, privacy/deletion observations, unresolved limitations, and explicit confirmation that unit and integration tests were neither written nor run. Do not publish, deploy, or claim App Store readiness as part of this plan.

## Current pending items

- Exact standalone SWE 2 Max selection is unverified; available Fusion/SWE-2 Flash Max entries are not selected as substitutes.
- Target application repository and project context are not established.
- Physical-device access, signing, exact Watch identity, and OS versions are not established.
- Representative evaluation recordings, intended daily duration, quality thresholds, and charging routine are not yet established.
- Spec publication awaits issue-tracker configuration; this is independent of completing this orchestration plan.
- This plan is prepared for document review. It does not launch implementation or authorize unattended publication.
