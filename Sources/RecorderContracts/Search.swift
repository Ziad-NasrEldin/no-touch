import Foundation

/// One local-search result: a transcript segment plus the conversation it
/// belongs to (nil while the segment is ungrouped). A segment shared by more
/// than one conversation yields one hit per conversation.
///
/// Lives in RecorderContracts (moved by I1) so `ExtendedArchiveStoreProtocol`
/// can expose `searchTranscripts` without the protocol depending on the
/// PhoneStorage module.
public struct TranscriptSearchHit: Sendable, Equatable {
    public var segment: TranscriptSegment
    public var conversationID: UUID?
    /// Normalized index terms from the query that matched this segment.
    public var matchedTerms: [String]

    public init(segment: TranscriptSegment, conversationID: UUID?, matchedTerms: [String]) {
        self.segment = segment
        self.conversationID = conversationID
        self.matchedTerms = matchedTerms
    }
}
