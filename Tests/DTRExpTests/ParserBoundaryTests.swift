import Foundation
import Testing
@testable import DTRExp

// Validation-boundary tests derived from the manual mutation pass over the
// parser: each pins a domain edge (a max, a min, an inclusive endpoint) that a
// surviving off-by-one mutant would otherwise accept or reject wrongly.

@Suite("Parser domain boundaries")
struct ParserBoundaryTests {

    private func valid(_ s: String) -> Bool { DTRExp.validate(s).valid }
    private func message(_ s: String) -> String? { DTRExp.validate(s).errors.first?.message }

    // Date-literal calendar bounds.

    @Test("December date literals are accepted")
    func decemberDate() { #expect(valid("20241225")) }

    @Test("month zero is rejected")
    func monthZero() { #expect(!valid("20240001")) }

    @Test("a date literal accepts minute and second 59")
    func dateLiteralMaxTime() {
        #expect(valid("20240101T2359"))
        #expect(valid("20240101T235959"))
    }

    // Time-value bounds — both the two-digit hour form and the hhmm/hhmmss forms.

    @Test("bare hour 23 is a valid time value")
    func hour23() { #expect(valid("T23")) }

    @Test("23:59:59 is a valid time value")
    func timeMaxima() {
        #expect(valid("T2359"))
        #expect(valid("T120059"))
    }

    // Cadence: a duration equal in length to its period is not smaller than it.

    @Test("a seven-day duration is not smaller than a one-week period")
    func durationEqualsPeriodCrossUnit() { #expect(!valid("20240101/1W/7D")) }

    // A very large but in-range integer clears the overflow guard and is then
    // judged on its domain, not rejected as too large.
    @Test("a fifteen-digit period clears the size guard")
    func fifteenDigitPeriod() { #expect(valid("20240101/100000000000000D")) }

    // Year domain is 1…9999 inclusive at both ends.

    @Test("year 1 is in domain")
    func yearOne() { #expect(valid("Y1")) }

    @Test("year 0 is reported as out of domain, not as negative")
    func yearZero() {
        #expect(!valid("Y0"))
        #expect(message("Y0")?.contains("out of domain") == true)
    }

    // A stride interval equal to the parent domain size is allowed (only a
    // strictly larger one must become a cadence).

    @Test("a stride interval equal to the domain size is allowed")
    func strideIntervalEqualsDomain() { #expect(valid("M1/12")) }

    // The most-negative end-relative index equals the domain element count.

    @Test("the full negative weekday index is in domain")
    func fullNegativeWeekday() { #expect(valid("E-7")) }

    @Test("the full negative day index is in domain")
    func fullNegativeDay() { #expect(valid("D-31")) }

    @Test("day 31 is in the month-scope domain")
    func day31() { #expect(valid("D31")) }

    // A range with equal literal endpoints is a single value, never a wrap.

    @Test("M5:5 selects only month five")
    func equalEndpointRange() throws {
        let expr = try DTRExp("M5:5")
        #expect(try expr.covers(ISO8601DateFormatter().date(from: "2024-05-15T00:00:00Z")!, tz: "UTC"))
        #expect(!(try expr.covers(ISO8601DateFormatter().date(from: "2024-06-15T00:00:00Z")!, tz: "UTC")))
    }
}
