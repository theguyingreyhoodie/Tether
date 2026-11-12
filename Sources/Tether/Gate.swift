import AppKit
import SwiftUI
import TetherCore

/// The full-screen pause. Going back is always one keypress; going through costs a wait and a reason.
struct GateView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.flatSurfaces) private var still
    var request: GateRequest
    @State private var shown = false

    var body: some View {
        ZStack {
            Backdrop()
            Color.black.opacity(0.35)
            Group {
                switch request.mode {
                case .drift(let kind, let site, let wait):
                    DriftGate(kind: kind, site: site, wait: wait, startedAt: request.startedAt)
                case .urge(let caught):
                    UrgeSurf(caught: caught, startedAt: request.startedAt)
                }
            }
            .opacity(shown || still ? 1 : 0)
            .scaleEffect(shown || still ? 1 : 0.97)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) { shown = true }
        }
    }
}

/// Shown on every other display so there is nowhere to keep scrolling.
struct GateBackdrop: View {
    var body: some View {
        ZStack {
            Backdrop()
            Color.black.opacity(0.35)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Drift

private struct DriftGate: View {
    @Environment(AppModel.self) private var model
    var kind: GateKind
    var site: String
    var wait: Int
    var startedAt: Date

    @State private var reason = ""
    @FocusState private var reasonFocused: Bool

    private var siteName: String { Fmt.siteName(site) }
    private var reasonOK: Bool {
        reason.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").count >= 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow(eyebrow)
                Text(headline)
                    .font(.system(size: 32, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if kind == .session, let step = model.session?.firstStep, !step.isEmpty {
                    Label("Next move: \(step)", systemImage: "arrow.turn.down.right")
                        .font(.title3)
                        .padding(.top, 4)
                }
            }

            HStack(spacing: 10) {
                Button(action: model.backToIt) {
                    Text(kind == .session ? "Back to it" : "Close \(siteName)")
                        .frame(minWidth: 120)
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(reasonFocused ? nil : .defaultAction)

                if kind != .session {
                    Button("Pick one thing to do", action: model.leaveGateForTask)
                        .buttonStyle(.glass)
                }
            }
            .controlSize(.extraLarge)

            Divider()

            TimelineView(.periodic(from: startedAt, by: 0.25)) { timeline in
                let left = Double(wait) - timeline.date.timeIntervalSince(startedAt)
                if left > 0 {
                    waiting(left)
                } else {
                    through
                }
            }

            if model.today.pulledBack > 0 {
                Text("You've pulled yourself back \(model.today.pulledBack)× today.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(36)
        .frame(width: 540, alignment: .leading)
        .surface(.rect(cornerRadius: 30))
        // Escape is the easy key, so it does the right thing.
        .background {
            Button("", action: model.backToIt)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private func waiting(_ left: Double) -> some View {
        HStack(spacing: 12) {
            ProgressRing(progress: 1 - left / Double(wait), lineWidth: 3, tint: .white.opacity(0.7))
                .frame(width: 22, height: 22)
            Text(kind == .checkIn
                 ? "Or keep going in \(Int(left.rounded(.up)))s"
                 : "Still need it? You can ask in \(Int(left.rounded(.up)))s. Take a breath meanwhile.")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 30)
    }

    @ViewBuilder
    private var through: some View {
        if kind == .checkIn {
            Button("Keep scrolling", action: model.keepScrolling)
                .buttonStyle(.glass)
                .controlSize(.large)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                TextField("What do you need on \(siteName)? Be specific.", text: $reason)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .focused($reasonFocused)
                HStack(spacing: 10) {
                    Button("Let me through for \(model.settings.passMinutes) minutes") {
                        model.letThrough(reason: reason, wholeSession: false)
                    }
                    if kind == .session {
                        Button("It's part of the task") {
                            model.letThrough(reason: reason, wholeSession: true)
                        }
                        .help("Allow \(siteName) until this session ends")
                    }
                    Spacer()
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(!reasonOK)
                Text("Your answer is kept in today's ledger. The next wait is twice as long.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var eyebrow: String {
        switch kind {
        case .session: "You're tethered to"
        case .night: "Night guard"
        case .budget: "Scroll budget spent"
        case .checkIn: "Check-in"
        }
    }

    private var headline: String {
        switch kind {
        case .session: model.session?.title ?? "Your task"
        case .night: "It's \(model.now.formatted(date: .omitted, time: .shortened))."
        case .budget: "That's today's \(model.settings.scrollBudgetMinutes) minutes."
        case .checkIn: "\(max(1, model.settings.checkInMinutes)) minutes on \(siteName)."
        }
    }

    private var detail: String {
        switch kind {
        case .session:
            let left = model.session.map { $0.isOvertime ? "" : " \(Fmt.minutesLeft($0.remainingSeconds)) left on the clock." } ?? ""
            return "This is \(siteName).\(left)"
        case .night:
            return "\(siteName) will be the same tomorrow. You won't be, if you stay up for it."
        case .budget:
            return "You've scrolled \(Fmt.span(model.today.scrollSeconds)) today. Past this point it's rarely fun any more, just hard to stop."
        case .checkIn:
            return "Is this still what you want to be doing?"
        }
    }
}

// MARK: - Urge surf

private struct UrgeSurf: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.flatSurfaces) private var still
    var caught: Bool
    var startedAt: Date

    static let length: Double = 90
    static let earliestExit: Double = 15

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(startedAt)
            let crested = elapsed >= Self.length
            VStack(spacing: 30) {
                breath(elapsed: elapsed, crested: crested)

                VStack(spacing: 10) {
                    Eyebrow(caught ? "Wall" : "Urge button")
                    Text(crested ? "That was the crest. It passed."
                         : caught ? "Closed it. Stay here for a minute." : "Good catch. Ride it out here.")
                        .font(.system(size: 30, weight: .semibold))
                        .multilineTextAlignment(.center)
                    Text("An urge is a wave. It builds, crests and fades on its own in a minute or two, whether or not you act on it. Breathe with the circle and let it go by.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    if caught, model.today.walls >= 3 {
                        Text("That's \(model.today.walls) times today. Leaving the room works better than willpower.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                .frame(width: 520)

                HStack(spacing: 10) {
                    Button(action: model.urgeDone) {
                        Text(model.session == nil ? "I'm steady. Give me something to do" : "I'm steady. Back to work")
                            .frame(minWidth: 150)
                    }
                    .buttonStyle(.glassProminent)
                    Button("Lock the Mac and walk away", action: model.lockAndWalk)
                        .buttonStyle(.glass)
                }
                .controlSize(.extraLarge)
                .opacity(elapsed >= Self.earliestExit ? 1 : 0)
                .disabled(elapsed < Self.earliestExit)
                .animation(.easeOut(duration: 0.6), value: elapsed >= Self.earliestExit)
            }
        }
    }

    private func breath(elapsed: Double, crested: Bool) -> some View {
        // Four seconds in, six out: a long exhale is what slows the pulse.
        let cycle = elapsed.truncatingRemainder(dividingBy: 10)
        let inhaling = cycle < 4
        let t = inhaling ? cycle / 4 : 1 - (cycle - 4) / 6
        let eased = t * t * (3 - 2 * t)
        let scale = reduceMotion || crested ? 0.85 : 0.6 + 0.4 * eased
        return ZStack {
            ProgressRing(progress: min(1, elapsed / Self.length), lineWidth: 3, tint: .white.opacity(0.75))
                .frame(width: 216, height: 216)
            Circle()
                .fill(RadialGradient(colors: [Tint.focus.opacity(0.75), Tint.focus.opacity(0.3)],
                                     center: .center, startRadius: 10, endRadius: 95))
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                .frame(width: 190, height: 190)
                .scaleEffect(scale)
            Text(crested ? "Done" : inhaling ? "Breathe in" : "Breathe out")
                .font(.title3.weight(.medium))
                .contentTransition(.opacity)
        }
        .frame(width: 220, height: 220)
        .accessibilityElement()
        .accessibilityLabel("Breathing guide, \(Int(max(0, Self.length - elapsed))) seconds left")
    }
}

// MARK: - Windows

private final class GateWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class GateController {
    private let model: AppModel
    private var windows: [NSWindow] = []

    init(model: AppModel) { self.model = model }

    func present(_ request: GateRequest) {
        dismiss()
        let mouse = NSEvent.mouseLocation
        let primary = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        for screen in NSScreen.screens {
            let w = GateWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.level = .screenSaver
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.animationBehavior = .none
            w.setFrame(screen.frame, display: false)
            if screen == primary {
                w.contentView = NSHostingView(rootView: GateView(request: request).environment(model))
            } else {
                w.contentView = NSHostingView(rootView: GateBackdrop())
            }
            w.orderFrontRegardless()
            windows.append(w)
            if screen == primary {
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Takes the windows down at once. A gate that lingers, even invisibly, would swallow every click,
    /// so nothing here waits on an animation finishing.
    func dismiss() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }
}
