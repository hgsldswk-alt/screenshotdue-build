import Foundation

struct CivilDay: Codable, Hashable, Comparable, Sendable {
    var year: Int
    var month: Int
    var day: Int

    static func calendar(zone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    init(_ date: Date, calendar: Calendar = CivilDay.calendar()) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        year = parts.year ?? 2001
        month = parts.month ?? 1
        day = parts.day ?? 1
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    func date(in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    func adding(_ days: Int, in calendar: Calendar) -> CivilDay {
        let start = date(in: calendar)
        return CivilDay(calendar.date(byAdding: .day, value: days, to: start) ?? start, calendar: calendar)
    }
}

struct DueDate: Codable, Equatable {
    var day: CivilDay
    var hour = 9
    var minute = 0

    static func best(on day: CivilDay, now: Date = .now, calendar: Calendar = CivilDay.calendar()) -> DueDate {
        let usual = DueDate(day: day)
        guard day == CivilDay(now, calendar: calendar), usual.date(in: calendar) < now else { return usual }
        let nextHour = calendar.component(.hour, from: now) + 1
        return nextHour < 24 ? DueDate(day: day, hour: nextHour) : usual
    }

    func date(in calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: day.date(in: calendar))
        guard let next = calendar.nextDate(after: start.addingTimeInterval(-1),
                                           matching: DateComponents(hour: hour, minute: minute, second: 0),
                                           matchingPolicy: .nextTime,
                                           repeatedTimePolicy: .first),
              CivilDay(next, calendar: calendar) == day else { return start }
        return next
    }
}

enum RepeatRule: String, CaseIterable, Codable, Identifiable {
    case never, daily, weekly
    var id: Self { self }
    var title: String { L.t("repeat." + rawValue) }
    var step: Int { self == .weekly ? 7 : 1 }
}
