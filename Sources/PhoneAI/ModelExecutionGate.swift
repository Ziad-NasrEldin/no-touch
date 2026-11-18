import Foundation

/// Serializes model execution across lanes so peak memory stays bounded:
/// speech transcription and text intelligence never run concurrently through
/// the same gate. Callers still get concurrency *around* the gate (decoding,
/// parsing, persistence) — only engine inference is exclusive.
public actor ModelExecutionGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Runs `body` while holding the only execution slot. Cancellation while
    /// waiting gives the slot to the next waiter; cancellation inside `body`
    /// propagates and the slot is still released.
    public func withExclusiveAccess<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !held {
            held = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        // Resumed waiters have the slot assigned to them (held stays true).
        // If the wait was cancelled while queued, hand the slot onward.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            held = false
        }
    }
}
