import Foundation
import Testing
@testable import DTRExp

// Conformance runner over vectors.json (spec §12): every `invalid` expression
// must throw at parse; every `warnings` expression must parse while reporting
// a warning; every `quiet` expression must parse with NO warnings; every
// instant in every `coverage` group must return the expected boolean under
// the group's tz.

private struct VectorFile: Decodable {
    let spec: Double
    let coverage: [CoverageGroup]
    let invalid: [InvalidCase]
    let warnings: [WarningCase]
    let quiet: [QuietCase]
}

private struct CoverageGroup: Decodable {
    let id: String
    let expression: String
    let tz: String
    let cases: [String: Bool]
}

private struct InvalidCase: Decodable {
    let expression: String
    let reason: String
}

private struct WarningCase: Decodable {
    let expression: String
    let warning: String
}

private struct QuietCase: Decodable {
    let expression: String
    let note: String
}

private func loadVectors() throws -> VectorFile {
    let url = try #require(Bundle.module.url(forResource: "vectors", withExtension: "json"))
    return try JSONDecoder().decode(VectorFile.self, from: Data(contentsOf: url))
}

private func parseInstant(_ s: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    return fractional.date(from: s) ?? plain.date(from: s)
}

@Suite("Conformance vectors")
struct ConformanceVectors {

    @Test("invalid expressions are rejected at parse")
    func invalidExpressions() throws {
        let vectors = try loadVectors()
        #expect(!vectors.invalid.isEmpty)
        for c in vectors.invalid {
            #expect(throws: ParseError.self, "'\(c.expression)' should be rejected: \(c.reason)") {
                _ = try DTRExp(c.expression)
            }
        }
    }

    @Test("warning expressions parse but report a warning")
    func warningExpressions() throws {
        let vectors = try loadVectors()
        #expect(!vectors.warnings.isEmpty)
        for c in vectors.warnings {
            let expression = try DTRExp(c.expression)
            #expect(!expression.warnings.isEmpty,
                    "'\(c.expression)' should warn: \(c.warning)")
        }
    }

    @Test("quiet expressions parse with no warnings")
    func quietExpressions() throws {
        let vectors = try loadVectors()
        #expect(!vectors.quiet.isEmpty)
        for c in vectors.quiet {
            let expression = try DTRExp(c.expression)
            #expect(expression.warnings.isEmpty,
                    "'\(c.expression)' should stay quiet (\(c.note)), got \(expression.warnings)")
        }
    }

    @Test("coverage groups return the expected booleans")
    func coverageGroups() throws {
        let vectors = try loadVectors()
        #expect(!vectors.coverage.isEmpty)
        var checked = 0
        defer { #expect(checked > 0, "no coverage instants were exercised") }
        for group in vectors.coverage {
            let expression: DTRExp
            do {
                expression = try DTRExp(group.expression)
            } catch {
                Issue.record("[\(group.id)] '\(group.expression)' failed to parse: \(error)")
                continue
            }
            for (instantString, expected) in group.cases.sorted(by: { $0.key < $1.key }) {
                let instant = try #require(parseInstant(instantString), "unparseable instant \(instantString)")
                let got = try expression.covers(instant, tz: group.tz)
                checked += 1
                #expect(got == expected,
                        "[\(group.id)] '\(group.expression)' @ \(instantString) (\(group.tz)) expected \(expected)")
            }
        }
    }
}
