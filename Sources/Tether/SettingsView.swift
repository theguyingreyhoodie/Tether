import AppKit
import SwiftUI
import TetherCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = false
    @State private var axTrusted = WindowTitle.trusted

    private func bind<T>(_ keyPath: WritableKeyPath<TetherCore.Settings, T>) -> Binding<T> {
        Binding(get: { model.state.settings[keyPath: keyPath] },
                set: { value in model.update { $0[keyPath: keyPath] = value } })
    }

    var body: some View {
        Form {
            general
            sessions
            scrolling
            night
            wall
            nudges
            browsers
            data
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .onAppear {
            launchAtLogin = model.launchAtLogin
            axTrusted = WindowTitle.trusted
            model.refreshAccess()
        }
    }

    // MARK: Sections

    private var general: some View {
        Section("General") {
            Toggle("Open Tether at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    guard on != model.launchAtLogin else { return }
                    model.launchAtLogin = on
                    launchAtLogin = model.launchAtLogin
                }
            Toggle("Show the floating pill", isOn: bind(\.showPill))
            Toggle("Play sounds", isOn: bind(\.sounds))
            LabeledContent("Command bar", value: "⌃⌥Space")
            LabeledContent("Urge button", value: "⌃⌥U")
        }
    }

    private var sessions: some View {
        Section {
            Stepper("Default length: \(model.settings.defaultSessionMinutes) minutes",
                    value: bind(\.defaultSessionMinutes), in: 5...180, step: 5)
            Toggle("Close the tab when I go back", isOn: bind(\.closeTabOnReturn))
            Stepper("First wait at the gate: \(model.settings.gateBaseSeconds) seconds",
                    value: bind(\.gateBaseSeconds), in: 5...60, step: 5)
            Stepper("A pass lasts \(model.settings.passMinutes) minutes",
                    value: bind(\.passMinutes), in: 1...15)
        } header: {
            Text("Sessions")
        } footer: {
            Text("While you're tethered, a scroll site in front brings up the gate. Getting through means waiting, then saying why. The wait doubles with every pass you take that day.")
        }
    }

    private var scrolling: some View {
        Section {
            Stepper("Daily budget: \(model.settings.scrollBudgetMinutes) minutes",
                    value: bind(\.scrollBudgetMinutes), in: 0...240, step: 5)
            Stepper(model.settings.checkInMinutes == 0 ? "Check-ins: off"
                    : "Check in after \(model.settings.checkInMinutes) minutes straight",
                    value: bind(\.checkInMinutes), in: 0...60, step: 5)
            DisclosureGroup("Scroll sites (\(model.settings.scrollSites.count))") {
                SiteList(sites: bind(\.scrollSites), placeholder: "youtube.com or youtube.com/shorts")
            }
        } header: {
            Text("Scrolling while untethered")
        } footer: {
            Text("A site, or a site and a path. YouTube is only caught on Shorts by default so lectures and tutorials still work. Add youtube.com to catch all of it.")
        }
    }

    private var night: some View {
        Section {
            Toggle("Night guard", isOn: bind(\.nightGuard))
            if model.settings.nightGuard {
                DatePicker("From", selection: minutes(\.nightStartMinutes), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: minutes(\.nightEndMinutes), displayedComponents: .hourAndMinute)
            }
        } footer: {
            Text("Between these hours scroll sites are gated even when you're not in a session, budget or no budget.")
        }
    }

    private var wall: some View {
        Section {
            Toggle("Close adult sites on sight", isOn: Binding(
                get: { model.settings.adultWall && model.settings.adultWallDisableAt == nil },
                set: { model.setAdultWall($0) }))
            if let off = model.settings.adultWallDisableAt {
                HStack {
                    Label("Comes down at \(off.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Keep it up") { model.setAdultWall(true) }
                }
            }
            DisclosureGroup("Extra sites to wall off (\(model.settings.extraAdultSites.count))") {
                SiteList(sites: bind(\.extraAdultSites), placeholder: "example.com")
            }
        } header: {
            Text("Wall")
        } footer: {
            Text("The tab is closed immediately and you get ninety seconds to ride the urge out. There is no pass. Switching the wall off takes ten minutes to apply, so it can't be done in the heat of the moment. Walled sites are counted, never recorded.")
        }
    }

    private var nudges: some View {
        Section {
            Toggle("Nudge me when I'm drifting without a task", isOn: bind(\.nudges))
            if model.settings.nudges {
                Stepper("After \(model.settings.nudgeAfterMinutes) minutes untethered",
                        value: bind(\.nudgeAfterMinutes), in: 5...120, step: 5)
                Stepper("From \(hour(model.settings.nudgeStartHour))",
                        value: bind(\.nudgeStartHour), in: 0...(model.settings.nudgeEndHour - 1))
                Stepper("Until \(hour(model.settings.nudgeEndHour))",
                        value: bind(\.nudgeEndHour), in: (model.settings.nudgeStartHour + 1)...24)
            }
        } header: {
            Text("Nudges")
        }
    }

    private var browsers: some View {
        Section {
            let installed = Browsers.installed()
            ForEach(installed) { browser in
                BrowserRow(browser: browser)
            }
            if installed.contains(where: { $0.kind == .opaque }) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility")
                        Text("Lets Tether read window titles in browsers that can't be scripted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if axTrusted {
                        Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Allow…") { WindowTitle.prompt() }
                    }
                }
            }
        } header: {
            Text("Browsers")
        } footer: {
            Text("Tether asks each browser for the address of its front tab, once a second, and compares it with your lists on this Mac. It keeps no history.")
        }
    }

    private var data: some View {
        Section("Data") {
            LabeledContent("Stored on this Mac only") {
                Button("Show in Finder") {
                    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                        .appendingPathComponent("Tether")
                    NSWorkspace.shared.open(dir)
                }
            }
        }
    }

    // MARK: Helpers

    private func minutes(_ keyPath: WritableKeyPath<TetherCore.Settings, Int>) -> Binding<Date> {
        Binding(
            get: {
                let m = model.state.settings[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.update { $0[keyPath: keyPath] = (c.hour ?? 0) * 60 + (c.minute ?? 0) }
            })
    }

    private func hour(_ h: Int) -> String {
        let date = Calendar.current.date(bySettingHour: h % 24, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

struct BrowserRow: View {
    @Environment(AppModel.self) private var model
    var browser: Browsers.Installed

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: browser.url.path))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            Text(browser.name)
            Spacer()
            if browser.kind == .opaque {
                Text("Window titles only").foregroundStyle(.secondary)
            } else {
                switch model.browserAccess[browser.bundleID] {
                case .granted:
                    Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .denied:
                    Button("Allow in System Settings…") { model.connect(browser) }
                default:
                    Button("Connect") { model.connect(browser) }
                }
            }
        }
    }
}

struct SiteList: View {
    @Binding var sites: [String]
    var placeholder: String
    @State private var entry = ""

    var body: some View {
        ForEach(sites, id: \.self) { site in
            HStack {
                Text(site)
                Spacer()
                Button {
                    sites.removeAll { $0 == site }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(site)")
            }
        }
        HStack {
            TextField(placeholder, text: $entry)
                .labelsHidden()
                .onSubmit(add)
            Button("Add", action: add)
                .disabled(Classifier.normalize(entry).isEmpty)
        }
    }

    private func add() {
        let rule = Classifier.normalize(entry)
        guard !rule.isEmpty, rule.contains("."), !sites.contains(rule) else { return }
        sites.append(rule)
        entry = ""
    }
}
