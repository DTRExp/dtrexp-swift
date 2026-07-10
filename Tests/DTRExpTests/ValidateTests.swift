import Testing
@testable import DTRExp

// `validate` (API Tier 1): the non-throwing counterpart of the parsing
// initializer — syntax errors and §9.1 warnings come back as positioned data.

@Suite("validate")
struct ValidateTests {

    @Test("static parse is the initializer under the fixed cross-language name")
    func staticParse() throws {
        let viaParse = try DTRExp.parse("T0900:1800 E1:5")
        let viaInit = try DTRExp("T0900:1800 E1:5")
        #expect(viaParse.source == viaInit.source)
        #expect(viaParse.warnings == viaInit.warnings)
        #expect(throws: ParseError.self) { try DTRExp.parse("M1 X5") }
    }

    @Test("valid input: valid, no errors, no warnings")
    func validInput() {
        let result = DTRExp.validate("T0900:1800 E1:5")
        #expect(result.valid)
        #expect(result.errors.isEmpty)
        #expect(result.warnings.isEmpty)
    }

    @Test("invalid input: one positioned error, no warnings, nothing thrown")
    func invalidInput() {
        let result = DTRExp.validate("M1 X5")
        #expect(!result.valid)
        #expect(result.errors.count == 1)
        #expect(result.errors.first?.message == "unexpected character 'X'")
        #expect(result.errors.first?.position == 3)
        #expect(result.warnings.isEmpty)
    }

    @Test("empty input is invalid, not a crash")
    func emptyInput() {
        let result = DTRExp.validate("")
        #expect(!result.valid)
        #expect(result.errors.count == 1)
        #expect(result.warnings.isEmpty)
    }

    @Test("warned input: valid with a positioned warning")
    func warnedInput() {
        let result = DTRExp.validate("D30 M2")
        #expect(result.valid)
        #expect(result.errors.isEmpty)
        #expect(result.warnings.count == 1)
        #expect(result.warnings.first?.position == 0)
    }

    @Test("warnings equal the initializer's",
          arguments: ["T0900:1800 E1:5", "D30 M2", "M-1 Q1", "M-2:2", "W53 Y2021", "M1 | D30 M2"])
    func warningsMatchInitializer(_ source: String) throws {
        let expression = try DTRExp(source)
        #expect(DTRExp.validate(source).warnings == expression.warnings)
    }
}

// Warning positions: the 0-based offset of the offending selector, absolute
// into the whole source — including selectors past a `|`.

@Suite("Warning positions")
struct WarningPositionTests {

    @Test("the offending selector's designator offset")
    func offendingSelectorOffset() throws {
        let expression = try DTRExp("M2 D30")
        #expect(expression.warnings.map(\.position) == [3])
    }

    @Test("M ∩ Q disjointness points at the month selector")
    func monthQuarterOffset() throws {
        let expression = try DTRExp("E1 M-1 Q1")
        #expect(expression.warnings.count == 1)
        #expect(expression.warnings.first?.position == 3)
    }

    @Test("offsets stay absolute across '|' branches")
    func branchOffsets() throws {
        let expression = try DTRExp("M1 | D30 M2")
        #expect(expression.warnings.map(\.position) == [5])
    }

    @Test("W53 in a 52-week year points at the week selector")
    func weekOffset() throws {
        let expression = try DTRExp("Y2021 W53")
        #expect(expression.warnings.map(\.position) == [6])
    }

    @Test("description renders the position like ParseError")
    func descriptionRendering() {
        #expect(Warning(message: "boom", at: 4).description == "boom (at offset 4)")
        #expect(Warning(message: "boom").description == "boom")
        #expect(ParseError("boom", at: 4).description == "boom (at offset 4)")
    }
}
