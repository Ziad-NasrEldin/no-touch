import Foundation

public enum RecorderError: Error, Sendable, Equatable {
    case notImplemented
    case invalidState(SessionState)
    case microphoneDenied
    case lowStorage
    case integrityMismatch
    case modelNotReady
    case storageFailure
    case notFound
}
