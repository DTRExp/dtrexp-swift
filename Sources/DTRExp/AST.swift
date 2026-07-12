// Parsed representation of a DTRExp.

enum Designator: Character, Sendable {
    case year = "Y"
    case quarter = "Q"
    case month = "M"
    case week = "W"
    case day = "D"
    case weekday = "E"
    case time = "T"
    case hour = "H"
    case minute = "m"
    case second = "s"
}

/// One endpoint of a surface range.
enum Endpoint: Equatable, Sendable {
    case value(Int)   // may be negative (end-relative)
    case star         // the domain edge in force (spec §3.1)
}

/// A value-list item: a single value or a range.
enum Item: Equatable, Sendable {
    case single(Int)
    /// `wraps` is decided syntactically at parse time, on literal non-negative
    /// endpoints only (spec §3).
    case range(start: Endpoint, end: Endpoint, wraps: Bool)
}

/// Half-open time-of-day span in milliseconds since local midnight.
struct TimeSpan: Equatable, Sendable {
    let startMs: Int
    let endMs: Int  // exclusive; ≤ 86_400_000
}

enum SelectorKind: Equatable, Sendable {
    case all                                   // `M*`
    case list([Item])                          // `M1,3,7:9`
    case exclusion([Item])                     // `M!5,7:9`
    case stride(start: Int, end: Endpoint?, interval: Int, duration: Int)
    case ordinal(weekday: Int, ordinal: Int)   // E only; weekday may be negative
    case timeSpans([TimeSpan])                 // T only; wrap already split
}

struct Selector: Equatable, Sendable {
    let designator: Designator
    let kind: SelectorKind
    /// Offset of the designator character in the source (for positioned warnings).
    let position: Int
}

enum CadenceUnit: Character, Sendable {
    case year = "Y"
    case month = "M"
    case week = "W"
    case day = "D"
    case hour = "H"
    case minute = "m"

    var isMonthOrYear: Bool { self == .year || self == .month }
}

struct Cadence: Equatable, Sendable {
    let anchor: NaiveDateTime
    let period: Int
    let periodUnit: CadenceUnit
    let duration: Int
    let durationUnit: CadenceUnit
}

/// Absolute bounds window as a naive local wall-clock interval (spec §6, §9.3).
struct BoundsWindow: Equatable, Sendable {
    let startMs: Int?  // inclusive naive local ms; nil = −∞
    let endMs: Int?    // exclusive naive local ms; nil = +∞
}

/// The scope a `D` value or an `E#` ordinal is measured against (spec §2).
enum ScopeUnit: Sendable {
    case month, quarter, year
}

/// One `|`-branch: intersected components.
struct Expression: Sendable {
    var selectors: [Selector] = []
    var cadence: Cadence? = nil
    var bounds: BoundsWindow? = nil
    /// `W` present ⇒ the `Y` selector tests the ISO week-year (spec §2).
    var hasWeek = false
    var dayScope: ScopeUnit = .month
    var ordinalScope: ScopeUnit = .month
}
