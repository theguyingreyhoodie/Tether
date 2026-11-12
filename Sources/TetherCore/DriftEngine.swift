import Foundation

public enum EngineAction: Equatable, Sendable {
    case none
    /// Adult content in front: close it and hold the user for an urge surf.
    case wall(site: String)
    /// Scroll site in front and it isn't allowed right now.
    case gate(kind: GateKind, site: String, wait: Int)
}

public struct TickResult: Equatable, Sendable {
    public var action: EngineAction = .none
    /// Set when the user has been active and untethered long enough to deserve a tap on the shoulder.
    public var nudgeMinutes: Int?
}

/// Decides, once a second, whether what is on screen is fine. Pure logic: no AppKit, no clock of its own.
public struct DriftEngine: Sendable {
    /// Seconds a scroll site has to stay in front before it counts. Stops gates on tab-flicking.
    public static let grace: TimeInterval = 3
    public static let maxWait = 120
    static let allSites = "*"

    public var calendar = Calendar.current

    /// Site (or "*") → when the pass runs out.
    private var passes: [String: Date] = [:]
    private var scrollSince: Date?
    private var neutralSince: Date?
    /// Continuous scrolling, forgiven after a minute elsewhere.
    public private(set) var stretchSeconds: Double = 0
    private var nextCheckIn: Double?
    private var untetheredActive: Double = 0

    public init() {}

    public mutating func tick(now: Date, dt: Double, verdict: Verdict, idleSeconds: Double, state: inout AppState) -> TickResult {
        let key = DayKey.key(for: now, calendar: calendar)
        var day = state.days[key] ?? DayLog()
        defer { state.days[key] = day }

        let settings = state.settings
        var result = TickResult()
        passes = passes.filter { $0.value > now }

        if state.session != nil {
            state.session!.elapsedSeconds += dt
            untetheredActive = 0
        } else if idleSeconds < 60, settings.nudges {
            untetheredActive += dt
            let hour = calendar.component(.hour, from: now)
            if untetheredActive >= Double(settings.nudgeAfterMinutes) * 60,
               hour >= settings.nudgeStartHour, hour < settings.nudgeEndHour {
                result.nudgeMinutes = settings.nudgeAfterMinutes
                untetheredActive = 0
            }
        }

        var site: String
        switch verdict {
        case .neutral:
            neutral(now: now, dt: dt, state: &state, day: &day)
            return result
        case .adult(let s):
            if settings.isWallUp(now) {
                scrollSince = nil
                result.action = .wall(site: s)
                return result
            }
            site = s
        case .scroll(let s):
            site = s
        }

        // A site declared part of the task is work for as long as the session lasts.
        if let session = state.session, session.allowedSites.contains(site) {
            neutral(now: now, dt: dt, state: &state, day: &day)
            return result
        }

        neutralSince = nil
        if scrollSince == nil { scrollSince = now }
        // Ten minutes without touching anything is a video or an empty chair; stop counting.
        if idleSeconds < 600 {
            day.scrollSeconds += dt
            stretchSeconds += dt
            day.extend(.scroll, to: now, dt: dt)
        }

        if passes[site] != nil || passes[Self.allSites] != nil { return result }
        guard now.timeIntervalSince(scrollSince ?? now) >= Self.grace else { return result }

        let wait = Self.wait(base: settings.gateBaseSeconds, passesToday: day.passes.count)
        if state.session != nil {
            result.action = .gate(kind: .session, site: site, wait: wait)
        } else if settings.isNight(now, calendar: calendar) {
            result.action = .gate(kind: .night, site: site, wait: wait)
        } else if day.scrollSeconds >= Double(settings.scrollBudgetMinutes) * 60 {
            result.action = .gate(kind: .budget, site: site, wait: wait)
        } else if settings.checkInMinutes > 0 {
            let due = nextCheckIn ?? Double(settings.checkInMinutes) * 60
            if stretchSeconds >= due {
                result.action = .gate(kind: .checkIn, site: site, wait: 5)
            }
        }
        return result
    }

    private mutating func neutral(now: Date, dt: Double, state: inout AppState, day: inout DayLog) {
        scrollSince = nil
        if neutralSince == nil { neutralSince = now }
        if let since = neutralSince, now.timeIntervalSince(since) >= 60 {
            stretchSeconds = 0
            nextCheckIn = nil
        }
        guard state.session != nil else { return }
        state.session!.focusSeconds += dt
        day.focusSeconds += dt
        day.extend(.focus, to: now, dt: dt)
        if let i = state.tasks.firstIndex(where: { $0.id == state.session!.taskID }) {
            state.tasks[i].focusSeconds += dt
        }
    }

    public static func wait(base: Int, passesToday: Int) -> Int {
        let doubled = Double(max(base, 1)) * pow(2, Double(min(passesToday, 10)))
        return Int(min(Double(maxWait), doubled))
    }

    // MARK: Resolutions

    /// The user chose to go back to work.
    public mutating func pulledBack(now: Date, state: inout AppState) {
        mutateDay(now, &state) { $0.pulledBack += 1 }
        state.session?.pulledBack += 1
        scrollSince = nil
        stretchSeconds = 0
        nextCheckIn = nil
    }

    /// The user waited out the gate, typed a reason and went through.
    public mutating func grantPass(site: String, reason: String, kind: GateKind, wholeSession: Bool, now: Date, state: inout AppState) {
        let record = PassRecord(id: UUID(), at: now, site: site, reason: reason, kind: kind, wholeSession: wholeSession)
        mutateDay(now, &state) { $0.passes.append(record) }
        if wholeSession, state.session != nil {
            if !state.session!.allowedSites.contains(site) { state.session!.allowedSites.append(site) }
        } else {
            // In a session the pass is for that one site; otherwise it lifts the budget or night gate everywhere.
            let scope = kind == .session ? site : Self.allSites
            passes[scope] = now.addingTimeInterval(Double(state.settings.passMinutes) * 60)
        }
        scrollSince = nil
    }

    /// "Keep scrolling" on a check-in: no pass recorded, the next check-in is one interval away.
    public mutating func snoozeCheckIn(state: AppState) {
        nextCheckIn = stretchSeconds + Double(max(state.settings.checkInMinutes, 1)) * 60
    }

    public mutating func recordWall(now: Date, state: inout AppState) {
        mutateDay(now, &state) { $0.walls += 1 }
    }

    public mutating func recordUrgeSurfed(now: Date, state: inout AppState) {
        mutateDay(now, &state) { $0.urgesSurfed += 1 }
    }

    public mutating func sessionChanged() {
        scrollSince = nil
        untetheredActive = 0
    }

    public func hasPass(for site: String, now: Date) -> Bool {
        [site, Self.allSites].contains { (passes[$0] ?? .distantPast) > now }
    }

    private func mutateDay(_ now: Date, _ state: inout AppState, _ body: (inout DayLog) -> Void) {
        let key = DayKey.key(for: now, calendar: calendar)
        var day = state.days[key] ?? DayLog()
        body(&day)
        state.days[key] = day
    }
}
