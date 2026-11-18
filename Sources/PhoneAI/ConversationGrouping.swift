import Foundation
import RecorderContracts

/// Deterministic timing-gap conversation grouping — no model required.
///
/// Segments are ordered by wall-clock anchor (`wallStartTime`, which the
/// speech adapter sets from `wallStartedAt + chunk-relative start`) and split
/// wherever the wall gap between consecutive segments exceeds `gapThreshold`.
/// A group may span many chunks and a chunk may produce several groups;
/// group membership never rewrites source timestamps.
///
/// Segments missing `wallStartTime` can't be ordered against other chunks'
/// segments, so they only merge within their own chunk; across chunks they
/// conservatively form their own boundary (better a spurious split than
/// merging unrelated audio).
public struct ConversationGroupingHeuristic: Sendable {
    /// Wall-clock silence (seconds) that ends a conversation.
    public var gapThreshold: TimeInterval

    public init(gapThreshold: TimeInterval = 120) {
        self.gapThreshold = gapThreshold
    }

    /// The clock position used for ordering and gap math, or nil when the
    /// segment carries no wall anchor.
    public func interval(of segment: TranscriptSegment) -> (start: Date, end: Date)? {
        guard let wallStart = segment.wallStartTime else { return nil }
        return (wallStart, wallStart.addingTimeInterval(segment.endTime - segment.startTime))
    }

    /// Groups `segments` for `sessionID`. The trailing group is
    /// `isProvisional` (late chunks may still extend it); earlier groups are
    /// settled unless late data re-sorts them — storage merges on upsert.
    public func propose(
        sessionID: UUID,
        segments: [TranscriptSegment]
    ) -> [ConversationGroup] {
        let ordered = segments.sorted { a, b in
            switch (interval(of: a)?.start, interval(of: b)?.start) {
            case let (x?, y?): return x == y ? a.startTime < b.startTime : x < y
            case (nil, nil): return a.chunkID == b.chunkID ? a.startTime < b.startTime
                : a.chunkID.uuidString < b.chunkID.uuidString
            case (nil, _?): return false
            case (_?, nil): return true
            }
        }

        var groups: [ConversationGroup] = []
        for (index, segment) in ordered.enumerated() {
            let splitBefore = index > 0 && gap(between: ordered[index - 1], segment) > gapThreshold
            if splitBefore || groups.isEmpty {
                groups.append(ConversationGroup(
                    sessionID: sessionID,
                    segmentIDs: [segment.id],
                    isProvisional: false,
                    startedAt: interval(of: segment)?.start,
                    endedAt: interval(of: segment)?.end
                ))
            } else {
                var last = groups[groups.count - 1]
                last.segmentIDs.append(segment.id)
                if let end = interval(of: segment)?.end {
                    last.endedAt = max(last.endedAt ?? end, end)
                }
                groups[groups.count - 1] = last
            }
        }
        if !groups.isEmpty {
            groups[groups.count - 1].isProvisional = true
        }
        return groups
    }

    /// Wall gap between two consecutive ordered segments. Cross-chunk
    /// comparisons without wall anchors are treated as infinite — a split.
    public func gap(between earlier: TranscriptSegment, _ later: TranscriptSegment) -> TimeInterval {
        if let a = interval(of: earlier), let b = interval(of: later) {
            return b.start.timeIntervalSince(a.end)
        }
        return earlier.chunkID == later.chunkID
            ? later.startTime - earlier.endTime
            : .infinity
    }

    /// One adjacent-group boundary that a model may review for a merge.
    public struct BoundaryCandidate: Sendable {
        /// Index of the later group in the ordered group array.
        public var laterGroupIndex: Int
        public var gapSeconds: TimeInterval
        public init(laterGroupIndex: Int, gapSeconds: TimeInterval) {
            self.laterGroupIndex = laterGroupIndex
            self.gapSeconds = gapSeconds
        }
    }

    /// Boundaries sorted smallest-gap-first — the likeliest false splits,
    /// bounded by `limit` so a day of audio never fans out unbounded model
    /// calls.
    public func boundaryCandidates(
        groups: [ConversationGroup],
        segments: [TranscriptSegment],
        limit: Int
    ) -> [BoundaryCandidate] {
        let byID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        var candidates: [BoundaryCandidate] = []
        for i in 1..<groups.count where groups[i - 1].sessionID == groups[i].sessionID {
            guard
                let lastID = groups[i - 1].segmentIDs.last, let earlier = byID[lastID],
                let firstID = groups[i].segmentIDs.first, let later = byID[firstID]
            else { continue }
            candidates.append(BoundaryCandidate(
                laterGroupIndex: i,
                gapSeconds: gap(between: earlier, later)
            ))
        }
        return candidates
            .sorted { $0.gapSeconds < $1.gapSeconds }
            .prefix(limit)
            .map { $0 }
    }

    /// Merges the group at `index` into the group before it. Returns nil if
    /// the index is out of range.
    public func merge(groups: [ConversationGroup], at index: Int) -> [ConversationGroup]? {
        guard index > 0, index < groups.count else { return nil }
        var result = groups
        var earlier = result[index - 1]
        let later = result[index]
        earlier.segmentIDs.append(contentsOf: later.segmentIDs)
        earlier.startedAt = [earlier.startedAt, later.startedAt].compactMap { $0 }.min()
        earlier.endedAt = [earlier.endedAt, later.endedAt].compactMap { $0 }.max()
        earlier.isProvisional = earlier.isProvisional || later.isProvisional
        result[index - 1] = earlier
        result.remove(at: index)
        return result
    }
}
