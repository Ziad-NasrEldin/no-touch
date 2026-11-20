import SwiftUI
import AVFoundation
import RecorderContracts
import PhoneIntegration
import PhoneStorage

// MARK: - Model

/// One continuous recording. The watch saves audio in 1-minute clips;
/// back-to-back clips of the same session are merged into one item here.
struct RecordingItem: Identifiable {
    let id: UUID
    let sessionID: UUID
    /// Clip IDs in playback order.
    let chunkIDs: [UUID]
    let startedAt: Date
    let endedAt: Date
    let duration: TimeInterval
    let speechSeconds: TimeInterval?
    let transcript: String?
    let segments: [TranscriptSegment]
    /// Summary/title/category of the conversation this clip belongs to.
    let title: String?
    let summary: String?
    let category: String?

    var displayTitle: String {
        title ?? startedAt.formatted(date: .omitted, time: .shortened)
    }
}

/// A conversation the phone grouped out of one or more recordings.
struct ConversationItem: Identifiable {
    let id: UUID
    let startedAt: Date?
    let endedAt: Date?
    let title: String?
    let summary: String?
    let category: String?
    let isProvisional: Bool
    let transcript: String
    let segments: [TranscriptSegment]
    let chunkIDs: [UUID]
    let duration: TimeInterval

    var displayTitle: String {
        title ?? "Conversation"
    }
}

struct DaySection: Identifiable {
    let id: Date          // start of day
    var recordings: [RecordingItem]
    var conversations: [ConversationItem]

    var totalDuration: TimeInterval { recordings.reduce(0) { $0 + $1.duration } }
}

@MainActor
final class RecordingsLibrary: ObservableObject {
    @Published private(set) var days: [DaySection] = []
    @Published private(set) var isLoading = false

    func recording(id: UUID) -> RecordingItem? {
        for day in days {
            if let match = day.recordings.first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }

    func conversation(id: UUID) -> ConversationItem? {
        for day in days {
            if let match = day.conversations.first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }

    func load(from coordinator: SessionCoordinator?) async {
        guard let coordinator else { return }
        isLoading = true
        defer { isLoading = false }
        let store = coordinator.archiveStore()
        let calendar = Calendar.current

        var sessionIDs = Set((try? await store.sessionIDsWithStoredChunks()) ?? [])
        for session in (try? await store.sessions()) ?? [] { sessionIDs.insert(session.id) }

        var byDay: [Date: DaySection] = [:]
        for sessionID in sessionIDs {
            let chunks = await coordinator.receivedChunks(sessionID: sessionID)
            let chunkByID = Dictionary(uniqueKeysWithValues: chunks.map { ($0.id, $0) })
            let segments = (try? await store.transcriptSegments(sessionID: sessionID)) ?? []
            let textByChunk = Dictionary(grouping: segments, by: \.chunkID)
                .mapValues { $0.sorted { $0.startTime < $1.startTime }.map(\.text).joined(separator: " ") }

            let groups = (try? await store.conversationGroups(sessionID: sessionID)) ?? []
            var metaByGroup: [UUID: GeneratedConversationMetadata] = [:]
            var groupBySegment: [UUID: UUID] = [:]
            for group in groups {
                if let meta = try? await store.effectiveMetadata(conversationID: group.id) {
                    metaByGroup[group.id] = meta
                }
                for segID in group.segmentIDs { groupBySegment[segID] = group.id }
            }
            let segmentsByChunk = Dictionary(grouping: segments, by: \.chunkID)
                .mapValues { $0.sorted { $0.startTime < $1.startTime } }

            // Merge back-to-back clips (gap ≤ 15 s) into one recording.
            let ordered = chunks.sorted {
                if $0.integrity.wallStartedAt == $1.integrity.wallStartedAt {
                    return $0.integrity.sequenceNumber < $1.integrity.sequenceNumber
                }
                return $0.integrity.wallStartedAt < $1.integrity.wallStartedAt
            }
            var runs: [[AudioChunkMetadata]] = []
            for chunk in ordered {
                if let last = runs.last?.last,
                   chunk.integrity.wallStartedAt.timeIntervalSince(last.integrity.wallEndedAt) <= 15 {
                    runs[runs.count - 1].append(chunk)
                } else {
                    runs.append([chunk])
                }
            }

            for run in runs {
                guard let first = run.first, let last = run.last else { continue }
                let runSegments = run.flatMap { segmentsByChunk[$0.id] ?? [] }
                let owningGroup = Dictionary(grouping: runSegments.compactMap { groupBySegment[$0.id] }, by: { $0 })
                    .max(by: { $0.value.count < $1.value.count })?.key
                let meta = owningGroup.flatMap { metaByGroup[$0] }
                let start = first.integrity.wallStartedAt
                let day = calendar.startOfDay(for: start)
                let text = run.compactMap { textByChunk[$0.id] }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let duration = run.reduce(0.0) { total, chunk in
                    // Older clips were sealed with a 0 s duration; fall back
                    // to their wall-clock span.
                    let d = chunk.integrity.duration
                    return total + (d > 0 ? d : max(0, chunk.integrity.wallEndedAt.timeIntervalSince(chunk.integrity.wallStartedAt)))
                }
                let speech = run.compactMap { $0.integrity.voiceActivity?.speechSeconds }
                let item = RecordingItem(
                    id: first.id,
                    sessionID: sessionID,
                    chunkIDs: run.map(\.id),
                    startedAt: start,
                    endedAt: last.integrity.wallEndedAt,
                    duration: duration,
                    speechSeconds: speech.isEmpty ? nil : speech.reduce(0, +),
                    transcript: text.isEmpty ? nil : text,
                    segments: runSegments,
                    title: meta?.title,
                    summary: meta?.summary,
                    category: meta?.suggestedCategory
                )
                byDay[day, default: DaySection(id: day, recordings: [], conversations: [])].recordings.append(item)
            }

            let segmentByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
            for group in groups {
                let meta = metaByGroup[group.id]
                let groupSegments = group.segmentIDs.compactMap { segmentByID[$0] }
                let anchor = group.startedAt ?? groupSegments.compactMap(\.wallStartTime).min()
                guard let anchor else { continue }
                let day = calendar.startOfDay(for: anchor)
                var seenChunkIDs = Set<UUID>()
                var orderedChunkIDs: [UUID] = []
                for seg in groupSegments where seenChunkIDs.insert(seg.chunkID).inserted {
                    orderedChunkIDs.append(seg.chunkID)
                }
                let groupDuration = orderedChunkIDs.reduce(0.0) { total, cid in
                    guard let chunk = chunkByID[cid] else { return total }
                    let d = chunk.integrity.duration
                    return total + (d > 0 ? d : max(0, chunk.integrity.wallEndedAt.timeIntervalSince(chunk.integrity.wallStartedAt)))
                }
                let item = ConversationItem(
                    id: group.id,
                    startedAt: anchor,
                    endedAt: group.endedAt,
                    title: meta?.title,
                    summary: meta?.summary,
                    category: meta?.suggestedCategory,
                    isProvisional: group.isProvisional,
                    transcript: groupSegments.map(\.text).joined(separator: " "),
                    segments: groupSegments,
                    chunkIDs: orderedChunkIDs,
                    duration: groupDuration
                )
                byDay[day, default: DaySection(id: day, recordings: [], conversations: [])].conversations.append(item)
            }
        }

        days = byDay.values
            .map { section in
                var s = section
                s.recordings.sort { $0.startedAt > $1.startedAt }
                s.conversations.sort { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
                return s
            }
            .sorted { $0.id > $1.id }
    }
}

// MARK: - Playback

@MainActor
final class ChunkPlayer: ObservableObject {
    enum PlaybackState: Equatable {
        case idle
        case loading
        case playing
        case paused
    }

    @Published private(set) var activeID: UUID?
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var activeTitle: String = ""
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var totalDuration: TimeInterval = 0
    @Published private(set) var currentClipIndex: Int = 0
    @Published private(set) var clipCount: Int = 0
    @Published private(set) var errorMessage: String?

    var playingID: UUID? { state == .playing ? activeID : nil }

    func isActive(_ id: UUID) -> Bool { activeID == id && state != .idle }
    func isPlaying(_ id: UUID) -> Bool { activeID == id && state == .playing }
    func isPaused(_ id: UUID) -> Bool { activeID == id && state == .paused }
    func isLoading(_ id: UUID) -> Bool { activeID == id && state == .loading }

    private var loadGeneration: UInt64 = 0
    private var player: AVQueuePlayer?
    private var clipURLs: [URL] = []
    private var clipDurations: [TimeInterval] = []
    private var clipStartOffsets: [TimeInterval] = []
    private var itemIndexByID: [ObjectIdentifier: Int] = [:]
    private var timeObserver: Any?
    private var currentItemKVO: NSKeyValueObservation?
    private var itemStatusKVO: NSKeyValueObservation?
    private var timeControlKVO: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []
    private var isScrubbing = false

    func togglePlayPause(for item: RecordingItem, coordinator: SessionCoordinator?) async {
        await togglePlayPause(
            id: item.id,
            title: item.displayTitle,
            chunkIDs: item.chunkIDs,
            fallbackDuration: item.duration,
            coordinator: coordinator
        )
    }

    func togglePlayPause(for item: ConversationItem, coordinator: SessionCoordinator?) async {
        await togglePlayPause(
            id: item.id,
            title: item.displayTitle,
            chunkIDs: item.chunkIDs,
            fallbackDuration: item.duration,
            coordinator: coordinator
        )
    }

    func togglePlayPause(
        id: UUID,
        title: String,
        chunkIDs: [UUID],
        fallbackDuration: TimeInterval,
        coordinator: SessionCoordinator?
    ) async {
        errorMessage = nil

        if activeID == id {
            switch state {
            case .playing:
                pause()
                return
            case .paused:
                resume()
                return
            case .loading:
                stop()
                return
            case .idle:
                break
            }
        }

        stop(clearError: true)
        loadGeneration &+= 1
        let generation = loadGeneration

        activeID = id
        activeTitle = title
        state = .loading
        currentTime = 0
        totalDuration = max(0, fallbackDuration)
        currentClipIndex = 0
        clipCount = chunkIDs.count

        guard let coordinator else {
            fail("Archive is unavailable.")
            return
        }
        guard !chunkIDs.isEmpty else {
            fail("No audio clips are linked to this item.")
            return
        }

        let store = coordinator.archiveStore()
        var urls: [URL] = []
        let fm = FileManager.default
        for chunkID in chunkIDs {
            if let url = try? await store.audioFileURL(chunkID: chunkID),
               let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? NSNumber,
               size.intValue > 0 {
                urls.append(url)
            }
        }

        guard generation == loadGeneration else { return }
        guard !urls.isEmpty else {
            fail("Audio file is unavailable (expired, deleted, or empty).")
            return
        }

        // Probe real clip durations asynchronously so scrubbing and total length are exact.
        var durations: [TimeInterval] = []
        durations.reserveCapacity(urls.count)
        let perClipFallback = fallbackDuration > 0 ? fallbackDuration / Double(urls.count) : 0
        for url in urls {
            let asset = AVURLAsset(url: url)
            let loaded = try? await asset.load(.duration)
            let seconds = loaded.map(CMTimeGetSeconds) ?? .nan
            if seconds.isFinite && seconds > 0 {
                durations.append(seconds)
            } else {
                durations.append(perClipFallback)
            }
        }

        guard generation == loadGeneration else { return }

        do {
            try configureAudioSessionForPlayback()
        } catch {
            fail("Could not start audio playback: \(error.localizedDescription)")
            return
        }

        var offsets: [TimeInterval] = []
        offsets.reserveCapacity(durations.count)
        var running: TimeInterval = 0
        for d in durations {
            offsets.append(running)
            running += d
        }

        clipURLs = urls
        clipDurations = durations
        clipStartOffsets = offsets
        clipCount = urls.count
        totalDuration = running > 0 ? running : max(0, fallbackDuration)
        currentClipIndex = 0
        currentTime = 0

        buildQueue(startingAt: 0, localOffset: 0, autoPlay: true)
    }

    func toggleCurrentPlayPause() {
        switch state {
        case .playing: pause()
        case .paused: resume()
        case .loading: stop()
        case .idle: break
        }
    }

    func pause() {
        guard state == .playing else { return }
        player?.pause()
        state = .paused
    }

    func resume() {
        guard state == .paused, let player else { return }
        errorMessage = nil
        do {
            try configureAudioSessionForPlayback()
        } catch {
            fail("Could not resume audio playback: \(error.localizedDescription)")
            return
        }
        player.play()
        state = .playing
    }

    func beginScrubbing() {
        isScrubbing = true
    }

    func scrub(to seconds: TimeInterval) {
        currentTime = min(max(0, seconds), totalDuration)
    }

    func endScrubbing(at seconds: TimeInterval) {
        isScrubbing = false
        seek(to: seconds)
    }

    func skip(by delta: TimeInterval) {
        guard state == .playing || state == .paused else { return }
        seek(to: currentTime + delta)
    }

    func seek(to target: TimeInterval) {
        guard !clipURLs.isEmpty, state == .playing || state == .paused else { return }
        let clamped = min(max(0, target), max(totalDuration, 0))
        let wasPlaying = (state == .playing)

        // Find the clip containing `clamped`.
        var targetIndex = clipURLs.count - 1
        for i in clipURLs.indices {
            let start = clipStartOffsets[i]
            let end = start + clipDurations[i]
            if clamped < end || i == clipURLs.count - 1 {
                targetIndex = i
                break
            }
        }
        let localOffset = max(0, clamped - clipStartOffsets[targetIndex])
        currentTime = clamped

        if targetIndex == currentClipIndex, let player, player.currentItem != nil {
            let cm = CMTime(seconds: localOffset, preferredTimescale: 600)
            player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        } else {
            buildQueue(startingAt: targetIndex, localOffset: localOffset, autoPlay: wasPlaying)
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func stop(clearError: Bool = true) {
        loadGeneration &+= 1
        tearDownPlayer()
        activeID = nil
        activeTitle = ""
        state = .idle
        currentTime = 0
        totalDuration = 0
        currentClipIndex = 0
        clipCount = 0
        clipURLs = []
        clipDurations = []
        clipStartOffsets = []
        isScrubbing = false
        if clearError { errorMessage = nil }
        BackgroundKeepAlive.shared.resumeIfNeeded()
    }

    // MARK: - Internals

    private func fail(_ message: String) {
        tearDownPlayer()
        activeID = nil
        activeTitle = ""
        state = .idle
        currentTime = 0
        totalDuration = 0
        currentClipIndex = 0
        clipCount = 0
        clipURLs = []
        clipDurations = []
        clipStartOffsets = []
        isScrubbing = false
        errorMessage = message
        BackgroundKeepAlive.shared.resumeIfNeeded()
    }

    private func configureAudioSessionForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        // Keep `.mixWithOthers` whenever BackgroundKeepAlive's silent audio
        // engine is running so playback never conflicts with or stalls it.
        if BackgroundKeepAlive.shared.isActive {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        } else {
            try session.setCategory(.playback, mode: .spokenAudio, options: [])
        }
        try session.setActive(true)
    }

    private func tearDownPlayer() {
        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        currentItemKVO?.invalidate()
        currentItemKVO = nil
        itemStatusKVO?.invalidate()
        itemStatusKVO = nil
        timeControlKVO?.invalidate()
        timeControlKVO = nil
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers = []
        itemIndexByID = [:]
        player?.pause()
        player?.removeAllItems()
        player = nil
    }

    private func buildQueue(startingAt startIndex: Int, localOffset: TimeInterval, autoPlay: Bool) {
        tearDownPlayer()
        guard startIndex >= 0, startIndex < clipURLs.count else {
            stop(clearError: false)
            return
        }

        var items: [AVPlayerItem] = []
        var indexMap: [ObjectIdentifier: Int] = [:]
        for idx in startIndex..<clipURLs.count {
            let item = AVPlayerItem(url: clipURLs[idx])
            items.append(item)
            indexMap[ObjectIdentifier(item)] = idx
        }
        itemIndexByID = indexMap

        let queuePlayer = AVQueuePlayer(items: items)
        queuePlayer.automaticallyWaitsToMinimizeStalling = false
        self.player = queuePlayer
        self.currentClipIndex = startIndex

        if localOffset > 0 {
            let cm = CMTime(seconds: localOffset, preferredTimescale: 600)
            queuePlayer.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
        }

        currentItemKVO = queuePlayer.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.syncCurrentItem()
            }
        }

        timeControlKVO = queuePlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.syncTimeControlStatus()
            }
        }

        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            let itemID = note.object.map { ObjectIdentifier($0 as AnyObject) }
            Task { @MainActor [weak self] in
                self?.handleItemEnded(itemID: itemID)
            }
        })

        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            let itemID = note.object.map { ObjectIdentifier($0 as AnyObject) }
            let reason = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor [weak self] in
                self?.handleItemFailed(itemID: itemID, reason: reason)
            }
        })

        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            Task { @MainActor [weak self] in
                if rawType == AVAudioSession.InterruptionType.began.rawValue {
                    self?.pause()
                }
            }
        })

        timeObserver = queuePlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            Task { @MainActor [weak self] in
                self?.handlePeriodicTime(seconds)
            }
        }

        if autoPlay {
            queuePlayer.play()
            state = .playing
        } else {
            state = .paused
        }
    }

    private func syncCurrentItem() {
        itemStatusKVO?.invalidate()
        itemStatusKVO = nil
        guard let item = player?.currentItem else { return }
        if let idx = itemIndexByID[ObjectIdentifier(item)] {
            currentClipIndex = idx
        }
        itemStatusKVO = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.syncCurrentItemStatus()
            }
        }
    }

    private func syncCurrentItemStatus() {
        guard let item = player?.currentItem else { return }
        if item.status == .failed {
            let reason = item.error?.localizedDescription ?? "Unplayable audio clip."
            handleItemFailed(itemID: ObjectIdentifier(item), reason: reason)
        }
    }

    private func syncTimeControlStatus() {
        guard let player, state != .idle else { return }
        switch player.timeControlStatus {
        case .playing:
            state = .playing
        case .paused:
            if state == .playing { state = .paused }
        case .waitingToPlayAtSpecifiedRate:
            break
        @unknown default:
            break
        }
    }

    private func handlePeriodicTime(_ localSeconds: Double) {
        guard !isScrubbing, state != .idle, localSeconds.isFinite else { return }
        let base = currentClipIndex < clipStartOffsets.count ? clipStartOffsets[currentClipIndex] : 0
        currentTime = min(max(0, base + max(0, localSeconds)), max(totalDuration, base + max(0, localSeconds)))
    }

    private func handleItemEnded(itemID: ObjectIdentifier?) {
        guard let itemID, let idx = itemIndexByID[itemID] else { return }
        if idx >= clipURLs.count - 1 {
            stop(clearError: false)
        }
    }

    private func handleItemFailed(itemID: ObjectIdentifier?, reason: String?) {
        guard let itemID, let idx = itemIndexByID[itemID] else { return }
        let message = "Audio clip \(idx + 1) failed to play: \(reason ?? "unknown error")."
        let nextIndex = idx + 1
        if nextIndex < clipURLs.count {
            errorMessage = message
            buildQueue(startingAt: nextIndex, localOffset: 0, autoPlay: state == .playing)
        } else {
            fail(message)
        }
    }
}

// MARK: - Views

struct RecordingsView: View {
    @ObservedObject var model: PhoneRecorderModel
    @StateObject private var library = RecordingsLibrary()
    @StateObject private var player = ChunkPlayer()

    var body: some View {
        NavigationStack {
            List {
                if model.live.isLive {
                    Section {
                        LiveRecordingBanner(status: model.live)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }

                if let error = player.errorMessage {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.primary)
                            Spacer()
                            Button {
                                player.clearError()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Dismiss playback error")
                        }
                        .padding(.vertical, 2)
                    }
                }

                if library.days.isEmpty {
                    ContentUnavailableView {
                        Label(library.isLoading ? "Loading…" : "No recordings yet",
                              systemImage: "waveform")
                    } description: {
                        Text("Tap Start day on your watch. Recordings appear here once the watch sends them to your iPhone.")
                    }
                    .listRowBackground(Color.clear)
                }

                ForEach(library.days) { day in
                    Section {
                        ForEach(day.conversations) { convo in
                            NavigationLink {
                                ConversationDetailView(
                                    conversationID: convo.id,
                                    fallbackItem: convo,
                                    library: library,
                                    model: model,
                                    player: player
                                )
                            } label: {
                                ConversationRow(item: convo)
                            }
                        }
                        ForEach(day.recordings) { rec in
                            HStack(spacing: 12) {
                                Button {
                                    Task { await player.togglePlayPause(for: rec, coordinator: model.coordinator) }
                                } label: {
                                    Group {
                                        if player.isLoading(rec.id) {
                                            ProgressView()
                                        } else {
                                            Image(systemName: player.isPlaying(rec.id) ? "pause.circle.fill" : "play.circle.fill")
                                                .font(.title2)
                                                .foregroundStyle(.tint)
                                        }
                                    }
                                    .frame(width: 40, height: 40)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(player.isPlaying(rec.id) ? "Pause \(rec.displayTitle)" : "Play \(rec.displayTitle)")

                                NavigationLink {
                                    RecordingDetailView(
                                        recordingID: rec.id,
                                        fallbackItem: rec,
                                        library: library,
                                        model: model,
                                        player: player
                                    )
                                } label: {
                                    RecordingRowContent(
                                        item: rec,
                                        isActive: player.isActive(rec.id),
                                        isPlaying: player.isPlaying(rec.id)
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        HStack {
                            Text(Self.dayTitle(day.id))
                            Spacer()
                            Text("\(day.recordings.count) \(day.recordings.count == 1 ? "recording" : "recordings") · \(Self.duration(day.totalDuration))")
                                .textCase(nil)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if player.state != .idle {
                    MiniPlayerBar(player: player)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: RecorderLiveNotifications.chunkDidArrive)) { _ in
                Task { await library.load(from: model.coordinator) }
            }
            .onReceive(NotificationCenter.default.publisher(for: RecorderLiveNotifications.analysisDidChange)) { _ in
                Task { await library.load(from: model.coordinator) }
            }
            .navigationTitle("Recordings")
            .refreshable { await reload() }
            .task { await reload() }
            .onAppear { Task { await library.load(from: model.coordinator) } }
        }
    }

    private func reload() async {
        await model.refresh()
        await library.load(from: model.coordinator)
    }

    static func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        if clamped < 1 { return "0s" }
        let f = DateComponentsFormatter()
        f.allowedUnits = clamped >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: clamped) ?? "\(Int(clamped))s"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

private struct MiniPlayerBar: View {
    @ObservedObject var player: ChunkPlayer

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button {
                    player.toggleCurrentPlayPause()
                } label: {
                    Group {
                        if player.state == .loading {
                            ProgressView()
                        } else {
                            Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                                .font(.title3)
                        }
                    }
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(player.state == .playing ? "Pause playback" : "Resume playback")

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.activeTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("\(RecordingsView.clock(player.currentTime)) / \(RecordingsView.clock(player.totalDuration))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if player.clipCount > 1 {
                            Text("· Clip \(player.currentClipIndex + 1)/\(player.clipCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                Button {
                    player.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop playback")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }
}

private struct RecordingRowContent: View {
    let item: RecordingItem
    let isActive: Bool
    let isPlaying: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(item.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text("· \(RecordingsView.duration(item.duration))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if isPlaying {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundStyle(.tint)
                } else if isActive {
                    Text("Paused")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Text(item.transcript ?? "Not transcribed yet")
                .font(.subheadline)
                .foregroundStyle(item.transcript == nil ? .tertiary : .secondary)
                .lineLimit(2)
        }
    }
}

private struct ConversationRow: View {
    let item: ConversationItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(.purple)
                Text(item.displayTitle).font(.headline)
                Spacer()
                if let start = item.startedAt {
                    Text(start.formatted(date: .omitted, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let category = item.category {
                Text(category)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.purple.opacity(0.15), in: Capsule())
            }
            Text(item.summary ?? item.transcript)
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 2)
    }
}

private struct AudioPlaybackSection: View {
    let itemID: UUID
    let title: String
    let chunkIDs: [UUID]
    let duration: TimeInterval
    @ObservedObject var model: PhoneRecorderModel
    @ObservedObject var player: ChunkPlayer

    private var isThisItem: Bool { player.isActive(itemID) }
    private var displayedTotal: TimeInterval { isThisItem && player.totalDuration > 0 ? player.totalDuration : max(0, duration) }
    private var displayedCurrent: TimeInterval { isThisItem ? player.currentTime : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if displayedTotal > 0 {
                VStack(spacing: 4) {
                    Slider(
                        value: Binding(
                            get: { min(displayedCurrent, displayedTotal) },
                            set: { newVal in
                                if isThisItem {
                                    player.scrub(to: newVal)
                                }
                            }
                        ),
                        in: 0...max(displayedTotal, 0.1),
                        onEditingChanged: { editing in
                            guard isThisItem else { return }
                            if editing {
                                player.beginScrubbing()
                            } else {
                                player.endScrubbing(at: player.currentTime)
                            }
                        }
                    )
                    .disabled(!isThisItem)

                    HStack {
                        Text(RecordingsView.clock(displayedCurrent))
                        Spacer()
                        if isThisItem && player.clipCount > 1 {
                            Text("Clip \(player.currentClipIndex + 1) of \(player.clipCount)")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        Text(RecordingsView.clock(displayedTotal))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button {
                    Task {
                        await player.togglePlayPause(
                            id: itemID,
                            title: title,
                            chunkIDs: chunkIDs,
                            fallbackDuration: duration,
                            coordinator: model.coordinator
                        )
                    }
                } label: {
                    HStack(spacing: 6) {
                        if player.isLoading(itemID) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading…")
                        } else if player.isPlaying(itemID) {
                            Image(systemName: "pause.fill")
                            Text("Pause")
                        } else if player.isPaused(itemID) {
                            Image(systemName: "play.fill")
                            Text("Resume")
                        } else {
                            Image(systemName: "play.fill")
                            Text("Play recording")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)

                if isThisItem {
                    Button {
                        player.skip(by: -15)
                    } label: {
                        Image(systemName: "gobackward.15")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Rewind 15 seconds")

                    Button {
                        player.skip(by: 15)
                    } label: {
                        Image(systemName: "goforward.15")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Forward 15 seconds")

                    Button(role: .destructive) {
                        player.stop()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Stop playback")
                }
            }

            if let error = player.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct RecordingDetailView: View {
    let recordingID: UUID
    let fallbackItem: RecordingItem
    @ObservedObject var library: RecordingsLibrary
    @ObservedObject var model: PhoneRecorderModel
    @ObservedObject var player: ChunkPlayer

    private var item: RecordingItem {
        library.recording(id: recordingID) ?? fallbackItem
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    if let category = item.category { CategoryChip(text: category) }
                    Text(item.summary ?? (item.transcript == nil
                        ? "No summary yet. Install the models on the Status tab, then tap Process now."
                        : "No summary yet. It appears once the text model has processed this conversation."))
                        .foregroundStyle(item.summary == nil ? .secondary : .primary)
                }
                .padding(.vertical, 4)

                if item.transcript == nil || item.summary == nil {
                    Button {
                        model.processNow()
                    } label: {
                        HStack {
                            if model.isProcessing {
                                ProgressView()
                                    .padding(.trailing, 4)
                                Text("Processing…")
                            } else {
                                Label("Process now", systemImage: "sparkles")
                            }
                            Spacer()
                        }
                    }
                    .disabled(model.isProcessing || model.isInstalling)

                    if let status = model.statusMessage, !status.isEmpty {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: { Text("Summary") }

            Section("Audio") {
                AudioPlaybackSection(
                    itemID: item.id,
                    title: item.displayTitle,
                    chunkIDs: item.chunkIDs,
                    duration: item.duration,
                    model: model,
                    player: player
                )
                LabeledContent("Time", value: "\(item.startedAt.formatted(date: .abbreviated, time: .shortened)) – \(item.endedAt.formatted(date: .omitted, time: .shortened))")
                LabeledContent("Length", value: RecordingsView.duration(item.duration))
                if item.chunkIDs.count > 1 {
                    LabeledContent("Clips", value: "\(item.chunkIDs.count)")
                }
                if let speech = item.speechSeconds {
                    LabeledContent("Speech detected", value: RecordingsView.duration(speech))
                }
            }

            TranscriptSection(segments: item.segments, origin: item.startedAt)
        }
        .navigationTitle(item.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ConversationDetailView: View {
    let conversationID: UUID
    let fallbackItem: ConversationItem
    @ObservedObject var library: RecordingsLibrary
    @ObservedObject var model: PhoneRecorderModel
    @ObservedObject var player: ChunkPlayer

    private var item: ConversationItem {
        library.conversation(id: conversationID) ?? fallbackItem
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    if let category = item.category { CategoryChip(text: category) }
                    Text(item.summary ?? "No summary yet.")
                        .foregroundStyle(item.summary == nil ? .secondary : .primary)
                }
                .padding(.vertical, 4)
            } header: { Text("Summary") }

            Section("Audio") {
                if !item.chunkIDs.isEmpty {
                    AudioPlaybackSection(
                        itemID: item.id,
                        title: item.displayTitle,
                        chunkIDs: item.chunkIDs,
                        duration: item.duration,
                        model: model,
                        player: player
                    )
                }
                if let start = item.startedAt {
                    LabeledContent("Started", value: start.formatted(date: .abbreviated, time: .shortened))
                }
                if let end = item.endedAt {
                    LabeledContent("Ended", value: end.formatted(date: .omitted, time: .shortened))
                }
            }

            TranscriptSection(segments: item.segments, origin: item.startedAt)
        }
        .navigationTitle(item.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CategoryChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.purple.opacity(0.15), in: Capsule())
    }
}

/// Transcript rendered as speaker turns: consecutive segments from the same
/// speaker (within the same clip) merge into one block.
private struct TranscriptSection: View {
    let segments: [TranscriptSegment]
    let origin: Date?

    private struct Turn: Identifiable {
        let id: UUID
        let speakerID: Int?
        let time: Date?
        var text: String
    }

    private var turns: [Turn] {
        var out: [Turn] = []
        var lastKey: String?
        for seg in segments {
            let key = "\(seg.chunkID)-\(seg.speakerID.map(String.init) ?? "?")"
            if key == lastKey, !out.isEmpty {
                out[out.count - 1].text += " " + seg.text
            } else {
                out.append(Turn(id: seg.id, speakerID: seg.speakerID, time: seg.wallStartTime, text: seg.text))
            }
            lastKey = key
        }
        return out
    }

    private var speakerCount: Int { Set(segments.compactMap(\.speakerID)).count }

    static let palette: [Color] = [.blue, .orange, .green, .pink, .teal, .indigo, .brown]

    var body: some View {
        Section {
            if segments.isEmpty {
                Text("Not transcribed yet.").foregroundStyle(.secondary)
            } else {
                ForEach(turns) { turn in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(color(turn.speakerID))
                                .frame(width: 8, height: 8)
                            Text(label(turn.speakerID))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(color(turn.speakerID))
                            Spacer()
                            if let time = turn.time {
                                Text(time.formatted(date: .omitted, time: .standard))
                                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        Text(turn.text).textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text(speakerCount > 1 ? "Transcript · \(speakerCount) speakers" : "Transcript")
        }
    }

    private func label(_ id: Int?) -> String {
        guard let id else { return "Speaker" }
        return "Speaker \(id + 1)"
    }

    private func color(_ id: Int?) -> Color {
        guard let id else { return .secondary }
        return Self.palette[id % Self.palette.count]
    }
}
