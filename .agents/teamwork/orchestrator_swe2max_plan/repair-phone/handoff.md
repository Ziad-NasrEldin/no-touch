# Repair-Phone — handoff

**Task**: `awr-repair-phone-01` — surgical repairs for R1 findings R1-1, R1-4,
R1-5, R1-7 on the integrated checkpoint `6bda965` (`main`).
**Output**: uncommitted working-tree changes confined to
`Sources/PhoneIntegration/` + `Sources/PhoneAI/` (5 files, ~+120/−15). No git
writes performed — parent commits after verification. Sibling `WatchCapture`
edits (repair-watch worker) left untouched.

## 1. Observations

**Environment / builds (build-only, per briefing — no tests, no devices)**
- `swift build --scratch-path .build/rp` → **Build complete!** — all 5 library
  targets + real deps (WhisperKit, MLXLLM/MLXLMCommon) on macOS.
- `xcodebuild -scheme PhoneRecorderApp -destination "generic/platform=iOS
  Simulator" -derivedDataPath .build/DerivedData-rp
  -skipPackagePluginValidation -skipMacroValidation build` → **BUILD
  SUCCEEDED** — exercises the `os(iOS)`-gated code the macOS build can't
  (UIKit memory-warning seam, WatchConnectivity, BackgroundTasks).
- Two real compile errors were caught and fixed during iteration:
  (a) Swift `repeat { } while` does NOT scope body declarations into the
  condition (unlike C) — `scheduleDrain` restructured to `var again`/`while`;
  (b) capturing `self` in the `addObserver` closure inside an actor `init`
  makes subsequent property access illegal ("nonisolated initializer") —
  fixed by making the observer token a `lazy var` forced on first
  `activate()`, so the `self` capture is always post-init.
- One upstream llbuild note (`missing creator for mutated node:
  mlx-swift_Cmlx.bundle`) and one AppIntents metadata note in xcodebuild —
  both pre-existing, not ours (same as I1/R1 records).
- No simulator runtimes, no devices, no model bytes — all verification is
  compile + code-trace. Nothing was run.

**Lane/API drift**
- `SessionCoordinator` init signature unchanged; all new surface is additive:
  `SpeechTranscriptionAdapter.unloadEngine()`,
  `TextIntelligenceAdapter.unloadEngine()`,
  `SessionCoordinator.releaseModelMemory()`. Protocols in
  `RecorderContracts` untouched — `unloadEngine` lives on the concrete
  adapters, not `SpeechTranscriptionAdapterProtocol`/
  `TextIntelligenceAdapterProtocol`.
- `cancelProcessing()` now has zero call sites by design — it remains the
  deliberate-shutdown lifecycle seam (its docstring now says so explicitly).

## 2. Reasoning

**R1-1 (major) — BG expiration must not be a process-lifetime kill.**
Fix chosen: *remove `coordinator.cancelProcessing()` from the expiration
path* (the "drop the call" option — simpler and more honest than resetting
the flag per pass, which would let a routine drain resurrect a runner that
was deliberately shut down). `drain.cancel()` alone is sufficient:
`Task.checkCancellation()` inside `runNextQueuedJob` propagates the
cancellation, lands the in-flight job `.cancelled`, and
`reconcilePendingTranscriptions()` (run by every `activate()`) revives it
for live targets — that revival path was already built and R1-verified for
exactly this case. A later drain — foreground `kickProcessing()`,
`activate()`, or another BG window — now actually runs jobs because
`runner.cancelled` is never set. `cancelProcessing()` remains for real
lifecycle teardown; both docstrings now name that lifecycle
(`BackgroundAnalysisScheduler.swift:18-24, 93-100`;
`SessionCoordinator.swift` `cancelProcessing` doc). The `[weak self]`
capture in the handler was dropped — `drain.cancel()` needs no self.

**R1-7 (minor) — fresh durable work now kicks the drain.**
The `onChunkStored` hook is constructed inside `makeDefault` *before* the
coordinator exists, so a `DrainKickRelay` (file-private `@unchecked
Sendable` box) is bound post-init: on a successful fresh enqueue the hook
fires `coordinator.kickProcessing()` — synchronous and cheap (spawns one
coalesced drain Task); the kick can't fire before binding since the hook
only runs after `activate()`. `[weak coordinator]` in the handler is
load-bearing: coordinator → receiveService → hook → relay → handler is a
retain cycle without it.
The drain loop was also made self-continuing to match the BG path's
asymmetry R1 flagged: `scheduleDrain`'s Task now repeats while
`drainAgain` (mid-pass kick) OR `ran > 0 && remaining > 0` (a capped pass
left queued work). A *zero-progress* pass always exits — `.queued` rows
that `nextAnalysisJob` can't advance (store errors) or a `cancelled`
runner (deliberate shutdown) must not spin. The per-pass bound
(`maxJobsPerKind` = 24/kind) is unchanged — continuation happens between
passes, so a day-scale backlog drains to empty without repeated lifecycle
events.

**R1-4 (major) — sequential residency realized at phase boundaries.**
Adapters gained `unloadEngine()` — it runs the engine's `unload()` *inside*
`gate.withExclusiveAccess`, so the unload can never overlap in-flight
inference on either engine (if the other engine holds the slot, the unload
simply waits; if the caller's Task is cancelled, `try?` skips the release —
never a correctness issue since engines lazily reload). Call sites:
`processAnalysisQueue` unloads the speech engine at the
transcription→intelligence phase boundary (after the phase-1 drain, before
regroup/boundary-review and the intelligence drain — all text-engine work)
and unloads the text engine at pass end, so the next pass's transcription
phase starts with nothing resident. Peak model residency is now one engine
instead of the sum of both.
Memory-pressure path: `releaseModelMemory()` unloads both engines and emits
an `integration.models_unloaded` diagnostics event. On iOS it's bound to
`UIApplication.didReceiveMemoryWarningNotification` via a lazy
`ObserverToken` (forced on first `activate()`; the token unregisters on its
own deinit — no actor-deinit isolation juggling). On other platforms it's a
public injectable seam — the PhoneAI/PhoneIntegration surface stays
usable without the app shell. Lazy reload verified by inspection:
`WhisperKitSpeechEngine.load` and `MLXChatTextEngine.load` both early-return
only while their resource is non-nil and rebuild after `unload()` nils it;
adapters call `load` inside the gate on every job anyway, so reload is
automatic on next use. Deterministic engines' `load`/`unload` are no-ops —
the seam is harmless when bound to them.

**R1-5 (minor) — per-field grounding honesty.**
Rule implemented and documented in the parser: a field (`title`,
`summary`) is dropped iff the model *supplied* a refs array for it
(`title_refs`/`summary_refs` key present — including `[]`, an explicit
zero-grounding claim) and zero refs resolve; the field is kept when the
key is absent or `null` (unspecified ≠ failed grounding — the model may
summarize holistically without citing). This matches the existing
drop-on-unresolvable treatment of decisions/action items. The resolved
refs are reused for the top-level `sources` list — identical content, one
resolution pass.

## 3. Decision tables

| Decision point | Chosen | Rejected | Why |
|---|---|---|---|
| R1-1 mechanism | Drop `cancelProcessing()` from expiration | Reset `runner.cancelled` per pass | A per-pass reset would let routine drains undo a deliberate shutdown; Task cancellation already covers everything `runner.cancel()` did there except the permanent flag. |
| R1-7 kick seam | `DrainKickRelay` late-bound in `makeDefault` | Kick inside `ingestChunk` only | The WC file path bypasses `ingestChunk` — the `onChunkStored` hook is the only seam covering file + data ingest. |
| R1-7 continuation | `ran > 0 && remaining > 0` (plus `drainAgain`) | Loop until queue empty unconditionally | Zero-progress + queued = error/suppression state; unconditional looping would spin or fight a deliberate `cancelProcessing`. |
| R1-4 unload safety | `unloadEngine()` inside `gate.withExclusiveAccess` | Direct engine.unload without the gate | Gate-serialized unload mechanically guarantees "no unload while the other engine holds the slot" even if a caller misuses the seam mid-inference — phase-boundary discipline is documented, not relied upon. |
| R1-4 memory-warning binding | Lazy `ObserverToken` + `UIApplication.didReceiveMemoryWarningNotification` inside PhoneIntegration | Apps/ wiring | Apps/ is outside this lane; self-wiring keeps the surface testable without the shell and needs no app change. `releaseModelMemory()` stays public as the injectable seam. |
| R1-5 `title_refs: []` | Drop the field | Keep (empty ≡ absent) | An explicit empty array is a zero-grounding claim, consistent with how decisions/action items with no resolvable refs are dropped. Absent/null key keeps the field. |

## 4. Caveats / unverified

- **Not exercised at runtime (no devices/simulators/model bytes):**
  actual `BGProcessingTask` expiration behavior, real model load/unload
  memory deltas, reload-after-unload latency under WhisperKit/MLX, and the
  memory-warning delivery. All fixes were verified by compile + code trace.
- **Pre-existing, unchanged**: a job left `.cancelled` by BG expiration is
  revived on the next `activate()` (foreground) — the BG path doesn't call
  `reconcilePendingTranscriptions`, so a pure-BG cadence would revive it
  one `activate()` later. R1 didn't flag this; left as-is per surgical
  scope. `.cancelled` → `.queued` revival happens before every foreground
  drain, so no work is lost.
- **`unloadEngine` under repeated memory warnings** can cause
  unload→reload churn mid-pass if the OS keeps warning during a drain —
  correctness holds (gate-serialized, lazy reload), and warnings are
  bounded by OS cadence; noted for Gate A observation.
- **`processNow()` (app shell)** still calls `processAnalysisQueue`
  directly outside `scheduleDrain` — unchanged semantics; its own passes
  also get the phase-boundary unloads.

## 5. Gate A readiness

| Finding | Fix | Evidence (file:line) | Ready |
|---|---|---|---|
| R1-1 (major) | `cancelProcessing()` removed from expiration path; Task cancel only; lifecycle role documented | `Sources/PhoneIntegration/BackgroundAnalysisScheduler.swift:93-100` (handler), `:18-24` (doc); `Sources/PhoneIntegration/SessionCoordinator.swift` `cancelProcessing` docstring | compile + trace verified |
| R1-7 (minor) | Post-enqueue kick via `DrainKickRelay` → `kickProcessing()`; drain loop self-continues while `drainAgain ‖ (ran>0 && queued>0)` | `SessionCoordinator.swift` — relay fire in `makeDefault` hook (`:74-88`), late bind (`:112-119`), loop (`:392-408`), `DrainKickRelay` (`:513-517`) | compile + trace verified |
| R1-4 (major) | `unloadEngine()` on both adapters under the gate; speech unloaded at phase-1→2 boundary, text at pass end; `releaseModelMemory()` + iOS `didReceiveMemoryWarning` binding | `Sources/PhoneAI/SpeechTranscriptionAdapter.swift:107-121`; `Sources/PhoneAI/TextIntelligenceAdapter.swift:198-212`; `SessionCoordinator.swift` phase unloads (`:245-253`, `:284-290`), `releaseModelMemory` (`:187-201`), lazy token (`:46-59`), activate force (`:160-162`), `ObserverToken` (`:519-525`) | compile + trace verified |
| R1-5 (minor) | Drop `title`/`summary` when supplied refs resolve to zero; keep on absent/null refs key | `Sources/PhoneAI/MetadataPrompting.swift:248-256`, doc `:132-139` | compile + trace verified |

**Invariants preserved (traced, not just assumed):** per-field override
protection (untouched — parser only drops generated fields pre-upsert);
tombstone suppression (untouched paths); grounded metadata honesty
(*strengthened* — title/summary now held to the same standard as
decisions/action items); serial inference (`ModelExecutionGate` unchanged;
unloads are gate-serialized; phases remain sequential); additive-only API
surface (no contract/protocol/signature changes); ack-after-verified-store
(`onChunkStored` still fires post-registry-insert, pre-ack — the added kick
is synchronous and returns before the ack).

**Residual risk for Gate A:** none of the four fixes introduces new device-
dependent behavior beyond what the review already flagged for measurement.
Recommend Gate A specifically observe: (a) first BG-task expiration →
subsequent foreground drain resumes jobs (R1-1 closed-loop); (b) resident
set during a mixed drain — expect one model resident at a time plus
transient reload at each phase boundary (R1-4); (c) memory warning during
a drain — expect `integration.models_unloaded` diagnostics + reload on next
job.
