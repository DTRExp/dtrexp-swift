// Recursive-descent parser for the DTRExp grammar (spec §8) plus the static
// validity rules of §§2–6. Tokens match greedily; the date literal's T-glue is
// unconditional (spec §8).

/// Thrown when an expression fails to parse or violates a static validity rule.
public struct ParseError: Error, CustomStringConvertible, Sendable {
    public let message: String
    /// The 0-based offset, in Unicode code points, of the first character of
    /// the token at fault (spec §8). Always set; optional only so code written
    /// against earlier releases keeps compiling.
    public var position: Int? { offset }
    let offset: Int

    public var description: String { "\(message) (at offset \(offset))" }

    init(_ message: String, at position: Int) {
        self.message = message
        self.offset = position
    }
}

struct Parser {
    /// An integer's largest value (spec §8); leading zeros do not count against it.
    static let maxInteger = 2_147_483_647

    private let chars: [Character]
    private var pos = 0
    /// The earliest rule error the branch has found. A rule error does not stop
    /// the branch: it reads on, and its earliest error wins, a later grammar
    /// error included; only D's domain waits for the complete branch (spec §8).
    private var pending: ParseError?

    init(_ source: String) {
        // One element per Unicode scalar, so an offset is a code-point offset
        // (spec §8), never a count of grapheme clusters.
        self.chars = source.unicodeScalars.map(Character.init)
    }

    // MARK: - Errors

    /// Notes a rule error; the branch reads on.
    private mutating func note(_ message: String, at position: Int) {
        if pending.map({ position < $0.offset }) ?? true {
            pending = ParseError(message, at: position)
        }
    }

    /// A grammar error: the branch ends with it, or with an earlier rule error.
    private mutating func fail(_ message: String, at position: Int) -> ParseError {
        note(message, at: position)
        return pending!
    }

    // MARK: - Scanner primitives

    private var atEnd: Bool { pos >= chars.count }
    private func peek(_ ahead: Int = 0) -> Character? {
        let i = pos + ahead
        return i < chars.count ? chars[i] : nil
    }
    private mutating func advance() { pos += 1 }

    private mutating func skipSpaces() {
        while peek() == " " { advance() }
    }

    private mutating func readDigits() -> String {
        var out = ""
        while let c = peek(), c.isASCII, c.isNumber {
            out.append(c)
            advance()
        }
        return out
    }

    /// Digits as an integer. `token` is where the token holding them starts
    /// (a value's sign), where a value above the limit is reported.
    private mutating func readInt(_ what: String, token: Int? = nil) throws(ParseError) -> Int {
        let start = pos
        let digits = readDigits()
        guard !digits.isEmpty else { throw fail("expected \(what)", at: start) }
        // Leading zeros are free (`M0000000003` is `M3`); the value is bounded.
        // Equal-length digit strings compare as their numbers do.
        let significant = String(digits.drop { $0 == "0" })
        guard significant.count < 10 || (significant.count == 10 && significant <= "2147483647") else {
            note("integer \(significant) is above the limit of \(Parser.maxInteger)", at: token ?? start)
            return Parser.maxInteger
        }
        return Int(significant) ?? 0
    }

    /// Optional leading `-` followed by digits.
    private mutating func readSignedInt(_ what: String) throws(ParseError) -> Int {
        let start = pos
        var negative = false
        if peek() == "-" {
            negative = true
            advance()
        }
        let v = try readInt(what, token: start)
        if negative && v == 0 {
            // the sign requires a nonzero integer: '-0' is not a value (spec §3)
            note("'-0' is not a value", at: start)
        }
        return negative ? -v : v
    }

    // MARK: - Top level

    mutating func parse() throws(ParseError) -> [Expression] {
        var branches: [Expression] = []
        while true {
            skipSpaces()
            branches.append(try parseExpression())
            skipSpaces()
            // parseExpression consumes a whole branch, stopping only at end of
            // input or a '|' separator — any other character is rejected inside
            // parseComponent — so the position here is always one or the other.
            if atEnd { break }
            advance()  // consume the '|' and parse the next branch
        }
        return branches
    }

    private mutating func parseExpression() throws(ParseError) -> Expression {
        var raw: [RawComponent] = []
        var seen = Set<Character>()
        var hasCadence = false
        var hasBounds = false
        while true {
            skipSpaces()
            if atEnd || peek() == "|" { break }
            let component = try parseComponent()
            switch component {
            case .selector(let sel, _):
                if !seen.insert(sel.designator.rawValue).inserted {
                    note("duplicate designator '\(sel.designator.rawValue)' in one expression", at: sel.position)
                }
            case .cadence(_, let position):
                if hasCadence { note("more than one cadence per expression", at: position) }
                hasCadence = true
            case .bounds(_, let position):
                if hasBounds { note("more than one bounds component per expression", at: position) }
                hasBounds = true
            }
            raw.append(component)
        }
        guard !raw.isEmpty else { throw fail("empty expression", at: pos) }
        return try assemble(raw)
    }

    // MARK: - Components

    /// Where a selector's values and stride interval sit in the source, for
    /// the domain errors raised once the whole expression is known.
    private struct SelectorPlaces {
        /// Per item: its value (or range start) and its range end.
        var items: [(start: Int, end: Int)] = []
        var interval = 0
    }

    private enum RawComponent {
        case selector(Selector, SelectorPlaces)
        case cadence(Cadence, position: Int)
        case bounds(BoundsWindow, position: Int)
    }

    private mutating func parseComponent() throws(ParseError) -> RawComponent {
        let start = pos
        guard let c = peek() else { throw fail("unexpected end of expression", at: pos) }
        if c == "*" {
            // Bounds with an open start: `*:date`.
            advance()
            guard peek() == ":" else {
                throw fail("'*' outside a selector must start a '*:<date>' bounds range", at: pos)
            }
            advance()
            if peek() == "*" {
                throw fail("bounds require at least one date-literal endpoint ('*:*' is invalid)", at: pos)
            }
            let end = try parseDateLiteral()
            return .bounds(BoundsWindow(startMs: nil, endMs: end.spanEndMs), position: start)
        }
        if c.isASCII && c.isNumber {
            return try parseDateLed(at: start)
        }
        if c == "!" {
            throw fail("exclusion '!' may appear only immediately after a designator", at: start)
        }
        if let d = Designator(rawValue: c) {
            advance()
            let (selector, places) = try parseSelector(d, at: start)
            return .selector(selector, places)
        }
        throw fail("unexpected character '\(c)'", at: start)
    }

    // MARK: - Date literals, bounds, cadences

    private struct DateLiteral {
        var dateTime: NaiveDateTime
        /// day / minute / second — the literal's whole-span unit (spec §6).
        var spanMs: Int

        var spanStartMs: Int { dateTime.naiveMs }
        var spanEndMs: Int { dateTime.naiveMs + spanMs }
    }

    /// `YYYYMMDD[Thhmm[ss]]`. T-glue is unconditional (spec §8). A literal the
    /// rules do not allow is noted and read past, its digit runs and T part
    /// whole; every error in it is reported at its first character.
    private mutating func parseDateLiteral() throws(ParseError) -> DateLiteral {
        let start = pos
        let digits = readDigits()
        guard !digits.isEmpty else { throw fail("malformed date literal — expected 8 digits YYYYMMDD", at: start) }
        var dt = NaiveDateTime(year: 1, month: 1, day: 1)
        if digits.count != 8 {
            note("malformed date literal — expected 8 digits YYYYMMDD", at: start)
        } else {
            let y = Int(digits.prefix(4))!
            let mo = Int(digits.dropFirst(4).prefix(2))!
            let d = Int(digits.suffix(2))!
            // Date-literal years are 1-9999 (spec §3.1): `00000101` is no date.
            if y >= 1, (1...12).contains(mo), d >= 1, d <= daysInMonth(y, mo) {
                dt = NaiveDateTime(year: y, month: mo, day: d)
            } else {
                note("'\(digits)' is not a real calendar date", at: start)
            }
        }
        var spanMs = msPerDay
        if peek() == "T" {
            advance()
            let tDigits = readDigits()
            // a further digit makes the time part malformed, never the start of
            // another literal
            guard tDigits.count == 4 || tDigits.count == 6 else {
                note("malformed time-part in date literal — expected Thhmm or Thhmmss", at: start)
                return DateLiteral(dateTime: dt, spanMs: msPerMinute)
            }
            let hh = Int(tDigits.prefix(2))!
            let mi = Int(tDigits.dropFirst(2).prefix(2))!
            if hh > 23 || mi > 59 {
                note("time-part out of range in date literal", at: start)
            }
            dt.hour = min(hh, 23)
            dt.minute = min(mi, 59)
            spanMs = msPerMinute
            if tDigits.count == 6 {
                let ss = Int(tDigits.suffix(2))!
                if ss > 59 {
                    note("seconds out of range in date literal", at: start)
                }
                dt.second = min(ss, 59)
                spanMs = msPerSecond
            }
        }
        return DateLiteral(dateTime: dt, spanMs: spanMs)
    }

    /// A component starting with a digit: a bounds literal/range or a cadence.
    private mutating func parseDateLed(at start: Int) throws(ParseError) -> RawComponent {
        let first = try parseDateLiteral()
        switch peek() {
        case "/":
            advance()
            return .cadence(try parseCadenceTail(anchor: first.dateTime), position: start)
        case ":":
            advance()
            if peek() == "*" {
                advance()
                return .bounds(BoundsWindow(startMs: first.spanStartMs, endMs: nil), position: start)
            }
            let lastStart = pos
            let last = try parseDateLiteral()
            if first.spanStartMs >= last.spanEndMs {
                note("backwards bounds range", at: lastStart)
            }
            return .bounds(BoundsWindow(startMs: first.spanStartMs, endMs: last.spanEndMs), position: start)
        default:
            return .bounds(BoundsWindow(startMs: first.spanStartMs, endMs: first.spanEndMs), position: start)
        }
    }

    private mutating func parseCadenceUnit() throws(ParseError) -> CadenceUnit {
        guard let c = peek(), let unit = CadenceUnit(rawValue: c) else {
            throw fail("unknown cadence unit '\(peek().map(String.init) ?? "")'", at: pos)
        }
        advance()
        return unit
    }

    private mutating func parseCadenceTail(anchor: NaiveDateTime) throws(ParseError) -> Cadence {
        let periodAt = pos
        let period = try readInt("cadence period")
        if period < 1 { note("cadence period must be at least 1", at: periodAt) }
        let periodUnit = try parseCadenceUnit()
        var duration = 1
        var durationUnit = periodUnit
        // A duration that is not smaller than its period is reported at the
        // duration when it is written, and at the period when it is implied.
        var durationAt = periodAt
        if peek() == "/" {
            advance()
            durationAt = pos
            duration = try readInt("cadence duration")
            if duration < 1 { note("cadence duration must be at least 1", at: durationAt) }
            durationUnit = try parseCadenceUnit()
        }
        if durationUnit.isMonthOrYear && !periodUnit.isMonthOrYear {
            note("month/year duration units require a month/year period", at: durationAt)
        }
        // duration < period, compared conservatively with fixed unit lengths
        // (spec §5.2); same-unit comparisons are exact.
        if durationUnit == periodUnit {
            if duration >= period {
                note("cadence duration must be smaller than its period", at: durationAt)
            }
        } else {
            // Max length (duration side) and min length (period side), in minutes.
            func maxMinutes(_ u: CadenceUnit) -> Int {
                switch u {
                case .year: return 366 * 1440
                case .month: return 31 * 1440
                case .week: return 7 * 1440
                case .day: return 1440
                case .hour: return 60
                case .minute: return 1
                }
            }
            func minMinutes(_ u: CadenceUnit) -> Int {
                switch u {
                case .year: return 365 * 1440
                case .month: return 28 * 1440
                case .week: return 7 * 1440
                case .day: return 1440
                case .hour: return 60
                case .minute: return 1
                }
            }
            if duration * maxMinutes(durationUnit) >= period * minMinutes(periodUnit) {
                note("cadence duration is not conservatively smaller than its period", at: durationAt)
            }
        }
        return Cadence(anchor: anchor, period: period, periodUnit: periodUnit,
                       duration: duration, durationUnit: durationUnit)
    }

    // MARK: - Selectors

    private mutating func parseSelector(_ d: Designator, at start: Int) throws(ParseError) -> (Selector, SelectorPlaces) {
        var places = SelectorPlaces()
        if d == .time {
            return (Selector(designator: .time, kind: .timeSpans(try parseTimeList(at: start)), position: start), places)
        }
        switch peek() {
        case nil, " ", "|":
            throw fail("designator '\(d.rawValue)' without a value", at: pos)
        case "*" where peek(1) == "/":
            // `Y*/3`: a stride with no start to anchor it (spec §5.1)
            advance()
            places.items.append((start + 1, start + 1))
            let slash = pos
            advance()
            let kind = try parseStrideTail(d, item: .range(start: .star, end: .star, wraps: false),
                                           places: &places, slash: slash)
            return (Selector(designator: d, kind: kind, position: start), places)
        case "*" where peek(1) != ":":
            advance()
            return (Selector(designator: d, kind: .all, position: start), places)
        case "!":
            advance()
            let items = try parseValueList(d, places: &places)
            return (Selector(designator: d, kind: .exclusion(items), position: start), places)
        default:
            break
        }

        let items = try parseValueList(d, places: &places)

        if peek() == "#" {
            advance()
            guard d == .weekday else {
                throw fail("ordinal '#' is only valid on E", at: pos - 1)
            }
            guard items.count == 1, case .single(let weekday) = items[0] else {
                throw fail("ordinal '#' takes a single weekday value, never a list or range", at: pos - 1)
            }
            let ordStart = pos
            let ord = try readSignedInt("ordinal")
            if ord == 0 {
                note("ordinal must not be zero", at: ordStart)
            } else if !(1...5).contains(abs(ord)) {
                note("ordinal out of range (-5…-1, 1…5)", at: ordStart)
            }
            return (Selector(designator: d, kind: .ordinal(weekday: weekday, ordinal: ord), position: start), places)
        }

        if peek() == "/" {
            let slash = pos
            advance()
            guard items.count == 1 else {
                throw fail("a stride attaches to a single value or range, not a list", at: slash)
            }
            let kind = try parseStrideTail(d, item: items[0], places: &places, slash: slash)
            return (Selector(designator: d, kind: kind, position: start), places)
        }

        return (Selector(designator: d, kind: .list(items), position: start), places)
    }

    /// The stride after the first `/` at `slash`; a start or range the stride
    /// does not allow is reported at the `/` (spec §8).
    private mutating func parseStrideTail(_ d: Designator, item: Item, places: inout SelectorPlaces,
                                          slash: Int) throws(ParseError) -> SelectorKind {
        // 1 lies in every domain, so a '*' start (an error of its own) adds no other
        var strideStart = 1
        var strideEnd: Endpoint?
        switch item {
        case .single(let v):
            strideStart = v
            strideEnd = nil  // domain edge
        case .range(let s, let e, let wraps):
            if case .value(let sv) = s {
                strideStart = sv
            } else {
                note("stride start must be an explicit value ('*' has no anchor)", at: slash)
            }
            // a Y range that wraps is backwards, already noted at its end, which comes first
            if wraps {
                note("wrap ranges take no stride", at: slash)
            }
            strideEnd = e
        }
        if strideStart < 0 {
            note("stride start must be non-negative (end-relative anchors shift per parent instance)", at: slash)
        }
        let intervalAt = pos
        places.interval = intervalAt
        let interval = try readInt("stride interval")
        if interval < 2 {
            note("stride interval must be at least 2", at: intervalAt)
        }
        // D's domain depends on its scope and waits for the branch
        if d != .day, let limits = Parser.domainLimits(d, dayScope: .month), interval > limits.count {
            note("stride interval \(interval) exceeds the parent domain (max \(limits.count)) — use a cadence",
                 at: intervalAt)
        }
        if peek() == "/" {
            advance()
            let durationAt = pos
            let duration = try readInt("stride duration")
            if duration < 1 || duration >= interval {
                note("stride duration must be 1 ≤ duration < interval", at: durationAt)
            }
            return .stride(start: strideStart, end: strideEnd, interval: interval, duration: duration)
        }
        return .stride(start: strideStart, end: strideEnd, interval: interval, duration: 1)
    }

    private mutating func parseValueList(_ d: Designator, places: inout SelectorPlaces) throws(ParseError) -> [Item] {
        var items: [Item] = [try parseItem(d, places: &places)]
        while peek() == "," {
            advance()
            items.append(try parseItem(d, places: &places))
        }
        return items
    }

    /// One value or range, each value checked as it is read but for D's, whose
    /// domain waits for the branch; its value (or range start) and range end
    /// positions go into `places`.
    private mutating func parseItem(_ d: Designator, places: inout SelectorPlaces) throws(ParseError) -> Item {
        let start = pos
        let startPoint: Endpoint
        if peek() == "*" {
            guard peek(1) == ":" else {
                throw fail("bare '*' in a list — a list containing the whole domain is the whole domain", at: start)
            }
            advance()  // now positioned at the ':' checked via peek(1)
            startPoint = .star
        } else {
            let v = try readSignedInt("value")
            if d != .day { checkValue(d, v, at: start, dayScope: .month) }
            guard peek() == ":" else {
                places.items.append((start, start))
                return .single(v)
            }
            startPoint = .value(v)
        }
        advance()  // consume the ':' (guaranteed present in both branches)
        let endAt = pos
        places.items.append((start, endAt))
        let endPoint: Endpoint
        if peek() == "*" {
            advance()
            endPoint = .star
        } else {
            let v = try readSignedInt("range end")
            if d != .day { checkValue(d, v, at: endAt, dayScope: .month) }
            endPoint = .value(v)
        }
        // Wrap is decided syntactically, on literal non-negative endpoints only (spec §3).
        var wraps = false
        if case .value(let sv) = startPoint, case .value(let ev) = endPoint, sv >= 0, ev >= 0, sv > ev {
            wraps = true
            // Y has no edge to wrap around: the range is wrong at its end
            if d == .year {
                note("backwards Y range — Y has no edge to wrap around", at: endAt)
            }
        }
        return .range(start: startPoint, end: endPoint, wraps: wraps)
    }

    // MARK: - T selector

    private struct TimeValue {
        let boundaryMs: Int  // start-of instant within the day
        let unitMs: Int      // implied unit interval for single values
        let is2400: Bool
    }

    private mutating func parseTimeValue(at selStart: Int) throws(ParseError) -> TimeValue {
        let start = pos
        if peek() == "*" {
            throw fail("T takes no '*'", at: start)
        }
        if peek() == "-" {
            throw fail("T takes no negative values", at: start)
        }
        let digits = readDigits()
        var ms = 0
        var unit = msPerSecond
        var is2400 = false
        switch digits.count {
        case 0:
            throw fail("malformed time value — expected hh, hhmm or hhmmss[.sss]", at: start)
        case 2:
            let hh = Int(digits)!
            if hh > 23 { note("hour out of range in time value", at: start) }
            ms = hh * msPerHour
            unit = msPerHour
        case 4, 6:
            let hh = Int(digits.prefix(2))!
            let mi = Int(digits.dropFirst(2).prefix(2))!
            if mi > 59 { note("minute out of range in time value", at: start) }
            if digits.count == 4 && digits == "2400" {
                is2400 = true
                ms = msPerDay
                unit = msPerMinute
            } else {
                if hh > 23 { note("hour out of range in time value", at: start) }
                ms = hh * msPerHour + mi * msPerMinute
                unit = msPerMinute
                if digits.count == 6 {
                    let ss = Int(digits.suffix(2))!
                    if ss > 59 { note("second out of range in time value", at: start) }
                    ms += ss * msPerSecond
                    unit = msPerSecond
                    if peek() == "." {
                        // the fraction is its own token, from its '.'
                        let fracStart = pos
                        advance()
                        let frac = readDigits()
                        if frac.count == 3 {
                            ms += Int(frac)!
                            unit = 1
                        } else {
                            note("milliseconds must be exactly 3 digits", at: fracStart)
                        }
                    }
                }
            }
        default:
            note("malformed time value — expected hh, hhmm or hhmmss[.sss]", at: start)
        }
        if peek() == "." {
            // a fraction follows only a 6-digit time value; elsewhere it is a rule error at its '.'
            note("milliseconds follow only a 6-digit hhmmss time value", at: pos)
            advance()
            _ = readDigits()
        }
        return TimeValue(boundaryMs: ms, unitMs: unit, is2400: is2400)
    }

    private mutating func parseTimeList(at start: Int) throws(ParseError) -> [TimeSpan] {
        if peek() == "!" {
            throw fail("T takes no exclusion — write the complement explicitly", at: pos)
        }
        var spans: [TimeSpan] = []
        while true {
            let itemStart = pos
            let first = try parseTimeValue(at: start)
            if peek() == ":" {
                advance()
                if first.is2400 {
                    note("'2400' is valid only as a range end", at: itemStart)
                }
                let secondStart = pos
                let second = try parseTimeValue(at: start)
                let s = first.boundaryMs
                let e = second.boundaryMs
                if s == e {
                    note("T range with equal endpoints — half-open, it would cover nothing", at: secondStart)
                }
                if s > e {
                    // Midnight wrap, within each covered day (spec §4).
                    if e > 0 { spans.append(TimeSpan(startMs: 0, endMs: e)) }
                    spans.append(TimeSpan(startMs: s, endMs: msPerDay))
                } else {
                    spans.append(TimeSpan(startMs: s, endMs: e))
                }
            } else {
                if first.is2400 {
                    note("'2400' is valid only as a range end", at: itemStart)
                }
                spans.append(TimeSpan(startMs: first.boundaryMs,
                                      endMs: min(first.boundaryMs + first.unitMs, msPerDay)))
            }
            if peek() == "," {
                advance()
                continue
            }
            break
        }
        switch peek() {
        case "/": throw fail("T takes no stride", at: pos)
        case "#": throw fail("T takes no ordinal", at: pos)
        default: break
        }
        return spans
    }

    // MARK: - Assembly & static validation

    private mutating func assemble(_ raw: [RawComponent]) throws(ParseError) -> Expression {
        var expr = Expression()
        var seen = Set<Character>()
        var days: [(Selector, SelectorPlaces)] = []
        for component in raw {
            switch component {
            case .selector(let sel, let selPlaces):
                seen.insert(sel.designator.rawValue)
                expr.selectors.append(sel)
                if sel.designator == .day { days.append((sel, selPlaces)) }
            case .cadence(let cad, _):
                expr.cadence = cad
            case .bounds(let window, _):
                expr.bounds = window
            }
        }
        expr.hasWeek = seen.contains("W")
        // D and E# take the nearest of M / Q / Y present, else M (spec §2).
        let scope: ScopeUnit = seen.contains("M") ? .month : seen.contains("Q") ? .quarter : seen.contains("Y") ? .year : .month
        expr.dayScope = scope
        expr.ordinalScope = scope
        // The branch is complete: D's domain is known now, and the earliest error wins.
        for (sel, selPlaces) in days {
            validateDays(sel, places: selPlaces, scope: scope)
        }
        if let pending { throw pending }
        return expr
    }

    /// Parse-time domain limits: (isZeroBased, max positive literal, element count).
    /// `nil` for Y (unbounded) and T (validated during parse).
    static func domainLimits(_ d: Designator, dayScope: ScopeUnit) -> (zeroBased: Bool, max: Int, count: Int)? {
        switch d {
        case .year, .time: return nil
        case .quarter: return (false, 4, 4)
        case .month: return (false, 12, 12)
        case .week: return (false, 53, 53)
        case .weekday: return (false, 7, 7)
        case .day:
            switch dayScope {
            case .month: return (false, 31, 31)
            case .quarter: return (false, 92, 92)
            case .year: return (false, 366, 366)
            }
        case .hour: return (true, 23, 24)
        case .minute, .second: return (true, 59, 60)
        }
    }

    /// Notes a value outside its designator's domain (spec §3.1), at the value.
    private mutating func checkValue(_ d: Designator, _ v: Int, at position: Int, dayScope: ScopeUnit) {
        if d == .year {
            if v < 0 {
                note("negative value on Y — no edge to count back from", at: position)
            } else if !(1...9999).contains(v) {
                // Y takes 4-digit ISO years (spec §2): 1-9999.
                note("year \(v) out of domain (1-9999)", at: position)
            }
            return
        }
        let limits = Parser.domainLimits(d, dayScope: dayScope)!
        if v == 0 && !limits.zeroBased {
            note("zero value on '\(d.rawValue)'", at: position)
        }
        if v > limits.max {
            note("value \(v) out of domain for '\(d.rawValue)' (max \(limits.max))", at: position)
        }
        if v < 0 && v < -limits.count {
            note("negative value \(v) out of domain for '\(d.rawValue)' (symmetric check: -\(limits.count)…-1)",
                 at: position)
        }
    }

    /// D's domain, once the branch's scope is known; each error names the value
    /// (or the stride interval) at fault (spec §8).
    private mutating func validateDays(_ sel: Selector, places: SelectorPlaces, scope: ScopeUnit) {
        func endpoint(_ e: Endpoint?) -> Int? {
            if case .value(let v) = e { return v }
            return nil
        }
        var values: [(Int, Int)] = []
        switch sel.kind {
        case .list(let items), .exclusion(let items):
            for (item, place) in zip(items, places.items) {
                switch item {
                case .single(let v):
                    values.append((v, place.start))
                case .range(let s, let e, _):
                    if let v = endpoint(s) { values.append((v, place.start)) }
                    if let v = endpoint(e) { values.append((v, place.end)) }
                }
            }
        case .stride(let start, let end, let interval, _):
            values.append((start, places.items[0].start))
            if let v = endpoint(end) { values.append((v, places.items[0].end)) }
            let count = Parser.domainLimits(.day, dayScope: scope)!.count
            if interval > count {
                note("stride interval \(interval) exceeds the parent domain (max \(count)) — use a cadence",
                     at: places.interval)
            }
        default:
            break
        }
        for (v, position) in values {
            checkValue(.day, v, at: position, dayScope: scope)
        }
    }
}
