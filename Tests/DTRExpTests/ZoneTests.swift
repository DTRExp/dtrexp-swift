import Foundation
import Testing
@testable import DTRExp

// withZone(): a bound copy evaluates in its zone by default; a zone passed to a
// call wins, and the original is left as it is. Tuesday 07:30 UTC is 09:30 in
// Berlin (CEST): inside 09:00–18:00 there, outside it in UTC.

private let hours = "T0900:1800 E1:5"
private let t = Date(timeIntervalSince1970: 1_783_409_400)  // 2026-07-07T07:30:00Z
private let berlinZone = TimeZone(identifier: "Europe/Berlin")!
private let utcZone = TimeZone(identifier: "UTC")!

@Suite("withZone()")
struct WithZoneTests {

    @Test("returns a bound copy and leaves the original unbound")
    func boundCopy() throws {
        let expr = try DTRExp(hours)
        let berlin = expr.withZone(berlinZone)
        #expect(berlin.zone == berlinZone)
        #expect(expr.zone == nil)
        #expect(!expr.covers(t))  // UTC
        #expect(berlin.covers(t))  // 09:30 Berlin
    }

    @Test("binds by IANA identifier")
    func bindByIdentifier() throws {
        let berlin = try DTRExp(hours).withZone("Europe/Berlin")
        #expect(berlin.zone?.identifier == "Europe/Berlin")
        #expect(berlin.covers(t))
    }

    @Test("a zone passed to a call wins over the bound zone")
    func callZoneWins() throws {
        let berlin = try DTRExp(hours).withZone(berlinZone)
        #expect(!berlin.covers(t, timeZone: utcZone))
        #expect(berlin.covers(t, timeZone: nil))  // nil is no zone passed
        #expect(!(try berlin.covers(t, tz: "UTC")))
        let utc = try DTRExp(hours).withZone(utcZone)
        #expect(utc.covers(t, timeZone: berlinZone))
        #expect(try utc.covers(t, tz: "Europe/Berlin"))
    }

    @Test("rebinds a bound copy")
    func rebind() throws {
        let berlin = try DTRExp(hours).withZone(berlinZone)
        let tokyo = try berlin.withZone("Asia/Tokyo")
        let later = t.addingTimeInterval(2 * 3600)  // 09:30 UTC
        #expect(tokyo.zone?.identifier == "Asia/Tokyo")
        #expect(!tokyo.covers(later))  // 18:30 Tokyo
        #expect(berlin.covers(later))  // 11:30 Berlin
    }

    @Test("refuses localtime in a call too, which some systems link to the host's zone")
    func localtimeInACall() throws {
        let expr = try DTRExp(hours)
        #expect {
            _ = try expr.covers(Date(), tz: "localtime")
        } throws: { error in
            (error as? EvaluationError)?.description == "unknown IANA time zone identifier 'localtime'"
        }
    }

    @Test("throws at once on an unknown or empty identifier")
    func unknownOrEmpty() throws {
        let expr = try DTRExp(hours)
        for id in ["Mars/Olympus", "", "Local", "localtime", "./localtime", "posix/localtime", "Europe//Berlin"] {
            #expect {
                _ = try expr.withZone(id)
            } throws: { error in
                (error as? EvaluationError)?.description == "unknown IANA time zone identifier '\(id)'"
            }
        }
    }

    @Test("leaves everything about the expression itself unchanged")
    func expressionUnchanged() throws {
        for source in [hours, "D30 M2"] {
            let expr = try DTRExp(source)
            let bound = expr.withZone(berlinZone)
            #expect(bound.source == expr.source)
            #expect(bound.warnings == expr.warnings)
            #expect(bound.branches.count == expr.branches.count)
        }
        #expect(!(try DTRExp("D30 M2").withZone(berlinZone).warnings.isEmpty))
    }
}
