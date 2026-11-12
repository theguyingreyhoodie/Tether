import AppKit
import Observation
import ServiceManagement
import TetherCore

struct GateRequest: Identifiable, Equatable {
    enum Mode: Equatable {
        case drift(kind: GateKind, site: String, wait: Int)
        /// `caught` is true when the wall closed something, false when the user pressed the urge button.
        case urge(caught: Bool)
    }
    let id = UUID()
    var mode: Mode
    var startedAt = Date()
}

enum PillState: Equatable {
    case hidden
    case session
    case scrolling(site: String, left: Double)
    case nudge(minutes: Int)
    case finished(title: String, focus: Double, completed: Bool)
}

@MainActor
protocol AppUI: AnyObject {
    func present(gate: GateRequest)
    func dismissGate()
    func openCommandBar()
    func refreshChrome()
    func closePopover()
}

@MainActor
@Observable
final class AppModel {
    var state: AppState
    var now = Date()
    var verdict: Verdict = .neutral
    var gate: GateRequest?
    var browserAccess: [String: Access] = [:]
    var blockedBrowser: String?

    @ObservationIgnored weak var ui: AppUI?
    @ObservationIgnored let watcher = ContextWatcher()
    @ObservationIgnored private let store: Store
    @ObservationIgnored private var engine = DriftEngine()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick = Date()
    @ObservationIgnored private var dirtyTicks = 0
    @ObservationIgnored private var screenAway = false
    @ObservationIgnored private var gateContext = Context()
    @ObservationIgnored private var gateApp: NSRunningApplication?
    @ObservationIgnored private var gateSite = ""

    var nudge: (minutes: Int, until: Date)?
    var finished: (title: String, focus: Double, completed: Bool, until: Date)?

    init(store: Store = Store()) {
        self.store = store
        state = store.load()
        state.prune(now: Date())
        // A session left over from a previous day is not one anybody is still in.
        if let s = state.session, Date().timeIntervalSince(s.startedAt) > 12 * 3600 {
            endSession(completed: false, announce: false)
        }
    }

    var settings: Settings { state.settings }
    var today: DayLog { state.day(now) }
    var session: FocusSession? { state.session }
    var budgetLeft: Double { max(0, Double(settings.scrollBudgetMinutes) * 60 - today.scrollSeconds) }

    var pill: PillState {
        if let f = finished, f.until > now { return .finished(title: f.title, focus: f.focus, completed: f.completed) }
        if state.session != nil { return .session }
        if case .scroll(let site) = verdict, gate == nil { return .scrolling(site: site, left: budgetLeft) }
        if let n = nudge, n.until > now { return .nudge(minutes: n.minutes) }
        return .hidden
    }

    // MARK: Clock

    /// `ignoreLock` is for the UI smoke test, which runs behind the lock screen.
    func startTicking(ignoreLock: Bool = false) {
        if timer == nil { observeScreen() }
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Launched at login behind the lock screen: nothing is being looked at yet.
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        screenAway = !ignoreLock && (session?["CGSSessionScreenIsLocked"] as? Bool) == true
        lastTick = Date()
        tick()
    }

    private func observeScreen() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAway(true) }
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAway(false) }
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAway(true) }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setAway(false) }
        }
    }

    private func setAway(_ away: Bool) {
        screenAway = away
        lastTick = Date()
        if away { save() }
    }

    func tick() {
        let current = Date()
        let dt = min(max(current.timeIntervalSince(lastTick), 0), 2.5)
        lastTick = current
        now = current
        guard !screenAway, state.settings.onboarded else { return }

        if let off = state.settings.adultWallDisableAt, current >= off {
            state.settings.adultWall = false
            state.settings.adultWallDisableAt = nil
        }

        watcher.refresh()
        let ctx = watcher.context
        let v = Classifier.classify(ctx, settings: state.settings)
        if v != verdict { verdict = v }
        if watcher.blockedBrowser != blockedBrowser { blockedBrowser = watcher.blockedBrowser }

        // While a gate is up Tether itself is in front; the clock on the drift is stopped.
        if gate == nil {
            let result = engine.tick(now: current, dt: dt, verdict: v, idleSeconds: ContextWatcher.idleSeconds(), state: &state)
            handle(result, ctx: ctx)
        }

        if let s = state.session, s.isOvertime, !s.timeUpAnnounced {
            state.session?.timeUpAnnounced = true
            play("Glass")
        }

        dirtyTicks += 1
        if dirtyTicks >= 15 { save() }
        ui?.refreshChrome()
    }

    private func handle(_ result: TickResult, ctx: Context) {
        if let minutes = result.nudgeMinutes {
            nudge = (minutes, now.addingTimeInterval(45))
        }
        switch result.action {
        case .none:
            break
        case .wall(let site):
            // Close first, talk second.
            watcher.dismiss(ctx, app: watcher.frontApp, host: site, closeTab: true)
            engine.recordWall(now: now, state: &state)
            gateContext = ctx
            gateApp = watcher.frontApp
            gateSite = site
            show(GateRequest(mode: .urge(caught: true)))
        case .gate(let kind, let site, let wait):
            gateContext = ctx
            gateApp = watcher.frontApp
            gateSite = site
            show(GateRequest(mode: .drift(kind: kind, site: site, wait: wait)))
        }
    }

    private func show(_ request: GateRequest) {
        gate = request
        nudge = nil
        ui?.closePopover()
        ui?.present(gate: request)
        save()
    }

    private func closeGate(reactivate: Bool) {
        gate = nil
        ui?.dismissGate()
        if reactivate, let app = gateApp, !app.isTerminated, !app.isHidden {
            app.activate()
        }
        lastTick = Date()
        save()
    }

    // MARK: Gate resolutions

    /// "Back to it": the page goes away and the pull-back is counted.
    func backToIt() {
        guard gate != nil else { return }
        engine.pulledBack(now: now, state: &state)
        watcher.dismiss(gateContext, app: gateApp, host: gateSite, closeTab: settings.closeTabOnReturn)
        closeGate(reactivate: true)
    }

    func letThrough(reason: String, wholeSession: Bool) {
        guard case .drift(let kind, let site, _)? = gate?.mode else { return }
        engine.grantPass(site: site, reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
                         kind: kind, wholeSession: wholeSession, now: now, state: &state)
        closeGate(reactivate: true)
    }

    func keepScrolling() {
        engine.snoozeCheckIn(state: state)
        closeGate(reactivate: true)
    }

    /// Leaves the gate and goes straight to picking a task.
    func leaveGateForTask() {
        if case .drift? = gate?.mode {
            engine.pulledBack(now: now, state: &state)
            watcher.dismiss(gateContext, app: gateApp, host: gateSite, closeTab: settings.closeTabOnReturn)
        }
        closeGate(reactivate: false)
        ui?.openCommandBar()
    }

    func urgeButton() {
        guard gate == nil else { return }
        engine.recordUrgeSurfed(now: now, state: &state)
        gateApp = watcher.frontApp
        show(GateRequest(mode: .urge(caught: false)))
    }

    func urgeDone() {
        let tethered = state.session != nil
        closeGate(reactivate: tethered)
        if !tethered { ui?.openCommandBar() }
    }

    func lockAndWalk() {
        closeGate(reactivate: false)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }

    // MARK: Sessions

    /// Tethers to a task. An existing open task with the same title is reused instead of duplicated.
    func start(title: String, firstStep: String? = nil, minutes: Int? = nil, taskID: UUID? = nil) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty || taskID != nil else { return }
        if state.session != nil { endSession(completed: false, announce: false) }

        let step = firstStep?.trimmingCharacters(in: .whitespacesAndNewlines)
        var task: TaskItem
        if let i = state.tasks.firstIndex(where: { $0.id == taskID || (!$0.isDone && $0.title.caseInsensitiveCompare(clean) == .orderedSame) }) {
            if let step, !step.isEmpty { state.tasks[i].firstStep = step }
            task = state.tasks[i]
        } else {
            task = TaskItem(title: clean, firstStep: (step?.isEmpty ?? true) ? nil : step, createdAt: now)
            state.tasks.insert(task, at: 0)
        }
        state.session = FocusSession(taskID: task.id, title: task.title, firstStep: task.firstStep,
                                     minutes: minutes ?? settings.defaultSessionMinutes, now: now)
        engine.sessionChanged()
        nudge = nil
        finished = nil
        play("Tink")
        save()
        ui?.refreshChrome()
    }

    func endSession(completed: Bool, announce: Bool = true) {
        guard let s = state.session else { return }
        let key = DayKey.key(for: now)
        var day = state.days[key] ?? DayLog()
        day.sessions.append(SessionRecord(id: s.id, title: s.title, startedAt: s.startedAt, endedAt: now,
                                          focusSeconds: s.focusSeconds, completed: completed))
        state.days[key] = day
        if completed, let i = state.tasks.firstIndex(where: { $0.id == s.taskID }) {
            state.tasks[i].doneAt = now
        }
        state.session = nil
        engine.sessionChanged()
        if announce {
            finished = (s.title, s.focusSeconds, completed, now.addingTimeInterval(6))
            if completed { play("Hero") }
        }
        save()
        ui?.refreshChrome()
    }

    func extend(minutes: Int) {
        guard let s = state.session else { return }
        // From overtime, "ten more" means ten from now, not ten from the old deadline.
        let base = max(s.plannedSeconds, s.elapsedSeconds)
        state.session?.plannedSeconds = base + Double(minutes) * 60
        state.session?.timeUpAnnounced = false
        save()
        ui?.refreshChrome()
    }

    // MARK: Tasks

    func addTask(_ title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        state.tasks.insert(TaskItem(title: clean, createdAt: now), at: 0)
        save()
    }

    func toggleDone(_ id: UUID) {
        guard let i = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        if state.tasks[i].isDone {
            state.tasks[i].doneAt = nil
        } else if state.session?.taskID == id {
            endSession(completed: true)
        } else {
            state.tasks[i].doneAt = now
        }
        save()
    }

    func deleteTask(_ id: UUID) {
        if state.session?.taskID == id { endSession(completed: false, announce: false) }
        state.tasks.removeAll { $0.id == id }
        save()
    }

    // MARK: Settings

    func update(_ change: (inout Settings) -> Void) {
        change(&state.settings)
        save()
        ui?.refreshChrome()
    }

    /// Raising the wall is instant. Lowering it takes ten minutes, on purpose.
    func setAdultWall(_ on: Bool) {
        update { s in
            if on {
                s.adultWall = true
                s.adultWallDisableAt = nil
            } else if s.adultWall, s.adultWallDisableAt == nil {
                s.adultWallDisableAt = Date().addingTimeInterval(Settings.wallDisableDelay)
            }
        }
    }

    func setPillOrigin(_ point: CGPoint) {
        state.pillX = point.x
        state.pillY = point.y
        dirtyTicks = 10
    }

    func save() {
        dirtyTicks = 0
        store.save(state)
    }

    // MARK: Permissions

    func refreshAccess() {
        let bridge = watcher.bridge
        let ids = Browsers.installed().filter { $0.kind != .opaque }.map(\.bundleID)
        bridge.perform { [weak self] in
            let result = Dictionary(uniqueKeysWithValues: ids.map { ($0, bridge.access($0)) })
            DispatchQueue.main.async { self?.browserAccess = result }
        }
    }

    /// Asks macOS for permission to read this browser's front tab. Launches it first if needed.
    func connect(_ browser: Browsers.Installed) {
        let bridge = watcher.bridge
        let ask = { [weak self] in
            bridge.perform {
                let result = bridge.access(browser.bundleID, ask: true)
                DispatchQueue.main.async {
                    self?.browserAccess[browser.bundleID] = result
                    if result == .denied {
                        // Already refused once; macOS won't ask again, so open the pane where it can be flipped.
                        let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
                    }
                }
            }
        }
        if NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID).isEmpty {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: browser.url, configuration: config) { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { ask() }
            }
        } else {
            ask()
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Tether: launch at login failed: %@", "\(error)")
            }
        }
    }

    private func play(_ name: String) {
        guard settings.sounds else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
