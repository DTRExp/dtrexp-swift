import Foundation
import Testing
@testable import DTRExp

// Behavioral tests for the corners the conformance vectors don't reach:
// evaluation-time errors, the quarter-scoped E# ordinal path, exclusion lists,
// and the parser's positioned rejections. Every case asserts observable
// behavior (a thrown error's identity/message, or a coverage boolean), never
// just line execution.

private func instant(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)!
}

@Suite("Evaluation errors")
struct EvaluationErrorTests {

    @Test("covers(tz:) throws on an unknown IANA identifier")
    func unknownZoneThrows() throws {
        let expr = try DTRExp("M1")
        #expect(throws: EvaluationError.self) {
            _ = try expr.covers(instant("2024-01-15T00:00:00Z"), tz: "Nowhere/Atlantis")
        }
    }

    @Test("a known identifier evaluates without throwing")
    func knownZoneEvaluates() throws {
        let expr = try DTRExp("M1")
        #expect(try expr.covers(instant("2024-01-15T00:00:00Z"), tz: "Europe/Berlin"))
    }

    @Test("unknownTimeZone renders the identifier in its description")
    func errorDescription() {
        let error = EvaluationError.unknownTimeZone("Foo/Bar")
        #expect(error.description == "unknown IANA time zone identifier 'Foo/Bar'")
    }
}

@Suite("Quarter-scoped ordinal weekday")
struct QuarterOrdinalTests {

    // With Q present and no M, the E# ordinal is measured against the quarter
    // (spec §2): E1#1 is the first Monday of the quarter, not of the month.

    @Test("first Monday of Q1 matches on the quarter's first Monday")
    func firstMondayOfQuarter() throws {
        let expr = try DTRExp("Q1 E1#1")  // 2024-01-01 is a Monday
        #expect(try expr.covers(instant("2024-01-01T12:00:00Z"), tz: "UTC"))
    }

    @Test("the second Monday is not the quarter's first")
    func secondMondayIsNotFirst() throws {
        let expr = try DTRExp("Q1 E1#1")
        #expect(!(try expr.covers(instant("2024-01-08T12:00:00Z"), tz: "UTC")))
    }

    @Test("last Monday of the quarter, counted from the quarter end")
    func lastMondayOfQuarter() throws {
        // Q1 2024 ends 2024-03-31; its last Monday is 2024-03-25.
        let expr = try DTRExp("Q1 E1#-1")
        #expect(try expr.covers(instant("2024-03-25T12:00:00Z"), tz: "UTC"))
        #expect(!(try expr.covers(instant("2024-03-18T12:00:00Z"), tz: "UTC")))
    }
}

@Suite("Exclusion value lists")
struct ExclusionListTests {

    // `M!1,2` is a comma value-list under exclusion: every month except 1 and 2.

    @Test("an exclusion list excludes each listed value")
    func excludesListed() throws {
        let expr = try DTRExp("M!1,2")
        #expect(!(try expr.covers(instant("2024-01-15T00:00:00Z"), tz: "UTC")))  // January excluded
        #expect(!(try expr.covers(instant("2024-02-15T00:00:00Z"), tz: "UTC")))  // February excluded
        #expect(try expr.covers(instant("2024-03-15T00:00:00Z"), tz: "UTC"))     // March kept
    }
}

@Suite("kindMatches dedicated-path guard")
struct KindMatchesGuardTests {

    // kindMatches is the numeric-domain matcher; ordinal (E#) and timeSpans (T)
    // are routed through their own paths in selectorMatches, so if either kind
    // ever reaches kindMatches it must decline rather than mis-match.

    @Test("ordinal and timeSpans kinds never match through kindMatches")
    func dedicatedKindsDecline() {
        #expect(!kindMatches(.ordinal(weekday: 1, ordinal: 2), value: 1, lo: 1, hi: 7))
        #expect(!kindMatches(.timeSpans([TimeSpan(startMs: 0, endMs: 1)]), value: 0, lo: 0, hi: 0))
    }
}

@Suite("fixedDurationMs precondition")
struct FixedDurationTests {

    // Month/year durations are handled by constrain arithmetic upstream, never by
    // fixedDurationMs; passing one is a programmer error and must trap, not lie.

    @Test("a month duration traps")
    func monthTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = fixedDurationMs(1, .month)
        }
    }

    @Test("a year duration traps")
    func yearTraps() async {
        await #expect(processExitsWith: .failure) {
            _ = fixedDurationMs(1, .year)
        }
    }
}

@Suite("Parser rejections")
struct ParserRejectionTests {

    private func message(_ source: String) -> String? {
        do { _ = try DTRExp(source); return nil }
        catch { return error.message }
    }

    @Test("an over-long integer literal is rejected before the domain check")
    func integerTooLarge() {
        #expect(message("M1234567890123456") == "value is too large")
    }

    @Test("a bare '*' component must open a '*:<date>' bounds range")
    func starOutsideSelector() {
        #expect(message("*M1") == "'*' outside a selector must start a '*:<date>' bounds range")
    }

    @Test("a date literal must be exactly eight digits")
    func shortDateLiteral() {
        #expect(message("1234") == "malformed date literal — expected 8 digits YYYYMMDD")
    }

    @Test("seconds past 59 in a date literal are rejected")
    func dateLiteralSeconds() {
        #expect(message("20240101T120060") == "seconds out of range in date literal")
    }

    @Test("an ordinal takes a single weekday, never a list")
    func ordinalOnList() {
        #expect(message("E1,2#1") == "ordinal '#' takes a single weekday value, never a list or range")
    }

    @Test("a stride start must be an explicit value, not '*'")
    func strideStarStart() {
        #expect(message("M*:5/2") == "stride start must be an explicit value ('*' has no anchor)")
    }

    @Test("a wrap range takes no stride")
    func wrapRangeStride() {
        #expect(message("M5:3/2") == "wrap ranges take no stride")
    }

    @Test("T takes no negative values")
    func timeNegative() {
        #expect(message("T-5") == "T takes no negative values")
    }

    @Test("sub-second fractions must be exactly three digits")
    func timeFraction() {
        #expect(message("T120000.12") == "milliseconds must be exactly 3 digits")
    }

    @Test("a malformed time value is rejected")
    func timeMalformed() {
        #expect(message("T1") == "malformed time value — expected hh, hhmm or hhmmss[.sss]")
    }

    @Test("'2400' is valid only as a range end")
    func lone2400() {
        #expect(message("T2400") == "'2400' is valid only as a range end")
    }

    @Test("Y has no edge to wrap a backwards range around")
    func backwardsYearRange() {
        #expect(message("Y2020:2010") == "backwards Y range — Y has no edge to wrap around")
    }
}
