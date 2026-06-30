import Foundation

// MARK: - Bandwidth Schedule

public struct BandwidthSchedule: Codable, Sendable {
    public enum Weekday: Int, Codable, Sendable, CaseIterable {
        case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday
    }

    public let weekdays: Set<Weekday>
    public let startHour: Int // 0–23
    public let startMinute: Int // 0–59
    public let endHour: Int
    public let endMinute: Int
    public let limitBPS: Double // bytes per second

    public init(
        weekdays: Set<Weekday>,
        startHour: Int,
        startMinute: Int = 0,
        endHour: Int,
        endMinute: Int = 0,
        limitBPS: Double
    ) {
        self.weekdays = weekdays
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.limitBPS = limitBPS
    }

    public func isActive(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        let comps = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = comps.weekday, let hour = comps.hour, let minute = comps.minute else { return false }
        guard let day = Weekday(rawValue: weekday), weekdays.contains(day) else { return false }
        let currentMinutes = hour * 60 + minute
        let startMinutes = startHour * 60 + startMinute
        let endMinutes = endHour * 60 + endMinute
        if startMinutes <= endMinutes {
            return currentMinutes >= startMinutes && currentMinutes < endMinutes
        } else {
            // Spans midnight
            return currentMinutes >= startMinutes || currentMinutes < endMinutes
        }
    }
}

// MARK: - UploadThrottlePolicy

public actor UploadThrottlePolicy {
    private var manualLimitBPS: Double? // nil = unlimited
    private var schedules: [BandwidthSchedule] = []
    private var lastThrottleCheck = Date()

    public static let shared = UploadThrottlePolicy()
    private init() {}

    public func setManualLimit(_ bps: Double?) {
        manualLimitBPS = bps
    }

    public func addSchedule(_ schedule: BandwidthSchedule) {
        schedules.append(schedule)
    }

    public func removeAllSchedules() {
        schedules.removeAll()
    }

    /// Effective bytes-per-second limit right now. nil = unlimited.
    public func effectiveLimitBPS(at date: Date = Date()) -> Double? {
        // Manual limit overrides schedules
        if let manual = manualLimitBPS { return manual }
        // Find first matching schedule
        for schedule in schedules {
            if schedule.isActive(at: date) { return schedule.limitBPS }
        }
        return nil
    }

    /// Compute delay to insert between chunk POSTs to hit the target rate.
    /// Preferred over TCP-level shaping which causes retransmit issues.
    public func delayBetweenChunks(chunkSize: Int, activeConcurrency: Int) async -> TimeInterval {
        guard let limit = effectiveLimitBPS(), limit > 0 else { return 0 }
        let perStreamLimit = limit / Double(max(1, activeConcurrency))
        let idealSeconds = Double(chunkSize) / perStreamLimit
        // Subtract estimated network time (assume 10ms base RTT)
        return max(0, idealSeconds - 0.01)
    }
}
