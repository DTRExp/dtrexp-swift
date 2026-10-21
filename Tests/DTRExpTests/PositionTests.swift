import Foundation
import Testing
@testable import DTRExp

// Error positions (spec §8): every syntax error carries the 0-based offset, in
// Unicode code points, of the first character of the token at fault, by three
// rules. The vectors pin one case or two per rule; these pin the rest of the
// parser's paths, one per rule and error site.

@Suite("Error positions")
struct ErrorPositionTests {

    private func position(_ source: String) -> Int? { DTRExp.validate(source).errors.first?.position }

    @Test("where the grammar accepts no token: the first token it cannot accept",
          arguments: [
              ("", 0), ("   ", 3), ("M3 | | M5", 5), ("M1|  ", 5), ("M", 1), ("M |M1", 1), ("M٣", 1),
              ("*", 1), ("* M1", 1), ("*:", 2), ("*:*", 2), ("20200101/D", 9), ("20200101/10", 11),
              ("20200101/1D/", 12), ("20200101/1D/5", 13), ("M1,3/2", 4), ("D5#2", 2), ("E1,2#1", 4),
              ("E1:2#1", 4), ("M!*", 2), ("M1,*", 3), ("T0900.500", 5), ("T0900:*", 6), ("M1/", 3),
              ("M1/2/", 5), ("M:5", 1), ("M1:", 3), ("E1#", 3),
          ] as [(String, Int)])
    func noToken(_ source: String, _ expected: Int) {
        #expect(position(source) == expected, "\(source)")
    }

    @Test("a value, date literal or count the rules do not allow: that token",
          arguments: [
              ("M13", 1), ("Q2 D40 M1", 4), ("M1:20", 3), ("M13:20", 1), ("H1,2,24", 5), ("M!13", 2),
              ("D-32", 1), ("Y0", 1), ("Y-1", 1), ("Y12000", 1), ("E8#1", 1), ("E7#6", 3), ("E7#0", 3),
              ("M-0", 1), ("H1,-0", 3), ("E1#-0", 3), ("M3/14", 3), ("M1/1", 3), ("M1/3/3", 5),
              ("M1:6/20", 5), ("M13:14/2", 1), ("M1:13/2", 3), ("M1:12/2/13", 8), ("20200101/0D", 9), ("20200101/1D/0D", 12), ("20200101/10D/1M", 13),
              ("20200101/10D/20D", 13), ("20240131/1M", 9), ("20200101/1D/24H", 12),
              ("20230229/1Y", 0), ("20180120T09", 0), ("20180120T2400", 0), ("20180120T235960", 0),
              ("*:20181301", 2), ("00000101", 0), ("00000101/1D", 0), ("*:00000101", 2),
              ("20200101:00000101", 9), ("2020010120200102/10D", 0), ("M2147483648", 1),
              ("M-2147483648", 1), ("Y1:*/2147483648", 5), ("M1/3/2147483648", 5), ("E1#2147483648", 3),
              ("20200101/2147483648D", 9), ("20200101/1D/2147483648H", 12),
          ] as [(String, Int)])
    func badToken(_ source: String, _ expected: Int) {
        #expect(position(source) == expected, "\(source)")
    }

    @Test("a rule between two tokens: the later one",
          arguments: [
              ("M3 M5", 3), ("20200106/10D 20300101/10D", 13), ("M3 20180101:* 20190101:*", 14),
              ("20180301:20170301", 9), ("20180120T1801:20180120T1800", 14), ("T0900:0900", 6),
              ("T12:1200", 4), ("H22:0/2", 5), ("M5:2/2", 4), ("Y*/3", 2), ("M*:5/2", 4), ("D-10:*/2", 6),
              ("M-1/2", 3), ("Y2030:2020", 6), ("Y2030:2020/2", 6), ("Y5:1/2", 3),
          ] as [(String, Int)])
    func laterToken(_ source: String, _ expected: Int) {
        #expect(position(source) == expected, "\(source)")
    }

    @Test("a rule error reads on to the end of its branch, a later grammar error included",
          arguments: [
              ("M13,X", 1), ("Y2020:2019,X", 6), ("Y-1 X", 1), ("Y0 X", 1), ("M-0 X", 1), ("M0 X", 1),
              ("M-13 X", 1), ("E7#0 X", 3), ("E7#6 X", 3), ("M1/1 X", 3), ("M1/13 X", 3), ("M1/3/3 X", 5),
              ("H22:0/2 X", 5), ("Y*/3 X", 2), ("M*:3/2 X", 4), ("M-1:3/2 X", 5), ("M2147483648 X", 1),
              ("T25 X", 1), ("T0960 X", 1), ("T2400 X", 1), ("T2400:0100 X", 1), ("T090060 X", 1),
              ("T1 X", 1), ("T090 X", 1), ("T0900:0900,X", 6), ("T090000.5 X", 7), ("T2500:2600 X", 1),
              ("20230229 X", 0), ("20200101T2400 X", 0), ("20200101T000060 X", 0), ("2020010 X", 0),
              ("20200101T09 X", 0), ("20200101/0D X", 9), ("20200101/2D/0D X", 12),
              ("20200101/2D/3D X", 12), ("20200101/2D/1M X", 12), ("20200101/1D/24H X", 12),
              ("20180301:20170301 X", 9), ("20200101 20200102 X", 9), ("20200101 *:20200102 X", 9),
              ("20200101/2D 20200101/2D X", 12), ("M1 M2 X", 3),
          ] as [(String, Int)])
    func readsOn(_ source: String, _ expected: Int) {
        #expect(position(source) == expected, "\(source)")
    }

    @Test("D's domain waits for its scope: a grammar error first wins, a complete branch competes",
          arguments: [
              ("D40 M3/1", 1), ("D40 20230229", 1), ("D2/40 X", 6), ("D2/40 M1", 3), ("D-40 M3/1", 1),
              ("D1:40 Q1 M13", 3), ("D!40", 2), ("D1,40", 3), ("D*:40", 3), ("D40/2", 1),
              ("D1:40/2 M1", 3), ("D*/2", 2), ("D366 Q1", 1), ("D40:41", 1), ("D40:41/2", 1),
              ("D1/32", 3), ("D40 T1", 1), ("D40 T:0900", 5), ("D40 M*5", 1), ("20200101/0D/1H", 9),
              ("D0 X", 3), ("D-0 X", 1),
          ] as [(String, Int)])
    func daysWait(_ source: String, _ expected: Int) {
        #expect(position(source) == expected, "\(source)")
    }

    @Test("a whole-domain D waits for no scope")
    func wholeDay() {
        #expect(DTRExp.validate("D* M2").errors.isEmpty)
        #expect(DTRExp.validate("D1/31").errors.isEmpty)  // a stride over D's whole domain
        #expect(DTRExp.validate("M1/3/1").errors.isEmpty)  // a duration of 1
    }

    @Test("positions count code points, not grapheme clusters")
    func codePoints() {
        // A combining mark after a space joins it in one grapheme cluster, but
        // it is a code point of its own: the space is fine, the mark is not.
        #expect(position("M1 \u{301}M5") == 3)
        #expect(position(" \u{301}M1") == 1)
        #expect(position("M1\u{301}") == 2)
    }

    @Test("every error carries a position")
    func alwaysPositioned() {
        for source in ["M-0", "Q2 D40 M1", "Y0", "M3/14", "E8#1", "Y2030:2020", "20230229/1Y"] {
            #expect(DTRExp.validate(source).errors.first?.position != nil, "\(source)")
        }
    }
}

@Suite("Integers and date literals")
struct IntegerLimitTests {

    private func valid(_ s: String) -> Bool { DTRExp.validate(s).valid }

    @Test("leading zeros are free; the value is what is bounded")
    func leadingZeros() throws {
        #expect(valid("M00000003"))
        #expect(valid("M0000000000000003"))
        #expect(valid("E1#00000000000000000001"))
        #expect(valid("Y1:*/0000002147483647"))
        let expr = try DTRExp("M0000000000000000000003 20200101/000000000000000000010D")
        #expect(expr.covers(Date(timeIntervalSince1970: 1_583_020_800)))   // 2020-03-01, 60 days on
        #expect(!expr.covers(Date(timeIntervalSince1970: 1_583_107_200)))  // 2020-03-02
    }

    @Test("a count far above the limit is a syntax error, never a trap at covers")
    func noTrap() {
        let result = DTRExp.validate("20200101/1000000000000D")
        #expect(!result.valid)
        #expect(result.errors.first?.position == 9)
    }

    @Test("a date literal's year is 1-9999")
    func yearZero() {
        #expect(!valid("00000101"))
        #expect(valid("00010101"))
        #expect(DTRExp.validate("00000101").errors.first?.message == "'00000101' is not a real calendar date")
    }
}
