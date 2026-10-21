<p align="center"><img src="./.github/logo.svg" width="200" alt="dtrexp-swift" /></p>

# dtrexp-swift

Swift implementation of **[DTRExp](https://github.com/DTRExp/dtrexp)** (read: "**DTR Expression**") — a compact string expression for date-time ranges and recurrence, evaluated by **coverage** rather than enumeration.

```
T0900:1800 E1:5          Mon–Fri, 09:00–18:00
E7#-1 M4                 last Sunday of April, every year
20200106/10D             every 10 days from 2020-01-06 (cron can't say this)
M!7                      every month except July
```

Scope: **parsing, validation and coverage evaluation** (the spec's core interface). Rendering, description and RRULE export are out of scope; the [reference implementation][js] has them.

## Install

Add the package to your `Package.swift`:

```swift
.package(url: "https://github.com/DTRExp/dtrexp-swift", from: "1.2.0")
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
// omit it and evaluation is in the bound zone, else UTC.

// By IANA name; throws on an unknown identifier:
let ok = try dtr.covers(Date(), tz: "Europe/Berlin")

// Bind the zone once; a copy, dtr is left as it is:
let hours = try dtr.withZone("Europe/Berlin")
hours.covers(Date())                       // in Berlin
try hours.covers(Date(), tz: "UTC")        // a zone passed to the call wins
```

`DTRExp("…")` and the equivalent static `DTRExp.parse("…")` both parse; `parse` is the fixed cross-language name for what the initializer does natively.

Note that you parse **once** (at write/config time) and evaluate **many**; a `DTRExp` value is an immutable `struct`, `Sendable`, and safe to share across concurrent evaluations. `covers` is a single calendar-field extraction followed by integer comparisons; no occurrence iteration.

**Which to use:** bind the zone with `withZone(_:)` when it belongs to what the expression describes (a store's hours, a venue's schedule), and pass the zone per call when it belongs to whoever is asking (a rule shown to each user in their own zone). A bound copy shares its `source` with the original, so a cache of parsed expressions keys on `source` and `zone` together.

### Time Zones

An identifier is one of the tz database's zone and link names (`Europe/Berlin`, `US/Eastern`, `UTC`, `Etc/GMT+5`), matched without regard to case: `europe/berlin` works, and `withZone("europe/berlin").zone?.identifier` is `"Europe/Berlin"`. The names come from the tz source file that ships beside the compiled zones (`/usr/share/zoneinfo/tzdata.zi`; Foundation's `TimeZone.knownTimeZoneIdentifiers` where the file is missing, though that list leaves out the links), so the answer never depends on whether the file system ignores case. Anything else is an unknown zone, even where Foundation would take it: a fixed offset (`+02:00`, `UTC+2`), `Z`, the zoneinfo files that name no zone (`posixrules`, `Factory`, `localtime`, `SystemV/*`, the `posix/` and `right/` copies) and the empty name.

The zone rules are Foundation's, read from the system's tz database: on Apple platforms the one the OS release ships, on Linux the `/usr/share/zoneinfo` of the system's `tzdata` package. Two machines agree wherever their tz releases agree; to pin a release, pin the OS or the `tzdata` package.

## Errors and Warnings

An error and a warning each carry a **position**. An error's position is the 0-based offset, in Unicode code points (not `Character`s), of the first character of the token at fault, as [spec §8](https://github.com/DTRExp/dtrexp/blob/main/spec.md#8-grammar-ebnf) defines it; the same in every DTRExp implementation:

```swift
do {
    _ = try DTRExp("Y*/3")             // anchorless stride — a syntax error
} catch let error {                    // typed catch — error is a ParseError
    error.position                     // 2: the '/' the anchorless start does not allow
}

let result = DTRExp.validate("D30 M2") // never throws
result.valid                           // true — it parses
result.warnings                        // [Warning] — no February has 30 days
```

- `DTRExp(_:)` and `DTRExp.parse(_:)` return the parsed value or throw a `ParseError` (*message* `String`, *position* `Int?`, always set). Both are typed as `throws(ParseError)`. An integer is at most 2,147,483,647 (leading zeros are free: `M0000000003` is `M3`); a larger one is a syntax error at that integer, never a trap at evaluation.
- `DTRExp.validate(_:)` never throws; typo-shaped input comes back as data. Returns a `ValidationResult` with *valid* `Bool`, *errors* `[ParseError]` (parsing stops at the first syntax error, so at most one) and *warnings* `[Warning]`.
- Warnings are the spec's [§9.1](https://github.com/DTRExp/dtrexp/blob/main/spec.md#91-the-existence-rule) unsatisfiability lint: expressions that parse but can never match. The parsed value's `warnings` property and `validate(_:).warnings` carry the same content.
- `covers(_:tz:)` throws an `EvaluationError` for an unknown IANA identifier (see Time Zones above). The zone-typed `covers(_:timeZone:)` cannot fail; its default (`nil`) is the bound `zone`, else UTC, and a zone passed to either call wins over the bound one.
- `withZone(_:)` returns a copy whose evaluation defaults to that zone, readable as `zone` (`TimeZone?`, `nil` when unbound); its `source` and `warnings` are the original's. The `TimeZone` form cannot fail; the identifier form throws `EvaluationError.unknownTimeZone` at once for an unknown or empty identifier, so binding never falls back to UTC or the host's zone.

## Conformance & Quality

- The test suite is driven by the shared [`vectors.json`][vectors] from the spec repo (the draft 3 file), vendored at `Tests/DTRExpTests/Resources/vectors.json`: every coverage, rejection (at its pinned position), warning and quiet vector, including the calendar traps (Feb 29 across 2000/2024/**2100**, `W53` existence, DST gap/overlap in `Europe/Berlin`). Run the suite with `swift test`. See [VECTORS.md][vectors-md] for how the vectors are structured.
- 100% line coverage, and mutation-tested by a scripted exit-code harness; Swift's standard tool ([muter][muter]) is unmaintained and cannot rewrite current Swift or read a Swift Testing suite, so the pass applies the classic mutant classes itself and treats any nonzero `swift test` exit as a kill, framework-free. Tally, commands and per-survivor equivalence proofs: [TESTING.md](TESTING.md).
- Zero dependencies.

## Related Projects

- [**dtrexp** (spec)][spec] — the DTRExp specification (grammar, semantics, conformance vectors) this package implements.
- [**dtrexp-js**][js] — the reference implementation; adds `intersect`, `next`, `describe`, `toRRule` and canonicalization.
- [**dtrexp-py**][py] · [**dtrexp-go**][go] · [**dtrexp-rs**][rs] · [**dtrexp-java**][java] — the other ports; same core interface.
- [**dtrexp-wasm**][wasm] — the Rust core compiled to WebAssembly for JS hosts.

## License

© 2026, Onur Yıldırım. [**MIT**](LICENSE) License.

[spec]: https://github.com/DTRExp/dtrexp
[js]: https://github.com/DTRExp/dtrexp-js
[py]: https://github.com/DTRExp/dtrexp-py
[go]: https://github.com/DTRExp/dtrexp-go
[rs]: https://github.com/DTRExp/dtrexp-rs
[java]: https://github.com/DTRExp/dtrexp-java
[muter]: https://github.com/muter-mutation-testing/muter
[vectors]: https://github.com/DTRExp/dtrexp/blob/main/vectors.json
[vectors-md]: https://github.com/DTRExp/dtrexp/blob/main/VECTORS.md
[wasm]: https://github.com/DTRExp/dtrexp-wasm
