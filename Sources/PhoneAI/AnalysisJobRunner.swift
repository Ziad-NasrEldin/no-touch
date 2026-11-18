import Foundation
import RecorderContracts

/// Bounded, cancellable, resumable pump for the durable `AnalysisJob` queue.
///
/// - Bounded: each job is one chunk (transcription) or one conversation
///   window (intelligence); `maxJobs` caps a single drain pass.
/// - Cancellable: `cancel()` or `Task` cancellation stops the loop between
///   jobs and marks the in-flight job `.cancelled`; engine work itself is
///   cancellation-checked between decode, gate wait, and inference.
/// - Resumable: jobs persist in the archive; anything left `.queued` is
///   picked up by the next `runQueuedJobs` call (e.g. on app foreground).
///
/// Two resolver closures bridge storage details the frozen contract doesn't
/// expose — see handoff for the `analysisJob(id:)`/chunk-lookup contract
/// requests these paper over.
/// Anything backed by a versioned model engine — lets the runner stamp
/// `AnalysisJob.modelVersion` without knowing the concrete adapter types.
public protocol EngineBackedAdapter: Sendable {
    var engineIdentifier: String { get }
    var engineModelVersion: String { get }
}

public actor AnalysisJobRunner {
    /// Archive + external lookups the runner needs. `audioFileResolver` maps
    /// a chunk to its stored audio file (nil = audio expired/missing);
    /// `chunkMetadataResolver` fetches `AudioChunkMetadata` by id.
    public struct Dependencies: Sendable {
        public var archive: any ConversationArchiveStoreProtocol
        public var transcriber: any SpeechTranscriptionAdapterProtocol
        public var intelligence: any TextIntelligenceAdapterProtocol
        public var audioFileResolver: @Sendable (AudioChunkMetadata) async -> URL?
        public var chunkMetadataResolver: @Sendable (UUID) async -> AudioChunkMetadata?
        public var diagnostics: @Sendable (DiagnosticsEvent) -> Void

        public init(
            archive: any ConversationArchiveStoreProtocol,
            transcriber: any SpeechTranscriptionAdapterProtocol,
            intelligence: any TextIntelligenceAdapterProtocol,
            audioFileResolver: @escaping @Sendable (AudioChunkMetadata) async -> URL?,
            chunkMetadataResolver: @escaping @Sendable (UUID) async -> AudioChunkMetadata?,
            diagnostics: @escaping @Sendable (DiagnosticsEvent) -> Void = { _ in }
        ) {
            self.archive = archive
            self.transcriber = transcriber
            self.intelligence = intelligence
            self.audioFileResolver = audioFileResolver
            self.chunkMetadataResolver = chunkMetadataResolver
            self.diagnostics = diagnostics
        }
    }

    private let dependencies: Dependencies
    private var cancelled = false

    public init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Stops the drain loop at the next checkpoint and cancels in-flight work
    /// cooperatively. Queued jobs stay queued for the next run.
    public func cancel() {
        cancelled = true
    }

    /// Runs the oldest queued job of `kind` (any kind when nil). Returns the
    /// job in its terminal state, or nil when nothing was queued.
    @discardableResult
    public func runNextQueuedJob(kind: AnalysisJobKind?) async throws -> AnalysisJob? {
        guard !cancelled else { return nil }
        let archive = dependencies.archive
        guard var job = try await archive.nextAnalysisJob(kind: kind) else {
            return nil
        }

        job.state = .running
        job.attemptCount += 1
        job.updatedAt = Date()
        try await archive.updateAnalysisJob(job)

        do {
            try Task.checkCancellation()
            switch job.kind {
            case .transcription:
                try await executeTranscription(job: &job)
            case .intelligence:
                try await executeIntelligence(job: &job)
            }
            job.state = .succeeded
            job.lastError = nil
        } catch is CancellationError {
            job.state = .cancelled
            job.lastError = "cancelled"
        } catch {
            job.state = .failed
            job.lastError = String(describing: error).prefix(300).description
            dependencies.diagnostics(DiagnosticsEvent(
                subsystem: .ai,
                severity: .error,
                name: "analysisJob.failed",
                payload: [
                    "job": job.id.uuidString,
                    "kind": job.kind.rawValue,
                    "error": job.lastError ?? "unknown",
                ]
            ))
        }
        job.updatedAt = Date()
        try await archive.updateAnalysisJob(job)
        return job
    }

    /// Drains queued jobs until the queue is empty, cancelled, or `maxJobs`
    /// ran. `maxJobs` bounds one pass so a day backlog can't pin the CPU —
    /// callers re-enter on the next foreground/scheduler opportunity.
    @discardableResult
    public func runQueuedJobs(kind: AnalysisJobKind?, maxJobs: Int = 24) async throws -> Int {
        var ran = 0
        while !cancelled, ran < maxJobs {
            let job = try await runNextQueuedJob(kind: kind)
            if job == nil { break }
            ran += 1
            // A terminal `cancelled`/`failed` job doesn't stop the drain; an
            // empty queue does.
        }
        return ran
    }

    // MARK: - Job bodies

    private func executeTranscription(job: inout AnalysisJob) async throws {
        guard let chunkID = job.chunkID else {
            throw PhoneAIError.invalidModelDescriptor("transcription job \(job.id) has no chunkID")
        }
        guard let metadata = await dependencies.chunkMetadataResolver(chunkID) else {
            throw RecorderError.notFound
        }
        guard let fileURL = await dependencies.audioFileResolver(metadata) else {
            throw RecorderError.notFound
        }
        let segments = try await dependencies.transcriber.transcribe(
            audioFileURL: fileURL,
            chunk: metadata
        )
        try await dependencies.archive.upsertTranscriptSegments(segments)
        job.modelVersion = (dependencies.transcriber as? EngineBackedAdapter)?.engineModelVersion
        dependencies.diagnostics(DiagnosticsEvent(
            subsystem: .ai,
            name: "job.transcription.completed",
            payload: ["job": job.id.uuidString, "segments": "\(segments.count)"]
        ))
    }

    private func executeIntelligence(job: inout AnalysisJob) async throws {
        guard let conversationID = job.conversationID else {
            throw PhoneAIError.invalidModelDescriptor("intelligence job \(job.id) has no conversationID")
        }
        let segments = try await dependencies.archive.transcriptSegments(conversationID: conversationID)
        guard !segments.isEmpty else {
            throw RecorderError.notFound
        }
        let metadata = try await dependencies.intelligence.generateMetadata(
            conversationID: conversationID,
            segments: segments
        )
        try await dependencies.archive.upsertGeneratedMetadata(metadata)
        job.modelVersion = (dependencies.intelligence as? EngineBackedAdapter)?.engineModelVersion
        dependencies.diagnostics(DiagnosticsEvent(
            subsystem: .ai,
            name: "job.intelligence.completed",
            payload: ["job": job.id.uuidString, "conversationID": conversationID.uuidString]
        ))
    }
}
