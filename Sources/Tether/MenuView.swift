import SwiftUI
import TetherCore

/// The menu-bar popover: what you're tethered to, what's next, and an honest account of today.
struct MenuView: View {
    @Environment(AppModel.self) private var model
    var openSettings: () -> Void
    var quit: () -> Void

    @State private var quickStart = ""
    @State private var newTask = ""
    @State private var showPasses = false
    @FocusState private var quickFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let s = model.session {
                SessionCard(session: s)
            } else {
                startField
            }

            if let id = model.blockedBrowser, let browser = Browsers.installed().first(where: { $0.bundleID == id }) {
                connectBanner(browser)
            }

            tasks
            Divider()
            ledger
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: Start

    private var startField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow("Untethered")
            HStack(spacing: 8) {
                Image(systemName: "circle.dotted")
                    .foregroundStyle(.secondary)
                TextField("What's the one thing?", text: $quickStart)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($quickFocused)
                    .onSubmit(startQuick)
                if !quickStart.isEmpty {
                    Text(Fmt.minutesLeft(Double(TaskParser.parse(quickStart).minutes ?? model.settings.defaultSessionMinutes) * 60))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("Add a length like 45m. ⌃⌥Space opens this from anywhere.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .onAppear { quickFocused = true }
    }

    private func startQuick() {
        let parsed = TaskParser.parse(quickStart)
        guard !parsed.title.isEmpty else { return }
        model.start(title: parsed.title, minutes: parsed.minutes)
        quickStart = ""
        model.ui?.closePopover()
    }

    private func connectBanner(_ browser: Browsers.Installed) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash")
                .foregroundStyle(Tint.scroll)
            Text("Tether can't see \(browser.name) yet, so it can't catch drift there.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Connect") { model.connect(browser) }
                .controlSize(.small)
        }
        .padding(10)
        .background(Tint.scroll.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Tasks

    private var tasks: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow("Tasks")
                .padding(.bottom, 2)
            let open = model.state.openTasks
            let done = model.state.tasks.filter { $0.isDone && DayKey.key(for: $0.doneAt ?? .distantPast) == DayKey.key(for: model.now) }
            ForEach(open.prefix(7)) { task in
                TaskRow(task: task, isCurrent: model.session?.taskID == task.id)
            }
            if open.count > 7 {
                Text("and \(open.count - 7) more")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 26)
            }
            ForEach(done.prefix(3)) { task in
                TaskRow(task: task, isCurrent: false)
            }
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
                TextField("Add for later", text: $newTask)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        model.addTask(newTask)
                        newTask = ""
                    }
            }
            .padding(.vertical, 3)
        }
    }

    // MARK: Ledger

    private var ledger: some View {
        let day = model.today
        let budget = Double(model.settings.scrollBudgetMinutes) * 60
        return VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Today")
            HStack(alignment: .top, spacing: 0) {
                Stat(value: Fmt.span(day.focusSeconds), label: "focused", tint: Tint.focus)
                Stat(value: Fmt.span(day.scrollSeconds), label: "of \(Fmt.span(budget)) scroll",
                     tint: day.scrollSeconds >= budget ? Tint.scroll : nil)
                Stat(value: "\(day.pulledBack)", label: "pulled back", tint: nil)
                Stat(value: "\(day.passes.count)", label: day.passes.count == 1 ? "pass" : "passes", tint: nil)
            }
            DayStrip(segments: day.segments, dayStart: DayKey.start(for: model.now), now: model.now)

            if day.walls + day.urgesSurfed > 0 {
                Label(urgeLine(day), systemImage: "water.waves")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !day.passes.isEmpty {
                DisclosureGroup(isExpanded: $showPasses) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(day.passes.suffix(6)) { pass in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(pass.at, style: .time)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                Text("\(Fmt.siteName(pass.site)): “\(pass.reason)”")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("What you said to get through")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow("This week")
                    Text(Fmt.span(model.weekBars.map(\.focus).reduce(0, +)) + " focused")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                WeekBars(days: model.weekBars)
                    .frame(width: 150)
            }
            .padding(.top, 2)
        }
    }

    private func urgeLine(_ day: DayLog) -> String {
        var parts: [String] = []
        if day.walls > 0 { parts.append("Wall held \(day.walls)×") }
        if day.urgesSurfed > 0 { parts.append("\(day.urgesSurfed) urge\(day.urgesSurfed == 1 ? "" : "s") ridden out") }
        return parts.joined(separator: " · ")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                model.urgeButton()
            } label: {
                Label("Urge button", systemImage: "water.waves")
            }
            .help("Feeling the pull? Ride it out for 90 seconds. ⌃⌥U from anywhere.")
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            .accessibilityLabel("Settings")
            Button(action: quit) {
                Image(systemName: "power")
            }
            .help("Quit Tether")
            .accessibilityLabel("Quit Tether")
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }
}

private struct Stat: View {
    var value: String
    var label: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint ?? .primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SessionCard: View {
    @Environment(AppModel.self) private var model
    var session: FocusSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow(session.isOvertime ? "Time's up" : "Tethered to")
                    Text(session.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    if let step = session.firstStep, !step.isEmpty {
                        Label(step, systemImage: "arrow.turn.down.right")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                ZStack {
                    ProgressRing(progress: session.progress, lineWidth: 4)
                    Text(session.isOvertime ? "+" + Fmt.clock(-session.remainingSeconds) : Fmt.clock(session.remainingSeconds))
                        .font(.caption.weight(.medium).monospacedDigit())
                }
                .frame(width: 58, height: 58)
            }
            HStack(spacing: 8) {
                Button {
                    model.endSession(completed: true)
                } label: {
                    Label("Done", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("+10 min") { model.extend(minutes: 10) }
                Button("Stop") { model.endSession(completed: false) }
                    .help("End the session without finishing the task")
            }
            .controlSize(.large)
        }
        .padding(14)
        .background(Tint.focus.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct TaskRow: View {
    @Environment(AppModel.self) private var model
    var task: TaskItem
    var isCurrent: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.toggleDone(task.id)
            } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.isDone ? AnyShapeStyle(Tint.focus) : AnyShapeStyle(.tertiary))
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.isDone ? "Mark not done" : "Mark done")

            Text(task.title)
                .lineLimit(1)
                .strikethrough(task.isDone)
                .foregroundStyle(task.isDone ? .secondary : .primary)
            Spacer(minLength: 4)

            if isCurrent {
                Image(systemName: "smallcircle.filled.circle")
                    .foregroundStyle(Tint.focus)
                    .help("You're tethered to this")
            } else if hovering, !task.isDone {
                Button {
                    model.start(title: task.title, taskID: task.id)
                    model.ui?.closePopover()
                } label: {
                    Image(systemName: "play.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Tether to this for \(model.settings.defaultSessionMinutes) minutes")
            } else if task.focusSeconds >= 60 {
                Text(Fmt.span(task.focusSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if !task.isDone {
                Button("Tether to This") {
                    model.start(title: task.title, taskID: task.id)
                    model.ui?.closePopover()
                }
            }
            Button(task.isDone ? "Mark as Not Done" : "Mark as Done") { model.toggleDone(task.id) }
            Divider()
            Button("Delete", role: .destructive) { model.deleteTask(task.id) }
        }
    }
}
