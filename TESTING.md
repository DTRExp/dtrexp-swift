# Testing

The package is tested at three levels: the conformance vectors (`Tests/DTRExpTests/Resources/vectors.json`, the behavioral contract shared across every DTRExp implementation), unit tests for everything the vectors don't reach (evaluation errors, quarter-scoped ordinals, exclusion lists, parser rejections, and the arithmetic helpers), and a scripted mutation pass over the parser and evaluator boundary logic, with a published record.

## Commands

```sh
swift test                          # run the suite
swift test --enable-code-coverage   # run with coverage instrumentation
```

Coverage report, per source file:

```sh
swift test --enable-code-coverage
BIN=$(swift build --show-bin-path)
xcrun llvm-cov report \
  "$BIN/DTRExpTests.xctest/Contents/MacOS/DTRExpTests" \
  -instr-profile "$BIN/codecov/default.profdata" \
  -ignore-filename-regex 'Tests/|DerivedSources|\.derived'
```

The bin path comes from SwiftPM rather than a fixed folder, since the layout under `.build` changes between toolchains (`.build/debug` before Swift 6.4, `.build/out/Products/Debug` since).

To list any uncovered lines in a file, swap `report` for `show --show-line-counts` and grep for zero-count lines.

Mutation, one spec at a time:

```sh
python3 Tests/mutation/mutate.py Tests/mutation/eval_civil.json
python3 Tests/mutation/mutate.py Tests/mutation/parser.json
python3 Tests/mutation/mutate.py Tests/mutation/warn_top.json
python3 Tests/mutation/mutate.py Tests/mutation/zone.json
```

## Coverage: 100% of Lines

Every executable line in `Sources/DTRExp` is exercised; `llvm-cov show` reports no zero-count source line in any of the six files.

A few things worth noting about how that 100% is reached:

- `fixedDurationMs` traps on a month or year unit, which the two callers never pass (constrained-anchor arithmetic handles those). The trap is pinned by a Swift Testing exit test, which runs in a subprocess; that subprocess's coverage does not merge back into the profile (checked 2026-10-21, Swift 6.4), so the trap's message closure is the one place the profile cannot see run.
- The `?? 0` fallback in `resolveCompatible` is a defensive default: the offset set is seeded with three probes and is never empty, so the fallback branch never runs. It is a sub-line region the line-coverage number does not flag.
- `llvm-cov report` counts each closure as a line of its own, so its Lines column shows two uncovered lines in `Evaluator.swift`, both closures sharing a line with code that runs: the trap message above and the `?? 0` fallback. `llvm-cov show` reports no zero-count source line in any file, which is the measure this section states.
- `llvm-cov report` shows a region total below 100% (97.8% on 2026-10-21). Those are sub-line artifacts — the trap message autoclosure, the `?? 0` fallback, and the exhaustive-`switch` arms the input domain can't reach — not unexercised statements. The mutation pass covers the branch logic directly.

The vendored conformance vectors pass untouched, with every invalid vector's error position checked. The runner reads vector instants on the proleptic Gregorian calendar itself: `ISO8601DateFormatter` switches to the Julian calendar before 1582 and reads `0001-01-01T00:00:00Z` two days late.

## Mutation Testing

Swift has no maintained mutation-testing tool. [muter](https://github.com/muter-mutation-testing/muter) is the one the ecosystem standardized on, and it is out of the running twice over: its last release (v16, September 2023) predates today's toolchains, and under Swift 6.3 its source rewriting emits corrupted mutants (mangled operators and identifiers) and aborts before testing a single one (verified 2026-07-14); and it detects kills by parsing XCTest output, so it cannot read a Swift Testing suite at all.

The pass here is scripted instead, and stronger for it: a driver applies spec'd mutants one at a time, from the standard classes: flip every comparison operator (`<`↔`<=`, `>`↔`>=`, `==`↔`!=`), swap `&&`↔`||`, negate index/boundary arithmetic, nudge the integer literals in comparisons. It runs `swift test`, and reads the **process exit code** (a failed expectation or a compile error is a kill), which is framework-agnostic by construction. Every mutant, edit, and outcome is recorded. The pass is exhaustive over the parser's validation boundaries and the evaluator's inclusivity logic (the arms where an off-by-one is a real coverage bug), and samples the plumbing.

The harness and its specs sit in `Tests/mutation/`: `mutate.py`, and one spec per area, each a list of `[id, file, old, new]` where `old` must occur exactly once in the file. Each run writes `<spec>_results.json` beside its spec; those are reports, so they are not committed.

Latest run (2026-10-21, all four specs, spec draft 3: error positions, the integer limit, the year-9999 edge, tz-database zone names; the parser rerun on its own the same day, after it began reading on past a rule error so that the earliest error wins, a later grammar error included, with only D's domain waiting for the branch): **221 mutants, 221 killed.** Every killable survivor found in a first pass got a real behavioral test and now dies. The 15 that no test can distinguish from the original were proven equivalent and have left the specs and their results, so they are not scored as misses; their proofs stay below.

| Spec | Files | Mutants | Killed | Equivalents dropped |
| --- | --- | --- | --- | --- |
| `eval_civil.json` | `Civil`, `Evaluator` | 86 | 86 | 7 |
| `parser.json` | `Parser` | 97 | 97 | 5 |
| `warn_top.json` | `Warnings`, `DTRExp` | 14 | 14 | 2 |
| `zone.json` | `DTRExp` (`withZone`, `covers`, `isIANAShaped`, the tz name list) | 24 | 24 | 1 |

### Killable Survivors, Now Killed

Each survived the first pass and is killed by a behavioral test written for it.

- **Civil and Evaluator** (`BoundaryTests.swift`): `floorDiv`'s `a % b != 0` → `== 0`, `q - 1` → `q + 1`, and `floorMod`'s `r + b` → `r - b`, by the floor-arithmetic contract on negative operands; `isLeapYear`'s `y % 400 == 0` → `!= 0`, by "the last day of Feb 2000 is the 29th"; the cadence `f.month - anchor.month` → `+`, by a monthly window matching in a later month; dropping the `kEstimate - 1` iteration, by an end-of-month-anchored window found in a shorter month (`20240131/1M/2D` at 02-01); the year duration `* 12` → `* 11`, by a one-year window still covering month 12; `elapsed >= 0` → `> 0`, by the anchor instant itself being covered; `elapsed % period < duration` → `<=`, by the instant exactly at the window end being excluded.
- **Parser** (`ParserBoundaryTests.swift`): the inclusive maxima (December; date-literal minute and second 59; time-value 23 and 59; day of month 31); month-zero rejection; an equal-length cross-unit cadence (`1W/7D` invalid); a fifteen-digit period clearing the size guard; the year domain 1…9999 (`Y1` valid, `Y0` out of domain); a stride interval equal to the domain size (`M1/12`); the full negative weekday index (`E-7`); an equal-endpoint range as a single value (`M5:5`).
- **Draft 3** (`PositionTests.swift`, `ZoneTests.swift`, `BoundaryTests.swift`): a month window capped at the year-9999 edge, by `99991201/2M/1M` still covering January 10000; every other new mutant (positions, the integer limit, the zone list, the window caps) died on the first pass.
- **Earliest error** (`PositionTests.swift`): a zero cadence period with a written duration (`20200101/0D/1H` at 9); a D range's start and a D stride range's start (`D40:41`, `D40:41/2`); a stride duration of 1 (`M1/3/1`); a D stride over its whole domain (`D1/31` valid, `D1/32` not); a one-digit time value as a rule error and an empty one as a grammar error, told apart by a D value before them (`D40 T1` at 1, `D40 T:0900` at 5). Two more were equivalent, so the code they mutated was simplified away: Y's exception in the stride wrap check (a Y wrap is already an error at its end, which comes first) and a separate interval position for `Y*/3` (its anchorless error at the `/` always comes first).
- **Warnings** (`WarningBoundaryTests.swift`): the month → quarter index (`M3 Q1`, `M6 Q2` stay quiet); the Q1 length ceiling (`D92 Q1` warns); a single-value year range enumerating one year (`Y2000:2000 W53`); a single-point year stride (`Y2000:2000/2 W53`); the half-open stride boundary (`Y2003:2004/5 W53`, only 2003 on).

### Dropped Equivalents (15)

Each is a mutant no test can distinguish, because the mutated comparison only differs on inputs the parser already excludes, or on iterations/branches that provably never run. A proven equivalent leaves the spec rather than being scored as a survivor; the id names the exact edit, so a change to that line brings it back for another look.

| Id | Site | Mutant | Why equivalent |
| --- | --- | --- | --- |
| `CIV2-floorDiv-xor<=` | `Civil.floorDiv` | `(a ^ b) < 0` → `<= 0` | `a ^ b == 0` only when `a == b`; then `a % b == 0`, so the first conjunct is false and short-circuits before the second is read. |
| `EV17-ord-wdraw<0<=` | `Evaluator` ordinal | `weekdayRaw < 0` → `<= 0` | An ordinal weekday is 1…7 or −7…−1; the parser rejects a zero weekday, so equality is unreachable. |
| `EV20-ord->0>=0` | `Evaluator` ordinal | `ord > 0` → `>= 0` | An ordinal is 1…5 or −5…−1; the parser rejects a zero ordinal, so equality is unreachable. |
| `EV34-cad-my-drop+1` | `Evaluator` month/year cadence | drop the `kEstimate + 1` iteration | The month estimate never underestimates the true occurrence index (a month start is `anchor.month + k·period` exactly; only the day-of-month clamp shifts the true `k`, and only downward), so `kEstimate + 1` never matches. |
| `EV35-cad-my-widen-2` | `Evaluator` month/year cadence | widen the low bound to `kEstimate − 2` | The true `k` is `≥ kEstimate − 1`, so `kEstimate − 2` never matches, a harmless extra iteration with the same result. |
| `EV36-cad-my-widen+2` | `Evaluator` month/year cadence | widen the high bound to `kEstimate + 2` | Same as the dropped `+1`: the high iterations are dead. |
| `EV59-fields-qend-oct` | `Evaluator.Fields` | `qStartMonth == 10` → `== 11` | `qStartMonth` is one of 1/4/7/10; for Q4 the else branch computes `daysFromCivil(y, 13, 1)`, and month 13 in the Howard-Hinnant formula denotes January of `y+1`, the exact value the `== 10` branch produces. |
| `P-wrap-sv0` | `Parser` wrap detection | `start ≥ 0` → `start > 0` | A wrap needs `start > end` with `end ≥ 0`, so `start ≥ 1`; `start == 0` can never wrap and the guarded `start > end` is already false. |
| `P-vd-negcount-lt` | `Parser` negative-domain check | `v < 0` → `v <= 0` | The conjunction `&& v < −count` is false at `v == 0` (`−count` is negative), so the extra `v == 0` case is rejected by the second operand anyway. |
| `P-vd-single-at` | `Parser` domain check of a single value | `place.start` → `place.end` | A single value is recorded with its start as its end (`(start, start)`), so both name the same offset. |
| `P-tl-wrap` | `Parser` time wrap split | `s > e` → `s >= e` | Equal endpoints are an error two lines earlier, and the branch ends with it, so a range built from them is never evaluated. |
| `P-tl-e0` | `Parser` wrap low-span | `e > 0` → `e >= 0` | At `e == 0` the mutant appends a `[0, 0)` span, which is empty and matches no instant; identical coverage. |
| `W-concyears-range<lim` | `Warnings` year enumeration | `b − a < limit` → `<= limit` | The 1000-year cap only chooses enumerate-vs-fallback; across any span that large every week-year length (52, 53) and day-year length (365, 366) occurs, so the enumerated domain equals the fallback domain and the warnings are identical. |
| `W-concyears-stridelim` | `Warnings` year stride enumeration | `end − start < limit` → `<= limit` | Same reasoning for the stride span. |

| `Z-iana-guard` | `DTRExp.ianaZone` | drop the `isIANAShaped(identifier)` condition | Every name the shape check refuses (`localtime`, `posix/localtime`, `./localtime`, `Europe/./Berlin`, `Europe//Berlin`, `/UTC`, `Europe/`) is also missing from the tz name list the lookup goes through, so the guard changes no answer; it stays as a second line against path-shaped names. The check itself is killed directly through `isIANAShaped`. |

The exact edit behind each of the first thirteen is in its spec as of 7ffbcf1, the last commit that carried it; `P-vd-single-at` is spelled out in its row.
