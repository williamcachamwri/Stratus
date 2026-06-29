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

// Box to hold callback context — passed via info pointer to C FSEventStreamCallback.
private final class FSEventsCallbackBox {
    let pairID: UUID
    let onEvent: (ChangeEvent) -> Void
    init(pairID: UUID, onEvent: @escaping (ChangeEvent) -> Void) {
        self.pairID = pairID
        self.onEvent = onEvent
    }
}

private final class FSEventsMonitor: @unchecked Sendable {
    let pairID: UUID
    let rootURL: URL
    private var streamRef: FSEventStreamRef?
    private var callbackBox: FSEventsCallbackBox?
    private let queue = DispatchQueue(label: "com.stratus.fsevents", qos: .utility)

    init(pairID: UUID, rootURL: URL) {
        self.pairID = pairID
        self.rootURL = rootURL
    }

    func start(onEvent: @escaping (ChangeEvent) -> Void) {
        let box = FSEventsCallbackBox(pairID: pairID, onEvent: onEvent)
        self.callbackBox = box  // keep alive for stream duration

        let paths = [rootURL.path] as CFArray
        let infoPtr = Unmanaged.passUnretained(box).toOpaque()
        var ctx = FSEventStreamContext(version: 0, info: infoPtr, retain: nil, release: nil, copyDescription: nil)

        // Non-capturing C function pointer: uses info to access box
        let fsCallback: FSEventStreamCallback = { _, infoPtr, numEvents, eventPaths, eventFlags, _ in
            guard let infoPtr else { return }
            let box = Unmanaged<FSEventsCallbackBox>.fromOpaque(infoPtr).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as! [String]
            let flags = UnsafeBufferPointer(start: eventFlags, count: numEvents)
            for (path, flag) in zip(paths, flags) {
                let url = URL(fileURLWithPath: path)
                let changeType: ChangeType
                if flag & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 { changeType = .renamed }
                else if flag & UInt32(kFSEventStreamEventFlagItemCreated) != 0 { changeType = .created }
                else if flag & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 { changeType = .deleted }
                else { changeType = .modified }
                box.onEvent(ChangeEvent(pairID: box.pairID, localURL: url, changeType: changeType))
            }
        }

        let stream = FSEventStreamCreate(
            nil, fsCallback, &ctx, paths,
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
        callbackBox = nil
    }
}
