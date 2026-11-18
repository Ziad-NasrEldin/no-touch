import Foundation
import RecorderContracts

/// Compatibility aliases for the F0 app shell, which instantiates
/// `PlaceholderReceiveService()` / `PlaceholderArchiveStore()` in
/// `Apps/PhoneRecorderApp/ContentView.swift` (outside this lane's ownership).
///
/// These are NOT placeholders: both names now resolve to the real durable
/// implementations with non-throwing default initializers (lazy open), so the
/// shell gets real storage until I1 rewires it. The old in-memory placeholder
/// implementations were removed.
public typealias PlaceholderReceiveService = PhoneReceiveService
public typealias PlaceholderArchiveStore = SQLiteArchiveStore
