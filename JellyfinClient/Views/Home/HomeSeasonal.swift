import Foundation

/// Rows for holidays and events (Easter, Halloween, Christmas, New Year's Eve, …). Each has a date
/// window; while it's open the row sits at the top of the Seerr categories (not shuffled), and it
/// disappears by itself afterwards.
enum HomeSeasonal {
    /// "Today", overridable in debug builds with JF_DEBUG_DATE=2026-12-20 to test the windows.
    static var today: Date {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["JF_DEBUG_DATE"],
           let date = try? Date(value + "T12:00:00Z", strategy: .iso8601) {
            return date
        }
        #endif
        return .now
    }

    /// The event rows open on `date`, in a fixed order, each with the last day it's shown.
    static func active(on date: Date = today) -> [HomeCategory] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let year = calendar.component(.year, from: date)
        let today = calendar.startOfDay(for: date)
        func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? today
        }
        func shift(_ date: Date, days: Int) -> Date { calendar.date(byAdding: .day, value: days, to: date) ?? date }

        var rows: [HomeCategory] = []
        /// Adds the rows when today is within start...end (inclusive).
        func add(_ start: Date, _ end: Date, _ categories: [HomeCategory]) {
            guard start <= today, today <= end else { return }
            rows += categories.map { category in
                var category = category
                category.until = end
                return category
            }
        }

        let popular = ("sortBy", "popularity.desc")
        let easter = easterSunday(year: year, calendar: calendar)

        // New Year's Eve: 27 December to 1 January (the window spans the turn of the year).
        let newYear = [HomeCategory(id: "event-newyear", title: "New Year's Eve & New Year", queries: [
            .init(type: .movie, filters: [popular, ("voteCountGte", "50")], keyword: "new year's eve"),
            .init(type: .movie, filters: [popular, ("genre", "35"), ("voteCountGte", "500")], keyword: "party")])]
        add(day(year, 12, 27), day(year + 1, 1, 1), newYear)
        add(day(year - 1, 12, 27), day(year, 1, 1), newYear)

        // Valentine's Day.
        add(day(year, 2, 7), day(year, 2, 14), [HomeCategory(id: "event-valentine", title: "Valentine's Day: Movies to Fall in Love", queries: [
            .init(type: .movie, filters: [popular, ("voteCountGte", "50")], keyword: "valentine's day"),
            .init(type: .movie, filters: [popular, ("genre", "10749"), ("voteCountGte", "1500")])])])

        // Carnival: from Weiberfastnacht (Thursday before) to Ash Wednesday.
        add(shift(easter, days: -52), shift(easter, days: -46), [HomeCategory(id: "event-carnival", title: "Carnival: Comedies for the Crazy Days", queries: [
            .init(type: .movie, filters: [popular, ("genre", "35"), ("voteCountGte", "1500")]),
            .init(type: .movie, filters: [popular, ("genre", "35"), ("language", "de"), ("voteCountGte", "100")])])])

        // Easter: Holy Week to Easter Monday.
        add(shift(easter, days: -6), shift(easter, days: 1), [
            HomeCategory(id: "event-easter", title: "Happy Easter", queries: [
                .init(type: .movie, filters: [popular, ("voteCountGte", "20")], keyword: "easter"),
                .init(type: .movie, filters: [popular, ("genre", "10751"), ("voteCountGte", "1500")])]),
            HomeCategory(id: "event-easter-bible", title: "Easter: The Great Bible Epics", queries: [
                .init(type: .movie, filters: [popular, ("voteCountGte", "50")], keyword: "jesus christ")]),
        ])

        // Star Wars Day.
        add(day(year, 5, 1), day(year, 5, 4), [HomeCategory(id: "event-may4", title: "May the 4th: Adventures in Space", queries: [
            .init(type: .movie, filters: [popular, ("studio", "1")]),
            .init(type: .movie, filters: [popular, ("voteCountGte", "500")], keyword: "space opera")])])

        // Pride Month.
        add(day(year, 6, 1), day(year, 6, 30), [HomeCategory(id: "event-pride", title: "Pride Month", queries: [
            .init(type: .movie, filters: [popular, ("voteCountGte", "200")], keyword: "lgbt"),
            .init(type: .tv, filters: [popular, ("voteCountGte", "50")], keyword: "lgbt")])])

        // Summer holidays.
        add(day(year, 7, 1), day(year, 8, 31), [HomeCategory(id: "event-summer", title: "Summer, Sun, Beach", queries: [
            .init(type: .movie, filters: [popular, ("voteCountGte", "200")], keyword: "summer"),
            .init(type: .movie, filters: [popular, ("voteCountGte", "200")], keyword: "beach")])])

        // German Unity Day and the fall of the Wall.
        let germanHistory = [HomeCategory(id: "event-germany", title: "The Wall, the GDR and German History", queries: [
            .init(type: .movie, filters: [popular, ("voteCountGte", "20")], keyword: "east germany"),
            .init(type: .movie, filters: [popular, ("voteCountGte", "20")], keyword: "berlin wall")])]
        add(day(year, 10, 1), day(year, 10, 3), germanHistory)
        add(day(year, 11, 7), day(year, 11, 9), germanHistory)

        // Halloween.
        add(day(year, 10, 15), day(year, 10, 31), [
            HomeCategory(id: "event-halloween", title: "Halloween Horror", queries: [
                .init(type: .movie, filters: [popular, ("genre", "27"), ("voteCountGte", "200")], keyword: "halloween")]),
            HomeCategory(id: "event-halloween-family", title: "Halloween for the Whole Family", queries: [
                .init(type: .movie, filters: [popular, ("genre", "10751"), ("voteCountGte", "100")], keyword: "halloween")]),
        ])

        // Christmas: Christmas movies from late November, more rows in December.
        add(day(year, 11, 25), day(year, 12, 26), [HomeCategory(id: "event-christmas", title: "Christmas Movies", queries: [
            .init(type: .movie, filters: [popular, ("voteCountGte", "300")], keyword: "christmas"),
            .init(type: .tv, filters: [popular, ("voteCountGte", "30")], keyword: "christmas")])])
        add(day(year, 12, 1), day(year, 12, 26), [
            HomeCategory(id: "event-christmas-family", title: "Christmas with the Family", queries: [
                .init(type: .movie, filters: [popular, ("genre", "10751"), ("voteCountGte", "100")], keyword: "christmas")]),
            HomeCategory(id: "event-christmas-romance", title: "Cozy Christmas Romances", queries: [
                .init(type: .movie, filters: [popular, ("genre", "10749"), ("voteCountGte", "30")], keyword: "christmas")]),
        ])

        return rows
    }

    /// Easter Sunday (Gregorian calendar, anonymous algorithm).
    static func easterSunday(year: Int, calendar: Calendar) -> Date {
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .now
    }
}
