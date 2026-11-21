import AppKit
import CadenzaCore

/// Practice statistics over the session archive: totals for today, this
/// week and all time, then one row per day for the last seven. The math is
/// plain calendar bucketing over the records the store already keeps.
@MainActor
enum PracticeStats {
    struct Day: Sendable, Equatable {
        let day: Date
        let seconds: Double
        let notes: Int
    }

    /// Sessions rolled up per calendar day, oldest day last of the result.
    static func dayTotals(_ sessions: [SessionRecord]) -> [Day] {
        var buckets: [Date: Day] = [:]
        let calendar = Calendar.current
        for session in sessions {
            let day = calendar.startOfDay(for: session.startedAt)
            var bucket = buckets[day] ?? Day(day: day, seconds: 0, notes: 0)
            bucket = Day(day: bucket.day, seconds: bucket.seconds + session.durationSeconds,
                         notes: bucket.notes + session.noteCount)
            buckets[day] = bucket
        }
        return buckets.values.sorted { $0.day < $1.day }
    }

    /// The sessions started since this week's Monday 00:00.
    static func weekSessions(_ sessions: [SessionRecord], now: Date = Date()) -> [SessionRecord] {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        components.weekday = 2 // Monday
        guard let monday = calendar.date(from: components) ?? calendar.startOfWeek(for: now) else { return [] }
        return sessions.filter { $0.startedAt >= monday }
    }

    static func timeString(_ seconds: Double) -> String {
        let total = Int(seconds)
        if total >= 3600 { return "\(total / 3600) h \(total / 60 % 60) min" }
        return "\(total / 60) min"
    }

    /// The line the practice summary shows: today's total plus the week's.
    static func summaryLine(_ sessions: [SessionRecord], now: Date = Date()) -> String {
        let today = dayTotals(sessions.filter { Calendar.current.isDateInToday($0.startedAt) })
        let week = weekSessions(sessions, now: now)
        let weekSeconds = week.reduce(0.0) { $0 + $1.durationSeconds }
        let weekNotes = week.reduce(0) { $0 + $1.noteCount }
        guard let today = today.last else {
            return week.isEmpty ? "No practice recorded yet"
                : "This week · \(timeString(weekSeconds)) · \(weekNotes) notes"
        }
        return "Today · \(timeString(today.seconds)) · \(today.notes) notes · week \(timeString(weekSeconds)), \(weekNotes) notes"
    }
}

extension Calendar {
    /// The Monday 00:00 of the week that contains date. A plain fallback of
    /// startOfDay when the week math refuses.
    func startOfWeek(for date: Date) -> Date? {
        guard let week = dateInterval(of: .weekOfYear, for: date) else { return nil }
        return startOfDay(for: week.start)
    }
}

/// The statistics window: a small paper sheet with the totals and the
/// week's days, opened from the menu lens.
@MainActor
final class StatsController: NSObject {
    private var window: NSWindow?

    func show(relativeTo parent: NSWindow?, sessions: [SessionRecord]) {
        let size = NSSize(width: 380, height: 336)
        let window: NSWindow
        if let existing = self.window {
            window = existing
            window.contentView = content(sessions: sessions, size: size)
        } else {
            window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false)
            // the controller owns this window; AppKit releasing it on close
            // as well would leave a dangling reference behind
            window.isReleasedWhenClosed = false
            window.title = "Statistics"
            window.contentView = content(sessions: sessions, size: size)
            if let parent {
                let frame = window.frame
                window.setFrameOrigin(NSPoint(
                    x: parent.frame.midX - frame.width / 2,
                    y: parent.frame.midY - frame.height / 2))
            }
        }
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// The statistics section built for the app's overlay card.
    func overlayContent(sessions: [SessionRecord],
                        size: NSSize = NSSize(width: 440, height: 400)) -> NSView {
        content(sessions: sessions, size: size)
    }

    private func content(sessions: [SessionRecord], size: NSSize) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.autoresizingMask = [.width, .height]
        let paper = PaperView()
        paper.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(paper)

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 12
        rows.edgeInsets = NSEdgeInsets(top: 26, left: 30, bottom: 26, right: 30)
        rows.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(rows)

        func large(_ text: String, weight: NSFont.Weight = .semibold) -> NSTextField {
            makeInkLabel(text, font: .systemFont(ofSize: 19, weight: weight), color: PaperTheme.ink)
        }
        func caption(_ text: String) -> NSTextField {
            makeInkLabel(text, font: .systemFont(ofSize: 11, weight: .medium), color: PaperTheme.secondaryInk)
        }
        func line(_ text: String) -> NSTextField {
            makeInkLabel(text, font: .systemFont(ofSize: 13, weight: .regular), color: PaperTheme.ink)
        }
        func hairline() -> NSView {
            let view = NSView()
            view.translatesAutoresizingMaskIntoConstraints = false
            view.heightAnchor.constraint(equalToConstant: 1).isActive = true
            view.wantsLayer = true
            view.layer?.backgroundColor = PaperTheme.hairline.cgColor
            return view
        }

        let week = PracticeStats.weekSessions(sessions)
        let weekSeconds = week.reduce(0.0) { $0 + $1.durationSeconds }
        let weekNotes = week.reduce(0) { $0 + $1.noteCount }
        let totalSeconds = sessions.reduce(0.0) { $0 + $1.durationSeconds }
        let totalNotes = sessions.reduce(0) { $0 + $1.noteCount }

        rows.addArrangedSubview(makeInkLabel(
            "Statistics",
            font: PaperTheme.displaySerif(26, weight: .semibold),
            color: PaperTheme.ink
        ))
        rows.addArrangedSubview(caption("This week"))
        rows.addArrangedSubview(large("\(PracticeStats.timeString(weekSeconds)) · \(weekNotes) notes"))
        rows.addArrangedSubview(caption("All time"))
        rows.addArrangedSubview(line("\(PracticeStats.timeString(totalSeconds)) · \(totalNotes) notes in \(sessions.count) sessions"))
        rows.addArrangedSubview(hairline())

        let formatter = SessionStamp.day
        let days = PracticeStats.dayTotals(sessions).suffix(7)
        if days.isEmpty {
            rows.addArrangedSubview(line("No practice recorded yet"))
        } else {
            for day in days {
                rows.addArrangedSubview(line(
                    "\(formatter.string(from: day.day))  ·  \(PracticeStats.timeString(day.seconds))  ·  \(day.notes) notes"))
            }
        }

        NSLayoutConstraint.activate([
            paper.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            paper.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            paper.topAnchor.constraint(equalTo: root.topAnchor),
            paper.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            rows.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            rows.topAnchor.constraint(equalTo: root.topAnchor),
        ])
        return root
    }
}
