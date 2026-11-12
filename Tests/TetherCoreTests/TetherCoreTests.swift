import XCTest
@testable import TetherCore

final class ClassifierTests: XCTestCase {
    let settings = Settings()

    func verdict(_ url: String) -> Verdict {
        Classifier.classify(Context(appName: "Safari", isBrowser: true, url: url), settings: settings)
    }

    func testScrollSites() {
        XCTAssertEqual(verdict("https://www.instagram.com/reels/abc"), .scroll(site: "instagram.com"))
        XCTAssertEqual(verdict("https://old.reddit.com/r/swift"), .scroll(site: "reddit.com"))
        XCTAssertEqual(verdict("https://m.youtube.com/shorts/xyz"), .scroll(site: "youtube.com"))
        XCTAssertEqual(verdict("https://x.com/home"), .scroll(site: "x.com"))
    }

    func testPathRulesOnlyCatchThatPath() {
        XCTAssertEqual(verdict("https://www.youtube.com/watch?v=lecture"), .neutral)
        XCTAssertEqual(verdict("https://www.youtube.com/shortsighted"), .neutral)
        XCTAssertEqual(verdict("https://www.linkedin.com/jobs/view/1"), .neutral)
        XCTAssertEqual(verdict("https://www.linkedin.com/feed/"), .scroll(site: "linkedin.com"))
    }

    func testNeutralPages() {
        XCTAssertEqual(verdict("https://github.com/apple/swift"), .neutral)
        XCTAssertEqual(verdict("https://notinstagram.com/"), .neutral)
        XCTAssertEqual(verdict("https://box.com/"), .neutral, "x.com must not match as a suffix of another host")
        XCTAssertEqual(verdict("chrome://newtab/"), .neutral)
        XCTAssertEqual(verdict("about:blank"), .neutral)
        XCTAssertEqual(verdict(""), .neutral)
    }

    func testAdultHosts() {
        XCTAssertEqual(verdict("https://www.pornhub.com/view_video.php?viewkey=1"), .adult(site: "pornhub.com"))
        XCTAssertEqual(verdict("https://de.xhamster.com/"), .adult(site: "de.xhamster.com"))
        XCTAssertEqual(verdict("https://beeg.com/"), .adult(site: "beeg.com"))
        XCTAssertEqual(verdict("https://www.reddit.com/r/gonewild/"), .adult(site: "reddit.com"))
        XCTAssertEqual(verdict("https://rule34.xxx/index.php"), .adult(site: "rule34.xxx"))
    }

    func testAdultKeywordsDoNotFireOnOrdinaryPages() {
        // Looking for help must never trip the wall.
        XCTAssertEqual(verdict("https://www.google.com/search?q=how+to+quit+porn"), .neutral)
        XCTAssertEqual(verdict("https://www.essex.ac.uk/"), .neutral)
        XCTAssertEqual(verdict("https://www.milfordct.gov/"), .neutral)
        XCTAssertEqual(verdict("https://en.wikipedia.org/wiki/Pornography_addiction"), .neutral)
        XCTAssertEqual(verdict("https://www.reddit.com/r/massachusetts/"), .scroll(site: "reddit.com"))
        XCTAssertEqual(verdict("https://www.reddit.com/r/classicalmusic/comments/1/nsfw_title"), .scroll(site: "reddit.com"))
    }

    func testExtraAdultSitesAndScrollApps() {
        var s = Settings()
        s.extraAdultSites = ["https://Example-Adult.com/"]
        s.scrollApps = ["com.hnc.Discord"]
        XCTAssertEqual(Classifier.classify(Context(isBrowser: true, url: "https://cdn.example-adult.com/x"), settings: s),
                       .adult(site: "cdn.example-adult.com"))
        XCTAssertEqual(Classifier.classify(Context(bundleID: "com.hnc.Discord", appName: "Discord"), settings: s),
                       .scroll(site: "Discord"))
        XCTAssertEqual(Classifier.classify(Context(bundleID: "com.apple.dt.Xcode", appName: "Xcode"), settings: s), .neutral)
    }

    func testTitleFallbackForUnscriptableBrowsers() {
        let firefox = Context(bundleID: "org.mozilla.firefox", appName: "Firefox", isBrowser: true, title: "Instagram — Mozilla Firefox")
        XCTAssertEqual(Classifier.classify(firefox, settings: settings), .scroll(site: "instagram.com"))
        let docs = Context(bundleID: "org.mozilla.firefox", appName: "Firefox", isBrowser: true, title: "Swift docs — Mozilla Firefox")
        XCTAssertEqual(Classifier.classify(docs, settings: settings), .neutral)
        // The same title in a non-browser app means nothing.
        let notes = Context(bundleID: "com.apple.Notes", appName: "Notes", title: "Instagram caption ideas")
        XCTAssertEqual(Classifier.classify(notes, settings: settings), .neutral)
    }
}

final class ParserTests: XCTestCase {
    func check(_ input: String, _ title: String, _ minutes: Int?, line: UInt = #line) {
        let r = TaskParser.parse(input)
        XCTAssertEqual(r.title, title, line: line)
        XCTAssertEqual(r.minutes, minutes, line: line)
    }

    func testDurations() {
        check("finish viva slides 45m", "finish viva slides", 45)
        check("read chapter 4 for 20 minutes", "read chapter 4", 20)
        check("deep work 1h30", "deep work", 90)
        check("deep work 1h 30m", "deep work", 90)
        check("write report 2h", "write report", 120)
        check("study 1.5 hours", "study", 90)
        check("  email prof  ", "email prof", nil)
        check("review chapter 4", "review chapter 4", nil)
        check("fix bug in v2m", "fix bug in v2m", nil)
        check("45m", "", 45)
        check("marathon 999m", "marathon", 480)
    }

    func testFormatting() {
        XCTAssertEqual(Fmt.clock(1394), "23:14")
        XCTAssertEqual(Fmt.clock(3729), "1:02:09")
        XCTAssertEqual(Fmt.span(7800), "2h 10m")
        XCTAssertEqual(Fmt.span(59), "0m")
        XCTAssertEqual(Fmt.minutesLeft(61), "2m")
        XCTAssertEqual(Fmt.minutesLeft(3600), "1h")
    }
}

final class EngineTests: XCTestCase {
    var engine = DriftEngine()
    var state = AppState()
    var now = Date(timeIntervalSince1970: 0)
    let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return c
    }()

    func at(_ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: hour, minute: minute))!
    }

    override func setUp() {
        engine = DriftEngine()
        engine.calendar = cal
        state = AppState()
        now = at(14)
    }

    /// Runs `seconds` one-second ticks and returns every non-idle action in order.
    @discardableResult
    func run(_ seconds: Int, _ verdict: Verdict, idle: Double = 0) -> [EngineAction] {
        var actions: [EngineAction] = []
        for _ in 0..<seconds {
            now = now.addingTimeInterval(1)
            let r = engine.tick(now: now, dt: 1, verdict: verdict, idleSeconds: idle, state: &state)
            if r.action != .none { actions.append(r.action) }
        }
        return actions
    }

    func startSession(minutes: Int = 25) {
        let task = TaskItem(title: "Write intro")
        state.tasks.append(task)
        state.session = FocusSession(taskID: task.id, title: task.title, firstStep: nil, minutes: minutes, now: now)
        engine.sessionChanged()
    }

    var day: DayLog { state.days[DayKey.key(for: now, calendar: cal)] ?? DayLog() }

    func testSessionGatesScrollSiteAfterGrace() {
        startSession()
        XCTAssertEqual(run(3, .scroll(site: "reddit.com")), [], "inside the grace period")
        XCTAssertEqual(run(1, .scroll(site: "reddit.com")), [.gate(kind: .session, site: "reddit.com", wait: 10)])
    }

    func testFlickingThroughATabDoesNotGate() {
        startSession()
        for _ in 0..<5 {
            XCTAssertEqual(run(2, .scroll(site: "reddit.com")), [])
            XCTAssertEqual(run(2, .neutral), [])
        }
    }

    func testFocusAndScrollAreAccountedSeparately() {
        startSession()
        run(120, .neutral)
        run(2, .scroll(site: "x.com"))
        XCTAssertEqual(day.focusSeconds, 120)
        XCTAssertEqual(day.scrollSeconds, 2)
        XCTAssertEqual(state.session?.elapsedSeconds, 122)
        XCTAssertEqual(state.session?.focusSeconds, 120)
        XCTAssertEqual(state.tasks[0].focusSeconds, 120)
        XCTAssertEqual(day.segments.map(\.kind), [.focus, .scroll])
    }

    func testPassLetsOneSiteThroughAndEscalatesTheNextWait() {
        startSession()
        run(4, .scroll(site: "reddit.com"))
        engine.grantPass(site: "reddit.com", reason: "checking a thread for the task", kind: .session, wholeSession: false, now: now, state: &state)
        XCTAssertEqual(run(200, .scroll(site: "reddit.com")), [], "pass is good for five minutes")
        // A different site is not covered, and the wait has doubled.
        XCTAssertEqual(run(4, .scroll(site: "x.com")).first, .gate(kind: .session, site: "x.com", wait: 20))
        run(5, .neutral)
        // Pass expires.
        run(120, .neutral)
        XCTAssertEqual(run(4, .scroll(site: "reddit.com")).first, .gate(kind: .session, site: "reddit.com", wait: 20))
        XCTAssertEqual(day.passes.count, 1)
        XCTAssertEqual(day.passes[0].reason, "checking a thread for the task")
    }

    func testSiteAllowedForSessionCountsAsFocus() {
        startSession()
        run(4, .scroll(site: "youtube.com"))
        let before = day.scrollSeconds
        engine.grantPass(site: "youtube.com", reason: "lecture video", kind: .session, wholeSession: true, now: now, state: &state)
        XCTAssertEqual(run(600, .scroll(site: "youtube.com")), [])
        XCTAssertEqual(day.scrollSeconds, before)
        XCTAssertEqual(day.focusSeconds, 600)
        // Gone once the session is.
        state.session = nil
        engine.sessionChanged()
        state.settings.scrollBudgetMinutes = 0
        XCTAssertEqual(run(4, .scroll(site: "youtube.com")).first, .gate(kind: .budget, site: "youtube.com", wait: 20))
    }

    func testWaitEscalationIsCapped() {
        XCTAssertEqual(DriftEngine.wait(base: 10, passesToday: 0), 10)
        XCTAssertEqual(DriftEngine.wait(base: 10, passesToday: 2), 40)
        XCTAssertEqual(DriftEngine.wait(base: 10, passesToday: 9), 120)
        XCTAssertEqual(DriftEngine.wait(base: 10, passesToday: 500), 120)
    }

    func testUntetheredBudgetAndCheckIn() {
        state.settings.scrollBudgetMinutes = 15
        state.settings.checkInMinutes = 10
        XCTAssertEqual(run(599, .scroll(site: "instagram.com")), [])
        XCTAssertEqual(run(1, .scroll(site: "instagram.com")), [.gate(kind: .checkIn, site: "instagram.com", wait: 5)])
        engine.snoozeCheckIn(state: state)
        XCTAssertEqual(run(299, .scroll(site: "instagram.com")), [])
        XCTAssertEqual(run(1, .scroll(site: "instagram.com")), [.gate(kind: .budget, site: "instagram.com", wait: 10)])
        // A budget pass covers every site for its five minutes.
        engine.grantPass(site: "instagram.com", reason: "replying to a friend", kind: .budget, wholeSession: false, now: now, state: &state)
        XCTAssertEqual(run(290, .scroll(site: "x.com")), [])
        XCTAssertEqual(run(20, .scroll(site: "x.com")).first, .gate(kind: .budget, site: "x.com", wait: 20))
    }

    func testStretchForgivenAfterAMinuteAway() {
        state.settings.scrollBudgetMinutes = 600
        run(590, .scroll(site: "reddit.com"))
        run(61, .neutral)
        XCTAssertEqual(run(590, .scroll(site: "reddit.com")), [])
    }

    func testPulledBackIsCounted() {
        startSession()
        run(4, .scroll(site: "reddit.com"))
        engine.pulledBack(now: now, state: &state)
        XCTAssertEqual(day.pulledBack, 1)
        XCTAssertEqual(state.session?.pulledBack, 1)
        XCTAssertEqual(run(3, .scroll(site: "reddit.com")), [], "grace restarts after going back")
    }

    func testNightGuard() {
        now = at(1, 30)
        XCTAssertEqual(run(4, .scroll(site: "reddit.com")).first, .gate(kind: .night, site: "reddit.com", wait: 10))
        state.settings.nightGuard = false
        engine = DriftEngine(); engine.calendar = cal
        XCTAssertEqual(run(4, .scroll(site: "reddit.com")), [])
    }

    func testNightWindowWrapsMidnight() {
        var s = Settings()
        s.nightStartMinutes = 23 * 60
        s.nightEndMinutes = 6 * 60
        XCTAssertTrue(s.isNight(at(23, 30), calendar: cal))
        XCTAssertTrue(s.isNight(at(2), calendar: cal))
        XCTAssertFalse(s.isNight(at(6), calendar: cal))
        XCTAssertFalse(s.isNight(at(14), calendar: cal))
    }

    func testAdultWall() {
        XCTAssertEqual(run(1, .adult(site: "pornhub.com")), [.wall(site: "pornhub.com")], "no grace period")
        startSession()
        XCTAssertEqual(run(1, .adult(site: "pornhub.com")), [.wall(site: "pornhub.com")])
        XCTAssertEqual(day.scrollSeconds, 0)
    }

    func testWallComesDownOnlyAfterTheDelay() {
        state.settings.adultWallDisableAt = now.addingTimeInterval(Settings.wallDisableDelay)
        XCTAssertEqual(run(1, .adult(site: "pornhub.com")), [.wall(site: "pornhub.com")])
        now = now.addingTimeInterval(Settings.wallDisableDelay)
        state.settings.scrollBudgetMinutes = 0
        // Down, but still a scroll site.
        XCTAssertEqual(run(5, .adult(site: "pornhub.com")).first, .gate(kind: .budget, site: "pornhub.com", wait: 10))
    }

    func testNudgeAfterUntetheredActivity() {
        state.settings.nudgeAfterMinutes = 15
        var nudges = 0
        for _ in 0..<(31 * 60) {
            now = now.addingTimeInterval(1)
            if engine.tick(now: now, dt: 1, verdict: .neutral, idleSeconds: 0, state: &state).nudgeMinutes != nil { nudges += 1 }
        }
        XCTAssertEqual(nudges, 2)
        // None while tethered, none while away from the keyboard, none outside the hours.
        startSession()
        for _ in 0..<(20 * 60) {
            now = now.addingTimeInterval(1)
            XCTAssertNil(engine.tick(now: now, dt: 1, verdict: .neutral, idleSeconds: 0, state: &state).nudgeMinutes)
        }
        state.session = nil
        for _ in 0..<(20 * 60) {
            now = now.addingTimeInterval(1)
            XCTAssertNil(engine.tick(now: now, dt: 1, verdict: .neutral, idleSeconds: 300, state: &state).nudgeMinutes)
        }
        now = at(3)
        for _ in 0..<(20 * 60) {
            now = now.addingTimeInterval(1)
            XCTAssertNil(engine.tick(now: now, dt: 1, verdict: .neutral, idleSeconds: 0, state: &state).nudgeMinutes)
        }
    }

    func testIdleScrollStopsCounting() {
        state.settings.scrollBudgetMinutes = 600
        state.settings.checkInMinutes = 0
        run(100, .scroll(site: "netflix.com"), idle: 700)
        XCTAssertEqual(day.scrollSeconds, 0)
    }
}

final class StoreTests: XCTestCase {
    func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tether-tests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testRoundTrip() {
        let store = Store(directory: tempDir())
        var state = AppState()
        state.tasks = [TaskItem(title: "Viva slides", firstStep: "open the deck")]
        state.settings.scrollBudgetMinutes = 12
        state.session = FocusSession(taskID: state.tasks[0].id, title: "Viva slides", firstStep: nil, minutes: 45)
        state.days["2026-11-12"] = DayLog()
        store.save(state)
        XCTAssertEqual(store.load(), state)
    }

    func testOlderFileWithoutNewSettingsStillLoads() throws {
        let store = Store(directory: tempDir())
        let old = #"{"tasks":[],"days":{},"settings":{"scrollBudgetMinutes":7}}"#
        try old.write(to: store.url, atomically: true, encoding: .utf8)
        let state = store.load()
        XCTAssertEqual(state.settings.scrollBudgetMinutes, 7)
        XCTAssertEqual(state.settings.defaultSessionMinutes, 25)
        XCTAssertTrue(state.settings.adultWall)
    }

    func testUnreadableFileIsKeptNotOverwritten() throws {
        let store = Store(directory: tempDir())
        try "not json".write(to: store.url, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), AppState())
        let files = try FileManager.default.contentsOfDirectory(atPath: store.url.deletingLastPathComponent().path)
        XCTAssertTrue(files.contains { $0.hasPrefix("state.unreadable-") })
    }

    func testDayRollsOverAtFourAM() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        let late = cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 1, minute: 30))!
        let morning = cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 4, minute: 1))!
        XCTAssertEqual(DayKey.key(for: late, calendar: cal), "2026-11-12")
        XCTAssertEqual(DayKey.key(for: morning, calendar: cal), "2026-11-13")
    }
}
