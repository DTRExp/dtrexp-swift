import Testing
@testable import DTRExp

// Static-analysis boundary tests derived from the manual mutation pass over the
// warning logic: the month-to-quarter mapping, the quarter length table, and
// the concrete-year enumeration that decides W/D satisfiability.

@Suite("Warning static-analysis boundaries")
struct WarningBoundaryTests {

    private func warns(_ s: String) throws -> Bool { try !DTRExp(s).warnings.isEmpty }

    // A month falls in the quarter (m - 1) / 3 + 1; March is Q1, not Q2.

    @Test("a month inside its quarter is quiet")
    func monthInQuarterQuiet() throws {
        #expect(!(try warns("M3 Q1")))   // March is in Q1
        #expect(!(try warns("M6 Q2")))   // June is in Q2
    }

    @Test("a month outside the selected quarter still warns")
    func monthOutsideQuarterWarns() throws {
        #expect(try warns("M3 Q2"))      // March is not in Q2
    }

    // Q1 is at most 91 days (leap year); day 92 of Q1 can never occur.

    @Test("day 92 of Q1 is unsatisfiable")
    func day92Quarter1() throws {
        #expect(try warns("D92 Q1"))
        #expect(!(try warns("D91 Q1")))  // day 91 occurs in a leap year
    }

    // A single-value Y range and a single-point Y stride each enumerate to one
    // concrete year, so W53 against a 52-week year is caught as unsatisfiable.

    @Test("a single-value year range enumerates its one year")
    func singleValueYearRange() throws {
        #expect(try warns("Y2000:2000 W53"))   // 2000 is a 52-week year
    }

    @Test("a single-point year stride enumerates its one year")
    func singlePointYearStride() throws {
        #expect(try warns("Y2000:2000/2 W53"))
    }

    // The stride on/off test is half-open: with interval 5 and duration 1 only
    // the anchor year is on, so a 53-week year one step past it stays excluded.

    @Test("a strided year set excludes the year past its duration")
    func stridedYearDurationBoundary() throws {
        #expect(try warns("Y2003:2004/5 W53"))  // only 2003 (52 weeks) is on
    }
}
