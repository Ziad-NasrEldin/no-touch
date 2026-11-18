# A1 — Local Arabic AI worker — progress

## Status: complete — implementation + real-model evals done, handoff written

## Done so far
- Read briefing, spec sections (transcription candidate, text intelligence, execution/resource use, derived outputs), F0 handoff (dependency decisions for A1), frozen contracts.
- API-verified against real upstream sources (fetched at pin level):
  - `argmaxinc/WhisperKit` repo now redirects to `argmaxinc/argmax-oss-swift` (monorepo; products `WhisperKit`/`TTSKit`/`SpeakerKit`/`ArgmaxOSS`); latest tag `v1.1.1` (2026-10-08). Confirmed `WhisperKitConfig`, `WhisperKit.download(variant:downloadBase:from:progressCallback:)`, `transcribe(audioArray:decodeOptions:)`, `DecodingOptions(task:language:detectLanguage:wordTimestamps:chunkingStrategy:)`, `TranscriptionResult/Segment/WordTiming`, `ModelState`, `ChunkingStrategy .vad`, iOS 16+/macOS 13+.
  - `ml-explore/mlx-swift-lm` `2.31.3` (2.x line — self-contained; 3.x requires extra HF tokenizer/downloader integration packages, deferred). Confirmed `loadModelContainer(id:directory:progressHandler:)`, `downloadModel(hub:configuration:progressHandler:)`, `ChatSession(ModelContainer,instructions:generateParameters:)`, `GenerateParameters(maxTokens:maxKVSize:temperature:topP:repetitionPenalty:)`, `HubApi(downloadBase:)` via `import Hub`, `LLMRegistry` trampoline registration, iOS 17+/macOS 14+.
- Implemented `Sources/PhoneAI/` (sole-owned):
  - `EngineProtocols.swift` — public `SpeechTranscriptionEngine`/`TextIntelligenceEngine` seams + engine-neutral types (external engines can be injected — used by eval harness).
  - `ModelCatalog.swift` — descriptors: whisper `large-v3-v20240930_626MB` (compressed turbo, ~626MB), `small`, `mlx-community/Qwen3-1.7B-4bit` (~1.1GB), `Qwen3-0.6B-4bit`.
  - `ModelInstallController.swift` — notInstalled/downloading/verifying/ready/failed machine, persisted `install-record.json`, progress stream, free-space check, explicit `install()`/`cancelInstall()`/`uninstall()` only (no auto-download), interrupted-install normalization, `ModelContentDownloader` seam + `URLSessionModelDownloader` (Range resume, byte+SHA-256 verify).
  - `WhisperKitIntegration.swift` / `MLXIntegration.swift` — real engines + repo downloaders under `#if canImport(WhisperKit)` / `#if canImport(MLXLLM)&&canImport(MLXLMCommon)`; activate automatically once I1 registers the products.
  - `DeterministicEngines.swift` — energy-VAD speech engine + extractive text engine for manual exercise.
  - `SpeechTranscriptionAdapter.swift` — real `SpeechTranscriptionAdapterProtocol`; bounded decode (maxAudioSeconds), gate-held load+inference, wall-anchored `TranscriptSegment`s.
  - `LanguageSpanDeriver.swift` — word-timed Unicode-script ar/en spans with exact UTF-16 ranges.
  - `ConversationGrouping.swift` — gap-threshold heuristic + bounded boundary-merge candidates.
  - `MetadataPrompting.swift` — ref-indexed bounded renderer + injection-disciplined system prompt + strict-grounding JSON parser (drops ungrounded items, literal-support checks for owner/due).
  - `TextIntelligenceAdapter.swift` — heuristic grouping always + bounded engine merge refinement; `generateMetadata` requires ready engine, one JSON-repair retry.
  - `AnalysisJobRunner.swift` — durable queue drain honoring `AnalysisJob` lifecycle, maxJobs bound, cancel+resume, diagnostics events.
  - `ModelExecutionGate.swift`, `AudioDecoding.swift` (AVAudioFile→16k mono PCM), `PhoneAI.swift` (factory + backup-excluded models root), `PhoneAIError.swift`.
- Build evidence:
  - `swift build --scratch-path .build/a1 --target PhoneAI` → Build complete, zero warnings.
  - `xcodebuild -scheme PhoneRecorderApp -destination "generic/platform=iOS Simulator" -derivedDataPath .build/DerivedData-a1 build` → BUILD SUCCEEDED.

## Eval results (macOS arm64, Xcode 27.2, real deps compiled)
- `.build/a1-eval/` compiled the SHIPPED `WhisperKitIntegration.swift`/`MLXIntegration.swift` against real `WhisperKit 1.1.1` + `MLXLLM/MLXLMCommon 2.31.3` — caught and fixed two real bugs (`DirectoryEnumerator` iteration unavailable in async contexts → `nextObject()`; WhisperKit `segment.text` leaks decoder control tokens → `stripSpecialTokens`).
- Install flow (.files method, real HTTPS): notInstalled → downloading(progress) → verifying → ready; snapshot persisted and restored on fresh controller.
- WhisperKit `large-v3-v20240930_626MB`: downloaded 625MB in 82.1s via `WhisperKit.download`; cold transcribe (first CoreML compile) 80–113s; warm 2.86s for 9.74s clip (RTF 0.30); peak RSS 126MB. AR output "مرحبا اجتماعنا بكرة الساعة ثلاثة العصر" + "قررنا نراجع المشروع ونجهز العرض التقديمي" (conf 0.92, lang `ar`); EN "We will review the deployment plan tomorrow and assign the action items." (conf 0.90); LanguageSpans cover full text ranges after token-strip fix.
- MLX `Qwen3-1.7B-4bit`: downloaded ~937MB in 115.7s via `downloadModel`; load 1.8s; metadata 6.16s for 5-segment prompt, peak RSS 1,086MB. Valid JSON; 3 decisions + 1 action item all grounded to S-refs; title/summary null (model emitted null); category emitted `مالية` (not in list) → correctly dropped by strict parser; `<think></think>` block tolerated by parser.
- Grouping heuristic: 2 groups from gap threshold, second marked provisional. AnalysisJobRunner: 1 job drained end-to-end through in-memory archive + gate.
- Deterministic engines: VAD segment + extractive metadata produced.

## Notes / decisions
- Engine seam made public deliberately: the eval harness binds the same `PhoneAI` sources with deps registered, exercising the shipped `WhisperKitSpeechEngine`/`MLXChatTextEngine` code paths for real (not just the API contract).
- WhisperKit variant for A1 default: `large-v3-v20240930_626MB` (Argmax-recommended compressed turbo for iOS); `small` as Gate A comparison.
- mlx-swift-lm pinned to 2.x line (2.31.3): 3.x needs `swift-huggingface`+`swift-transformers` integration plumbing — candidate note in handoff.
- Deterministic engines never auto-selected over real engines; `engineIdentifier` exposes which backend bound ("whisperkit"/"mlx-lm" expected after I1 dep registration).
