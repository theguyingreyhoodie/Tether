import AppKit
import SwiftUI
import TetherCore

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    var finish: (_ launchAtLogin: Bool) -> Void
    @State private var launchAtLogin = true

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tether")
                        .font(.largeTitle.weight(.bold))
                    Text("One thing at a time, and a hand on your shoulder when you drift.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                point("smallcircle.filled.circle", "Say what you're doing",
                      "Press ⌃⌥Space anywhere, type the task, press Return. That's the whole ritual. Tether keeps it in view and keeps the clock.")
                point("hand.raised", "Get stopped mid-drift",
                      "Open Instagram, Reddit or Shorts while you're tethered and the screen pauses. Going back is one key. Going through means waiting, then typing why.")
                point("hourglass", "Scroll on a budget",
                      "Untethered, you get \(model.settings.scrollBudgetMinutes) minutes of scroll sites a day, with the meter in plain sight. Late at night they're gated outright.")
                point("water.waves", "A wall where you want one",
                      "Adult sites are closed the moment they open, and you get ninety seconds to breathe through the urge instead. Feel it coming? ⌃⌥U gets you there first.")
            }

            VStack(alignment: .leading, spacing: 10) {
                Eyebrow("Let Tether see your browsers")
                VStack(spacing: 8) {
                    ForEach(Browsers.installed().filter { $0.kind != .opaque }) { browser in
                        BrowserRow(browser: browser)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("macOS will ask once per browser. Tether only reads the address of the front tab, checks it against your lists on this Mac, and keeps no history. Without this it can't catch anything in that browser.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Toggle("Open Tether at login", isOn: $launchAtLogin)
                Spacer()
                Button {
                    finish(launchAtLogin)
                } label: {
                    Text("Start")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560)
        .onAppear { model.refreshAccess() }
    }

    private func point(_ symbol: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Tint.focus)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
