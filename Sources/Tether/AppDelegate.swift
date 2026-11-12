import AppKit
import Carbon.HIToolbox
import SwiftUI
import TetherCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, AppUI {
    let model: AppModel
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private lazy var gates = GateController(model: model)
    private lazy var bar = CommandBarController(model: model)
    private lazy var pill = PillController(model: model)
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var hotKeys: [HotKey] = []
    private var lastSymbol = ""

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.ui = self
        buildMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.setAccessibilityLabel("Tether")
        }

        let host = NSHostingController(rootView: MenuView(
            openSettings: { [weak self] in self?.showSettings() },
            quit: { [weak self] in self?.quit() }
        ).environment(model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true

        hotKeys = [
            HotKey(key: kVK_Space, modifiers: controlKey | optionKey, id: 1) { [weak self] in self?.bar.toggle() },
            HotKey(key: kVK_ANSI_U, modifiers: controlKey | optionKey, id: 2) { [weak self] in self?.model.urgeButton() },
        ]

        model.startTicking()
        model.refreshAccess()
        if !model.settings.onboarded { showOnboarding() }
    }

    func applicationWillTerminate(_ notification: Notification) { model.save() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opening the app again from Finder or Spotlight shows the popover rather than doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { togglePopover() }
        return false
    }

    // MARK: AppUI

    func present(gate: GateRequest) {
        bar.close()
        gates.present(gate)
        pill.update()
    }

    func dismissGate() {
        gates.dismiss()
        pill.update()
    }

    func openCommandBar() { bar.open() }

    func closePopover() {
        if popover.isShown { popover.performClose(nil) }
    }

    func refreshChrome() {
        pill.update()
        guard let button = statusItem?.button else { return }
        var symbol = "circle.dotted"
        var title = ""
        var description = "Tether, untethered"
        if let s = model.session {
            symbol = "smallcircle.filled.circle"
            title = s.isOvertime ? "+" + Fmt.minutesLeft(-s.remainingSeconds) : Fmt.minutesLeft(s.remainingSeconds)
            description = "Tethered to \(s.title), \(title)"
        } else if case .scroll = model.verdict {
            symbol = "hourglass"
            title = Fmt.minutesLeft(model.budgetLeft)
            description = "Scrolling, \(title) of budget left"
        }
        if symbol != lastSymbol {
            lastSymbol = symbol
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image?.isTemplate = true
            button.image = image
        }
        let padded = title.isEmpty ? "" : " " + title
        if button.title != padded { button.title = padded }
        button.setAccessibilityLabel(description)
    }

    // MARK: Popover and windows

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        model.refreshAccess()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func showSettings() {
        closePopover()
        if settingsWindow == nil {
            settingsWindow = window(title: "Tether Settings", content: SettingsView().environment(model),
                                    style: [.titled, .closable, .miniaturizable])
        }
        front(settingsWindow)
    }

    private func showOnboarding() {
        let view = OnboardingView { [weak self] launchAtLogin in
            guard let self else { return }
            self.model.update { $0.onboarded = true }
            if launchAtLogin { self.model.launchAtLogin = true }
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
            self.bar.open()
        }
        onboardingWindow = window(title: "Welcome to Tether", content: view.environment(model),
                                  style: [.titled, .closable, .fullSizeContentView])
        onboardingWindow?.titlebarAppearsTransparent = true
        onboardingWindow?.titleVisibility = .hidden
        front(onboardingWindow)
    }

    private func window(title: String, content: some View, style: NSWindow.StyleMask) -> NSWindow {
        let host = NSHostingController(rootView: content)
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = style
        w.isReleasedWhenClosed = false
        w.setContentSize(host.view.fittingSize)
        w.center()
        return w
    }

    private func front(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        closePopover()
        // ⌘Q at a gate is the emergency exit. No alert: it would open underneath the gate.
        if model.gate != nil {
            NSApp.terminate(nil)
            return
        }
        if let s = model.session {
            let alert = NSAlert()
            alert.messageText = "You're still tethered to “\(s.title)”."
            alert.informativeText = "Quitting ends the session and takes the gate down with it."
            alert.addButton(withTitle: "Stay Tethered")
            alert.addButton(withTitle: "Quit Anyway")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            model.endSession(completed: false, announce: false)
        }
        NSApp.terminate(nil)
    }

    /// An accessory app has no visible menu bar, but text fields still need these for ⌘C, ⌘V and friends.
    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Tether", action: #selector(quit), keyEquivalent: "q").target = self
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    @objc private func openSettingsFromMenu() { showSettings() }
}
