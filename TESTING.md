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
BIN=.build/debug
xcrun llvm-cov report \
  "$BIN/dtrexp-swiftPackageTests.xctest/Contents/MacOS/dtrexp-swiftPackageTests" \
  -instr-profile "$BIN/codecov/default.profdata" \
  -ignore-filename-regex 'Tests/|DerivedSources|\.derived'
```

To list any uncovered lines in a file, swap `report` for `show --show-line-counts` and grep for zero-count lines.

Mutation, one spec at a time:

```sh
python3 Tests/mutation/mutate.py Tests/mutation/eval_civil.json
python3 Tests/mutation/mutate.py Tests/mutation/parser.json
python3 Tests/mutation/mutate.py Tests/mutation/warn_top.json
```

## Coverage: 100% of Lines

Every executable line in `Sources/DTRExp` is exercised; `llvm-cov show` reports no zero-count source line in any of the six files.

A few things worth noting about how that 100% is reached:

- `fixedDurationMs` traps on a month or year unit, which the two callers never pass (constrained-anchor arithmetic handles those). The trap is pinned by a Swift Testing exit test, which runs in a subprocess; its coverage merges back into the profile.
- The `?? 0` fallback in `resolveCompatible` is a defensive default: the offset set is seeded with three probes and is never empty, so the fallback branch never runs. It is a sub-line region the line-coverage number does not flag.
- `llvm-cov report` shows a region/branch total slightly below 100% (~99.7%). Those are sub-line artifacts — the trap message autoclosure, the `?? 0` fallback, and the exhaustive-`switch` arms the input domain can't reach — not unexercised statements. The mutation pass covers the branch logic directly.

The vendored conformance vectors pass untouched.

## Mutation Testing

Swift has no maintained mutation-testing tool. [muter](https://github.com/muter-mutation-testing/muter) is the one the ecosystem standardized on, and it is out of the running twice over: its last release (v16, September 2023) predates today's toolchains, and under Swift 6.3 its source rewriting emits corrupted mutants (mangled operators and identifiers) and aborts before testing a single one (verified 2026-07-14); and it detects kills by parsing XCTest output, so it cannot read a Swift Testing suite at all.

The pass here is scripted instead, and stronger for it: a driver applies spec'd mutants one at a time, from the standard classes: flip every comparison operator (`<`↔`<=`, `>`↔`>=`, `==`↔`!=`), swap `&&`↔`||`, negate index/boundary arithmetic, nudge the integer literals in comparisons. It runs `swift test`, and reads the **process exit code** (a failed expectation or a compile error is a kill), which is framework-agnostic by construction. Every mutant, edit, and outcome is recorded. The pass is exhaustive over the parser's validation boundaries and the evaluator's inclusivity logic (the arms where an off-by-one is a real coverage bug), and samples the plumbing.

The harness and its specs sit in `Tests/mutation/`: `mutate.py`, and one spec per area, each a list of `[id, file, old, new]` where `old` must occur exactly once in the file. Each run writes `<spec>_results.json` beside its spec; those are reports, so they are not committed.

Latest run (2026-09-26): **136 mutants, 136 killed.** Every killable survivor found in the first pass got a real behavioral test and now dies. The 13 that no test can distinguish from the original were proven equivalent and have left the specs and their results, so they are not scored as misses; their proofs stay below.

| Spec | Files | Mutants | Killed | Equivalents dropped |
| --- | --- | --- | --- | --- |
| `eval_civil.json` | `Civil`, `Evaluator` | 80 | 80 | 7 |
| `parser.json` | `Parser` | 45 | 45 | 4 |
| `warn_top.json` | `Warnings`, `DTRExp` | 11 | 11 | 2 |

### Killable Survivors, Now Killed

Each survived the first pass and is killed by a behavioral test written for it.

- **Civil and Evaluator** (`BoundaryTests.swift`): `floorDiv`'s `a % b != 0` → `== 0`, `q - 1` → `q + 1`, and `floorMod`'s `r + b` → `r - b`, by the floor-arithmetic contract on negative operands; `isLeapYear`'s `y % 400 == 0` → `!= 0`, by "the last day of Feb 2000 is the 29th"; the cadence `f.month - anchor.month` → `+`, by a monthly window matching in a later month; dropping the `kEstimate - 1` iteration, by an end-of-month-anchored window found in a shorter month (`20240131/1M/2D` at 02-01); the year duration `* 12` → `* 11`, by a one-year window still covering month 12; `elapsed >= 0` → `> 0`, by the anchor instant itself being covered; `elapsed % period < duration` → `<=`, by the instant exactly at the window end being excluded.
- **Parser** (`ParserBoundaryTests.swift`): the inclusive maxima (December; date-literal minute and second 59; time-value 23 and 59; day of month 31); month-zero rejection; an equal-length cross-unit cadence (`1W/7D` invalid); a fifteen-digit period clearing the size guard; the year domain 1…9999 (`Y1` valid, `Y0` out of domain); a stride interval equal to the domain size (`M1/12`); the full negative weekday index (`E-7`); an equal-endpoint range as a single value (`M5:5`).
- **Warnings** (`WarningBoundaryTests.swift`): the month → quarter index (`M3 Q1`, `M6 Q2` stay quiet); the Q1 length ceiling (`D92 Q1` warns); a single-value year range enumerating one year (`Y2000:2000 W53`); a single-point year stride (`Y2000:2000/2 W53`); the half-open stride boundary (`Y2003:2004/5 W53`, only 2003 on).

### Dropped Equivalents (13)

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
| `P-tl-wrap` | `Parser` time wrap split | `s > e` → `s >= e` | Equal endpoints are rejected two lines earlier by `guard s != e`, so `s == e` never reaches this comparison. |
| `P-tl-e0` | `Parser` wrap low-span | `e > 0` → `e >= 0` | At `e == 0` the mutant appends a `[0, 0)` span, which is empty and matches no instant; identical coverage. |
| `W-concyears-range<lim` | `Warnings` year enumeration | `b − a < limit` → `<= limit` | The 1000-year cap only chooses enumerate-vs-fallback; across any span that large every week-year length (52, 53) and day-year length (365, 366) occurs, so the enumerated domain equals the fallback domain and the warnings are identical. |
| `W-concyears-stridelim` | `Warnings` year stride enumeration | `end − start < limit` → `<= limit` | Same reasoning for the stride span. |

The exact edit behind each is in its spec as of 7ffbcf1, the last commit that carried it.
