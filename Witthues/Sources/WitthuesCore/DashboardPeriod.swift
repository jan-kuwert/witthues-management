import Foundation

/// Time spans the dashboard can show. `custom` uses dates the user picks.
public enum DashboardPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case thisMonth, lastMonth, last12Months, thisQuarter, lastQuarter, thisYear, lastYear, all, custom

    public var id: Self { self }

    public var label: String {
        switch self {
        case .thisMonth: return "Dieser Monat"
        case .lastMonth: return "Letzter Monat"
        case .last12Months: return "Letzte 12 Monate"
        case .thisQuarter: return "Dieses Quartal"
        case .lastQuarter: return "Letztes Quartal"
        case .thisYear: return "Dieses Jahr"
        case .lastYear: return "Letztes Jahr"
        case .all: return "Gesamt"
        case .custom: return "Eigener Zeitraum"
        }
    }

    /// Start (inclusive) and end (exclusive) of the span; nil for `all` and `custom`, which depend on data or user input.
    public func interval(now: Date = Date(), calendar cal: Calendar = .current) -> DateInterval? {
        func month(_ offset: Int) -> DateInterval {
            cal.dateInterval(of: .month, for: cal.date(byAdding: .month, value: offset, to: now)!)!
        }
        switch self {
        case .thisMonth: return month(0)
        case .lastMonth: return month(-1)
        case .last12Months:
            // The current month and the eleven before it.
            let end = month(0).end
            return DateInterval(start: cal.date(byAdding: .month, value: -12, to: end)!, end: end)
        case .thisQuarter, .lastQuarter:
            // Calendar quarters; Foundation's .quarter component is not reliable, so they are computed from months.
            var year = cal.component(.year, from: now)
            var first = (cal.component(.month, from: now) - 1) / 3 * 3 + 1
            if self == .lastQuarter {
                first -= 3
                if first < 1 { first += 12; year -= 1 }
            }
            let start = cal.date(from: DateComponents(year: year, month: first, day: 1))!
            return DateInterval(start: start, end: cal.date(byAdding: .month, value: 3, to: start)!)
        case .thisYear: return cal.dateInterval(of: .year, for: now)
        case .lastYear: return cal.dateInterval(of: .year, for: cal.date(byAdding: .year, value: -1, to: now)!)
        case .all, .custom: return nil
        }
    }
}
