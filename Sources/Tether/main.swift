import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if DevTools.runIfRequested() { return }

    let delegate = AppDelegate(model: AppModel())
    app.delegate = delegate
    // `delegate` stays alive for the life of the process: run() never returns.
    app.run()
}
