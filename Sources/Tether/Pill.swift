import AppKit
import SwiftUI
import TetherCore

/// The small floating capsule: what you're tethered to, or how much scrolling is left.
struct PillView: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false
    /// Reports the pill's size so its window can hug it instead of covering a strip of screen.
    var onSize: (CGSize) -> Void = { _ in }

    var body: some View {
        content
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(DragHandle())
            .surface(.capsule)
            .onHover { hovering = $0 }
            .animation(.snappy(duration: 0.25), value: hovering)
            .animation(.snappy(duration: 0.3), value: model.pill)
            .padding(14)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { onSize($0) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.pill {
        case .hidden:
            EmptyView()
        case .session:
            if let s = model.session { sessionPill(s) }
        case .scrolling(let site, let left):
            HStack(spacing: 8) {
                Image(systemName: "hourglass")
                    .foregroundStyle(Tint.scroll)
                Text(Fmt.siteName(site))
                    .fontWeight(.medium)
                Text(left > 0 ? "\(Fmt.minutesLeft(left)) of scrolling left today" : "past today's budget")
                    .foregroundStyle(left > 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Tint.scroll))
                    .monospacedDigit()
            }
        case .nudge(let minutes):
            Button {
                model.ui?.openCommandBar()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "circle.dotted")
                        .foregroundStyle(.secondary)
                    Text("\(minutes) minutes untethered.")
                        .foregroundStyle(.secondary)
                    Text("What's the one thing?")
                        .fontWeight(.medium)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the command bar (⌃⌥Space)")
        case .finished(let title, let focus, let completed):
            HStack(spacing: 8) {
                Image(systemName: completed ? "checkmark.circle.fill" : "stop.circle")
                    .foregroundStyle(completed ? AnyShapeStyle(Tint.focus) : AnyShapeStyle(.secondary))
                Text(title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .frame(maxWidth: 180)
                    .fixedSize()
                Text("\(Fmt.span(focus)) focused")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func sessionPill(_ s: FocusSession) -> some View {
        HStack(spacing: 9) {
            ProgressRing(progress: s.progress, lineWidth: 2.5)
                .frame(width: 15, height: 15)
            Text(s.title)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 190)
                .fixedSize()
            Text(s.isOvertime ? "+" + Fmt.clock(-s.remainingSeconds) : Fmt.clock(s.remainingSeconds))
                .monospacedDigit()
                .foregroundStyle(s.isOvertime ? AnyShapeStyle(Tint.scroll) : AnyShapeStyle(.secondary))
            if hovering || s.isOvertime {
                HStack(spacing: 2) {
                    pillButton("checkmark", "Done") { model.endSession(completed: true) }
                    pillButton("plus", "Ten more minutes") { model.extend(minutes: 10) }
                    pillButton("stop.fill", "Stop without finishing") { model.endSession(completed: false) }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
    }

    private func pillButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(.quaternary, in: Circle())
        .help(label)
        .accessibilityLabel(label)
    }
}

@MainActor
final class PillController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var panel: NSPanel?
    /// Top-centre of the pill in screen coordinates. The window grows and shrinks around this point.
    private var anchor = NSPoint.zero
    private var resizing = false

    init(model: AppModel) { self.model = model }

    /// Shows or hides the pill to match the model. Called every tick.
    func update() {
        let wanted = model.settings.showPill && model.pill != .hidden && model.gate == nil
        if wanted {
            if panel == nil { build() }
            if panel?.isVisible == false { panel?.orderFrontRegardless() }
        } else if panel?.isVisible == true {
            panel?.orderOut(nil)
        }
    }

    private func build() {
        anchor = startingAnchor()
        let host = NSHostingView(rootView: PillView(onSize: { [weak self] in self?.fit($0) }).environment(model))
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.contentView = host
        p.delegate = self
        panel = p
        fit(host.fittingSize)
    }

    private func fit(_ size: CGSize) {
        guard let p = panel, size.width > 1, size.height > 1 else { return }
        let frame = NSRect(x: anchor.x - size.width / 2, y: anchor.y - size.height, width: size.width, height: size.height)
        guard p.frame != frame else { return }
        resizing = true
        p.setFrame(frame, display: true)
        resizing = false
    }

    /// The saved spot if it is still on a screen, otherwise hanging just under the menu bar, centred.
    private func startingAnchor() -> NSPoint {
        if let x = model.state.pillX, let y = model.state.pillY {
            let saved = NSPoint(x: x, y: y - 30)
            if NSScreen.screens.contains(where: { $0.frame.contains(saved) }) {
                return NSPoint(x: x, y: y)
            }
        }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        let visible = screen.visibleFrame
        return NSPoint(x: visible.midX, y: visible.maxY + 6)
    }

    func windowDidMove(_ notification: Notification) {
        // Only a drag by the user moves the anchor; our own resizes keep it where it is.
        guard !resizing, let frame = panel?.frame else { return }
        anchor = NSPoint(x: frame.midX, y: frame.maxY)
        model.setPillOrigin(anchor)
    }
}
