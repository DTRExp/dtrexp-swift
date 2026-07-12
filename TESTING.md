# Testing

The package is tested at three levels: the conformance vectors (`Tests/DTRExpTests/Resources/vectors.json`, the behavioral contract shared across every DTRExp implementation), unit tests for everything the vectors don't reach (evaluation errors, quarter-scoped ordinals, exclusion lists, parser rejections, and the arithmetic helpers), and a manual mutation pass over the parser and evaluator boundary logic.

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

## Coverage: 100% of lines

Every executable line in `Sources/DTRExp` is exercised — `llvm-cov show` reports no zero-count source line in any of the six files.

A few things worth noting about how that 100% is reached:

- `fixedDurationMs` traps on a month or year unit, which the two callers never pass (constrained-anchor arithmetic handles those). The trap is pinned by a Swift Testing exit test, which runs in a subprocess; its coverage merges back into the profile.
- The `?? 0` fallback in `resolveCompatible` is a defensive default: the offset set is seeded with three probes and is never empty, so the fallback branch never runs. It is a sub-line region the line-coverage number does not flag.
- `llvm-cov report` shows a region/branch total slightly below 100% (~99.7%). Those are sub-line artifacts — the trap message autoclosure, the `?? 0` fallback, and the exhaustive-`switch` arms the input domain can't reach — not unexercised statements. The mutation pass covers the branch logic directly.

The vendored conformance vectors pass untouched.

## Mutation testing

Swift has no maintained mutation-testing tool (muter is unreliable on Swift 6), so the pass is manual and disciplined: for each source file, apply the standard mutant classes one at a time — flip every comparison operator (`<`↔`<=`, `>`↔`>=`, `==`↔`!=`), swap `&&`↔`||`, negate index/boundary arithmetic, and nudge the integer literals in comparisons — run `swift test`, record kill or survive, and restore. The pass is exhaustive over the parser's validation boundaries and the evaluator's inclusivity logic (the arms where an off-by-one is a real coverage bug), and samples the plumbing.

Latest run: **149 mutants — 136 killed, 13 survivors, all equivalent and justified below.** Every killable survivor found in the first pass got a real behavioral test and now dies; what remains is behaviorally indistinguishable from the original.

### Equivalent survivors (13)

Each is a mutant no test can distinguish, because the mutated comparison only differs on inputs the parser already excludes, or on iterations/branches that provably never run.

| Site | Mutant | Why equivalent |
| --- | --- | --- |
| `Civil.floorDiv` | `(a ^ b) < 0` → `<= 0` | `a ^ b == 0` only when `a == b`; then `a % b == 0`, so the first conjunct is false and short-circuits before the second is read. |
| `Evaluator` ordinal | `weekdayRaw < 0` → `<= 0` | An ordinal weekday is 1…7 or −7…−1; the parser rejects a zero weekday, so equality is unreachable. |
| `Evaluator` ordinal | `ord > 0` → `>= 0` | An ordinal is 1…5 or −5…−1; the parser rejects a zero ordinal, so equality is unreachable. |
| `Evaluator` month/year cadence | drop the `kEstimate + 1` iteration | The month estimate never underestimates the true occurrence index (a month start is `anchor.month + k·period` exactly; only the day-of-month clamp shifts the true `k`, and only downward), so `kEstimate + 1` never matches. |
| `Evaluator` month/year cadence | widen the low bound to `kEstimate − 2` | The true `k` is `≥ kEstimate − 1`, so `kEstimate − 2` never matches — a harmless extra iteration with the same result. |
| `Evaluator` month/year cadence | widen the high bound to `kEstimate + 2` | Same as the dropped `+1`: the high iterations are dead. |
| `Evaluator.Fields` | `qStartMonth == 10` → `== 11` | `qStartMonth` is one of 1/4/7/10; for Q4 the else branch computes `daysFromCivil(y, 13, 1)`, and month 13 in the Howard-Hinnant formula denotes January of `y+1` — the exact value the `== 10` branch produces. |
| `Parser` wrap detection | `start ≥ 0` → `start > 0` | A wrap needs `start > end` with `end ≥ 0`, so `start ≥ 1`; `start == 0` can never wrap and the guarded `start > end` is already false. |
| `Parser` negative-domain check | `v < 0` → `v <= 0` | The conjunction `&& v < −count` is false at `v == 0` (`−count` is negative), so the extra `v == 0` case is rejected by the second operand anyway. |
| `Parser` time wrap split | `s > e` → `s >= e` | Equal endpoints are rejected two lines earlier by `guard s != e`, so `s == e` never reaches this comparison. |
| `Parser` wrap low-span | `e > 0` → `e >= 0` | At `e == 0` the mutant appends a `[0, 0)` span, which is empty and matches no instant — identical coverage. |
| `Warnings` year enumeration | `b − a < limit` → `<= limit` | The 1000-year cap only chooses enumerate-vs-fallback; across any span that large every week-year length (52, 53) and day-year length (365, 366) occurs, so the enumerated domain equals the fallback domain and the warnings are identical. |
| `Warnings` year stride enumeration | `end − start < limit` → `<= limit` | Same reasoning for the stride span. |

Full per-mutant records (IDs, exact edits, kill/survive) are kept out of the tree.
