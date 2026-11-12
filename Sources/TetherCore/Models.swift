import Foundation

// MARK: - Tasks and sessions

public struct TaskItem: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var firstStep: String?
    public var createdAt: Date
    public var doneAt: Date?
    public var focusSeconds: Double

    public var isDone: Bool { doneAt != nil }

    public init(id: UUID = UUID(), title: String, firstStep: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.firstStep = firstStep
        self.createdAt = createdAt
        self.doneAt = nil
        self.focusSeconds = 0
    }
}

/// The one thing the Mac is currently tethered to.
public struct FocusSession: Codable, Equatable, Sendable {
    public var id: UUID
    public var taskID: UUID
    public var title: String
    public var firstStep: String?
    public var startedAt: Date
    public var plannedSeconds: Double
    /// Screen-on time since the session started. The countdown runs on this, so sleep and lock don't eat it.
    public var elapsedSeconds: Double
    /// Elapsed time that was not spent on a scroll site.
    public var focusSeconds: Double
    /// Sites the user declared part of the task for this session.
    public var allowedSites: [String]
    public var pulledBack: Int
    public var timeUpAnnounced: Bool

    public var remainingSeconds: Double { plannedSeconds - elapsedSeconds }
    public var isOvertime: Bool { elapsedSeconds >= plannedSeconds }
    public var progress: Double { plannedSeconds > 0 ? min(1, elapsedSeconds / plannedSeconds) : 1 }

    public init(taskID: UUID, title: String, firstStep: String?, minutes: Int, now: Date = Date()) {
        self.id = UUID()
        self.taskID = taskID
        self.title = title
        self.firstStep = firstStep
        self.startedAt = now
        self.plannedSeconds = Double(minutes) * 60
        self.elapsedSeconds = 0
        self.focusSeconds = 0
        self.allowedSites = []
        self.pulledBack = 0
        self.timeUpAnnounced = false
    }
}

// MARK: - Settings

public struct Settings: Codable, Equatable, Sendable {
    public var defaultSessionMinutes = 25

    /// Minutes of scroll sites allowed per day while untethered.
    public var scrollBudgetMinutes = 30
    /// While untethered and inside budget, check in after this many continuous minutes. 0 disables.
    public var checkInMinutes = 10
    /// Wait before "Let me through" unlocks. Doubles with every pass taken that day.
    public var gateBaseSeconds = 10
    public var passMinutes = 5

    /// "host" or "host/path-prefix".
    public var scrollSites: [String] = Settings.defaultScrollSites
    /// Bundle identifiers of apps treated like scroll sites.
    public var scrollApps: [String] = []

    public var adultWall = true
    /// Turning the wall off is delayed; this is when it actually comes down.
    public var adultWallDisableAt: Date?
    public var extraAdultSites: [String] = []

    public var nightGuard = true
    /// Minutes after midnight.
    public var nightStartMinutes = 0
    public var nightEndMinutes = 6 * 60

    public var nudges = true
    public var nudgeAfterMinutes = 15
    public var nudgeStartHour = 8
    public var nudgeEndHour = 23

    public var showPill = true
    public var closeTabOnReturn = true
    public var sounds = true
    public var onboarded = false

    public init() {}

    public static let defaultScrollSites = [
        "instagram.com", "tiktok.com", "x.com", "twitter.com", "reddit.com", "facebook.com",
        "threads.net", "threads.com", "youtube.com/shorts", "snapchat.com", "pinterest.com",
        "9gag.com", "twitch.tv", "netflix.com", "primevideo.com", "hotstar.com", "tumblr.com",
        "linkedin.com/feed", "bsky.app", "discord.com/channels",
    ]

    public static let wallDisableDelay: TimeInterval = 10 * 60

    public func isNight(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard nightGuard, nightStartMinutes != nightEndMinutes else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if nightStartMinutes < nightEndMinutes {
            return m >= nightStartMinutes && m < nightEndMinutes
        }
        return m >= nightStartMinutes || m < nightEndMinutes
    }

    public func isWallUp(_ date: Date) -> Bool {
        guard adultWall else { return false }
        if let off = adultWallDisableAt, date >= off { return false }
        return true
    }
}

// MARK: - Ledger

public enum SegmentKind: String, Codable, Sendable { case focus, scroll }

public struct Segment: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var kind: SegmentKind

    public init(start: Date, end: Date, kind: SegmentKind) {
        self.start = start
        self.end = end
        self.kind = kind
    }
}

public enum GateKind: String, Codable, Sendable { case session, night, budget, checkIn }

public struct PassRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var at: Date
    public var site: String
    public var reason: String
    public var kind: GateKind
    public var wholeSession: Bool

    public init(id: UUID, at: Date, site: String, reason: String, kind: GateKind, wholeSession: Bool) {
        self.id = id
        self.at = at
        self.site = site
        self.reason = reason
        self.kind = kind
        self.wholeSession = wholeSession
    }
}

public struct SessionRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date
    public var focusSeconds: Double
    public var completed: Bool

    public init(id: UUID, title: String, startedAt: Date, endedAt: Date, focusSeconds: Double, completed: Bool) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.focusSeconds = focusSeconds
        self.completed = completed
    }
}

public struct DayLog: Codable, Equatable, Sendable {
    public var focusSeconds: Double = 0
    public var scrollSeconds: Double = 0
    /// Times a gate ended with the user going back to work.
    public var pulledBack = 0
    public var passes: [PassRecord] = []
    /// Times the adult wall closed something. Counted, never named.
    public var walls = 0
    /// Times the user hit the urge button on their own.
    public var urgesSurfed = 0
    public var segments: [Segment] = []
    public var sessions: [SessionRecord] = []

    public init() {}

    mutating func extend(_ kind: SegmentKind, to now: Date, dt: Double) {
        if let last = segments.last, last.kind == kind, now.timeIntervalSince(last.end) < 6 {
            segments[segments.count - 1].end = now
        } else {
            segments.append(Segment(start: now.addingTimeInterval(-dt), end: now, kind: kind))
        }
    }
}

public struct AppState: Codable, Equatable, Sendable {
    public var tasks: [TaskItem] = []
    public var session: FocusSession?
    public var settings = Settings()
    public var days: [String: DayLog] = [:]
    public var pillX: Double?
    public var pillY: Double?

    public init() {}

    public func day(_ date: Date) -> DayLog { days[DayKey.key(for: date)] ?? DayLog() }

    public var openTasks: [TaskItem] { tasks.filter { !$0.isDone } }

    /// Drops ledger days older than `keep` days and finished tasks older than a week.
    public mutating func prune(now: Date, keep: Int = 60) {
        let cutoff = DayKey.key(for: now.addingTimeInterval(-Double(keep) * 86400))
        days = days.filter { $0.key >= cutoff }
        let weekAgo = now.addingTimeInterval(-7 * 86400)
        tasks.removeAll { ($0.doneAt ?? now) < weekAgo }
    }
}

// MARK: - Day boundaries

/// Days roll over at 4 AM, so a 1 AM spiral lands on the day it belongs to.
public enum DayKey {
    public static let rolloverHour = 4

    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let shifted = date.addingTimeInterval(-Double(rolloverHour) * 3600)
        let c = calendar.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public static func start(for date: Date, calendar: Calendar = .current) -> Date {
        let shifted = date.addingTimeInterval(-Double(rolloverHour) * 3600)
        return calendar.startOfDay(for: shifted).addingTimeInterval(Double(rolloverHour) * 3600)
    }
}
