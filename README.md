# dtrexp-swift

Swift implementation of **[DTRExp](https://github.com/DTRExp/dtrexp)** (read: "**DTR Expression**") — a compact string expression for date-time ranges and recurrence, evaluated by **coverage** rather than enumeration.

```
T0900:1800 E1:5          Mon–Fri, 09:00–18:00
E7#-1 M4                 last Sunday of April, every year
20200106/10D             every 10 days from 2020-01-06 (cron can't say this)
M!7                      every month except July
```

Scope: **parsing, validation and coverage evaluation** — the spec's core interface. Rendering, description and RRULE export are out of scope; the [reference implementation][js] has them.

## Install

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/DTRExp/dtrexp-swift", from: "1.0.0")
```

Then depend on the `DTRExp` product from your target:

```swift
.product(name: "DTRExp", package: "dtrexp-swift")
```

Swift 6.0+, Foundation only (`TimeZone` and `Date` for IANA zones and instants).

## Usage

```swift
import DTRExp

let dtr = try DTRExp("T0900:1800 E1:5")    // business hours, Mon–Fri

let berlin = TimeZone(identifier: "Europe/Berlin")!
dtr.covers(Date(), timeZone: berlin)
// —> true on a weekday, 09:00–18:00 Berlin local time
// The zone is an evaluation parameter, never part of the expression;
// omit it and evaluation is in UTC.

// By IANA name; throws on an unknown identifier:
let ok = try dtr.covers(Date(), tz: "Europe/Berlin")
```

`DTRExp("…")` and the equivalent static `DTRExp.parse("…")` both parse; `parse` is the fixed cross-language name for what the initializer does natively.

Note that you parse **once** (at write/config time) and evaluate **many**; a `DTRExp` value is an immutable `struct`, `Sendable`, and safe to share across concurrent evaluations. `covers` is a single calendar-field extraction followed by integer comparisons — no occurrence iteration.

## Errors and warnings

An error and a warning each carry a **position**; the 0-based character offset into the source, when known:

```swift
do {
    _ = try DTRExp("Y*/3")             // anchorless stride — a syntax error
} catch let error {                    // typed catch — error is a ParseError
    error.position                     // points at the offending character
}

let result = DTRExp.validate("D30 M2") // never throws
result.valid                           // true — it parses
result.warnings                        // [Warning] — no February has 30 days
```

- `DTRExp(_:)` and `DTRExp.parse(_:)` return the parsed value or throw a `ParseError` (*message* `String`, *position* `Int?`). Both are typed as `throws(ParseError)`.
- `DTRExp.validate(_:)` never throws; typo-shaped input comes back as data. Returns a `ValidationResult` with *valid* `Bool`, *errors* `[ParseError]` (parsing stops at the first syntax error, so at most one) and *warnings* `[Warning]`.
- Warnings are the spec's [§9.1](https://github.com/DTRExp/dtrexp/blob/main/spec.md#91-the-existence-rule) unsatisfiability lint — expressions that parse but can never match. The parsed value's `warnings` property and `validate(_:).warnings` carry the same content.
- `covers(_:tz:)` throws an `EvaluationError` for an unknown IANA identifier. The zone-typed `covers(_:timeZone:)` cannot fail.

## Conformance & quality

- The test suite is driven by the shared [`vectors.json`][vectors] from the spec repo (draft 2.8), vendored at `Tests/DTRExpTests/Resources/vectors.json` — every coverage, rejection, warning and quiet vector, including the calendar traps (Feb 29 across 2000/2024/**2100**, `W53` existence, DST gap/overlap in `Europe/Berlin`). Run the suite with `swift test`. See [VECTORS.md][vectors-md] for how the vectors are structured.
- Zero dependencies.

## Related projects

- [**dtrexp** (spec)][spec] — the DTRExp specification (grammar, semantics, conformance vectors) this package implements.
- [**dtrexp-js**][js] — the reference implementation; adds `intersect`, `next`, `describe`, `toRRule` and canonicalization.
- [**dtrexp-py**][py] · [**dtrexp-go**][go] · [**dtrexp-rs**][rs] · [**dtrexp-java**][java] — the other ports; same core interface.

## License

© 2026, Onur Yıldırım. [**MIT**](LICENSE) License.

[spec]: https://github.com/DTRExp/dtrexp
[js]: https://github.com/DTRExp/dtrexp-js
[py]: https://github.com/DTRExp/dtrexp-py
[go]: https://github.com/DTRExp/dtrexp-go
[rs]: https://github.com/DTRExp/dtrexp-rs
[java]: https://github.com/DTRExp/dtrexp-java
[vectors]: https://github.com/DTRExp/dtrexp/blob/main/vectors.json
[vectors-md]: https://github.com/DTRExp/dtrexp/blob/main/VECTORS.md
