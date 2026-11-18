# All-day Apple Watch recorder with local Arabic conversation intelligence

Status: Draft for review. Not published to an issue tracker.

Target hardware: iPhone 14 Pro Max and the user's Apple Watch, believed to be Series 6.

Primary language: Saudi/Gulf Arabic, sometimes mixed with English.

Scope authority: The conversation establishes the hardware, language, local AI requirement, and start-once recording experience. The user accepted the recording-session verification boundary and separate device trials, with an explicit instruction not to write or run unit or integration tests. The remaining architecture choices below are proposed implementation decisions. Model choice, endurance, accuracy, and runtime have not been validated on the target devices.

## Problem Statement

The user wants to capture conversations throughout the day without remembering to start a recording for each one. Those recordings need to become organized, searchable conversations that understand Saudi/Gulf Arabic and occasional English. A day-long audio file is difficult to review, and manually transcribing, separating, and categorizing conversations defeats the purpose of passive capture.

The solution must work with the user's existing iPhone 14 Pro Max and likely Apple Watch Series 6. The user wants AI processing on the Watch or iPhone. Continuous capture, battery endurance, and useful Arabic transcription are unresolved feasibility questions rather than demonstrated capabilities.

## Solution

Build a native Watch recording app and companion iPhone app. The user taps Start day once on the Watch and leaves the recording session running through ordinary quiet periods. The Watch saves recoverable audio chunks and queues them for transfer to the paired iPhone, including when the phone is temporarily unavailable.

The iPhone transcribes audio locally, preserving Arabic and English, groups related passages into conversations, and proposes editable categories. Each conversation can have an Arabic title, summary, decisions, and action items linked to source timestamps. The user can browse a daily timeline, search the transcript, and play the relevant original audio while it is retained.

Recording status and processing status are separate. The interface must distinguish recording, paused, interrupted, pending transfer, and pending analysis. Transfers and analysis may be delayed by operating-system scheduling. “All day” means start once and capture conversations throughout the day; it is not a promise of uninterrupted 24-hour recording or a specific number of hours on one charge.

Delivery starts with recording endurance and Arabic accuracy prototypes. A successful endurance result on the actual Watch and an acceptable Gulf Arabic evaluation on the actual iPhone are prerequisites for claiming the complete experience works.

## User Stories

1. As the recorder owner, I want to start a day-long recording session with one action, so that I do not need to start each conversation manually.
2. As the recorder owner, I want capture to continue when I lower my wrist, so that ordinary Watch use does not require keeping the screen awake.
3. As the recorder owner, I want capture to continue when I navigate away from the app where watchOS permits it, so that I can use other Watch features.
4. As the recorder owner, I want the session to keep listening through quiet periods, so that the next conversation can be captured without another tap.
5. As the recorder owner, I want a clear recording state, so that I know whether the microphone is active.
6. As the recorder owner, I want to pause capture immediately, so that I can exclude a private conversation or situation.
7. As the recorder owner, I want to resume a paused session, so that the rest of the day stays in the same recording session.
8. As the recorder owner, I want to stop the session explicitly, so that I can end capture when I choose.
9. As the recorder owner, I want microphone permission explained and requested, so that recording begins with my knowledge and control.
10. As the recorder owner, I want a useful explanation when permission is denied, so that I can understand why capture cannot start.
11. As the recorder owner, I want completed audio chunks preserved during interruptions, so that one failure does not lose the whole day.
12. As the recorder owner, I want interruptions and recording gaps shown, so that I do not mistake missing audio for silence.
13. As the recorder owner, I want recording to recover after a recoverable interruption when the system allows it, so that brief disruptions require less intervention.
14. As the recorder owner, I want to be told when manual restart is necessary, so that I can restore recording after a termination or unrecoverable error.
15. As the recorder owner, I want capture to work while my phone is temporarily disconnected, so that a conversation is not lost because of connectivity.
16. As the recorder owner, I want queued files transferred after reconnection, so that disconnected recordings eventually appear on my phone.
17. As the recorder owner, I want transfers to survive retries without duplicate recordings, so that the timeline remains trustworthy.
18. As the recorder owner, I want files kept on the Watch until the phone has durably received them, so that a transfer failure does not destroy the only copy.
19. As the recorder owner, I want clear storage and low-battery failure states, so that a stopped session is not presented as still recording.
20. As the recorder owner, I want measured recording endurance for my Watch, so that I can decide whether it meets my daily routine.
21. As the recorder owner, I want recordings transcribed on my iPhone, so that speech processing does not require uploading conversations to a server.
22. As the recorder owner, I want Saudi/Gulf Arabic recognized directly, so that I can speak naturally without translating into another language.
23. As the recorder owner, I want English words and passages preserved alongside Arabic, so that mixed-language conversations keep their meaning.
24. As the recorder owner, I want transcription rather than automatic translation, so that I can inspect what was actually said in its original language.
25. As the recorder owner, I want analysis to work without internet access after model installation, so that processing remains local when I am offline.
26. As the recorder owner, I want model download and readiness states shown, so that I understand when local analysis can begin.
27. As the recorder owner, I want recording preserved while models are unavailable, so that model setup or failure does not prevent audio capture.
28. As the recorder owner, I want pending and failed analysis shown separately from successful analysis, so that I know which conversations are ready to review.
29. As the recorder owner, I want unfinished analysis resumed without duplicating results, so that reopening the app can complete pending work.
30. As the recorder owner, I want connected audio chunks grouped into the same conversation, so that file boundaries do not fragment the discussion.
31. As the recorder owner, I want pauses and topic changes considered when splitting conversations, so that unrelated discussions are easier to review.
32. As the recorder owner, I want conversations listed in time order for each day, so that I can find the discussion I remember.
33. As the recorder owner, I want a short Arabic title for each conversation, so that I can scan the day quickly.
34. As the recorder owner, I want a concise Arabic summary, so that I can recover the main points without replaying everything.
35. As the recorder owner, I want useful category suggestions, so that work, personal matters, planning, and ideas are easier to find.
36. As the recorder owner, I want to edit a title or category, so that an AI mistake does not determine how my conversations are organized.
37. As the recorder owner, I want decisions extracted when the transcript supports them, so that I can revisit what was agreed.
38. As the recorder owner, I want action items extracted without inventing owners or deadlines, so that suggestions do not become false commitments.
39. As the recorder owner, I want generated statements linked to transcript passages, so that I can check their source.
40. As the recorder owner, I want transcript passages linked to playable audio timestamps, so that I can verify uncertain wording while audio is retained.
41. As the recorder owner, I want local search across Arabic and English transcripts, so that I can retrieve a conversation by remembered words.
42. As the recorder owner, I want readable Arabic and mixed-language text, so that titles, transcripts, and search results display correctly.
43. As the recorder owner, I want my recordings and derived data protected on the devices, so that the archive stays private.
44. As the recorder owner, I want to delete a conversation and its associated data, so that I control what remains in the archive.
45. As the recorder owner, I want a configurable raw-audio retention policy, so that I can balance playback, storage, and privacy.
46. As the recorder owner, I want retained text distinguished from expired audio, so that I understand why an older passage may no longer be playable.
47. As the recorder owner, I want persistent user edits protected from later analysis, so that reprocessing does not silently overwrite my corrections.
48. As the recorder owner, I want phone analysis to respect memory and thermal limits, so that organizing recordings does not make the phone unusable.

## Implementation Decisions

- **Platform split:** Use native Swift and SwiftUI for watchOS and iOS. The Watch handles capture, local buffering, controls, and transfer. The iPhone handles transcription, conversation grouping, categorization, storage, search, and review. Verify the exact Watch model, battery health, and installed OS versions before selecting minimum deployment versions.
- **No Apple Intelligence dependency:** The iPhone 14 Pro Max is not eligible for Apple Intelligence. Do not require Apple's system Foundation Models language model for the core workflow. This limitation does not imply that all Apple speech APIs are unavailable.
- **Recording lifecycle:** Model the session as idle, recording, paused, interrupted, or stopped, with an explicit failure reason where applicable. Only report recording while capture is actually active. Persist session identity and recoverable recording metadata.
- **Background capture:** Use the supported audio recording session and background-audio capability. Start capture through an explicit user action. Do not depend on a workout session, silent playback, or an unrelated execution mode to keep the app alive. Do not promise automatic microphone restart after force quit or reboot.
- **Silence handling:** Keep microphone capture active during an ongoing recording session. Voice activity detection may reduce persisted silence and downstream work, but is not a mechanism for waking an inactive microphone or eliminating its power cost. Preserve timing information if silence is discarded. Compare this optimization with straightforward continuous chunk recording during the endurance prototype before committing to it.
- **Chunk persistence:** Save short mono audio chunks with a stable identifier, session identifier, sequence number, timestamps, duration, and integrity metadata. Use an audio format supported on the target Watch; choose encoding and chunk duration from measured quality, endurance, and transfer behavior. If chunk rotation loses audio, correct the capture design before claiming continuity.
- **Transfer contract:** Transfer finalized chunks using Watch Connectivity. Treat delivery as asynchronous and potentially delayed. Persist a retryable queue, deduplicate received chunks, and acknowledge only after the iPhone has durably stored a verified file. Retain the Watch copy until that acknowledgment, subject to explicit user deletion. Move received temporary files into owned storage before reporting successful receipt. Handle phone and Watch restarts without losing queue state.
- **Failure visibility:** Record interruption intervals and the last known successful capture time. An interval whose capture cannot be confirmed after a crash is unknown or missing, not confirmed silence. Keep recording errors, transfer errors, and analysis errors distinct. If storage is exhausted, fail visibly rather than silently replacing untransferred audio.
- **Arabic transcription candidate:** Start evaluation with multilingual Whisper through WhisperKit. Compare a compressed large-v3 Turbo model with a smaller multilingual model on the iPhone 14 Pro Max. Avoid English-only model variants. Configure transcription rather than translation and evaluate both Gulf Arabic and Arabic/English switching. Choose the shipped model only after measuring accuracy, processing time, memory, heat, and battery use.
- **Local text intelligence candidate:** Evaluate a small quantized multilingual text model such as Qwen3 1.7B using an iOS-compatible runtime. This is a candidate, not a validated choice. Evaluate grounded category assignment and summaries separately from speech recognition so that transcription errors are not mistaken for categorization failures.
- **Execution and resource use:** Maintain a durable processing queue that can pause and resume. Process bounded chunks and bounded transcript windows rather than feeding an entire day into one model request. Prefer sequential use of speech and text models to limit peak memory. Respect iOS background execution, expiration, thermal, and low-power constraints. Opening the app must allow pending processing to continue; immediate background completion is not required.
- **Conversation grouping:** Combine timing gaps and topic continuity across chunk boundaries. A chunk may contain more than one conversation, and a conversation may span many chunks. Record group membership without changing source timestamps. Late-arriving chunks may update provisional groups, while user edits remain protected.
- **Derived outputs:** Generate structured titles, summaries, category suggestions, decisions, and action items. Leave unsupported fields empty. Do not infer a named speaker, assignee, or due date unless supported by the transcript. Treat recorded speech as data, not as instructions to the application. Store source passage references for generated claims.
- **Data model:** Represent recording sessions, audio chunks, transfer acknowledgments, analysis jobs, timestamped transcript segments, conversation groups, generated metadata, user overrides, and deletion records. Keep capture time separate from transfer and analysis time. Track model and analysis versions so that retries and reprocessing remain explainable.
- **Presentation and search:** Provide a daily conversation timeline, editable title and category, Arabic summary, transcript, source-linked playback, and local text search. Ensure Arabic right-to-left text, English passages, numbers, and timestamps render coherently. Category names and the initial vocabulary remain configurable product choices; examples in the conversation are not an approved fixed taxonomy.
- **Local privacy and lifecycle:** Keep audio and derived content on the paired devices for the core workflow. Use platform data protection with an accessibility policy tested against locked-device capture requirements; protect application-managed secrets in Keychain if needed. Exclude raw recordings from cloud backup by default and avoid content-bearing analytics. Model installation may require an initial download, but must not upload recordings or transcripts.
- **Deletion and retention:** Deleting a conversation invalidates its derived jobs and removes associated content from both devices when connected. Persist deletion intent so delayed transfers or retries cannot recreate deleted content. For source chunks shared by several conversations, remove the deleted conversation's audio spans or remove the shared audio file, leaving other transcripts intact and showing any resulting playback unavailability. Resolve the exact implementation during the storage prototype. Raw-audio expiration may keep the transcript; show that playback is no longer available.
- **Staged delivery:** First validate Watch recording and transfer endurance. Next evaluate real Gulf Arabic and mixed-language audio locally on the phone. Then implement conversation grouping, categorization, and review. Do not characterize the product as all-day or the model as accurate on this hardware until the corresponding evidence exists.

## Testing Decisions

- **Explicit user constraint:** Do not write or run unit or integration tests. Do not add an automated workflow suite, deterministic model substitutes, or a new testing framework as a workaround. The checks below are manual application-level verification and real-device measurements. This spec records the approach only; no application checks or device trials have been performed.
- **Accepted primary boundary:** Verify the recording-session workflow through its public controls and observable archive results: start a session, supply representative timestamped audio, interrupt and reconnect transfer, finish capture, allow processing, and inspect stored conversations. The user explicitly accepted this boundary, subject to the no-unit-or-integration-tests constraint. Use a manual end-to-end run rather than automated integration tests. Reuse equivalent existing public controls if a target codebase already provides them.
- **Good verification:** Inspect externally observable behavior, durable data, visible states, source timestamps, and absence of unintended network transmission. Avoid depending on private implementation, exact prompt wording, internal call counts, or exact generated prose. Evaluate actual models with representative recordings and a documented human review rubric.
- **Workflow coverage:** Manually exercise capture controls, ordinary silence followed by new speech, multi-chunk conversations, multiple conversations in one chunk, phone disconnection and reconnection, delayed delivery, and process restart. Inspect the resulting archive and acknowledgment behavior. Where duplicate delivery, out-of-order chunks, corrupt files, or failed persistence cannot be exercised safely through public controls, document the verification gap instead of building a unit or integration harness.
- **Recovery coverage:** Manually check recoverable interruption behavior, manual-restart messaging after unrecoverable interruption, recording gaps, microphone denial, low storage, missing model assets, observable model failure, background expiration, cancellation, and retry after reopening the app. Document scenarios that cannot be reproduced. No simulated result can establish real Watch endurance.
- **Archive lifecycle coverage:** Manually inspect local search, title and category edits surviving reprocessing, timestamp-to-audio mapping, audio retention expiration, deletion during pending transfer or analysis, deletion of shared source audio, and late chunks not recreating deleted content.
- **Local-processing coverage:** After model installation, demonstrate transcription and categorization offline. Inspect application network behavior to verify no audio or transcript leaves the devices for AI processing. Measure memory and thermal behavior with speech and text jobs running sequentially on the target phone.
- **Arabic evaluation:** With permission, use representative Saudi/Gulf speech, Arabic/English switching, names, numbers, dates, quiet conversation, normal wrist positions, clothing obstruction, and background noise. Include silence and non-conversation audio to assess false transcript generation. Keep reference transcripts and review transcription errors separately from downstream model errors.
- **Quality rubric:** Measure Arabic word or character error rates with documented normalization; mixed-language preservation; conversation split and merge errors; category usefulness; summary faithfulness; and precision of supported decisions and action items. Check that every extracted commitment has a source and that unsupported fields remain empty. Numeric shipping thresholds are not agreed and must not be presented as achieved.
- **Hardware evidence:** On the actual Watch and phone, progress from a one-hour trial to an intended full-day trial. Record actual hardware and OS versions, Watch battery health, starting and ending charge, duration, missing-audio intervals, bytes captured and transferred, queue backlog, processing time relative to recorded speech, peak phone memory, and thermal interruptions. Include wrist-down use, leaving the app, calls, phone disconnection, and reconnection. Use representative daily use rather than only a plugged-in foreground run.
- **Presentation checks:** Manually inspect real Arabic and mixed-language titles, transcripts, search, and timestamp playback. Visual review supplements the manual workflow checks; it does not establish speech accuracy. No automated UI suite is proposed.
- **Prior art:** No recorder repository, existing verification workflow, domain glossary, or ADRs have been identified in this conversation. The current workspace is a parent directory containing multiple unrelated repositories. Do not claim existing coverage. The user's prohibition on writing and running unit or integration tests applies regardless of what testing tools a future repository contains.
- **Release evidence:** Present the measured endurance and Arabic evaluation results with their limits. Desired daily duration and numeric quality thresholds remain open product decisions. If the Watch cannot meet the user's routine, report that result rather than silently moving capture to a different device.

## Out of Scope

- Running speech transcription or a generative language model on the Watch in the first version.
- Cloud transcription, cloud summarization, hosted AI APIs, and an account-based server backend for the core workflow.
- Guaranteed uninterrupted 24-hour capture, a fixed full-day battery claim, or guaranteed immediate background analysis.
- Automatic recording after reboot, force quit, or a new day without a user-started session.
- Recording telephone, FaceTime, or other apps' internal call audio. In scope is ambient audio captured by the Watch microphone; calls are interruption scenarios to test.
- Named speaker identification, voiceprint enrollment, or guaranteed separation of overlapping speakers.
- Automatic translation into English, additional language targets, and optimization for Arabic dialects other than the user's Saudi/Gulf target.
- Autonomous calendar entries, reminders, messages, or other actions based on extracted action items.
- Android support, a web dashboard, multi-user sharing, cross-account synchronization, and cloud backup of recordings.
- A requirement to buy a newer Watch or iPhone, or automatic substitution of another recording device if the feasibility test fails.
- App Store submission, public launch, pricing, and production rollout in this spec.
- Writing or running unit or integration tests, including an automated workflow harness serving the same purpose.

## Further Notes

- Confirmed user preferences: iPhone 14 Pro Max; Apple Watch believed to be Series 6; start once and capture conversations throughout the day; Saudi/Gulf Arabic with occasional English; AI processing on the user's devices; the recording-session verification boundary plus real-device trials; no writing or running unit or integration tests.
- The exact Watch identity, installed operating systems, and battery health are not confirmed. No prototype, on-device benchmark, accuracy evaluation, or endurance trial has been performed.
- The term “all day” expresses the desired interaction. The user has not specified a numeric duration, acceptable recording gaps, charging routine, retention period, accuracy threshold, or processing latency target. These must remain explicit unknowns rather than invented requirements.
- Capture status must be truthful even when the AI pipeline is delayed or unavailable. Recording, transfer, and analysis should not share one success indicator.
- The first evidence to collect is whether this Watch can record for a useful duration and whether local models can understand the user's actual speech. Sophisticated organization should not obscure failure of either premise.
- Sources discussed in the conversation: [Apple Intelligence eligibility](https://support.apple.com/en-us/121115), [Apple background recording documentation](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/record), [Watch Connectivity file transfer](https://developer.apple.com/documentation/watchconnectivity/wcsession/transferfile(_:metadata:)), [WhisperKit](https://github.com/argmaxinc/WhisperKit), and [Qwen3 language support](https://qwenlm.github.io/blog/qwen3/). These support candidate selection and API investigation, not a claim that the complete system has been verified.
- The user accepted the verification approach and prohibited unit and integration tests. Publication is pending because no target repository, project issue tracker, or project triage configuration has been provided. Run `/setup-matt-pocock-skills` to establish those details. Once the tracker is configured and document review is complete, publish this spec with the `ready-for-agent` label required by the invoked skill.
