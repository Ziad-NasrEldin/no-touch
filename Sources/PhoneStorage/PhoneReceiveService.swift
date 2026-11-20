import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
import RecorderContracts

/// Phone-side receive service. Implements the spec transfer contract:
///
///   deliver → land in `incoming/` → verify SHA-256 + byte count →
///   atomic rename into `chunks/<session>/` → dedup-index insert →
///   ONLY THEN produce `TransferAcknowledgment`.
///
/// Hard rules honored:
/// - No ack before durable verified storage — every failure path throws or
///   returns a `.failed` ack the transport may relay.
/// - The Watch keeps its copy until it sees `.acknowledged`.
/// - Duplicate/out-of-order deliveries are normal: a stored dedup row re-acks
///   idempotently, a tombstoned delivery acks-and-drops so deletion propagates
///   and deleted content can never be resurrected by a delayed transfer.
///
/// The service is transport-agnostic. `WatchConnectivityReceiveTransport`
/// (iOS only) adapts `WCSession` `transferFile` deliveries to
/// `ingestReceivedFile`; `storeReceivedChunk` is the protocol seam for data
/// delivered any other way.
public actor PhoneReceiveService: PhoneFileIngestProtocol {
    /// Shared archive — the dedup index, tombstones, and chunk registry all
    /// live in this store, which is also the default diagnostics sink.
    public let archiveStore: SQLiteArchiveStore
    private let diagnostics: (any DiagnosticsSink)?
    private var prepared = false
    /// I1 integration seam: invoked once per chunk the first time it becomes
    /// durable (after registry insert, before the ack returns). Never fires
    /// for tombstoned drops, dedup re-acks, quarantines, or failures — only
    /// for a fresh verified store. Keep it cheap (job enqueue bookkeeping).
    private let onChunkStored: (@Sendable (AudioChunkMetadata) async -> Void)?

    /// `directory: nil` → `Application Support/RecorderArchive` (or the
    /// `RECORDER_ARCHIVE_DIR` override for manual exercise).
    public init(
        directory: URL? = nil,
        archiveStore: SQLiteArchiveStore? = nil,
        diagnostics: (any DiagnosticsSink)? = nil,
        onChunkStored: (@Sendable (AudioChunkMetadata) async -> Void)? = nil
    ) {
        if let archiveStore {
            self.archiveStore = archiveStore
        } else {
            self.archiveStore = SQLiteArchiveStore(directory: directory)
        }
        self.diagnostics = diagnostics ?? self.archiveStore
        self.onChunkStored = onChunkStored
    }

    /// Opens the store, sweeps crash debris. Idempotent.
    public func prepare() async throws {
        try await archiveStore.prepare()
        if !prepared {
            prepared = true
            try await repairIncomingAndChunks()
        }
    }

    // MARK: - PhoneReceiveServiceProtocol

    /// Data-path ingest (protocol seam). Lands bytes in `incoming/` first so
    /// the verify→move→register→ack pipeline is identical to file delivery.
    public func storeReceivedChunk(
        data: Data,
        metadata: AudioChunkMetadata
    ) async throws -> TransferAcknowledgment {
        try await prepare()
        let receivedAt = Date()
        let digest = Self.sha256Hex(data)

        guard digest == metadata.integrity.sha256Hex.lowercased(),
              data.count == metadata.integrity.byteCount else {
            await emit(
                name: "transfer.integrity_mismatch",
                severity: .warning,
                payload: ["chunk_id": metadata.id.uuidString,
                          "expected_bytes": "\(metadata.integrity.byteCount)",
                          "actual_bytes": "\(data.count)"]
            )
            throw RecorderError.integrityMismatch
        }
        let landing = try land(data: data, metadata: metadata)
        return try await commitVerifiedDelivery(
            landingURL: landing,
            metadata: metadata,
            digestHex: digest,
            byteCount: data.count,
            receivedAt: receivedAt
        )
    }

    public func receivedChunks(sessionID: UUID) async -> [AudioChunkMetadata] {
        (try? await archiveStore.receivedChunkMetadata(sessionID: sessionID)) ?? []
    }

    // MARK: - File-path ingest (WCSession transport)

    /// Moves an already-on-disk delivery through the same pipeline without
    /// loading it wholly into memory (streaming hash). The delivered URL is
    /// consumed: on success the file lives in `chunks/`; on verification
    /// failure it is quarantined; on storage failure it is left in
    /// `incoming/` for the restart sweep.
    public func ingestReceivedFile(
        at url: URL,
        metadata: AudioChunkMetadata
    ) async throws -> TransferAcknowledgment {
        try await prepare()
        let receivedAt = Date()
        await emit(
            name: "transfer.file_received",
            payload: ["chunk_id": metadata.id.uuidString,
                      "session_id": metadata.sessionID.uuidString]
        )

        // Tombstone check happens BEFORE any byte work: deleted content must
        // never be resurrected — the durable tombstone record is itself the
        // accounting this ack stands for. The ack echoes the metadata's
        // declared digest/size so the Watch's ack verification passes and it
        // drops its copy (spec: deletion removes content on both devices).
        if try await archiveStore.chunkDeliveryIsTombstoned(
            chunkID: metadata.id, sessionID: metadata.sessionID
        ) {
            try? FileManager.default.removeItem(at: url)
            await emit(
                name: "transfer.tombstoned_delivery",
                severity: .warning,
                payload: ["chunk_id": metadata.id.uuidString]
            )
            return TransferAcknowledgment(
                chunkID: metadata.id,
                sessionID: metadata.sessionID,
                acknowledgedAt: receivedAt,
                verifiedSHA256Hex: metadata.integrity.sha256Hex.lowercased(),
                storedByteCount: metadata.integrity.byteCount
            )
        }

        // Dedup: identical re-delivery re-acks from the registry without
        // re-storing (spec: deduplicate received chunks).
        if let existing = try await archiveStore.chunkRecord(id: metadata.id),
           existing.state == ChunkRecord.stored,
           await archiveStore.fileExists(relativePath: existing.relativePath) {
            try? FileManager.default.removeItem(at: url)
            await emit(
                name: "transfer.dedup_hit",
                payload: ["chunk_id": metadata.id.uuidString]
            )
            return TransferAcknowledgment(
                chunkID: metadata.id,
                sessionID: metadata.sessionID,
                acknowledgedAt: Date(),
                verifiedSHA256Hex: existing.sha256,
                storedByteCount: existing.byteCount
            )
        }

        // Land in incoming/ then stream-verify.
        let landing = layout.incomingDirectory
            .appendingPathComponent("\(metadata.id.uuidString)-\(UUID().uuidString).part")
        do {
            try FileManager.default.moveItem(at: url, to: landing)
        } catch {
            // Source URL may sit on a different volume (WCSession inbox) —
            // fall back to copy+remove.
            do {
                try FileManager.default.copyItem(at: url, to: landing)
                try FileManager.default.removeItem(at: url)
            } catch {
                await emit(name: "transfer.landing_failed", severity: .error,
                           payload: ["chunk_id": metadata.id.uuidString])
                throw RecorderError.storageFailure
            }
        }

        let verification = try Self.verifyFile(
            at: landing,
            expectedSHA256Hex: metadata.integrity.sha256Hex,
            expectedByteCount: metadata.integrity.byteCount
        )
        guard verification.matches else {
            quarantine(landing, reason: "integrity_mismatch")
            await emit(
                name: "transfer.integrity_mismatch",
                severity: .warning,
                payload: ["chunk_id": metadata.id.uuidString,
                          "expected_bytes": "\(metadata.integrity.byteCount)",
                          "actual_bytes": "\(verification.byteCount)"]
            )
            throw RecorderError.integrityMismatch
        }
        return try await commitVerifiedDelivery(
            landingURL: landing,
            metadata: metadata,
            digestHex: verification.sha256Hex,
            byteCount: verification.byteCount,
            receivedAt: receivedAt
        )
    }

    // MARK: - Shared pipeline tail

    /// Landing file is verified; this is the single place where a file
    /// becomes durable. Order is deliberate: rename → registry insert → ack.
    /// Crash between rename and insert leaves an unaccounted file the restart
    /// sweep quarantines — the Watch retries and redelivery re-stores.
    private func commitVerifiedDelivery(
        landingURL: URL,
        metadata: AudioChunkMetadata,
        digestHex: String,
        byteCount: Int,
        receivedAt: Date
    ) async throws -> TransferAcknowledgment {
        // Tombstone may have landed between verify and commit — re-check so a
        // deletion racing a transfer still wins.
        if try await archiveStore.chunkDeliveryIsTombstoned(
            chunkID: metadata.id, sessionID: metadata.sessionID
        ) {
            try? FileManager.default.removeItem(at: landingURL)
            await emit(name: "transfer.tombstoned_delivery", severity: .warning,
                       payload: ["chunk_id": metadata.id.uuidString, "stage": "commit"])
            return TransferAcknowledgment(
                chunkID: metadata.id,
                sessionID: metadata.sessionID,
                acknowledgedAt: Date(),
                verifiedSHA256Hex: digestHex,
                storedByteCount: byteCount
            )
        }
        if let existing = try await archiveStore.chunkRecord(id: metadata.id),
           existing.state == ChunkRecord.stored,
           await archiveStore.fileExists(relativePath: existing.relativePath) {
            try? FileManager.default.removeItem(at: landingURL)
            await emit(name: "transfer.dedup_hit",
                       payload: ["chunk_id": metadata.id.uuidString, "stage": "commit"])
            return TransferAcknowledgment(
                chunkID: metadata.id,
                sessionID: metadata.sessionID,
                acknowledgedAt: Date(),
                verifiedSHA256Hex: existing.sha256,
                storedByteCount: existing.byteCount
            )
        }

        let sessionDir = layout.sessionChunksDirectory(sessionID: metadata.sessionID)
        do {
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        } catch {
            await emit(name: "storage.directory_failed", severity: .error,
                       payload: ["chunk_id": metadata.id.uuidString])
            throw RecorderError.storageFailure
        }
        let destination = layout.durableFileURL(for: metadata)
        do {
            try FileManager.default.moveItem(at: landingURL, to: destination)
            try layout.applyProtectionAttributes(to: destination)
            try layout.setExcludedFromBackup(true, url: destination)
        } catch {
            await emit(name: "storage.move_failed", severity: .error,
                       payload: ["chunk_id": metadata.id.uuidString])
            throw RecorderError.storageFailure
        }

        let relativePath = await archiveStore.relativePath(for: metadata)
        do {
            try await archiveStore.registerStoredChunk(
                metadata: metadata, relativePath: relativePath, receivedAt: receivedAt
            )
        } catch {
            // File moved but registry write failed → quarantine so an
            // unregistered file never masquerades as stored content.
            quarantine(destination, reason: "registry_insert_failed")
            await emit(name: "storage.registry_insert_failed", severity: .error,
                       payload: ["chunk_id": metadata.id.uuidString])
            throw RecorderError.storageFailure
        }

        let latency = Date().timeIntervalSince(receivedAt)
        await emit(
            name: "transfer.chunk_stored",
            payload: ["chunk_id": metadata.id.uuidString,
                      "bytes": "\(byteCount)",
                      "ack_latency_ms": "\(Int(latency * 1000))"]
        )
        // I1 seam: notify the pipeline AFTER durable registration but BEFORE
        // the ack — the watch may drop its copy once the job is also queued.
        if let onChunkStored { await onChunkStored(metadata) }
        return TransferAcknowledgment(
            chunkID: metadata.id,
            sessionID: metadata.sessionID,
            acknowledgedAt: Date(),
            verifiedSHA256Hex: digestHex,
            storedByteCount: byteCount
        )
    }

    // MARK: - Landing & quarantine

    private var layout: ArchiveFileLayout {
        archiveStore.storageLayout
    }

    private func land(data: Data, metadata: AudioChunkMetadata) throws -> URL {
        let landing = layout.incomingDirectory
            .appendingPathComponent("\(metadata.id.uuidString)-\(UUID().uuidString).part")
        do {
            try data.write(to: landing, options: [.atomic])
            return landing
        } catch {
            throw RecorderError.storageFailure
        }
    }

    private func quarantine(_ url: URL, reason: String) {
        let destination = layout.quarantineDirectory
            .appendingPathComponent("\(reason)-\(url.lastPathComponent)")
        try? FileManager.default.moveItem(at: url, to: destination)
    }

    /// Restart sweep: `incoming/` orphans are deleted (they were never acked
    /// and possibly partial); files under `chunks/` with no registry row are
    /// quarantined (they may be valid but unaccounted — never silently
    /// deleted); `quarantine/` is left for manual inspection.
    private func repairIncomingAndChunks() async throws {
        let fileManager = FileManager.default
        if let orphans = try? fileManager.contentsOfDirectory(
            at: layout.incomingDirectory,
            includingPropertiesForKeys: nil
        ) {
            for orphan in orphans { try? fileManager.removeItem(at: orphan) }
        }

        guard let sessionDirs = try? fileManager.contentsOfDirectory(
            at: layout.chunksDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        // Only files backing `stored` rows belong on disk. Files left behind
        // by expired/deleted rows are inconsistent state — quarantine them
        // alongside files with no row at all.
        var registeredPaths = Set<String>()
        if let records = try? await archiveStore.chunkRecords(state: ChunkRecord.stored) {
            for record in records {
                registeredPaths.insert(record.relativePath)
            }
        }
        for sessionDir in sessionDirs {
            guard let files = try? fileManager.contentsOfDirectory(
                at: sessionDir, includingPropertiesForKeys: nil
            ) else { continue }
            for file in files {
                let relative = layout.relativePath(for: file)
                if !registeredPaths.contains(relative) {
                    quarantine(file, reason: "unregistered")
                    await emit(name: "storage.orphan_quarantined", severity: .warning,
                               payload: ["path": relative])
                }
            }
            // Remove empty session dirs left behind by deletions.
            if (try? fileManager.contentsOfDirectory(
                at: sessionDir, includingPropertiesForKeys: nil
            ))?.isEmpty == true {
                try? fileManager.removeItem(at: sessionDir)
            }
        }
    }

    // MARK: - Hashing

    static func sha256Hex(_ data: Data) -> String {
        #if canImport(CryptoKit)
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        fatalError("CryptoKit required for SHA-256 verification")
        #endif
    }

    /// Streams a file through SHA-256 and byte count. Chunks are small
    /// (~minutes of mono audio) but streaming keeps the transport path honest
    /// for any size.
    static func verifyFile(
        at url: URL,
        expectedSHA256Hex: String,
        expectedByteCount: Int
    ) throws -> (matches: Bool, sha256Hex: String, byteCount: Int) {
        #if canImport(CryptoKit)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            byteCount += chunk.count
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (
            digest == expectedSHA256Hex.lowercased() && byteCount == expectedByteCount,
            digest,
            byteCount
        )
        #else
        throw RecorderError.notImplemented
        #endif
    }

    private func emit(
        name: String,
        severity: DiagnosticsSeverity = .info,
        payload: [String: String]
    ) async {
        await diagnostics?.record(DiagnosticsEvent(
            subsystem: .transfer,
            severity: severity,
            name: name,
            payload: payload
        ))
    }
}
