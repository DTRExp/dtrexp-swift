// Proleptic-Gregorian civil-date arithmetic, independent of Foundation.Calendar.
//
// The DTRExp evaluation model (spec §9.3) is built on *naive local wall-clock*
// arithmetic: calendar-period cadence windows and bounds spans are naive local
// intervals, never resolved to instants. Foundation.Calendar's arithmetic is
// Date-(instant-)based and DST-adjusting, which is exactly the wrong model, so
// all calendar math here is integer math on day numbers (days since 1970-01-01).

let msPerSecond = 1000
let msPerMinute = 60_000
let msPerHour = 3_600_000
let msPerDay = 86_400_000
let msPerWeek = 604_800_000

@inline(__always)
func floorDiv(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    return (a % b != 0 && (a ^ b) < 0) ? q - 1 : q
}

@inline(__always)
func floorMod(_ a: Int, _ b: Int) -> Int {
    let r = a % b
    return r < 0 ? r + b : r
}

func isLeapYear(_ y: Int) -> Bool {
    y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
}

func daysInMonth(_ y: Int, _ m: Int) -> Int {
    switch m {
    case 1, 3, 5, 7, 8, 10, 12: return 31
    case 4, 6, 9, 11: return 30
    default: return isLeapYear(y) ? 29 : 28
    }
}

func daysInYear(_ y: Int) -> Int { isLeapYear(y) ? 366 : 365 }

/// Days since 1970-01-01 (Howard Hinnant's algorithm).
func daysFromCivil(_ y: Int, _ m: Int, _ d: Int) -> Int {
    let yy = y - (m <= 2 ? 1 : 0)
    let era = floorDiv(yy, 400)
    let yoe = yy - era * 400                                  // 0...399
    let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1  // 0...365
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy           // 0...146096
    return era * 146_097 + doe - 719_468
}

/// Inverse of `daysFromCivil`.
func civilFromDays(_ z0: Int) -> (y: Int, m: Int, d: Int) {
    let z = z0 + 719_468
    let era = floorDiv(z, 146_097)
    let doe = z - era * 146_097
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    return (m <= 2 ? y + 1 : y, m, d)
}

/// ISO weekday: 1 = Monday ... 7 = Sunday. 1970-01-01 was a Thursday (4).
func isoWeekday(fromDayNumber days: Int) -> Int {
    floorMod(days + 3, 7) + 1
}

/// Number of ISO weeks in ISO week-year `y` (52 or 53).
func weeksInISOYear(_ y: Int) -> Int {
    func p(_ y: Int) -> Int { floorMod(y + floorDiv(y, 4) - floorDiv(y, 100) + floorDiv(y, 400), 7) }
    return (p(y) == 4 || p(y - 1) == 3) ? 53 : 52
}

/// ISO week-year and week number for a civil date.
func isoWeek(_ y: Int, _ m: Int, _ d: Int) -> (weekYear: Int, week: Int) {
    let dayNumber = daysFromCivil(y, m, d)
    let doy = dayNumber - daysFromCivil(y, 1, 1) + 1
    let wd = isoWeekday(fromDayNumber: dayNumber)
    let woy = (doy - wd + 10) / 7
    if woy < 1 { return (y - 1, weeksInISOYear(y - 1)) }
    if woy > weeksInISOYear(y) { return (y + 1, 1) }
    return (y, woy)
}

/// A naive (zone-less) local date-time. `ms` of the time part is always 0 for
/// parsed literals; kept for uniform arithmetic.
struct NaiveDateTime: Equatable, Sendable {
    var year: Int
    var month: Int
    var day: Int
    var hour: Int = 0
    var minute: Int = 0
    var second: Int = 0

    /// Naive "epoch" milliseconds: the number this date-time would be as a UTC instant.
    var naiveMs: Int {
        daysFromCivil(year, month, day) * msPerDay
            + hour * msPerHour + minute * msPerMinute + second * msPerSecond
    }

    /// Adds calendar months with `constrain` overflow semantics (spec §9.2):
    /// a nonexistent day-of-month clamps to the last valid day.
    func addingMonthsConstrained(_ months: Int) -> NaiveDateTime {
        let total = year * 12 + (month - 1) + months
        let y = floorDiv(total, 12)
        let m = floorMod(total, 12) + 1
        var out = self
        out.year = y
        out.month = m
        out.day = min(day, daysInMonth(y, m))
        return out
    }
}
