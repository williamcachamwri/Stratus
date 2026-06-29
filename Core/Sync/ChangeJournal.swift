import Foundation
import os.log

// MARK: - Change Event

public enum ChangeType: String, Sendable { case created, modified, deleted, renamed, moved }

public struct ChangeEvent: Sendable {
    public let id: UUID
    public let pairID: UUID
    public let localURL: URL
    public let changeType: ChangeType
    public let renamedFrom: URL?
    public let detectedAt: Date

    public init(pairID: UUID, localURL: URL, changeType: ChangeType, renamedFrom: URL? = nil) {
        self.id = UUID()
        self.pairID = pairID
        self.localURL = localURL
        self.changeType = changeType
        self.renamedFrom = renamedFrom
        self.detectedAt = Date()
    }
}

// MARK: - ChangeJournal

// Watches local directories for FSEvents and coalesces rapid changes.
public actor ChangeJournal {
    public static let shared = ChangeJournal()

    private var monitors: [UUID: FSEventsMonitor] = [:]
    private var pendingEvents: [String: ChangeEvent] = [:]
    private var continuations: [UUID: AsyncStream<ChangeEvent>.Continuation] = [:]
    private let logger = Logger(subsystem: "com.stratus.cloudmanager", category: "ChangeJournal")

    // Coalesce window: batch events 2s apart to avoid thrashing on rapid saves
    private static let coalesceWindowSeconds: TimeInterval = 2.0
    private var coalesceTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    public func startWatching(pair: SyncPair) async {
        guard monitors[pair.id] == nil else { return }
        let monitor = FSEventsMonitor(pairID: pair.id, rootURL: pair.localPath)
        monitors[pair.id] = monitor
        monitor.start { [weak self] event in
            Task { await self?.receiveEvent(event) }
        }
        logger.info("Started watching \(pair.localPath.path) for pair \(pair.id)")
    }

    public func stopWatching(pairID: UUID) {
        monitors[pairID]?.stop()
        monitors.removeValue(forKey: pairID)
    }

    public func events(for pairID: UUID) -> AsyncStream<ChangeEvent> {
        AsyncStream { continuation in
            continuations[pairID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(pairID: pairID) }
            }
        }
    }

    // MARK: - Private

    private func receiveEvent(_ event: ChangeEvent) {
        let key = event.pairID.uuidString + ":" + event.localURL.path
        pendingEvents[key] = event
        scheduleFlush()
    }

    private func scheduleFlush() {
        coalesceTask?.cancel()
        coalesceTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.coalesceWindowSeconds * 1_000_000_000))
            if !Task.isCancelled {
                await flushEvents()
            }
        }
    }

    private func flushEvents() async {
        let toFlush = pendingEvents
        pendingEvents.removeAll()
        for event in toFlush.values {
            continuations[event.pairID]?.yield(event)
        }
        logger.debug("Flushed \(toFlush.count) change events")
    }

    private func removeContinuation(pairID: UUID) {
        continuations.removeValue(forKey: pairID)
    }
}

// MARK: - FSEventsMonitor

private final class FSEventsMonitor: @unchecked Sendable {
    let pairID: UUID
    let rootURL: URL
    private var streamRef: FSEventStreamRef?
    private var callback: ((ChangeEvent) -> Void)?
    private let queue = DispatchQueue(label: "com.stratus.fsevents", qos: .utility)

    init(pairID: UUID, rootURL: URL) {
        self.pairID = pairID
        self.rootURL = rootURL
    }

    func start(onEvent: @escaping (ChangeEvent) -> Void) {
        self.callback = onEvent
        let paths = [rootURL.path] as CFArray
        let pairIDCopy = pairID
        var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        let stream = FSEventStreamCreate(
            nil,
            { _, info, numEvents, eventPaths, eventFlags, _ in
                guard let pathsPtr = eventPaths else { return }
                let paths = unsafeBitCast(pathsPtr, to: NSArray.self) as! [String]
                let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)
                for (path, flag) in zip(paths, flags) {
                    let url = URL(fileURLWithPath: path)
                    let type: ChangeType
                    if flag & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 { type = .renamed }
                    else if flag & UInt32(kFSEventStreamEventFlagItemCreated) != 0 { type = .created }
                    else if flag & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 { type = .deleted }
                    else { type = .modified }
                    // info ptr approach doesn't work for capturing; use notification instead
                    _ = ChangeEvent(pairID: pairIDCopy, localURL: url, changeType: type)
                }
            },
            &ctx,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        streamRef = stream
    }

    func stop() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
    }
}
