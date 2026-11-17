import SwiftUI
import EventKit

/// iPod Extras-style calendar: month grid with today ringed, wheel moves the
/// selected day, prev/next jump months; events for the selected day come
/// read-only from EventKit.
struct CalendarScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings

    /// The day under the cursor (starts at today). Drives everything at
    /// once: the highlighted month, the ringed/selected day cell, and the
    /// event strip below the grid.
    @State private var selected = Date()
    /// Events on `selected` (read-only), soonest first; reloaded whenever
    /// the selected day changes (see the `.task(id:)` in `body`).
    @State private var events: [EKEvent] = []
    /// True when EventKit access was refused; the strip shows a hint
    /// instead of events.
    @State private var accessDenied = false

    /// EventKit database handle; access is requested on each day-load.
    private let store = EKEventStore()
    /// The user's calendar, captured once; every date computation in this
    /// screen goes through it so locale (first weekday, month boundaries)
    /// is honored consistently.
    private let cal = Calendar.current

    /// Month header, weekday labels, day grid, and the event strip.
    var body: some View {
        VStack(spacing: 4) {
            header
            weekdayRow
            monthGrid
            eventStrip
        }
        .padding(.horizontal, 6)
        .padding(.top, 3)
        .onWheel { handle($0) }
        .task(id: cal.startOfDay(for: selected)) { await loadEvents() }
    }

    // MARK: Pieces

    /// Month title flanked by prev/next-month chevron buttons; the arrows
    /// keep the day-of-month when the target month has one.
    private var header: some View {
        HStack {
            Button {
                selected = cal.date(byAdding: .month, value: -1, to: selected) ?? selected
            } label: {
                Image(systemName: "chevron.left").font(Theme.font(12, .bold))
            }
            .buttonStyle(.plain)

            Spacer()
            Text(monthTitle)
                .font(Theme.barTitle(15))
            Spacer()

            Button {
                selected = cal.date(byAdding: .month, value: 1, to: selected) ?? selected
            } label: {
                Image(systemName: "chevron.right").font(Theme.font(12, .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Theme.ink)
    }

    /// "November 2026"-style title for the selected month.
    private var monthTitle: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: selected)
    }

    /// S M T W T F S column labels above the grid.
    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(["S", "M", "T", "W", "T", "F", "S"].indices, id: \.self) { i in
                Text(["S", "M", "T", "W", "T", "F", "S"][i])
                    .font(Theme.font(10.5, .bold))
                    .foregroundStyle(Theme.inkDim)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// The month rendered as week rows of day cells; blank cells pad the
    /// partial first and last weeks so day numbers stay date-aligned.
    private var monthGrid: some View {
        let days = gridDays(for: selected)
        return VStack(spacing: 2) {
            ForEach(0..<(days.count / 7), id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        let idx = row * 7 + col
                        if idx < days.count, let day = days[idx] {
                            dayCell(day)
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }

    /// One day number: gradient highlight when selected, blue ring when
    /// it is today, and a tap target shaped to the whole cell.
    private func dayCell(_ day: Date) -> some View {
        let num = cal.component(.day, from: day)
        let isSelected = cal.isDate(day, inSameDayAs: selected)
        let isToday = cal.isDateInToday(day)
        return Text("\(num)")
            .font(Theme.font(13, isSelected ? .bold : .medium))
            .foregroundStyle(isSelected ? Color.white : (isToday ? Theme.selMid : Theme.ink))
            .frame(maxWidth: .infinity, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? AnyShapeStyle(SelectionGradient()) : AnyShapeStyle(Color.clear))
            )
            .overlay {
                if isToday && !isSelected {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Theme.selMid, lineWidth: 1.2)
                }
            }
            .contentShape(Rectangle())
    }

    /// Up to three events for the selected day plus an "+N more" overflow
    /// line, each event prefixed by a dot in its calendar's color. Shows
    /// the access-denied hint or "No events" when appropriate.
    @ViewBuilder
    private var eventStrip: some View {
        VStack(alignment: .leading, spacing: 2) {
            Rectangle().fill(Color.black.opacity(0.12)).frame(height: 0.7).padding(.horizontal, 2)
            if accessDenied {
                Text("Allow calendar access in Settings to see events.")
                    .font(Theme.font(11.5, .medium))
                    .foregroundStyle(Theme.inkDim)
            } else if events.isEmpty {
                Text("No events")
                    .font(Theme.font(11.5, .medium))
                    .foregroundStyle(Theme.inkDim)
            } else {
                ForEach(events.prefix(3), id: \.eventIdentifier) { e in
                    HStack(spacing: 5) {
                        Circle().fill(Color(cgColor: e.calendar.cgColor)).frame(width: 6, height: 6)
                        Text(eventText(e))
                            .font(Theme.font(12, .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                    }
                }
                if events.count > 3 {
                    Text("+ \(events.count - 3) more")
                        .font(Theme.font(11, .medium))
                        .foregroundStyle(Theme.inkDim)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    /// "9:30  Title" label for one event ("all-day" has no time).
    private func eventText(_ e: EKEvent) -> String {
        let time = e.isAllDay ? "all-day" : TimeFormat.clock(e.startDate)
        return "\(time)  \(e.title ?? "")"
    }

    // MARK: Data

    /// Dates laid out in a 7-column grid; nil = leading/trailing blank cell.
    ///
    /// The leading blank count is the first weekday's offset from the
    /// calendar's `firstWeekday` (locale-dependent, e.g. Sunday vs Monday
    /// starts), wrapped mod 7 so it works for any locale; trailing nils
    /// complete the final week, keeping the cell count a multiple of 7 so
    /// the grid renders as clean week rows.
    private func gridDays(for date: Date) -> [Date?] {
        guard let interval = cal.dateInterval(of: .month, for: date) else { return [] }
        let firstWeekday = cal.component(.weekday, from: interval.start)
        let leading = (firstWeekday - cal.firstWeekday + 7) % 7
        let dayCount = cal.range(of: .day, in: .month, for: date)?.count ?? 30
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for d in 0..<dayCount {
            cells.append(cal.date(byAdding: .day, value: d, to: interval.start))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    /// Loads the events for the selected day. Full access is requested on
    /// every load — once granted the request resolves immediately without
    /// a prompt, and a later revocation shows up as the denied hint
    /// instead of a stale list. Events come from a synchronous EventKit
    /// query on a one-day predicate, sorted by start time.
    ///
    /// Concept: EventKit → docs/concepts/eventkit.md
    private func loadEvents() async {
        let start = cal.startOfDay(for: selected)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return }
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        accessDenied = !granted
        guard granted else { events = []; return }
        let pred = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = (store.events(matching: pred) ?? []).sorted { $0.startDate < $1.startDate }
    }

    // MARK: Input

    /// Wheel input: each tick moves the selection one day — crossing a
    /// month boundary shifts the whole grid too, since `selected` drives
    /// both; MENU pops back.
    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            if let next = cal.date(byAdding: .day, value: d, to: selected) {
                selected = next
                WheelFeedback.tick(dir: d)
            }
        case .menu:
            model.pop()
        default:
            break
        }
    }
}
