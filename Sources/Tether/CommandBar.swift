import AppKit
import SwiftUI
import TetherCore

/// The Spotlight-style bar behind ⌃⌥Space: name the one thing, press Return, you're tethered.
struct CommandBarView: View {
    @Environment(AppModel.self) private var model
    var close: () -> Void

    enum Stage { case task, step }
    private enum Field { case task, step }

    private enum Row: Identifiable {
        case done(String), extend, stop
        case task(TaskItem)

        var id: String {
            switch self {
            case .done: "done"
            case .extend: "extend"
            case .stop: "stop"
            case .task(let t): t.id.uuidString
            }
        }
    }

    @State private var stage: Stage
    @State private var text: String
    @State private var step = ""
    @State private var selection: Int?
    @FocusState private var focus: Field?

    init(text: String = "", stage: Stage = .task, close: @escaping () -> Void) {
        self.close = close
        _text = State(initialValue: text)
        _stage = State(initialValue: stage)
    }

    private var parsed: (title: String, minutes: Int?) { TaskParser.parse(text) }
    private var minutes: Int { parsed.minutes ?? model.settings.defaultSessionMinutes }

    private var rows: [Row] {
        var out: [Row] = []
        let query = parsed.title.lowercased()
        if let s = model.session, query.isEmpty {
            out += [.done(s.title), .extend, .stop]
        }
        let tasks = model.state.openTasks.filter { task in
            task.id != model.session?.taskID && (query.isEmpty || task.title.lowercased().contains(query))
        }
        out += tasks.prefix(5).map(Row.task)
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            switch stage {
            case .task: taskStage
            case .step: stepStage
            }
        }
        .frame(width: 600)
        .surface(.rect(cornerRadius: 24))
        .padding(40)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            // Next turn of the run loop, once the panel has become key.
            DispatchQueue.main.async { focus = stage == .task ? .task : .step }
        }
        .onChange(of: stage) { _, now in
            // The new stage's field doesn't exist until the next pass, so focus can't be set in the same breath.
            DispatchQueue.main.async { focus = now == .task ? .task : .step }
        }
        .onKeyPress(.escape) {
            if stage == .step {
                stage = .task
            } else {
                close()
            }
            return .handled
        }
    }

    // MARK: Stage one: the task

    private var taskStage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: model.session == nil ? "circle.dotted" : "smallcircle.filled.circle")
                    .font(.title2)
                    .foregroundStyle(model.session == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Tint.focus))
                TextField(model.session == nil ? "What's the one thing?" : "Switch to something else…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, weight: .regular))
                    .focused($focus, equals: .task)
                    .onSubmit(submitTask)
                    .onChange(of: text) { selection = nil }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                Text(Fmt.minutesLeft(Double(minutes) * 60))
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(parsed.minutes == nil ? .tertiary : .primary)
                    .help("Session length. Type something like 45m or 1h30 after the task.")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            if !rows.isEmpty {
                Divider().padding(.horizontal, 14)
                VStack(spacing: 2) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, selected: selection == index)
                            .contentShape(Rectangle())
                            .onTapGesture { perform(row) }
                    }
                }
                .padding(8)
            }

            hint(model.session == nil && rows.isEmpty
                 ? "Return to tether  ·  add 45m or 1h30 to set the length"
                 : "Return to tether  ·  ↑↓ to pick  ·  esc to close")
        }
    }

    private func rowView(_ row: Row, selected: Bool) -> some View {
        HStack(spacing: 10) {
            switch row {
            case .done(let title):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Tint.focus).frame(width: 22)
                Text("Done with “\(title)”").lineLimit(1)
            case .extend:
                Image(systemName: "plus.circle").foregroundStyle(.secondary).frame(width: 22)
                Text("Ten more minutes")
            case .stop:
                Image(systemName: "stop.circle").foregroundStyle(.secondary).frame(width: 22)
                Text("Stop without finishing")
            case .task(let task):
                Image(systemName: "circle").foregroundStyle(.tertiary).frame(width: 22)
                Text(task.title).lineLimit(1)
                if let step = task.firstStep, !step.isEmpty {
                    Text(step).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "return").font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? AnyShapeStyle(.selection.opacity(0.35)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        switch selection {
        case nil: selection = delta > 0 ? 0 : rows.count - 1
        case let i?:
            let next = i + delta
            selection = (0..<rows.count).contains(next) ? next : nil
        }
    }

    private func submitTask() {
        if let i = selection, rows.indices.contains(i) {
            perform(rows[i])
        } else if !parsed.title.isEmpty {
            stage = .step
        }
    }

    private func perform(_ row: Row) {
        switch row {
        case .done: model.endSession(completed: true)
        case .extend: model.extend(minutes: 10)
        case .stop: model.endSession(completed: false)
        case .task(let task): model.start(title: task.title, minutes: parsed.minutes, taskID: task.id)
        }
        close()
    }

    // MARK: Stage two: the first move

    private var stepStage: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow("\(Fmt.minutesLeft(Double(minutes) * 60)) on")
                Text(parsed.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)
            Divider().padding(.horizontal, 14)
            HStack(spacing: 12) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("What's the first two-minute move?", text: $step)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focus, equals: .step)
                    .onSubmit {
                        model.start(title: parsed.title, firstStep: step, minutes: parsed.minutes)
                        close()
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            hint("Small enough that you can't not do it. Return to start  ·  leave it empty to skip")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            .padding(.top, 2)
    }
}

/// A panel that can take typing without pulling the whole app to the front.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CommandBarController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var panel: KeyPanel?

    init(model: AppModel) { self.model = model }

    var isOpen: Bool { panel != nil }

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard panel == nil, model.gate == nil else { return }
        let size = NSSize(width: 680, height: 480)
        let p = KeyPanel(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                         backing: .buffered, defer: false)
        p.isReleasedWhenClosed = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .modalPanel
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.hidesOnDeactivate = false
        p.delegate = self
        p.contentView = NSHostingView(rootView: CommandBarView(close: { [weak self] in self?.close() }).environment(model))

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            // Upper third, where Spotlight lives.
            p.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * 0.22 - size.height))
        }
        p.animationBehavior = .utilityWindow
        panel = p
        p.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let p = panel else { return }
        panel = nil
        p.delegate = nil
        p.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}
