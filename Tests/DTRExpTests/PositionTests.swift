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
