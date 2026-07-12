import Foundation
import Testing
@testable import DTRExp

// Boundary and inclusivity tests derived from the manual mutation pass: each
// pins a comparison or arithmetic edge that a surviving mutant would otherwise
// slip through. White-box helper checks pin the floor-arithmetic contract that
// only fires on inputs the public API rarely reaches (pre-epoch day numbers).

private func at(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

@Suite("Floor arithmetic contract")
struct FloorArithmeticTests {

    // floorDiv / floorMod must floor toward negative infinity, distinct from
    // Swift's truncating `/` and `%`. The adjustment fires only on a negative,
    // non-exact quotient — exact negatives must NOT be adjusted.

    @Test("floorDiv floors toward negative infinity")
    func floorDivContract() {
        #expect(floorDiv(13, 4) == 3)
        #expect(floorDiv(12, 4) == 3)
        #expect(floorDiv(-13, 4) == -4)   // non-exact negative: rounds down
        #expect(floorDiv(-12, 4) == -3)   // exact negative: no adjustment
        #expect(floorDiv(-1, 4) == -1)
    }

    @Test("floorMod returns a non-negative residue")
    func floorModContract() {
        #expect(floorMod(1, 7) == 1)
        #expect(floorMod(-1, 7) == 6)
        #expect(floorMod(-7, 7) == 0)
        #expect(floorMod(-8, 7) == 6)
    }
}

@Suite("Century leap year")
struct CenturyLeapTests {

    // 2000 is a leap year (÷400); the last day of February is the 29th. This
    // pins the `y % 400 == 0` arm of the Gregorian leap rule.

    @Test("the last day of February 2000 is the 29th")
    func feb2000LastDay() throws {
        let expr = try DTRExp("M2 D-1")  // last day of February
        #expect(try expr.covers(at("2000-02-29T12:00:00Z"), tz: "UTC"))
        #expect(!(try expr.covers(at("2000-02-28T12:00:00Z"), tz: "UTC")))
    }
}

@Suite("Calendar cadence windows")
struct CalendarCadenceTests {

    // A monthly window lands on the constrained anchor day of each period; the
    // occurrence-index search must find it even when the naive month estimate
    // is off by one in either direction.

    @Test("a monthly window matches in a later month")
    func monthlyWindowLaterMonth() throws {
        let expr = try DTRExp("20240115/1M/3D")  // 15th of each month, 3 days
        #expect(try expr.covers(at("2024-03-16T00:00:00Z"), tz: "UTC"))
        #expect(!(try expr.covers(at("2024-03-19T00:00:00Z"), tz: "UTC")))
    }

    @Test("a window anchored on the 31st is found in a shorter month")
    func monthlyWindowAnchorEndOfMonth() throws {
        // Anchor 2024-01-31; the k=0 window [01-31, 02-02) contains 02-01, even
        // though the naive month estimate points one period later.
        let expr = try DTRExp("20240131/1M/2D")
        #expect(try expr.covers(at("2024-02-01T00:00:00Z"), tz: "UTC"))
    }

    @Test("a one-year window spans the full twelve months")
    func yearlyWindowFullYear() throws {
        let expr = try DTRExp("20200101/2Y/1Y")  // active for one year every two
        #expect(try expr.covers(at("2020-12-15T00:00:00Z"), tz: "UTC"))  // month 12 still inside
        #expect(!(try expr.covers(at("2021-06-15T00:00:00Z"), tz: "UTC")))  // year 2 is off
    }
}

@Suite("Sub-daily cadence window")
struct SubDailyCadenceTests {

    // A 30-minute window every 2 hours, anchored at midnight UTC. The window is
    // half-open [anchor, anchor+30m): the anchor instant is inside, the instant
    // exactly 30 minutes in is not.

    @Test("the anchor instant itself is covered")
    func anchorInstantCovered() throws {
        let expr = try DTRExp("20240101T0000/2H/30m")
        #expect(try expr.covers(at("2024-01-01T00:00:00Z"), tz: "UTC"))
    }

    @Test("the last instant before the window closes is covered")
    func lastInstantCovered() throws {
        let expr = try DTRExp("20240101T0000/2H/30m")
        #expect(try expr.covers(at("2024-01-01T00:29:59Z"), tz: "UTC"))
    }

    @Test("the instant exactly at the window end is excluded")
    func windowEndExcluded() throws {
        let expr = try DTRExp("20240101T0000/2H/30m")
        #expect(!(try expr.covers(at("2024-01-01T00:30:00Z"), tz: "UTC")))
    }
}
