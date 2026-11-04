import SwiftUI
import EventKit

/// iPod Extras-style calendar: month grid with today ringed, wheel moves the
/// selected day, prev/next jump months; events for the selected day come
/// read-only from EventKit.
struct CalendarScreen: View {
    @Environment(AppModel.self) private var model
    @EnvironmentObject private var settings: AppSettings

    @State private var selected = Date()
    @State private var events: [EKEvent] = []
    @State private var accessDenied = false

    private let store = EKEventStore()
    private let cal = Calendar.current

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

    private var header: some View {
        HStack {
            Button {
                selected = cal.date(byAdding: .month, value: -1, to: selected) ?? selected
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(.plain)

            Spacer()
            Text(monthTitle)
                .font(Theme.barTitle(15))
            Spacer()

            Button {
                selected = cal.date(byAdding: .month, value: 1, to: selected) ?? selected
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Theme.ink)
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: selected)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            ForEach(["S", "M", "T", "W", "T", "F", "S"].indices, id: \.self) { i in
                Text(["S", "M", "T", "W", "T", "F", "S"][i])
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Theme.inkDim)
                    .frame(maxWidth: .infinity)
            }
        }
    }

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

    private func dayCell(_ day: Date) -> some View {
        let num = cal.component(.day, from: day)
        let isSelected = cal.isDate(day, inSameDayAs: selected)
        let isToday = cal.isDateInToday(day)
        return Text("\(num)")
            .font(.system(size: 13, weight: isSelected ? .bold : .medium))
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

    @ViewBuilder
    private var eventStrip: some View {
        VStack(alignment: .leading, spacing: 2) {
            Rectangle().fill(Color.black.opacity(0.12)).frame(height: 0.7).padding(.horizontal, 2)
            if accessDenied {
                Text("Allow calendar access in Settings to see events.")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.inkDim)
            } else if events.isEmpty {
                Text("No events")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.inkDim)
            } else {
                ForEach(events.prefix(3), id: \.eventIdentifier) { e in
                    HStack(spacing: 5) {
                        Circle().fill(Color(cgColor: e.calendar.cgColor)).frame(width: 6, height: 6)
                        Text(eventText(e))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                    }
                }
                if events.count > 3 {
                    Text("+ \(events.count - 3) more")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.inkDim)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    private func eventText(_ e: EKEvent) -> String {
        let time = e.isAllDay ? "all-day" : TimeFormat.clock(e.startDate)
        return "\(time)  \(e.title ?? "")"
    }

    // MARK: Data

    private var gridDays: String { "" } // placeholder to keep grouping obvious

    /// Dates laid out in a 7-column grid; nil = leading/trailing blank cell.
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

    private func handle(_ event: ControlEvent) {
        switch event {
        case .tick(let d):
            if let next = cal.date(byAdding: .day, value: d, to: selected) {
                selected = next
                WheelFeedback.tick(dir: d)
            }
        case .prev:
            selected = cal.date(byAdding: .month, value: -1, to: selected) ?? selected
        case .next:
            selected = cal.date(byAdding: .month, value: 1, to: selected) ?? selected
        case .menu:
            model.pop()
        default:
            break
        }
    }
}
