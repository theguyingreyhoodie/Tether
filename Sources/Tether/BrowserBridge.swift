import AppKit
import ApplicationServices
import TetherCore

enum BrowserKind { case safari, chromium, opaque }

enum Browsers {
    /// Browsers Tether knows. `.opaque` ones can't be scripted, so only their window title is read.
    static let known: [String: BrowserKind] = [
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.canary": .chromium,
        "com.brave.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "company.thebrowser.Browser": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "com.operasoftware.Opera": .chromium,
        "org.chromium.Chromium": .chromium,
        "org.mozilla.firefox": .opaque,
        "org.mozilla.firefoxdeveloperedition": .opaque,
        "app.zen-browser.zen": .opaque,
        "com.duckduckgo.macos.browser": .opaque,
        "com.kagi.kagimacOS": .opaque,
        "company.thebrowser.dia": .opaque,
        "com.openai.atlas": .opaque,
        "ai.perplexity.comet": .opaque,
        "io.gitlab.librewolf-community": .opaque,
        "net.waterfox.waterfox": .opaque,
    ]

    struct Installed: Identifiable, Equatable {
        let bundleID: String
        let name: String
        let url: URL
        let kind: BrowserKind
        var id: String { bundleID }
    }

    static func installed() -> [Installed] {
        known.compactMap { id, kind in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return Installed(bundleID: id, name: name, url: url, kind: kind)
        }
        .sorted { $0.name < $1.name }
    }
}

enum Access: Equatable { case granted, denied, undetermined, notRunning }

/// Talks to browsers over Apple Events. All scripting happens on one dedicated thread:
/// NSAppleScript is not safe to share across threads, and a hung browser must never stall the UI.
final class BrowserBridge: @unchecked Sendable {
    private let worker = ScriptThread()
    private var scripts: [String: NSAppleScript] = [:]
    private var grantedCache: Set<String> = []
    private let lock = NSLock()

    init() {
        worker.name = "tether.script"
        worker.qualityOfService = .utility
        worker.start()
    }

    func perform(_ job: @escaping () -> Void) { worker.run(job) }

    /// Automation permission for a browser. With `ask`, shows the system prompt and blocks until answered,
    /// so never call it that way from the main thread.
    func access(_ bundleID: String, ask: Bool = false) -> Access {
        lock.lock()
        let cached = grantedCache.contains(bundleID)
        lock.unlock()
        if cached { return .granted }

        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        guard AECreateDesc(typeApplicationBundleID, bytes, bytes.count, &target) == noErr else { return .undetermined }
        defer { AEDisposeDesc(&target) }
        let status = AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, ask)
        switch status {
        case noErr:
            lock.lock(); grantedCache.insert(bundleID); lock.unlock()
            return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(procNotFound): return .notRunning
        default: return .undetermined
        }
    }

    // MARK: Scripts (worker thread only)

    func frontTab(bundleID: String, kind: BrowserKind) -> (url: String, title: String)? {
        guard kind != .opaque else { return nil }
        let tab = kind == .safari ? "current tab" : "active tab"
        let name = kind == .safari ? "name" : "title"
        let source = """
        with timeout of 3 seconds
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                try
                    set t to \(tab) of front window
                    return (URL of t as text) & linefeed & (\(name) of t as text)
                on error
                    return ""
                end try
            end tell
        end timeout
        """
        guard let out = run(source, key: "front." + bundleID), !out.isEmpty else { return nil }
        let parts = out.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
    }

    /// Closes the front tab, but only if it is still on `host`. The user may have moved on since we looked.
    func closeFrontTab(bundleID: String, kind: BrowserKind, host: String) {
        guard kind != .opaque else { return }
        let safe = host.filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        guard !safe.isEmpty else { return }
        let tab = kind == .safari ? "current tab" : "active tab"
        let source = """
        with timeout of 3 seconds
            tell application id "\(bundleID)"
                try
                    set t to \(tab) of front window
                    if (URL of t as text) contains "\(safe)" then close t
                end try
            end tell
        end timeout
        """
        _ = run(source, key: nil)
    }

    private func run(_ source: String, key: String?) -> String? {
        let script: NSAppleScript
        if let key, let cached = scripts[key] {
            script = cached
        } else {
            guard let made = NSAppleScript(source: source) else { return nil }
            var compileError: NSDictionary?
            guard made.compileAndReturnError(&compileError) else {
                NSLog("Tether: script did not compile: %@", compileError ?? [:])
                return nil
            }
            if let key { scripts[key] = made }
            script = made
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }
}

/// A thread that runs jobs one at a time, forever.
private final class ScriptThread: Thread, @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [() -> Void] = []

    func run(_ job: @escaping () -> Void) {
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    override func main() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            autoreleasepool { job() }
        }
    }
}

/// Accessibility fallback: the title of an app's focused window. Needs the Accessibility permission.
enum WindowTitle {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func prompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func focused(pid: pid_t) -> String? {
        guard trusted else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }
}

/// Watches what is in front. Cheap to call every second.
@MainActor
final class ContextWatcher {
    let bridge = BrowserBridge()
    private(set) var context = Context()
    private(set) var frontApp: NSRunningApplication?
    /// Scriptable browser in front that Tether has not been allowed to read yet.
    private(set) var blockedBrowser: String?
    private var inFlight = false
    /// Self-test only: pretend this is in front instead of asking the system.
    var override: Context?

    func refresh() {
        if let override {
            context = override
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        // Our own gate, bar and popover don't count as a change of scenery.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        frontApp = app
        let id = app.bundleIdentifier
        let name = app.localizedName ?? ""
        guard let id, let kind = Browsers.known[id] else {
            context = Context(bundleID: id, appName: name)
            blockedBrowser = nil
            return
        }
        if context.bundleID != id {
            context = Context(bundleID: id, appName: name, isBrowser: true)
        }
        guard !inFlight else { return }
        inFlight = true
        let pid = app.processIdentifier
        let bridge = self.bridge
        bridge.perform { [weak self] in
            var url: String?
            var title: String?
            var blocked = false
            if kind != .opaque, bridge.access(id) == .granted {
                if let tab = bridge.frontTab(bundleID: id, kind: kind) {
                    url = tab.url
                    title = tab.title
                }
            } else {
                blocked = kind != .opaque
                title = WindowTitle.focused(pid: pid)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                guard self.context.bundleID == id else { return }
                self.context = Context(bundleID: id, appName: name, isBrowser: true, url: url, title: title)
                self.blockedBrowser = blocked ? id : nil
            }
        }
    }

    /// Gets the offending page out of the way: closes the tab when possible, otherwise hides the app.
    func dismiss(_ ctx: Context, app: NSRunningApplication?, host: String, closeTab: Bool) {
        if closeTab, let id = ctx.bundleID, let kind = Browsers.known[id], kind != .opaque, ctx.url != nil {
            bridge.perform { [bridge] in bridge.closeFrontTab(bundleID: id, kind: kind, host: host) }
        } else {
            app?.hide()
        }
    }

    static func idleSeconds() -> Double {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }
}
