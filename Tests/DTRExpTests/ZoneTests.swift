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

    @Test("only a normalized path not ending in localtime can be an IANA name")
    func ianaShaped() {
        for id in ["Europe/Berlin", "UTC", "America/Argentina/Buenos_Aires", "Etc/GMT+5"] {
            #expect(DTRExp.isIANAShaped(id), "\(id)")
        }
        for id in ["", "localtime", "posix/localtime", "./localtime", "Europe/./Berlin", "Europe//Berlin", "/UTC", "Europe/"] {
            #expect(!DTRExp.isIANAShaped(id), "\(id)")
        }
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

// Zone identifiers (API.md): the tz database's zone and link names, matched
// without regard to case and bound in the database's spelling; anything else
// is an unknown zone.

@Suite("Zone identifiers")
struct ZoneIdentifierTests {

    @Test("a tz name matches in any case and binds the database's spelling",
          arguments: [("europe/berlin", "Europe/Berlin"), ("EUROPE/BERLIN", "Europe/Berlin"),
                      ("us/eastern", "US/Eastern"), ("etc/gmt+5", "Etc/GMT+5"), ("asia/TOKYO", "Asia/Tokyo")])
    func anyCase(_ id: String, _ canonical: String) throws {
        let bound = try DTRExp(hours).withZone(id)
        #expect(bound.zone?.identifier == canonical)
        #expect(DTRExp.zoneNames[id.lowercased()] == canonical)
    }

    @Test("a lowercase name evaluates in its zone")
    func lowercaseEvaluates() throws {
        #expect(try DTRExp(hours).covers(t, tz: "europe/berlin"))  // 09:30 Berlin
        #expect(!(try DTRExp(hours).covers(t, tz: "utc")))
    }

    @Test("anything but a tz name is an unknown zone",
          arguments: ["+02:00", "UTC+2", "GMT+2", "Z", "posixrules", "Factory", "localtime", "SystemV/AST4",
                      "posix/Europe/Berlin", "right/UTC", "", "Mars/Olympus", "Europe/Berlin ", "GMT+0200"])
    func notAZone(_ id: String) throws {
        let expr = try DTRExp(hours)
        #expect {
            _ = try expr.withZone(id)
        } throws: { error in
            (error as? EvaluationError)?.description == "unknown IANA time zone identifier '\(id)'"
        }
        #expect(throws: EvaluationError.self) { _ = try expr.covers(t, tz: id) }
    }

    @Test("the names come from the tz source: its zones and links, without the files that name no zone")
    func tzSource() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("dtrexp-tzdata-\(UUID()).zi").path
        let source = """
            # version test
            R d 1916 o - Jun 14 23s 1 S
            Z Europe/Berlin 0:53:28 - LMT 1893 Ap
            Z Factory 0 - -00
            L Europe/Berlin Europe/Busingen
            L Etc/UTC UTC
            Z
            L Etc/UTC
            """
        try source.write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(DTRExp.tzDatabaseNames(source: path) == ["Europe/Berlin", "Factory", "Europe/Busingen", "UTC"])
        #expect(DTRExp.tzDatabaseNames(source: path + ".missing") == TimeZone.knownTimeZoneIdentifiers)
    }

    @Test("files of the zoneinfo folder that name no zone are filtered out")
    func notZones() {
        for name in ["Factory", "localtime", "posixrules", "SystemV/AST4", "posix/Europe/Berlin", "right/UTC"] {
            #expect(DTRExp.isNotAZone(name), "\(name)")
        }
        for name in ["Europe/Berlin", "UTC", "Etc/GMT+5", "US/Eastern", "Posix", "America/Argentina/Buenos_Aires", ""] {
            #expect(!DTRExp.isNotAZone(name), "\(name)")
        }
        #expect(DTRExp.zoneNames["factory"] == nil)
        #expect(DTRExp.zoneNames["utc"] == "UTC")
        #expect(DTRExp.zoneNames(from: ["Europe/Berlin", "Factory", "posix/Asia/Tokyo"])
                == ["utc": "UTC", "europe/berlin": "Europe/Berlin"])
    }
}
