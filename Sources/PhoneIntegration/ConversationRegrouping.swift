import Foundation
import RecorderContracts

/// Pure reconciliation between freshly proposed groups and the persisted
/// set for one session — the piece that makes regrouping stable.
///
/// The lane heuristic emits *fresh* UUIDs every run, so a naive "upsert each
/// proposal" would duplicate groups forever. Instead each proposal adopts
/// the still-unclaimed persisted group sharing the most segment ids. Stable
/// ids keep user overrides attached, let late chunks extend the provisional
/// tail in place, and make membership-change detection honest.
public enum ConversationRegrouping {
    public struct Plan: Sendable {
        /// Proposals to persist — adopted proposals carry the matched
        /// existing group's id; unmatched proposals keep their fresh ids.
        public var upserts: [ConversationGroup]
        /// Persisted groups that no proposal claimed — their spans were
        /// reshuffled elsewhere (delete without tombstoning).
        public var disbandedIDs: [UUID]
        /// Conversation ids needing (re-)generated metadata: new groups and
        /// adopted groups whose membership changed. Provisionality flips
        /// alone do not enqueue — metadata doesn't depend on it.
        public var intelligenceTargets: [UUID]

        public init(upserts: [ConversationGroup], disbandedIDs: [UUID], intelligenceTargets: [UUID]) {
            self.upserts = upserts
            self.disbandedIDs = disbandedIDs
            self.intelligenceTargets = intelligenceTargets
        }
    }

    /// Maps `proposals` onto `existing` by maximum segment overlap.
    /// Deterministic: proposals are considered in startedAt order and each
    /// existing group can be adopted by at most one proposal.
    public static func plan(
        proposals: [ConversationGroup],
        existing: [ConversationGroup]
    ) -> Plan {
        var upserts: [ConversationGroup] = []
        var disbanded: [UUID] = []
        var targets: [UUID] = []
        var claimed = Set<UUID>()
        let ordered = proposals.sorted {
            ($0.startedAt ?? .distantFuture, $0.id.uuidString) < ($1.startedAt ?? .distantFuture, $1.id.uuidString)
        }

        for var proposal in ordered {
            let proposalSegments = Set(proposal.segmentIDs)
            var best: ConversationGroup?
            var bestOverlap = 0
            for candidate in existing where !claimed.contains(candidate.id) {
                let overlap = Set(candidate.segmentIDs).intersection(proposalSegments).count
                if overlap > bestOverlap {
                    best = candidate
                    bestOverlap = overlap
                }
            }

            if let adopted = best, bestOverlap > 0 {
                claimed.insert(adopted.id)
                proposal.id = adopted.id
                let membershipChanged = adopted.segmentIDs != proposal.segmentIDs
                upserts.append(proposal)
                if membershipChanged {
                    targets.append(adopted.id)
                }
            } else {
                upserts.append(proposal)
                targets.append(proposal.id)
            }
        }

        for stale in existing where !claimed.contains(stale.id) {
            disbanded.append(stale.id)
        }

        return Plan(upserts: upserts, disbandedIDs: disbanded, intelligenceTargets: targets)
    }
}
