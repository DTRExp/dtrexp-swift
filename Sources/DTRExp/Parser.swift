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

    init(_ source: String) {
        // One element per Unicode scalar, so an offset is a code-point offset
        // (spec §8), never a count of grapheme clusters.
        self.chars = source.unicodeScalars.map(Character.init)
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
        guard !digits.isEmpty else { throw ParseError("expected \(what)", at: start) }
        // Leading zeros are free (`M0000000003` is `M3`); the value is bounded.
        // Equal-length digit strings compare as their numbers do.
        let significant = String(digits.drop { $0 == "0" })
        guard significant.count < 10 || (significant.count == 10 && significant <= "2147483647") else {
            throw ParseError("integer \(significant) is above the limit of \(Parser.maxInteger)", at: token ?? start)
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
            throw ParseError("'-0' is not a value", at: start)
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
        while true {
            skipSpaces()
            if atEnd || peek() == "|" { break }
            raw.append(try parseComponent())
        }
        guard !raw.isEmpty else { throw ParseError("empty expression", at: pos) }
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
        guard let c = peek() else { throw ParseError("unexpected end of expression", at: pos) }
        if c == "*" {
            // Bounds with an open start: `*:date`.
            advance()
            guard peek() == ":" else {
                throw ParseError("'*' outside a selector must start a '*:<date>' bounds range", at: pos)
            }
            advance()
            if peek() == "*" {
                throw ParseError("bounds require at least one date-literal endpoint ('*:*' is invalid)", at: pos)
            }
            let end = try parseDateLiteral()
            return .bounds(BoundsWindow(startMs: nil, endMs: end.spanEndMs), position: start)
        }
        if c.isASCII && c.isNumber {
            return try parseDateLed(at: start)
        }
        if c == "!" {
            throw ParseError("exclusion '!' may appear only immediately after a designator", at: start)
        }
        if let d = Designator(rawValue: c) {
            advance()
            let (selector, places) = try parseSelector(d, at: start)
            return .selector(selector, places)
        }
        throw ParseError("unexpected character '\(c)'", at: start)
    }

    // MARK: - Date literals, bounds, cadences

    private struct DateLiteral {
        var dateTime: NaiveDateTime
        /// day / minute / second — the literal's whole-span unit (spec §6).
        var spanMs: Int

        var spanStartMs: Int { dateTime.naiveMs }
        var spanEndMs: Int { dateTime.naiveMs + spanMs }
    }

    /// `YYYYMMDD[Thhmm[ss]]`. T-glue is unconditional (spec §8).
    private mutating func parseDateLiteral() throws(ParseError) -> DateLiteral {
        let start = pos
        let digits = readDigits()
        guard digits.count == 8 else {
            throw ParseError("malformed date literal — expected 8 digits YYYYMMDD", at: start)
        }
        let y = Int(digits.prefix(4))!
        let mo = Int(digits.dropFirst(4).prefix(2))!
        let d = Int(digits.suffix(2))!
        // Date-literal years are 1-9999 (spec §3.1): `00000101` is no date.
        guard y >= 1, (1...12).contains(mo), d >= 1, d <= daysInMonth(y, mo) else {
            throw ParseError("'\(digits)' is not a real calendar date", at: start)
        }
        var dt = NaiveDateTime(year: y, month: mo, day: d)
        var spanMs = msPerDay
        if peek() == "T" {
            // A malformed or out-of-range time part is the date literal's
            // fault, reported at its first character (spec §8).
            advance()
            let tDigits = readDigits()
            guard tDigits.count == 4 || tDigits.count == 6 else {
                throw ParseError("malformed time-part in date literal — expected Thhmm or Thhmmss", at: start)
            }
            let hh = Int(tDigits.prefix(2))!
            let mi = Int(tDigits.dropFirst(2).prefix(2))!
            guard hh <= 23, mi <= 59 else {
                throw ParseError("time-part out of range in date literal", at: start)
            }
            dt.hour = hh
            dt.minute = mi
            spanMs = msPerMinute
            if tDigits.count == 6 {
                let ss = Int(tDigits.suffix(2))!
                guard ss <= 59 else {
                    throw ParseError("seconds out of range in date literal", at: start)
                }
                dt.second = ss
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
            guard first.spanStartMs < last.spanEndMs else {
                throw ParseError("backwards bounds range", at: lastStart)
            }
            return .bounds(BoundsWindow(startMs: first.spanStartMs, endMs: last.spanEndMs), position: start)
        default:
            return .bounds(BoundsWindow(startMs: first.spanStartMs, endMs: first.spanEndMs), position: start)
        }
    }

    private mutating func parseCadenceUnit() throws(ParseError) -> CadenceUnit {
        guard let c = peek(), let unit = CadenceUnit(rawValue: c) else {
            throw ParseError("unknown cadence unit '\(peek().map(String.init) ?? "")'", at: pos)
        }
        advance()
        return unit
    }

    private mutating func parseCadenceTail(anchor: NaiveDateTime) throws(ParseError) -> Cadence {
        let periodAt = pos
        let period = try readInt("cadence period")
        guard period >= 1 else { throw ParseError("cadence period must be at least 1", at: periodAt) }
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
            guard duration >= 1 else { throw ParseError("cadence duration must be at least 1", at: durationAt) }
            durationUnit = try parseCadenceUnit()
        }
        if durationUnit.isMonthOrYear && !periodUnit.isMonthOrYear {
            throw ParseError("month/year duration units require a month/year period", at: durationAt)
        }
        // duration < period, compared conservatively with fixed unit lengths
        // (spec §5.2); same-unit comparisons are exact.
        if durationUnit == periodUnit {
            guard duration < period else {
                throw ParseError("cadence duration must be smaller than its period", at: durationAt)
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
            guard duration * maxMinutes(durationUnit) < period * minMinutes(periodUnit) else {
                throw ParseError("cadence duration is not conservatively smaller than its period", at: durationAt)
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
            throw ParseError("designator '\(d.rawValue)' without a value", at: pos)
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
                throw ParseError("ordinal '#' is only valid on E", at: pos - 1)
            }
            guard items.count == 1, case .single(let weekday) = items[0] else {
                throw ParseError("ordinal '#' takes a single weekday value, never a list or range", at: pos - 1)
            }
            let ordStart = pos
            let ord = try readSignedInt("ordinal")
            guard ord != 0 else { throw ParseError("ordinal must not be zero", at: ordStart) }
            guard (1...5).contains(abs(ord)) else {
                throw ParseError("ordinal out of range (-5…-1, 1…5)", at: ordStart)
            }
            return (Selector(designator: d, kind: .ordinal(weekday: weekday, ordinal: ord), position: start), places)
        }

        if peek() == "/" {
            let slash = pos
            advance()
            guard items.count == 1 else {
                throw ParseError("a stride attaches to a single value or range, not a list", at: slash)
            }
            places.interval = pos
            let kind = try parseStrideTail(d, item: items[0], place: places.items[0], slash: slash)
            return (Selector(designator: d, kind: kind, position: start), places)
        }

        return (Selector(designator: d, kind: .list(items), position: start), places)
    }

    /// The stride after the first `/` at `slash`; a start or range the stride
    /// does not allow is reported at the `/` (spec §8).
    private mutating func parseStrideTail(_ d: Designator, item: Item, place: (start: Int, end: Int),
                                          slash: Int) throws(ParseError) -> SelectorKind {
        let strideStart: Int
        var strideEnd: Endpoint?
        switch item {
        case .single(let v):
            strideStart = v
            strideEnd = nil  // domain edge
        case .range(let s, let e, let wraps):
            guard case .value(let sv) = s else {
                throw ParseError("stride start must be an explicit value ('*' has no anchor)", at: slash)
            }
            if wraps {
                if d == .year {
                    throw ParseError("backwards Y range — Y has no edge to wrap around", at: place.end)
                }
                throw ParseError("wrap ranges take no stride", at: slash)
            }
            strideStart = sv
            strideEnd = e
        }
        guard strideStart >= 0 else {
            throw ParseError("stride start must be non-negative (end-relative anchors shift per parent instance)", at: slash)
        }
        let intervalAt = pos
        let interval = try readInt("stride interval")
        var duration = 1
        var durationAt = intervalAt
        if peek() == "/" {
            advance()
            durationAt = pos
            duration = try readInt("stride duration")
        }
        guard interval >= 2 else { throw ParseError("stride interval must be at least 2", at: intervalAt) }
        guard duration >= 1, duration < interval else {
            throw ParseError("stride duration must be 1 ≤ duration < interval", at: durationAt)
        }
        return .stride(start: strideStart, end: strideEnd, interval: interval, duration: duration)
    }

    private mutating func parseValueList(_ d: Designator, places: inout SelectorPlaces) throws(ParseError) -> [Item] {
        var items: [Item] = [try parseItem(d, places: &places)]
        while peek() == "," {
            advance()
            items.append(try parseItem(d, places: &places))
        }
        return items
    }

    /// One value or range; its value (or range start) and range end positions
    /// go into `places`.
    private mutating func parseItem(_ d: Designator, places: inout SelectorPlaces) throws(ParseError) -> Item {
        let start = pos
        let startPoint: Endpoint
        if peek() == "*" {
            guard peek(1) == ":" else {
                throw ParseError("bare '*' in a list — a list containing the whole domain is the whole domain", at: start)
            }
            advance()  // now positioned at the ':' checked via peek(1)
            startPoint = .star
        } else {
            let v = try readSignedInt("value")
            guard peek() == ":" else {
                places.items.append((start, start))
                return .single(v)
            }
            startPoint = .value(v)
        }
        advance()  // consume the ':' (guaranteed present in both branches)
        places.items.append((start, pos))
        let endPoint: Endpoint
        if peek() == "*" {
            advance()
            endPoint = .star
        } else {
            endPoint = .value(try readSignedInt("range end"))
        }
        // Wrap is decided syntactically, on literal non-negative endpoints only (spec §3).
        var wraps = false
        if case .value(let sv) = startPoint, case .value(let ev) = endPoint, sv >= 0, ev >= 0, sv > ev {
            wraps = true
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
            throw ParseError("T takes no '*'", at: start)
        }
        if peek() == "-" {
            throw ParseError("T takes no negative values", at: start)
        }
        let digits = readDigits()
        var ms = 0
        var unit: Int
        var is2400 = false
        switch digits.count {
        case 2:
            let hh = Int(digits)!
            guard hh <= 23 else { throw ParseError("hour out of range in time value", at: start) }
            ms = hh * msPerHour
            unit = msPerHour
        case 4, 6:
            let hh = Int(digits.prefix(2))!
            let mi = Int(digits.dropFirst(2).prefix(2))!
            guard mi <= 59 else { throw ParseError("minute out of range in time value", at: start) }
            if digits.count == 4 && digits == "2400" {
                is2400 = true
                ms = msPerDay
                unit = msPerMinute
            } else {
                guard hh <= 23 else { throw ParseError("hour out of range in time value", at: start) }
                ms = hh * msPerHour + mi * msPerMinute
                unit = msPerMinute
                if digits.count == 6 {
                    let ss = Int(digits.suffix(2))!
                    guard ss <= 59 else { throw ParseError("second out of range in time value", at: start) }
                    ms += ss * msPerSecond
                    unit = msPerSecond
                    if peek() == "." {
                        advance()
                        let frac = readDigits()
                        guard frac.count == 3 else {
                            throw ParseError("milliseconds must be exactly 3 digits", at: pos)
                        }
                        ms += Int(frac)!
                        unit = 1
                    }
                }
            }
        default:
            throw ParseError("malformed time value — expected hh, hhmm or hhmmss[.sss]", at: start)
        }
        return TimeValue(boundaryMs: ms, unitMs: unit, is2400: is2400)
    }

    private mutating func parseTimeList(at start: Int) throws(ParseError) -> [TimeSpan] {
        if peek() == "!" {
            throw ParseError("T takes no exclusion — write the complement explicitly", at: pos)
        }
        var spans: [TimeSpan] = []
        while true {
            let itemStart = pos
            let first = try parseTimeValue(at: start)
            if peek() == ":" {
                advance()
                guard !first.is2400 else {
                    throw ParseError("'2400' is valid only as a range end", at: itemStart)
                }
                let secondStart = pos
                let second = try parseTimeValue(at: start)
                let s = first.boundaryMs
                let e = second.boundaryMs
                guard s != e else {
                    throw ParseError("T range with equal endpoints — half-open, it would cover nothing", at: secondStart)
                }
                if s > e {
                    // Midnight wrap, within each covered day (spec §4).
                    if e > 0 { spans.append(TimeSpan(startMs: 0, endMs: e)) }
                    spans.append(TimeSpan(startMs: s, endMs: msPerDay))
                } else {
                    spans.append(TimeSpan(startMs: s, endMs: e))
                }
            } else {
                guard !first.is2400 else {
                    throw ParseError("'2400' is valid only as a range end", at: itemStart)
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
        case "/": throw ParseError("T takes no stride", at: pos)
        case "#": throw ParseError("T takes no ordinal", at: pos)
        default: break
        }
        return spans
    }

    // MARK: - Assembly & static validation

    private mutating func assemble(_ raw: [RawComponent]) throws(ParseError) -> Expression {
        var expr = Expression()
        var seen = Set<Character>()
        var places: [SelectorPlaces] = []
        for component in raw {
            switch component {
            case .selector(let sel, let selPlaces):
                guard seen.insert(sel.designator.rawValue).inserted else {
                    throw ParseError("duplicate designator '\(sel.designator.rawValue)' in one expression", at: sel.position)
                }
                expr.selectors.append(sel)
                places.append(selPlaces)
            case .cadence(let cad, let position):
                guard expr.cadence == nil else {
                    throw ParseError("more than one cadence per expression", at: position)
                }
                expr.cadence = cad
            case .bounds(let window, let position):
                guard expr.bounds == nil else {
                    throw ParseError("more than one bounds component per expression", at: position)
                }
                expr.bounds = window
            }
        }
        expr.hasWeek = seen.contains("W")
        // D and E# take the nearest of M / Q / Y present, else M (spec §2).
        let scope: ScopeUnit = seen.contains("M") ? .month : seen.contains("Q") ? .quarter : seen.contains("Y") ? .year : .month
        expr.dayScope = scope
        expr.ordinalScope = scope
        for (sel, selPlaces) in zip(expr.selectors, places) {
            try validateDomains(sel, places: selPlaces, expr: expr)
        }
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

    /// Domain checks once the scope is known; each error names the value (or
    /// the stride interval) at fault (spec §8).
    private func validateDomains(_ sel: Selector, places: SelectorPlaces, expr: Expression) throws(ParseError) {
        let d = sel.designator
        let limits = Parser.domainLimits(d, dayScope: expr.dayScope)

        func check(_ v: Int, at position: Int) throws(ParseError) {
            if d == .year {
                guard v >= 0 else {
                    throw ParseError("negative value on Y — no edge to count back from", at: position)
                }
                // Y takes 4-digit ISO years (spec §2): 1-9999.
                guard (1...9999).contains(v) else {
                    throw ParseError("year \(v) out of domain (1-9999)", at: position)
                }
                return
            }
            guard let limits else { return }
            if v == 0 && !limits.zeroBased {
                throw ParseError("zero value on '\(d.rawValue)'", at: position)
            }
            if v > limits.max {
                throw ParseError("value \(v) out of domain for '\(d.rawValue)' (max \(limits.max))", at: position)
            }
            if v < 0 && v < -limits.count {
                throw ParseError("negative value \(v) out of domain for '\(d.rawValue)' (symmetric check: -\(limits.count)…-1)",
                                 at: position)
            }
        }

        func checkEndpoint(_ e: Endpoint, at position: Int) throws(ParseError) {
            if case .value(let v) = e { try check(v, at: position) }
        }

        func checkItem(_ item: Item, at place: (start: Int, end: Int)) throws(ParseError) {
            switch item {
            case .single(let v):
                try check(v, at: place.start)
            case .range(let s, let e, let wraps):
                try checkEndpoint(s, at: place.start)
                try checkEndpoint(e, at: place.end)
                if d == .year && wraps {
                    throw ParseError("backwards Y range — Y has no edge to wrap around", at: place.end)
                }
            }
        }

        switch sel.kind {
        case .all, .timeSpans:
            break
        case .list(let items), .exclusion(let items):
            for (item, place) in zip(items, places.items) { try checkItem(item, at: place) }
        case .stride(let start, let end, let interval, _):
            try check(start, at: places.items[0].start)
            if let end { try checkEndpoint(end, at: places.items[0].end) }
            if let limits, interval > limits.count {
                throw ParseError("stride interval \(interval) exceeds the parent domain (max \(limits.count)) — use a cadence",
                                 at: places.interval)
            }
        case .ordinal(let weekday, _):
            try check(weekday, at: places.items[0].start)
        }
    }
}
