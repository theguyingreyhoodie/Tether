import AppKit
import SwiftUI
import TetherCore

/// Developer entry points, reached with launch arguments instead of the normal app:
///   Tether --selftest             drives the real model through a session with a faked front tab
///   Tether --snapshots <folder>   renders every screen to PNG without showing anything
///   Tether --uitest               opens every real window once and reports its geometry
///   Tether --livetest <folder>    drives the real windows with real key events on the live display
///                                 and saves a picture of each step (its own windows over the wallpaper)
/// All use a throwaway store and never touch real data, browsers or sound.
@MainActor
enum DevTools {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--uitest") {
            uiTest()
            return true
        }
        if let i = args.firstIndex(of: "--livetest"), args.indices.contains(i + 1) {
            liveTest(to: URL(fileURLWithPath: args[i + 1], isDirectory: true))
            return true
        }
        if args.contains("--selftest") {
            exit(selfTest() ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--snapshots"), args.indices.contains(i + 1) {
            snapshots(to: URL(fileURLWithPath: args[i + 1], isDirectory: true))
            exit(0)
        }
        return false
    }

    private static func scratchModel() -> AppModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-dev-\(UUID().uuidString)")
        let model = AppModel(store: Store(directory: dir))
        model.state.settings.sounds = false
        model.state.settings.onboarded = true
        model.state.settings.nudges = false
        return model
    }

    // MARK: Self-test

    private final class StubUI: AppUI {
        var gates: [GateRequest] = []
        var dismissed = 0
        var barOpened = 0
        func present(gate: GateRequest) { gates.append(gate) }
        func dismissGate() { dismissed += 1 }
        func openCommandBar() { barOpened += 1 }
        func refreshChrome() {}
        func closePopover() {}
    }

    private static func selfTest() -> Bool {
        let model = scratchModel()
        let ui = StubUI()
        model.ui = ui
        // Daytime behaviour is what's under test, whatever the clock says right now.
        model.state.settings.nightGuard = false
        var failures = 0

        func check(_ ok: Bool, _ what: String) {
            print(ok ? "  ok    \(what)" : "  FAIL  \(what)")
            if !ok { failures += 1 }
        }
        func front(_ url: String?, seconds: Int) {
            model.watcher.override = Context(appName: "Browser", isBrowser: true, url: url)
            for _ in 0..<seconds {
                model.tick()
                RunLoop.current.run(until: Date().addingTimeInterval(1))
            }
            model.tick()
        }

        print("Tethered")
        model.start(title: "Write intro", firstStep: "one ugly sentence", minutes: 25)
        check(model.session?.title == "Write intro" && model.state.tasks.count == 1, "starting a session creates the task")
        front("https://github.com/", seconds: 2)
        check(ui.gates.isEmpty && model.today.focusSeconds > 1, "neutral page: no gate, focus time accrues")

        front("https://www.reddit.com/r/swift", seconds: 5)
        check(ui.gates.last?.mode == .drift(kind: .session, site: "reddit.com", wait: 10), "scroll site brings up the session gate")
        check(model.pill == .session, "pill still shows the session")
        model.backToIt()
        check(model.gate == nil && ui.dismissed == 1 && model.today.pulledBack == 1, "back to it: gate down, pull-back counted")

        front("https://www.reddit.com/r/swift", seconds: 5)
        check(ui.gates.count == 2, "going straight back to the site gates again")
        model.letThrough(reason: "need the thread on actors", wholeSession: false)
        front("https://www.reddit.com/r/swift", seconds: 5)
        check(ui.gates.count == 2 && model.today.passes.first?.reason == "need the thread on actors", "pass holds and the reason is in the ledger")

        front("https://www.pornhub.com/", seconds: 1)
        check(ui.gates.last?.mode == .urge(caught: true) && model.today.walls == 1, "adult site: wall, no grace period")
        model.urgeDone()
        check(model.gate == nil && ui.barOpened == 0, "leaving the wall while tethered returns to work")

        front("https://github.com/", seconds: 1)
        model.extend(minutes: 10)
        check(model.session?.plannedSeconds == 35 * 60, "extend adds ten minutes")
        model.endSession(completed: true)
        check(model.session == nil && model.state.tasks.first?.isDone == true && model.today.sessions.count == 1,
              "done: task ticked off, session in the ledger")
        if case .finished = model.pill {} else { check(false, "pill announces the finished session") }

        print("Untethered")
        model.update { $0.scrollBudgetMinutes = 0 }
        front("https://www.instagram.com/reels/", seconds: 5)
        check(ui.gates.last?.mode == .drift(kind: .budget, site: "instagram.com", wait: 20), "over budget: gate, wait doubled by the earlier pass")
        model.leaveGateForTask()
        check(model.gate == nil && ui.barOpened == 1, "“pick one thing” opens the command bar")

        model.update { $0.scrollBudgetMinutes = 30 }
        model.finished = nil
        front("https://x.com/home", seconds: 1)
        if case .scrolling(let site, let left) = model.pill {
            check(site == "x.com" && left > 0, "inside budget: pill shows the scroll meter")
        } else {
            check(false, "inside budget: pill shows the scroll meter")
        }

        model.urgeButton()
        check(ui.gates.last?.mode == .urge(caught: false) && model.today.urgesSurfed == 1, "urge button opens the surf")
        model.urgeDone()
        check(ui.barOpened == 2, "leaving the surf untethered offers a task")

        print("Wall switch")
        model.setAdultWall(false)
        check(model.settings.isWallUp(Date()) && model.settings.adultWallDisableAt != nil, "switching the wall off is delayed")
        model.setAdultWall(true)
        check(model.settings.adultWallDisableAt == nil, "and can be cancelled")

        print(failures == 0 ? "Self-test passed." : "Self-test: \(failures) failure(s).")
        return failures == 0
    }

    // MARK: UI smoke test

    private static var smokeDelegate: AppDelegate?

    /// Runs the real app shell against a scratch store and walks through every window it can open.
    private static func uiTest() {
        let model = scratchModel()
        model.state.settings.nightGuard = false
        let delegate = AppDelegate(model: model)
        smokeDelegate = delegate
        NSApp.delegate = delegate

        func report(_ label: String) {
            print("— \(label)")
            for w in NSApp.windows where w.isVisible {
                let f = w.frame
                print("    \(type(of: w))  \(Int(f.width))×\(Int(f.height)) at (\(Int(f.minX)), \(Int(f.minY)))  level \(w.level.rawValue)\(w.isKeyWindow ? "  key" : "")")
            }
        }
        var steps: [(Double, () -> Void)] = [
            (1.0, { report("launched") }),
            (0.2, { delegate.openCommandBar() }),
            (0.8, {
                report("command bar open")
                let responder = NSApp.windows.first { $0 is KeyPanel }?.firstResponder
                print("    first responder: \(responder.map { String(describing: type(of: $0)) } ?? "none")")
            }),
            (0.2, { model.start(title: "Write the results section", firstStep: "paste the table", minutes: 25) }),
            (1.5, { report("tethered (pill up, bar closed)") }),
            (0.1, { model.watcher.override = Context(appName: "Browser", isBrowser: true, url: "https://www.reddit.com/") }),
            (5.5, { report("drifted to reddit.com → gate: \(String(describing: model.gate?.mode))") }),
            (0.2, { model.backToIt() }),
            (0.8, { report("back to it (pulled back \(model.today.pulledBack)×)") }),
            (0.1, { model.watcher.override = Context(appName: "Editor") }),
            (0.2, { model.urgeButton() }),
            (1.0, { report("urge button → \(String(describing: model.gate?.mode))") }),
            (0.2, { model.urgeDone() }),
            (0.6, { delegate.showSettings() }),
            (1.0, { report("settings") }),
            (0.2, { model.endSession(completed: true) }),
            (1.2, { report("session done") }),
            (0.1, {
                print("UI smoke test finished without a crash.")
                exit(0)
            }),
        ]
        func next() {
            guard !steps.isEmpty else { return }
            let (delay, step) = steps.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                step()
                next()
            }
        }
        DispatchQueue.main.async {
            // The delegate starts the clock in applicationDidFinishLaunching; restart it lock-blind.
            model.startTicking(ignoreLock: true)
            next()
        }
        NSApp.run()
    }

    // MARK: Live display test

    /// A picture of the screen as the window server composites it. Without the Screen Recording
    /// permission this holds only our own windows over the wallpaper, which is exactly what's wanted.
    private static func capture(_ name: String, to dir: URL) {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else {
            print("    capture: API missing")
            return
        }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // on-screen windows only, at full resolution
        guard let image = create(.infinite, 1, 0, 0)?.takeRetainedValue() else {
            print("    capture: nothing returned")
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
    }

    private static func liveTest(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = scratchModel()
        model.state.settings.nightGuard = false
        model.watcher.override = Context(appName: "Editor")
        let delegate = AppDelegate(model: model)
        smokeDelegate = delegate
        NSApp.delegate = delegate
        var failures = 0

        func check(_ ok: Bool, _ what: String) {
            print(ok ? "  ok    \(what)" : "  FAIL  \(what)")
            if !ok { failures += 1 }
        }
        func shot(_ name: String) {
            capture(name, to: dir)
            let visible = NSApp.windows.filter(\.isVisible).map { w in
                "\(type(of: w)) \(Int(w.frame.width))×\(Int(w.frame.height))@\(w.level.rawValue)\(w.isKeyWindow ? "*" : "")"
            }
            print("— \(name): \(visible.joined(separator: ", "))")
        }
        func typeText(_ text: String) {
            guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else {
                check(false, "a text field has the keyboard (wanted to type “\(text)”)")
                return
            }
            editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        func press(_ code: UInt16, _ chars: String) {
            guard let w = NSApp.keyWindow else {
                check(false, "a window is key (wanted to press key \(code))")
                return
            }
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: w.windowNumber, context: nil, characters: chars,
                                            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                    NSApp.sendEvent(e)
                }
            }
        }
        let ret: (UInt16, String) = (36, "\r")
        let esc: (UInt16, String) = (53, "\u{1b}")
        func barOpen() -> Bool { NSApp.windows.contains { $0 is KeyPanel && $0.isVisible } }
        func gateWindows() -> Int { NSApp.windows.filter { $0.isVisible && $0.level == .screenSaver }.count }

        var steps: [(Double, () -> Void)] = [
            (1.2, { shot("01-launched") }),
            (0.2, { delegate.openCommandBar() }),
            (1.0, { shot("02-bar-empty"); check(NSApp.keyWindow is KeyPanel, "command bar is the key window") }),
            (0.1, { typeText("finish viva slides 45m") }),
            (0.6, { shot("03-bar-typed") }),
            (0.1, { press(ret.0, ret.1) }),
            (0.8, { shot("04-bar-step"); check(barOpen() && model.session == nil, "Return moves to the first-move question") }),
            (0.1, { typeText("open the deck and fix slide 3") }),
            (0.5, { shot("05-bar-step-typed") }),
            (0.1, { press(ret.0, ret.1) }),
            (1.5, {
                shot("06-tethered-pill")
                check(model.session?.title == "finish viva slides" && model.session?.plannedSeconds == 45 * 60, "Return starts the session with the parsed length")
                check(model.session?.firstStep == "open the deck and fix slide 3", "first move saved")
                check(!barOpen(), "command bar closed itself")
            }),
            (0.1, { model.watcher.override = Context(appName: "Browser", isBrowser: true, url: "https://www.reddit.com/") }),
            (5.5, { shot("07-gate-waiting"); check(gateWindows() == NSScreen.screens.count, "gate covers every screen") }),
            (9.0, { shot("08-gate-open") }),
            (0.1, { press(esc.0, esc.1) }),
            (0.8, {
                shot("09-after-esc")
                check(model.gate == nil && gateWindows() == 0 && model.today.pulledBack == 1, "Esc at the gate: back to it, windows gone")
            }),
            (0.1, { model.watcher.override = Context(appName: "Browser", isBrowser: true, url: "https://www.reddit.com/") }),
            (5.5, { check(gateWindows() > 0, "gate comes back on the second drift") }),
            (0.1, { press(ret.0, ret.1) }),
            (0.8, { check(model.gate == nil && gateWindows() == 0 && model.today.pulledBack == 2, "Return at the gate: back to it") }),
            (0.1, { model.watcher.override = Context(appName: "Editor") }),
            (0.2, { model.urgeButton() }),
            (2.5, { shot("10-urge") }),
            (14.5, { shot("11-urge-buttons") }),
            (0.2, { model.urgeDone() }),
            (0.6, { check(gateWindows() == 0, "urge screen gone") }),
            (0.2, { delegate.openCommandBar() }),
            (1.0, { shot("12-bar-tethered") }),
            (0.1, { press(esc.0, esc.1) }),
            (0.6, { check(!barOpen(), "Esc closes the command bar") }),
            (0.2, { delegate.perform(Selector(("togglePopover"))) }),
            (1.5, { shot("13-popover-tethered") }),
            (0.2, { delegate.closePopover() }),
            (0.6, { delegate.showSettings() }),
            (1.2, { shot("14-settings") }),
            (0.2, { NSApp.windows.filter { $0.title == "Tether Settings" }.forEach { $0.close() } }),
            (0.2, { model.endSession(completed: true) }),
            (1.2, { shot("15-pill-finished") }),
            (0.1, {
                model.finished = nil
                model.watcher.override = Context(appName: "Browser", isBrowser: true, url: "https://x.com/home")
            }),
            (2.5, { shot("16-pill-scrolling") }),
            (0.2, { delegate.perform(Selector(("togglePopover"))) }),
            (1.5, { shot("17-popover-untethered") }),
            (0.1, {
                print(failures == 0 ? "Live test passed." : "Live test: \(failures) failure(s).")
                exit(failures == 0 ? 0 : 1)
            }),
        ]
        func next() {
            guard !steps.isEmpty else { return }
            let (delay, step) = steps.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                step()
                next()
            }
        }
        DispatchQueue.main.async {
            model.startTicking(ignoreLock: true)
            next()
        }
        NSApp.run()
    }

    // MARK: Snapshots

    private static func snapshots(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        let dayStart = DayKey.start(for: now)

        func sample(tethered: Bool) -> AppModel {
            let model = scratchModel()
            model.now = now
            var tasks = [
                TaskItem(title: "Finish viva slides", firstStep: "Open the deck and fix slide 3"),
                TaskItem(title: "Email the project guide about the review date"),
                TaskItem(title: "Write the results section"),
            ]
            tasks[2].focusSeconds = 41 * 60
            var done = TaskItem(title: "Push the README")
            done.doneAt = now
            tasks.append(done)
            model.state.tasks = tasks

            var day = DayLog()
            day.focusSeconds = 130 * 60
            day.scrollSeconds = 22 * 60
            day.pulledBack = 6
            day.walls = 1
            day.urgesSurfed = 2
            day.passes = [PassRecord(id: UUID(), at: now.addingTimeInterval(-3600), site: "reddit.com",
                                     reason: "the thread about actor reentrancy", kind: .session, wholeSession: false)]
            for (from, to, kind) in [(5.5, 6.4, SegmentKind.focus), (6.5, 6.7, .scroll), (7.0, 8.1, .focus), (9.2, 9.4, .scroll)] {
                day.segments.append(Segment(start: dayStart.addingTimeInterval(from * 3600),
                                            end: dayStart.addingTimeInterval(to * 3600), kind: kind))
            }
            model.state.days[DayKey.key(for: now)] = day
            for (back, minutes) in [(1, 95.0), (2, 20), (3, 160), (4, 0), (5, 75), (6, 110)] {
                var past = DayLog()
                past.focusSeconds = minutes * 60
                model.state.days[DayKey.key(for: now.addingTimeInterval(-Double(back) * 86400))] = past
            }
            if tethered {
                var s = FocusSession(taskID: tasks[0].id, title: tasks[0].title, firstStep: tasks[0].firstStep, minutes: 45, now: now)
                s.elapsedSeconds = 17 * 60 + 12
                s.focusSeconds = s.elapsedSeconds
                model.state.session = s
            }
            return model
        }

        func snap(_ name: String, model: AppModel, dark: Bool, size: NSSize? = nil, _ view: some View) {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let root = view
                .environment(model)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.flatSurfaces, true)
            let host = NSHostingView(rootView: root)
            host.appearance = appearance
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.contentView = host
            let fit = size ?? host.fittingSize
            window.setContentSize(fit)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            let file = dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
            print("wrote \(file.lastPathComponent)  \(Int(fit.width))×\(Int(fit.height))")
        }

        let screen = NSSize(width: 1280, height: 800)
        for dark in [false, true] {
            snap("menu-untethered", model: sample(tethered: false), dark: dark, MenuView(openSettings: {}, quit: {}))
            snap("menu-tethered", model: sample(tethered: true), dark: dark, MenuView(openSettings: {}, quit: {}))
            snap("bar-new", model: sample(tethered: false), dark: dark, size: NSSize(width: 680, height: 420),
                 CommandBarView(text: "results 45m", close: {}))
            snap("bar-tethered", model: sample(tethered: true), dark: dark, size: NSSize(width: 680, height: 420),
                 CommandBarView(close: {}))
            snap("bar-step", model: sample(tethered: false), dark: dark, size: NSSize(width: 680, height: 300),
                 CommandBarView(text: "Draft the literature review 1h", stage: .step, close: {}))
            snap("settings", model: sample(tethered: false), dark: dark, SettingsView())
            snap("onboarding", model: sample(tethered: false), dark: dark, OnboardingView(finish: { _ in }))

            let pills: [(String, (AppModel) -> Void, Bool)] = [
                ("pill-session", { _ in }, true),
                ("pill-overtime", { $0.state.session?.elapsedSeconds = 48 * 60 }, true),
                ("pill-scrolling", { $0.verdict = .scroll(site: "reddit.com") }, false),
                ("pill-nudge", { $0.nudge = (15, now.addingTimeInterval(600)) }, false),
                ("pill-finished", { $0.finished = ("Finish viva slides", 44 * 60, true, now.addingTimeInterval(600)) }, false),
            ]
            for (name, configure, tethered) in pills {
                let model = sample(tethered: tethered)
                configure(model)
                snap(name, model: model, dark: dark, size: NSSize(width: 520, height: 64), PillView())
            }
        }

        // Gates are always dark.
        let gates: [(String, GateRequest.Mode, Double, Bool)] = [
            ("gate-session-waiting", .drift(kind: .session, site: "instagram.com", wait: 10), 3, true),
            ("gate-session-open", .drift(kind: .session, site: "instagram.com", wait: 10), 60, true),
            ("gate-budget-open", .drift(kind: .budget, site: "reddit.com", wait: 10), 60, false),
            ("gate-night-waiting", .drift(kind: .night, site: "x.com", wait: 20), 4, false),
            ("gate-checkin-open", .drift(kind: .checkIn, site: "youtube.com", wait: 5), 30, false),
            ("urge-caught", .urge(caught: true), 22, false),
            ("urge-crested", .urge(caught: false), 95, true),
        ]
        for (name, mode, age, tethered) in gates {
            let model = sample(tethered: tethered)
            if case .drift(.budget, _, _) = mode { model.state.settings.scrollBudgetMinutes = 20 }
            let request = GateRequest(mode: mode, startedAt: Date().addingTimeInterval(-age))
            model.gate = request
            snap(name, model: model, dark: true, size: screen, GateView(request: request))
        }
    }
}
