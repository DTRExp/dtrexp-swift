// Static unsatisfiability analysis — the §9.1 required minimum:
//  - per-selector satisfiability against the set of domain sizes implied by
//    co-present selectors (catches `D30 M2`, `W53` under fixed 52-week years,
//    statically-empty non-wrap ranges like `D-1:5` / `M-2:2`),
//  - full-domain exclusions (`M!1:12`),
//  - `M` ∩ `Q` disjointness (`M-1 Q1`),
//  - warnings from every `|` branch surface on the whole expression.

/// A non-fatal validation finding: the expression parses but can never match.
public struct Warning: Sendable, CustomStringConvertible, Equatable {
    public let message: String
    /// Offset into the source string of the offending component, when known.
    public let position: Int?

    public var description: String {
        if let position { return "\(message) (at offset \(position))" }
        return message
    }

    init(message: String, at position: Int? = nil) {
        self.message = message
        self.position = position
    }
}

/// The set of values a selector covers within a domain of `lo...hi`.
private func coveredValues(_ kind: SelectorKind, lo: Int, hi: Int) -> Set<Int> {
    var out: Set<Int> = []
    for v in lo...hi where kindMatches(kind, value: v, lo: lo, hi: hi) {
        out.insert(v)
    }
    return out
}

/// Enumerates a Y selector's covered years when the set is finite and small;
/// `nil` when it is open-ended or not statically enumerable.
private func concreteYears(_ kind: SelectorKind, limit: Int = 1000) -> [Int]? {
    switch kind {
    case .list(let items):
        var years: [Int] = []
        for item in items {
            switch item {
            case .single(let v):
                years.append(v)
            case .range(.value(let a), .value(let b), false) where a <= b:
                guard b - a < limit else { return nil }
                years.append(contentsOf: a...b)
            default:
                return nil
            }
        }
        return years
    case .stride(let start, .value(let end), let interval, let duration) where end >= start:
        guard end - start < limit else { return nil }
        return (start...end).filter { ($0 - start) % interval < duration }
    default:
        return nil
    }
}

private func monthLengths(_ month: Int) -> Set<Int> {
    switch month {
    case 2: return [28, 29]
    case 4, 6, 9, 11: return [30]
    default: return [31]
    }
}

private func quarterLengths(_ quarter: Int) -> Set<Int> {
    switch quarter {
    case 1: return [90, 91]
    case 2: return [91]
    default: return [92]
    }
}

func computeWarnings(_ branches: [Expression]) -> [Warning] {
    var warnings: [Warning] = []
    for expr in branches {
        warnings.append(contentsOf: branchWarnings(expr))
    }
    return warnings
}

private func branchWarnings(_ expr: Expression) -> [Warning] {
    var out: [Warning] = []
    func selector(_ d: Designator) -> Selector? {
        expr.selectors.first { $0.designator == d }
    }

    let monthSelector = selector(.month)
    let monthSet = monthSelector.map { coveredValues($0.kind, lo: 1, hi: 12) }
    let quarterSet = selector(.quarter).map { coveredValues($0.kind, lo: 1, hi: 4) }
    let concreteYearList = selector(.year).flatMap { concreteYears($0.kind) }

    for sel in expr.selectors {
        // Possible (lo, hi) domain instances implied by co-present selectors.
        var domains: [(lo: Int, hi: Int)]
        switch sel.designator {
        case .year, .time:
            continue  // unbounded / validated at parse; never statically empty
        case .quarter: domains = [(1, 4)]
        case .month: domains = [(1, 12)]
        case .weekday:
            if case .ordinal = sel.kind { continue }  // day×weekday interplay is QoI
            domains = [(1, 7)]
        case .hour: domains = [(0, 23)]
        case .minute, .second: domains = [(0, 59)]
        case .week:
            if let years = concreteYearList, !years.isEmpty {
                domains = Set(years.map(weeksInISOYear)).map { (1, $0) }
            } else {
                domains = [(1, 52), (1, 53)]
            }
        case .day:
            var sizes: Set<Int>
            switch expr.dayScope {
            case .month:
                if let monthSet {
                    if monthSet.isEmpty { continue }  // M's own warning fires
                    sizes = monthSet.reduce(into: Set<Int>()) { $0.formUnion(monthLengths($1)) }
                } else {
                    sizes = [28, 29, 30, 31]
                }
            case .quarter:
                // D with quarter scope only arises when a Q selector is present
                // (assemble picks the scope), so quarterSet is always populated.
                guard let quarterSet, !quarterSet.isEmpty else { continue }
                sizes = quarterSet.reduce(into: Set<Int>()) { $0.formUnion(quarterLengths($1)) }
            case .year:
                // with W present, Y is the week-year while day-of-year stays
                // calendar (spec §2) — cross-selector territory, stays quiet (§9.1)
                if selector(.week) == nil, let years = concreteYearList, !years.isEmpty {
                    sizes = Set(years.map(daysInYear))
                } else {
                    sizes = [365, 366]
                }
            }
            domains = sizes.map { (1, $0) }
        }
        let satisfiable = domains.contains { !coveredValues(sel.kind, lo: $0.lo, hi: $0.hi).isEmpty }
        if !satisfiable {
            out.append(Warning(message: "unsatisfiable: '\(sel.designator.rawValue)' selector never matches in any parent instance",
                               at: sel.position))
        }
    }

    // M ∩ Q disjointness.
    if let monthSelector, let monthSet, let quarterSet, !monthSet.isEmpty, !quarterSet.isEmpty {
        let reachableQuarters = Set(monthSet.map { ($0 - 1) / 3 + 1 })
        if reachableQuarters.isDisjoint(with: quarterSet) {
            out.append(Warning(message: "unsatisfiable: the selected months never fall in the selected quarters",
                               at: monthSelector.position))
        }
    }

    return out
}
