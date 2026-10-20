import Foundation

/// A parsed DTRExp — a compact date-time range & recurrence expression
/// (spec draft 2.9), evaluated for **coverage**: "is this instant inside the
/// denoted set of intervals?"
///
/// ```swift
/// let businessHours = try DTRExp("T0900:1800 E1:5")
/// businessHours.covers(Date(), timeZone: TimeZone(identifier: "Europe/Berlin")!)
/// ```
///
/// Expressions are time-zone agnostic; the zone is a parameter of evaluation
/// (default the bound ``zone``, see ``withZone(_:)-(TimeZone)``, else UTC). Invalid expressions throw ``ParseError`` at initialization;
/// statically unsatisfiable ones parse and surface ``warnings``.
public struct DTRExp: Sendable {
    /// The original expression text.
    public let source: String

    /// Static-analysis findings (spec §9.1): the expression is valid but some
    /// part of it can never match — e.g. `D30 M2`. Warnings from every `|`
    /// branch surface here.
    public let warnings: [Warning]

    /// The bound evaluation zone, or `nil` when unbound. Set by
    /// ``withZone(_:)-(TimeZone)``; a zone passed to a call still wins.
    public let zone: TimeZone?

    let branches: [Expression]

    /// Parses a DTRExp, throwing ``ParseError`` on invalid input.
    public init(_ source: String) throws(ParseError) {
        var parser = Parser(source)
        let branches = try parser.parse()
        self.source = source
        self.branches = branches
        self.warnings = computeWarnings(branches)
        self.zone = nil
    }

    private init(_ original: DTRExp, zone: TimeZone) {
        self.source = original.source
        self.branches = original.branches
        self.warnings = original.warnings
        self.zone = zone
    }

    /// Parses a DTRExp, throwing ``ParseError`` on invalid input — the fixed
    /// cross-language name (API Tier 1) for what ``init(_:)`` does natively.
    public static func parse(_ source: String) throws(ParseError) -> DTRExp {
        try DTRExp(source)
    }

    /// Checks `source` without throwing (spec §9.1, API Tier 1): invalid input
    /// comes back as data, not as a thrown error.
    ///
    /// ```swift
    /// DTRExp.validate("D30 M2")  // valid, one 'unsatisfiable' warning at offset 0
    /// DTRExp.validate("X5")      // invalid, one error at offset 0
    /// ```
    public static func validate(_ source: String) -> ValidationResult {
        do {
            let expression = try DTRExp(source)
            return ValidationResult(valid: true, errors: [], warnings: expression.warnings)
        } catch {
            return ValidationResult(valid: false, errors: [error], warnings: [])
        }
    }

    /// A copy of the expression whose evaluation defaults to `timeZone`,
    /// readable as ``zone``; the original is left as it is. The copy's
    /// ``source`` and ``warnings`` are the original's, since the zone belongs
    /// to evaluation, never to the expression. A zone passed to a call wins.
    ///
    /// ```swift
    /// let hours = try DTRExp("T0900:1800 E1:5").withZone(TimeZone(identifier: "Europe/Berlin")!)
    /// hours.covers(Date())  // evaluated in Berlin
    /// ```
    public func withZone(_ timeZone: TimeZone) -> DTRExp {
        DTRExp(self, zone: timeZone)
    }

    /// A copy of the expression whose evaluation defaults to the zone named by
    /// the IANA identifier; see ``withZone(_:)-(TimeZone)``. The identifier is
    /// checked here, at once: an unknown or empty one throws
    /// ``EvaluationError/unknownTimeZone(_:)``, so binding never falls back to
    /// UTC or the host's zone.
    public func withZone(_ identifier: String) throws -> DTRExp {
        guard let zone = Self.ianaZone(identifier) else {
            throw EvaluationError.unknownTimeZone(identifier)
        }
        return withZone(zone)
    }

    /// Whether `instant` lies inside the expression's covered set, evaluated
    /// in `timeZone` (spec §9): by default the bound ``zone``, else UTC. A
    /// `timeZone` passed here, UTC included, wins over the bound zone.
    public func covers(_ instant: Date, timeZone: TimeZone? = nil) -> Bool {
        let timeZone = timeZone ?? zone ?? Self.utc
        let fields = Fields(instant: instant, timeZone: timeZone)
        return branches.contains { expressionCovers($0, fields: fields, timeZone: timeZone) }
    }

    /// Whether `instant` lies inside the expression's covered set, evaluated
    /// in the zone named by the IANA identifier `tz`, which wins over the
    /// bound ``zone``.
    /// Throws ``EvaluationError/unknownTimeZone(_:)`` for an unknown identifier.
    public func covers(_ instant: Date, tz identifier: String) throws -> Bool {
        guard let zone = Self.ianaZone(identifier) else {
            throw EvaluationError.unknownTimeZone(identifier)
        }
        return covers(instant, timeZone: zone)
    }

    private static let utc = TimeZone(identifier: "UTC")!

    /// The zone an IANA identifier names, or `nil`.
    private static func ianaZone(_ identifier: String) -> TimeZone? {
        isIANAShaped(identifier) ? TimeZone(identifier: identifier) : nil
    }

    /// Whether `identifier` can be an IANA name at all. Some systems link
    /// zoneinfo's `localtime` to the host's zone; it is no IANA name, and nor
    /// is a path that is not normalized (`./localtime`, `a//b`) or the empty
    /// string. Foundation on Linux reads such paths from the zoneinfo folder.
    static func isIANAShaped(_ identifier: String) -> Bool {
        let segments = identifier.split(separator: "/", omittingEmptySubsequences: false)
        return !segments.contains { $0.isEmpty || $0 == "." } && segments.last != "localtime"
    }
}

/// The outcome of ``DTRExp/validate(_:)`` — the non-throwing counterpart of
/// the parsing initializer. An expression can be valid **and** warned; that is
/// the point of the errors/warnings distinction.
public struct ValidationResult: Sendable {
    /// Whether the expression parses.
    public let valid: Bool

    /// Positioned syntax errors; empty when ``valid``. Parse failure is the
    /// only failure, so at most one error is reported.
    public let errors: [ParseError]

    /// Positioned static-analysis findings (spec §9.1); empty when invalid.
    /// Same content as ``DTRExp/warnings`` on the parsed expression.
    public let warnings: [Warning]
}

/// Errors raised at evaluation time.
public enum EvaluationError: Error, CustomStringConvertible, Sendable {
    case unknownTimeZone(String)

    public var description: String {
        switch self {
        case .unknownTimeZone(let id): return "unknown IANA time zone identifier '\(id)'"
        }
    }
}
