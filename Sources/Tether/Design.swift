import AppKit
import SwiftUI
import TetherCore

enum Tint {
    static let focus = Color.accentColor
    static let scroll = Color.orange
}

private struct FlatSurfacesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by the snapshot tool: Liquid Glass only composites on a real display, so offscreen
    /// renders swap it for a plain fill.
    var flatSurfaces: Bool {
        get { self[FlatSurfacesKey.self] }
        set { self[FlatSurfacesKey.self] = newValue }
    }
}

private struct Surface<S: Shape>: ViewModifier {
    @Environment(\.flatSurfaces) private var flat
    var shape: S

    func body(content: Content) -> some View {
        if flat {
            content
                .background(Color(nsColor: .underPageBackgroundColor), in: shape)
                .overlay(shape.stroke(.separator))
        } else {
            content.glassEffect(.regular, in: shape)
        }
    }
}

extension View {
    /// A floating Liquid Glass surface.
    func surface(_ shape: some Shape) -> some View { modifier(Surface(shape: shape)) }
}

/// Behind-window blur, for surfaces that sit over whatever the user was looking at.
struct Backdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .fullScreenUI

    func makeNSView(context: NSViewRepresentableContext<Backdrop>) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: NSViewRepresentableContext<Backdrop>) { v.material = material }
}

/// Lets a borderless panel be dragged by this area.
struct DragHandle: NSViewRepresentable {
    final class Handle: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: NSViewRepresentableContext<DragHandle>) -> Handle { Handle() }
    func updateNSView(_ v: Handle, context: NSViewRepresentableContext<DragHandle>) {}
}

struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 3
    var tint: Color = Tint.focus

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)
        }
    }
}

/// Small uppercase label used above sections and on the gate.
struct Eyebrow: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

/// The day from 4 AM to 4 AM, with focus and scroll time laid along it.
struct DayStrip: View {
    var segments: [Segment]
    var dayStart: Date
    var now: Date

    var body: some View {
        VStack(spacing: 3) {
            Canvas { ctx, size in
                let total = 86400.0
                let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: size.height / 2)
                ctx.fill(track, with: .color(.primary.opacity(0.08)))
                ctx.clip(to: track)
                for seg in segments {
                    let a = max(0, seg.start.timeIntervalSince(dayStart)) / total
                    let b = min(total, seg.end.timeIntervalSince(dayStart)) / total
                    guard b > a else { continue }
                    // Never thinner than a point and a half, or a five-minute slip would be invisible.
                    let rect = CGRect(x: a * size.width, y: 0, width: max(1.5, (b - a) * size.width), height: size.height)
                    ctx.fill(Path(rect), with: .color(seg.kind == .focus ? Tint.focus : Tint.scroll))
                }
                let x = min(1, max(0, now.timeIntervalSince(dayStart) / total)) * size.width
                ctx.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.primary.opacity(0.55)))
            }
            .frame(height: 10)

            GeometryReader { geo in
                ForEach([4, 8, 12, 16, 20], id: \.self) { h in
                    Text(label(h))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .position(x: geo.size.width * Double(h) / 24, y: 6)
                }
            }
            .frame(height: 12)
        }
        .accessibilityElement()
        .accessibilityLabel("Timeline of today's focus and scrolling")
    }

    /// Hour label for a mark `offset` hours after the 4 AM rollover.
    private func label(_ offset: Int) -> String {
        let hour = (DayKey.rolloverHour + offset) % 24
        if hour == 0 { return "12a" }
        if hour == 12 { return "12p" }
        return hour < 12 ? "\(hour)a" : "\(hour - 12)p"
    }
}

/// Seven days of focused time, today last.
struct WeekBars: View {
    var days: [(label: String, focus: Double, isToday: Bool)]

    var body: some View {
        let peak = max(days.map(\.focus).max() ?? 0, 30 * 60)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(day.isToday ? AnyShapeStyle(Tint.focus) : AnyShapeStyle(.tertiary))
                        .frame(height: max(2, 34 * day.focus / peak))
                        .frame(maxHeight: 34, alignment: .bottom)
                    Text(day.label)
                        .font(.system(size: 9, weight: day.isToday ? .semibold : .regular))
                        .foregroundStyle(day.isToday ? .secondary : .tertiary)
                }
                .frame(maxWidth: .infinity)
                .help("\(Fmt.span(day.focus)) focused")
            }
        }
    }
}

extension AppModel {
    var weekBars: [(label: String, focus: Double, isToday: Bool)] {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return (0..<7).reversed().map { back in
            let date = now.addingTimeInterval(-Double(back) * 86400)
            let anchor = DayKey.start(for: date)
            let weekday = Calendar.current.component(.weekday, from: anchor)
            return (symbols[weekday - 1], state.day(date).focusSeconds, back == 0)
        }
    }
}
