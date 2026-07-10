import Foundation

/// A parsed DTRExp — a compact date-time range & recurrence expression
/// (spec draft 2.8), evaluated for **coverage**: "is this instant inside the
/// denoted set of intervals?"
///
/// ```swift
/// let businessHours = try DTRExp("T0900:1800 E1:5")
/// businessHours.covers(Date(), timeZone: TimeZone(identifier: "Europe/Berlin")!)
/// ```
///
/// Expressions are time-zone agnostic; the zone is a parameter of evaluation
/// (default UTC). Invalid expressions throw ``ParseError`` at initialization;
/// statically unsatisfiable ones parse and surface ``warnings``.
public struct DTRExp: Sendable {
    /// The original expression text.
    public let source: String

    /// Static-analysis findings (spec §9.1): the expression is valid but some
    /// part of it can never match — e.g. `D30 M2`. Warnings from every `|`
    /// branch surface here.
    public let warnings: [Warning]

    let branches: [Expression]

    /// Parses a DTRExp, throwing ``ParseError`` on invalid input.
    public init(_ source: String) throws(ParseError) {
        var parser = Parser(source)
        let branches = try parser.parse()
        self.source = source
        self.branches = branches
        self.warnings = computeWarnings(branches)
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

    /// Whether `instant` lies inside the expression's covered set, evaluated
    /// in `timeZone` (spec §9).
    public func covers(_ instant: Date, timeZone: TimeZone = TimeZone(identifier: "UTC")!) -> Bool {
        let fields = Fields(instant: instant, timeZone: timeZone)
        return branches.contains { expressionCovers($0, fields: fields, timeZone: timeZone) }
    }

    /// Whether `instant` lies inside the expression's covered set, evaluated
    /// in the zone named by the IANA identifier `tz`.
    /// Throws ``EvaluationError/unknownTimeZone(_:)`` for an unknown identifier.
    public func covers(_ instant: Date, tz identifier: String) throws -> Bool {
        guard let zone = TimeZone(identifier: identifier) else {
            throw EvaluationError.unknownTimeZone(identifier)
        }
        return covers(instant, timeZone: zone)
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
