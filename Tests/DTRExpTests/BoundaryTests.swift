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

// Counts meet dates: with integers bounded at 2,147,483,647 (spec §8) a count
// in milliseconds fits an Int, and a window end that would pass the timeline's
// edge (year 9999) or the Int range is held there instead of overflowing.

@Suite("Cadence arithmetic at the edges")
struct CadenceEdgeTests {

    @Test("a window whose end passes year 9999 runs to the edge",
          arguments: [("99990101/2Y/1Y", "9999-12-31T23:59:59Z", true),
                      ("99980101/2Y/1Y", "9999-06-01T00:00:00Z", false),
                      ("99991215/1M/20D", "9999-12-31T23:59:59Z", true),
                      ("00010101/2D", "9999-12-31T23:59:59Z", true),
                      ("20200101/2147483647Y/2147483646Y", "9999-12-31T23:59:59Z", true),
                      ("20200101/2147483647Y/2147483646Y", "2019-12-31T23:59:59Z", false),
                      ("20200101/2147483647M/2147483646M", "9999-12-31T23:59:59Z", true),
                      ("20200101/2147483647W/2147483646W", "9999-12-31T23:59:59Z", true),
                      ("20200101/2147483647m/2147483646m", "6103-01-24T02:05:00Z", true),
                      ("20200101/2147483647m/2147483646m", "6103-01-24T02:06:00Z", false),
                      // the next occurrence starts past year 9999: it covers nothing, and never traps
                      ("20200101/1000000000Y", "2021-06-01T00:00:00Z", false),
                      ("20200101/1000000000Y", "2020-06-01T00:00:00Z", true),
                      ("20200101/2147483647M", "9999-12-31T23:59:59Z", false)])
    func pastTheEdge(_ source: String, _ iso: String, _ expected: Bool) throws {
        #expect(try DTRExp(source).covers(at(iso)) == expected, "\(source) @ \(iso)")
    }

    @Test("past year 9999 a capped window keeps covering")
    func beyondTheEdge() throws {
        // Outside years 1-9999 the answer is the implementation's (spec §3.1):
        // here a window capped at the edge goes on covering.
        let year10000 = Date(timeIntervalSince1970: 253_415_433_600)  // 10000-06-01T00:00:00Z
        #expect(try DTRExp("99990101/2Y/1Y").covers(year10000))
        let january10000 = Date(timeIntervalSince1970: 253_403_510_400)  // 10000-01-15T00:00:00Z
        #expect(try DTRExp("99991201/2M/1M").covers(january10000))
    }

    @Test("a window end past the Int range saturates rather than trapping")
    func saturates() throws {
        // Far outside years 1-9999, where an answer is the implementation's;
        // what matters is that the arithmetic holds at the edge of Int.
        let far = Date(timeIntervalSince1970: 9.2233e15)
        #expect(try DTRExp("20200101/2147483647W/2147483646W").covers(far))
        #expect(addingSaturated(Int.max - 1, 2) == Int.max)
        #expect(addingSaturated(Int.max - 2, 1) == Int.max - 1)
        #expect(windowEndMs(NaiveDateTime(year: 9999, month: 12, day: 31)) == NaiveDateTime(year: 9999, month: 12, day: 31).naiveMs)
        #expect(windowEndMs(NaiveDateTime(year: 10000, month: 1, day: 1)) == Int.max)
    }
}
