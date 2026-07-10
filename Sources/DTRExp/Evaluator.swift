import Foundation

// Coverage evaluation (spec §9). One calendar-field extraction per instant,
// then per-component integer tests.
//
// Foundation is used for exactly one thing: `TimeZone.secondsFromGMT(for:)`,
// i.e. the IANA offset of an absolute instant. All calendar arithmetic is the
// naive civil math in Civil.swift, because the spec's local-time model (§9.3)
// works on naive wall-clock intervals that must never be resolved to instants.

/// The calendar fields of one instant in one evaluation zone (spec §9 step 1).
struct Fields {
    let epochMs: Int      // absolute instant
    let naiveMs: Int      // local wall-clock as naive epoch ms
    let year: Int
    let quarter: Int
    let month: Int
    let day: Int
    let dayOfQuarter: Int
    let dayOfYear: Int
    let weekday: Int      // ISO 1–7
    let weekYear: Int
    let week: Int
    let hour: Int
    let minute: Int
    let second: Int
    let msOfDay: Int
    let daysInMonthHere: Int
    let daysInQuarterHere: Int
    let daysInYearHere: Int
    let weeksInWeekYearHere: Int

    init(instant: Date, timeZone: TimeZone) {
        let epochMs = Int((instant.timeIntervalSince1970 * 1000).rounded())
        let offsetSeconds = timeZone.secondsFromGMT(for: instant)
        let naiveMs = epochMs + offsetSeconds * 1000
        self.epochMs = epochMs
        self.naiveMs = naiveMs

        let dayNumber = floorDiv(naiveMs, msPerDay)
        let msOfDay = naiveMs - dayNumber * msPerDay
        let (y, mo, d) = civilFromDays(dayNumber)
        year = y
        month = mo
        day = d
        quarter = (mo - 1) / 3 + 1
        dayOfYear = dayNumber - daysFromCivil(y, 1, 1) + 1
        let qStartMonth = ((mo - 1) / 3) * 3 + 1
        let qStartDay = daysFromCivil(y, qStartMonth, 1)
        dayOfQuarter = dayNumber - qStartDay + 1
        let qEndDay = qStartMonth == 10 ? daysFromCivil(y + 1, 1, 1) : daysFromCivil(y, qStartMonth + 3, 1)
        daysInQuarterHere = qEndDay - qStartDay
        weekday = isoWeekday(fromDayNumber: dayNumber)
        (weekYear, week) = isoWeek(y, mo, d)
        weeksInWeekYearHere = weeksInISOYear(weekYear)
        daysInMonthHere = daysInMonth(y, mo)
        daysInYearHere = daysInYear(y)
        hour = msOfDay / msPerHour
        minute = (msOfDay / msPerMinute) % 60
        second = (msOfDay / msPerSecond) % 60
        self.msOfDay = msOfDay
    }
}

// MARK: - Selector matching

/// Tests a selector kind against a field value within an actual domain
/// `lo...hi` (spec §9 step 2). Negative values resolve as `hi + 1 + v`
/// against the actual parent instance; `*` is the domain edge in force.
func kindMatches(_ kind: SelectorKind, value v: Int, lo: Int, hi: Int) -> Bool {
    func resolve(_ raw: Int) -> Int { raw < 0 ? hi + 1 + raw : raw }
    func itemMatches(_ item: Item) -> Bool {
        switch item {
        case .single(let raw):
            return v == resolve(raw)
        case .range(let s, let e, let wraps):
            if wraps {
                // Literal non-negative endpoints; membership on the raw values.
                guard case .value(let sv) = s, case .value(let ev) = e else { return false }
                return v >= sv || v <= ev
            }
            let rs: Int
            switch s {
            case .star: rs = lo
            case .value(let raw): rs = resolve(raw)
            }
            let re: Int
            switch e {
            case .star: re = hi
            case .value(let raw): re = resolve(raw)
            }
            // An instance where the resolved start exceeds the resolved end
            // covers nothing there (spec §9.1).
            return rs <= v && v <= re
        }
    }
    switch kind {
    case .all:
        return true
    case .list(let items):
        return items.contains(where: itemMatches)
    case .exclusion(let items):
        return !items.contains(where: itemMatches)
    case .stride(let start, let end, let interval, let duration):
        let re: Int
        switch end {
        case nil: re = hi
        case .star: re = hi
        case .value(let raw): re = resolve(raw)
        }
        return v >= start && v <= re && (v - start) % interval < duration
    case .ordinal, .timeSpans:
        return false  // handled by dedicated paths
    }
}

func selectorMatches(_ sel: Selector, expr: Expression, fields f: Fields) -> Bool {
    switch sel.designator {
    case .time:
        guard case .timeSpans(let spans) = sel.kind else { return false }
        return spans.contains { f.msOfDay >= $0.startMs && f.msOfDay < $0.endMs }

    case .weekday:
        if case .ordinal(let weekdayRaw, let ord) = sel.kind {
            let wd = weekdayRaw < 0 ? 8 + weekdayRaw : weekdayRaw
            guard f.weekday == wd else { return false }
            let dayOfScope: Int
            let scopeLength: Int
            switch expr.ordinalScope {
            case .month:
                dayOfScope = f.day
                scopeLength = f.daysInMonthHere
            case .quarter:
                dayOfScope = f.dayOfQuarter
                scopeLength = f.daysInQuarterHere
            case .year:
                dayOfScope = f.dayOfYear
                scopeLength = f.daysInYearHere
            }
            if ord > 0 {
                return (dayOfScope - 1) / 7 + 1 == ord
            }
            return (scopeLength - dayOfScope) / 7 + 1 == -ord
        }
        return kindMatches(sel.kind, value: f.weekday, lo: 1, hi: 7)

    case .year:
        // With W present, Y tests the ISO week-year (spec §2). The domain is
        // unbounded: `*` resolves to ±∞.
        let v = expr.hasWeek ? f.weekYear : f.year
        let infinity = Int.max / 4
        return kindMatches(sel.kind, value: v, lo: -infinity, hi: infinity)

    case .quarter:
        return kindMatches(sel.kind, value: f.quarter, lo: 1, hi: 4)
    case .month:
        return kindMatches(sel.kind, value: f.month, lo: 1, hi: 12)
    case .week:
        return kindMatches(sel.kind, value: f.week, lo: 1, hi: f.weeksInWeekYearHere)
    case .day:
        switch expr.dayScope {
        case .month: return kindMatches(sel.kind, value: f.day, lo: 1, hi: f.daysInMonthHere)
        case .quarter: return kindMatches(sel.kind, value: f.dayOfQuarter, lo: 1, hi: f.daysInQuarterHere)
        case .year: return kindMatches(sel.kind, value: f.dayOfYear, lo: 1, hi: f.daysInYearHere)
        }
    case .hour:
        return kindMatches(sel.kind, value: f.hour, lo: 0, hi: 23)
    case .minute:
        return kindMatches(sel.kind, value: f.minute, lo: 0, hi: 59)
    case .second:
        return kindMatches(sel.kind, value: f.second, lo: 0, hi: 59)
    }
}

// MARK: - Cadence

private func fixedDurationMs(_ value: Int, _ unit: CadenceUnit) -> Int {
    switch unit {
    case .day: return value * msPerDay
    case .week: return value * msPerWeek
    case .hour: return value * msPerHour
    case .minute: return value * msPerMinute
    case .month, .year: preconditionFailure("month/year durations are handled by constrain arithmetic")
    }
}

func cadenceCovers(_ c: Cadence, fields f: Fields, timeZone: TimeZone) -> Bool {
    switch c.periodUnit {
    case .day, .week:
        // Naive local wall-clock windows on a fixed-length grid (spec §9.3).
        let periodMs = c.period * (c.periodUnit == .week ? msPerWeek : msPerDay)
        let anchorMs = c.anchor.naiveMs
        let delta = f.naiveMs - anchorMs
        guard delta >= 0 else { return false }
        let k = delta / periodMs
        let start = anchorMs + k * periodMs
        let end = start + fixedDurationMs(c.duration, c.durationUnit)
        return f.naiveMs < end

    case .month, .year:
        // Constrained anchor arithmetic (spec §9.2); windows are naive local
        // intervals; the end is measured from the constrained start.
        let periodMonths = c.period * (c.periodUnit == .year ? 12 : 1)
        let monthsApart = (f.year - c.anchor.year) * 12 + (f.month - c.anchor.month)
        let kEstimate = floorDiv(monthsApart, periodMonths)
        for k in (kEstimate - 1)...(kEstimate + 1) where k >= 0 {
            let start = c.anchor.addingMonthsConstrained(k * periodMonths)
            let startMs = start.naiveMs
            let endMs: Int
            switch c.durationUnit {
            case .month: endMs = start.addingMonthsConstrained(c.duration).naiveMs
            case .year: endMs = start.addingMonthsConstrained(c.duration * 12).naiveMs
            default: endMs = startMs + fixedDurationMs(c.duration, c.durationUnit)
            }
            if f.naiveMs >= startMs && f.naiveMs < endMs { return true }
        }
        return false

    case .hour, .minute:
        // Absolute elapsed time from a resolved anchor instant (spec §9.3).
        let anchorInstantMs = resolveCompatible(c.anchor, in: timeZone)
        let periodMs = c.period * (c.periodUnit == .hour ? msPerHour : msPerMinute)
        let elapsed = f.epochMs - anchorInstantMs
        guard elapsed >= 0 else { return false }
        return elapsed % periodMs < fixedDurationMs(c.duration, c.durationUnit)
    }
}

/// Resolves a naive local date-time to an absolute instant using Temporal's
/// `compatible` disambiguation (spec §9.3): a repeated local time resolves to
/// the **earlier** occurrence; a nonexistent one (spring-forward gap) resolves
/// **forward** past the gap, i.e. with the offset in effect before the
/// transition. In a gap the offset always *increases*, so "the offset before"
/// is the smaller candidate — independent of the zone or the sign of its
/// offset. Assumes at most one transition within ±24h, true of real IANA zones.
func resolveCompatible(_ naive: NaiveDateTime, in timeZone: TimeZone) -> Int {
    let n = naive.naiveMs
    var offsets: Set<Int> = []
    for probe in [n - msPerDay, n, n + msPerDay] {
        offsets.insert(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(probe) / 1000)))
    }
    var matches: [Int] = []
    for offset in offsets {
        let candidate = n - offset * 1000
        let actual = timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: Double(candidate) / 1000))
        if actual == offset { matches.append(candidate) }
    }
    if let earliest = matches.min() { return earliest }
    // Gap: resolve with the offset in effect before the transition.
    let offsetBefore = offsets.min() ?? 0
    return n - offsetBefore * 1000
}

// MARK: - Expression

func expressionCovers(_ expr: Expression, fields f: Fields, timeZone: TimeZone) -> Bool {
    for sel in expr.selectors {
        guard selectorMatches(sel, expr: expr, fields: f) else { return false }
    }
    if let cadence = expr.cadence {
        guard cadenceCovers(cadence, fields: f, timeZone: timeZone) else { return false }
    }
    if let bounds = expr.bounds {
        if let s = bounds.startMs, f.naiveMs < s { return false }
        if let e = bounds.endMs, f.naiveMs >= e { return false }
    }
    return true
}
