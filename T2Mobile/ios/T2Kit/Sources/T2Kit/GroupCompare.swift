import Foundation

// The tests behind the Analysis panel (group comparison): two-group and many-group tests of a
// number, tests of association for a category, and the false-discovery adjustment for the
// clinical screen. Every function is checked against R in the unit tests (wilcox.test,
// chisq.test, fisher.test, t.test, oneway.test, p.adjust); see Tests/T2KitTests/GroupCompareTests.swift.
// Specified in docs/ANALYSIS-SPEC.md (sections 3, 5 and the watchlist in 7).

public extension Stats {
    // MARK: rank-sum

    /// Wilcoxon rank-sum test, normal approximation with the tie correction and the continuity
    /// correction (R: wilcox.test(x ~ g, exact = FALSE, correct = TRUE)). `group[i]` is 0 or 1;
    /// group 0 is R's first level, so W = (rank sum of group 0) - n0 (n0 + 1) / 2. Any other group
    /// or a missing value drops the sample. Nil when a group is empty or every value is identical.
    static func wilcoxon(_ v: [Double], group: [Int]) -> (w: Double, p: Double)? {
        let rows = (0..<min(v.count, group.count)).filter { !v[$0].isNaN && (group[$0] == 0 || group[$0] == 1) }
        let values = rows.map { v[$0] }
        let n1 = Double(rows.filter { group[$0] == 0 }.count)
        let n2 = Double(rows.count) - n1
        guard n1 >= 1, n2 >= 1 else { return nil }
        let n = n1 + n2
        let r = ranks(values)
        var rankSum = 0.0
        for (k, row) in rows.enumerated() where group[row] == 0 { rankSum += r[k] }
        let w = rankSum - n1 * (n1 + 1) / 2
        var ties: [Double: Double] = [:]
        for x in values { ties[x, default: 0] += 1 }
        // sorted key order: a dictionary's order varies per instance, and the summation
        // order moves sigma in the last bits from one run to the next (see kruskalWallis)
        let tieSum = ties.keys.sorted().reduce(0) { acc, x in let t = ties[x]!; return acc + (t * t * t - t) }
        let sigma = (n1 * n2 / 12 * ((n + 1) - tieSum / (n * (n - 1)))).squareRoot()
        guard sigma > 0, sigma.isFinite else { return nil }       // every value identical
        let centred = w - n1 * n2 / 2
        let correction: Double = centred > 0 ? 0.5 : (centred < 0 ? -0.5 : 0)   // toward the mean
        let z = (centred - correction) / sigma
        return (w, min(1, 2 * min(normalLowerTail(z), normalLowerTail(-z))))
    }
    /// P(Z <= z) for a standard normal (erfc keeps the small tail's digits)
    private static func normalLowerTail(_ z: Double) -> Double { 0.5 * erfc(-z / 2.0.squareRoot()) }

    // MARK: tables

    /// Pearson chi-square test of a contingency table, no continuity correction
    /// (R: chisq.test(tab, correct = FALSE)). Rows and columns with no counts are dropped first;
    /// nil when fewer than two rows or columns are left. `expected` is for the table kept.
    static func chiSquareContingency(_ counts: [[Int]]) -> (statistic: Double, df: Int, p: Double, expected: [[Double]])? {
        guard let width = counts.first?.count, counts.allSatisfy({ $0.count == width }) else { return nil }
        let rowsKept = counts.indices.filter { counts[$0].reduce(0, +) > 0 }
        let colsKept = (0..<width).filter { c in counts.reduce(0) { $0 + $1[c] } > 0 }
        guard rowsKept.count >= 2, colsKept.count >= 2 else { return nil }
        let table = rowsKept.map { r in colsKept.map { Double(counts[r][$0]) } }
        let rowSum = table.map { $0.reduce(0, +) }
        let colSum = colsKept.indices.map { c in table.reduce(0) { $0 + $1[c] } }
        let total = rowSum.reduce(0, +)
        var expected = table
        var statistic = 0.0
        for i in table.indices {
            for j in colsKept.indices {
                let e = rowSum[i] * colSum[j] / total
                expected[i][j] = e
                statistic += (table[i][j] - e) * (table[i][j] - e) / e
            }
        }
        let df = (rowsKept.count - 1) * (colsKept.count - 1)
        return (statistic, df, chiSquareUpperTail(statistic, df: df), expected)
    }

    /// Two-sided Fisher exact test of a 2x2 table [[a, b], [c, d]] (R: fisher.test(tab)$p.value):
    /// the summed probability of every table with the same margins that is no more likely than
    /// the observed one, within R's relative tolerance of 1e-7.
    static func fisher2x2(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> Double {
        let m = a + b, n = c + d, k = a + c
        guard a >= 0, b >= 0, c >= 0, d >= 0, m + n > 0 else { return .nan }
        let lo = max(0, k - n), hi = min(k, m)
        func logChoose(_ nn: Int, _ kk: Int) -> Double {
            logGamma(Double(nn) + 1) - logGamma(Double(kk) + 1) - logGamma(Double(nn - kk) + 1)
        }
        let denominator = logChoose(m + n, k)
        let pmf = (lo...hi).map { exp(logChoose(m, $0) + logChoose(n, k - $0) - denominator) }
        let observed = pmf[a - lo]
        let cutoff = observed * (1 + 1e-7)
        return min(1, pmf.reduce(0) { $0 + ($1 <= cutoff ? $1 : 0) })
    }

    // MARK: means

    /// Welch's two-sample t test, Welch-Satterthwaite df, two-sided (R: t.test(x, y)); t is for x - y.
    /// Missing values are dropped; nil when a sample has fewer than two values or both have no spread.
    static func welchT(_ x: [Double], _ y: [Double]) -> (t: Double, df: Double, p: Double)? {
        let a = x.filter { !$0.isNaN }, b = y.filter { !$0.isNaN }
        guard a.count >= 2, b.count >= 2 else { return nil }
        let va = sd(a) * sd(a) / Double(a.count), vb = sd(b) * sd(b) / Double(b.count)
        guard va + vb > 0 else { return nil }
        let t = (mean(a) - mean(b)) / (va + vb).squareRoot()
        let df = (va + vb) * (va + vb) / (va * va / Double(a.count - 1) + vb * vb / Double(b.count - 1))
        return (t, df, tTwoSided(t, df: df))
    }

    /// Welch's one-way ANOVA, unequal variances (R: oneway.test(v ~ g, var.equal = FALSE)).
    /// `group[i]` >= 0; a negative group or a missing value drops the sample. Nil with fewer than
    /// two groups, a group of fewer than two values, or a group without spread.
    static func welchAnova(_ v: [Double], group: [Int]) -> (f: Double, df1: Double, df2: Double, p: Double)? {
        var byGroup: [Int: [Double]] = [:]
        for i in 0..<min(v.count, group.count) where !v[i].isNaN && group[i] >= 0 { byGroup[group[i], default: []].append(v[i]) }
        let samples = byGroup.keys.sorted().map { byGroup[$0]! }
        let k = Double(samples.count)
        guard samples.count >= 2, samples.allSatisfy({ $0.count >= 2 }) else { return nil }
        let means = samples.map { mean($0) }
        let counts = samples.map { Double($0.count) }
        let variances = samples.map { sd($0) * sd($0) }
        guard variances.allSatisfy({ $0 > 0 }) else { return nil }
        let w = zip(counts, variances).map { $0 / $1 }
        let wSum = w.reduce(0, +)
        let grand = zip(w, means).reduce(0) { $0 + $1.0 * $1.1 } / wSum
        var tmp = 0.0
        for i in samples.indices { tmp += (1 - w[i] / wSum) * (1 - w[i] / wSum) / (counts[i] - 1) }
        tmp /= (k * k - 1)
        var between = 0.0
        for i in samples.indices { between += w[i] * (means[i] - grand) * (means[i] - grand) }
        let f = between / ((k - 1) * (1 + 2 * (k - 2) * tmp))
        let df2 = 1 / (3 * tmp)
        return (f, k - 1, df2, fUpperTail(f, df1: k - 1, df2: df2))
    }

    /// P(F > f) for an F variable with `df1` and `df2` degrees of freedom
    static func fUpperTail(_ f: Double, df1: Double, df2: Double) -> Double {
        guard df1 > 0, df2 > 0, !f.isNaN else { return .nan }
        guard f > 0 else { return 1 }
        if f.isInfinite { return 0 }
        return regularizedBeta(df2 / (df2 + df1 * f), df2 / 2, df1 / 2)
    }

    // MARK: many tests

    /// Benjamini-Hochberg false-discovery adjustment (R: p.adjust(p, method = "BH")).
    /// A missing entry is left out of the number of tests and stays missing.
    static func benjaminiHochberg(_ p: [Double?]) -> [Double?] {
        let kept = p.indices.filter { p[$0].map { !$0.isNaN } ?? false }
        let m = Double(kept.count)
        let order = kept.sorted { p[$0]! > p[$1]! }              // largest p first
        var out = [Double?](repeating: nil, count: p.count)
        var running = Double.infinity
        for (k, i) in order.enumerated() {
            running = min(running, m / (m - Double(k)) * p[i]!)  // rank of this p among the kept, ascending
            out[i] = min(1, running)
        }
        return out
    }

    // MARK: display

    /// a p-value as the website prints it (fmtp in survival_prototype.R); missing -> "NA"
    static func pValueString(_ p: Double?) -> String {
        guard let p = p else { return "NA" }
        return PlotFormat.pValue(p)
    }
}

// MARK: - groupings and the test dispatcher

/// How the samples are put into groups (docs/ANALYSIS-SPEC.md section 2).
public enum Grouping: Equatable, Sendable {
    /// selected / excluded by the filters: one column's filter (leave-one-out), or nil = all of them
    case filterSplit(column: String?)
    /// a number cut into `k` (2 to 4) quantile groups over the samples passing every filter
    case quantized(name: String, k: Int)
    /// the levels of a categorical column
    case categorical(String)
}

/// The kind of variable that is tested across the groups.
public enum GroupVariableKind: Sendable, Equatable { case numeric, categorical, survival }

/// How the test is chosen: round 1 has only the automatic choice (the seam for model mode).
public enum AnalysisMethod: Sendable, Equatable { case auto }

/// Who is in which group. `group[i]` indexes `labels` (-1 = in no group); `refused` says why no
/// comparison can be made (then there are no groups).
public struct GroupAssignment: Sendable, Equatable {
    public var group: [Int]
    public var labels: [String]
    public var note: String?
    /// the samples the grouping is made over (the universe of spec section 2)
    public var nUniverse: Int
    public var refused: String?
    public init(group: [Int], labels: [String], note: String? = nil, nUniverse: Int, refused: String? = nil) {
        self.group = group; self.labels = labels; self.note = note; self.nUniverse = nUniverse; self.refused = refused
    }
}

/// One row of the groups block (spec 5): numbers carry the quartiles, survival the events and median.
public struct GroupSummaryRow: Sendable, Equatable {
    public var group: String
    public var n: Int
    public var median: Double?, q1: Double?, q3: Double?
    public var events: Int?
    /// "NR" when not reached
    public var medianSurvival: String?
}
/// One row of the long form for a categorical variable.
public struct GroupLevelRow: Sendable, Equatable {
    public var group: String, level: String
    public var count: Int
    public var prop: Double
}
/// One row of the tidy test block; model mode appends rows (covariates, contrasts).
public struct GroupTestRow: Sendable, Equatable {
    public var term: String
    public var method: String
    public var statistic: Double?
    public var df: Double?
    public var p: Double?
    public var pBH: Double?
    public var note: String?
}
public struct GroupTestResult: Sendable, Equatable {
    public var groups: [GroupSummaryRow] = []
    /// categorical variables only
    public var levels: [GroupLevelRow] = []
    public var test: [GroupTestRow] = []
    public var refused: String?
    /// complete cases in the groups that were tested
    public var n = 0
    public var analysisMethod: AnalysisMethod = .auto
}
public struct ScreenRow: Sendable, Equatable {
    public var variable: String
    public var kind: GroupVariableKind
    public var method: String
    public var n: Int
    public var statistic: Double?
    public var df: Double?
    public var p: Double?
    public var pBH: Double?
    public var note: String?
}

/// The minimum complete cases in a group (spec section 2, the same floor as t2_quantile_groups).
public let groupMinN = 5

/// The groups of a grouping, or nil when it cannot be made at all (an unknown or inactive column,
/// a quantized column that is not numeric). A grouping that is made but cannot be compared has
/// `refused` set. Every grouping works inside the filter, so all the other filters are kept.
public func makeGrouping(_ g: Grouping, filter: CrossFilter, column: (String) -> Column?) -> GroupAssignment? {
    let n = filter.sampleCount
    func count(_ m: Mask) -> Int { m.reduce(0) { $0 + ($1 ? 1 : 0) } }
    func refusal(_ why: String, universe: Int) -> GroupAssignment {
        GroupAssignment(group: [Int](repeating: -1, count: n), labels: [], nUniverse: universe, refused: why)
    }
    switch g {
    case .filterSplit(let name):
        guard let split = filter.splitMasks(on: name) else { return nil }
        let group = (0..<n).map { split.selected[$0] ? 0 : (split.excluded[$0] ? 1 : -1) }
        var note: String? = nil
        if let name {
            guard let col = column(name), let f = filter.filter(name) else { return nil }
            let missing = (0..<n).filter { (split.selected[$0] || split.excluded[$0]) && col.isMissing($0) }.count
            if missing > 0 { note = "\(f.includeMissing ? "Selected" : "Excluded") includes \(missing) samples missing \(name)." }
        } else {
            let active = filter.filters.filter { $0.isActive }.map { $0.column }
            if !active.isEmpty { note = "Filters: " + active.joined(separator: ", ") }
        }
        return GroupAssignment(group: group, labels: ["Selected", "Excluded"], note: note, nUniverse: count(split.selected) + count(split.excluded))
    case .quantized(let name, let k):
        guard let x = column(name)?.numbers, x.count == n, (2...4).contains(k) else { return nil }
        let universe = filter.mask()
        let u = count(universe)
        let cut = Stats.quantileGroupsUnique((0..<n).map { universe[$0] ? x[$0] : .nan }, groups: k)
        guard cut.count >= 2 else { return refusal("\(name) has too few distinct values to be split into \(k) groups. Try 2 groups.", universe: u) }
        var sizes = [Int](repeating: 0, count: cut.count)
        for v in cut.group where v >= 0 { sizes[v] += 1 }
        if sizes.contains(where: { $0 < groupMinN }) {
            return refusal("\(name): the groups would hold only \(sizes.map(String.init).joined(separator: "/")) samples (at least \(groupMinN) are needed in each). Try fewer groups.", universe: u)
        }
        let note = cut.count < k ? "\(k) groups were asked for; \(cut.count) were made (many samples share a value)." : nil
        return GroupAssignment(group: cut.group, labels: Stats.groupLabels(made: cut.count), note: note, nUniverse: u)
    case .categorical(let name):
        guard let col = column(name), case .categorical(let levels, let codes) = col.data, codes.count == n else { return nil }
        let universe = filter.mask()
        let u = count(universe)
        let order = col.levelsPresent(in: universe)           // served order, droplevels
        guard order.count >= 2 else { return refusal("\(name) has one value among these samples: there are no groups to compare.", universe: u) }
        let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let group = (0..<n).map { universe[$0] && codes[$0] >= 0 ? (index[codes[$0]] ?? -1) : -1 }
        return GroupAssignment(group: group, labels: order.map { levels[$0] }, nUniverse: u)
    }
}

/// The test of one variable across the groups (spec section 3). `values` is the variable for a
/// number or a category; a survival endpoint comes as `tte` (time, event), censored at `maxDays`
/// the way the Kaplan-Meier plot does. Samples in no group or missing the value are not used;
/// a group with fewer than 5 of them is dropped (and said so); fewer than 2 groups left: refused.
public func groupTest(values: Column.Data?, kind: GroupVariableKind, assignment: GroupAssignment, means: Bool,
                      tte: (time: [Double], event: [Double])?, maxDays: Double, method: AnalysisMethod = .auto) -> GroupTestResult {
    var out = GroupTestResult()
    out.analysisMethod = method
    if let why = assignment.refused { out.refused = why; return out }
    let n = assignment.group.count
    var x: [Double] = [], codes: [Int] = [], levels: [String] = []
    var time: [Double] = [], event: [Double] = []
    var present = [Bool](repeating: false, count: n)
    switch kind {
    case .numeric:
        guard case .numeric(let v)? = values, v.count == n else { out.refused = "This variable is not a number."; return out }
        x = v; present = v.map { !$0.isNaN }
    case .categorical:
        guard case .categorical(let l, let c)? = values, c.count == n else { out.refused = "This variable is not a category."; return out }
        levels = l; codes = c; present = c.map { $0 >= 0 }
    case .survival:
        guard let t = tte, t.time.count == n, t.event.count == n else { out.refused = "No survival data for this endpoint."; return out }
        time = t.time; event = t.event
        present = (0..<n).map { !time[$0].isNaN && !event[$0].isNaN && time[$0] > 0 }
        // follow-up: administratively censor at the limit rather than drop anyone (as the KM plot)
        if maxDays.isFinite && maxDays > 0 {
            for i in 0..<n where time[i] > maxDays { event[i] = 0; time[i] = maxDays }
        }
    }

    // complete cases per group; small groups go
    let g0 = assignment.labels.count
    var sizes = [Int](repeating: 0, count: g0)
    for i in 0..<n where present[i] && assignment.group[i] >= 0 { sizes[assignment.group[i]] += 1 }
    let kept = (0..<g0).filter { sizes[$0] >= groupMinN }
    let dropped = (0..<g0).filter { sizes[$0] < groupMinN }
    let dropNote: String? = dropped.isEmpty ? nil
        : "Dropped (fewer than \(groupMinN) samples with a value): " + dropped.map { "\(assignment.labels[$0]) (n = \(sizes[$0]))" }.joined(separator: ", ") + "."
    guard kept.count >= 2 else {
        out.refused = "Fewer than two groups have at least \(groupMinN) samples with a value" + (g0 > 0 ? " (" + (0..<g0).map { "\(assignment.labels[$0]) \(sizes[$0])" }.joined(separator: ", ") + ")." : ".")
        return out
    }
    let index = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1, $0) })
    let group = (0..<n).map { present[$0] && assignment.group[$0] >= 0 ? (index[assignment.group[$0]] ?? -1) : -1 }
    let labels = kept.map { assignment.labels[$0] }
    let members = labels.indices.map { g in (0..<n).filter { group[$0] == g } }
    out.n = members.reduce(0) { $0 + $1.count }

    func row(_ term: String, _ name: String, _ statistic: Double?, _ df: Double?, _ p: Double?) -> GroupTestResult {
        var r = out
        r.test = [GroupTestRow(term: term, method: name, statistic: statistic, df: df, p: p, pBH: nil, note: dropNote)]
        return r
    }

    switch kind {
    case .numeric:
        out.groups = labels.indices.map { g in
            let v = members[g].map { x[$0] }
            return GroupSummaryRow(group: labels[g], n: v.count, median: Stats.median(v), q1: Stats.quantile(v, 0.25), q3: Stats.quantile(v, 0.75))
        }
        if labels.count == 2 {
            let a = members[0].map { x[$0] }, b = members[1].map { x[$0] }
            if means {
                guard let t = Stats.welchT(a, b) else { return noSpreadKeeping(out) }
                return row("group", "Welch t-test", t.t, t.df, t.p)
            }
            guard let w = Stats.wilcoxon(x, group: group) else { return noSpreadKeeping(out) }
            return row("group", "Wilcoxon rank-sum", w.w, nil, w.p)
        }
        if means {
            guard let a = Stats.welchAnova(x, group: group) else { return noSpreadKeeping(out) }
            var r = row("group", "Welch ANOVA", a.f, a.df1, a.p)
            r.test[0].note = [dropNote, String(format: "Denominator df = %.3g.", a.df2)].compactMap { $0 }.joined(separator: " ")
            return r
        }
        guard let k = Stats.kruskalWallis(x, group: group) else { return noSpreadKeeping(out) }
        return row("group", "Kruskal-Wallis", k.statistic, Double(k.df), k.p)
    case .categorical:
        var table = [[Int]](repeating: [Int](repeating: 0, count: levels.count), count: labels.count)
        for g in labels.indices { for i in members[g] { table[g][codes[i]] += 1 } }
        out.groups = labels.indices.map { GroupSummaryRow(group: labels[$0], n: members[$0].count) }
        for g in labels.indices {
            for l in levels.indices where table.contains(where: { $0[l] > 0 }) {
                out.levels.append(GroupLevelRow(group: labels[g], level: levels[l], count: table[g][l], prop: Double(table[g][l]) / Double(members[g].count)))
            }
        }
        guard let chi = Stats.chiSquareContingency(table) else { return noSpreadKeeping(out) }
        if chi.expected.count == 2, chi.expected[0].count == 2, chi.expected.joined().contains(where: { $0 < 5 }) {
            let rowsKept = table.indices.filter { table[$0].reduce(0, +) > 0 }
            let colsKept = levels.indices.filter { c in table.reduce(0) { $0 + $1[c] } > 0 }
            let t = rowsKept.map { r in colsKept.map { table[r][$0] } }
            return row("group", "Fisher exact", nil, nil, Stats.fisher2x2(t[0][0], t[0][1], t[1][0], t[1][1]))
        }
        return row("group", "Chi-squared", chi.statistic, Double(chi.df), chi.p)
    case .survival:
        out.groups = labels.indices.map { g in
            let km = Stats.kaplanMeierBand(time: members[g].map { time[$0] }, event: members[g].map { event[$0] })
            return GroupSummaryRow(group: labels[g], n: km.n, events: km.events,
                                   medianSurvival: km.medianTime.map { String(Int($0.rounded())) } ?? "NR")
        }
        guard let lr = Stats.logRank(time: time, event: event, group: group) else { return noSpreadKeeping(out) }
        return row("group", "Log-rank", lr.chiSquare, Double(lr.df), lr.p)
    }
}
// a refusal that keeps the group summaries
private func noSpreadKeeping(_ r: GroupTestResult) -> GroupTestResult {
    var r = r; r.refused = "The variable has no spread to compare among these groups."; return r
}

/// The clinical screen (spec section 4): every variable in `vars` tested across the same groups,
/// the p-values adjusted together (Benjamini-Hochberg over the tests that gave a p), ranked by p;
/// refused variables come last, unranked and outside the count of tests. The caller leaves out
/// the grouping's own source column.
public func groupScreen(vars: [String], column: (String) -> Column?, kinds: [String: GroupVariableKind],
                        assignment: GroupAssignment, means: Bool,
                        tteSpecs: [String: (time: [Double], event: [Double])], maxDays: Double) -> [ScreenRow] {
    let results = vars.map { v -> GroupTestResult in
        let kind = kinds[v] ?? .numeric
        return groupTest(values: kind == .survival ? nil : column(v)?.data, kind: kind, assignment: assignment, means: means,
                         tte: tteSpecs[v], maxDays: maxDays)
    }
    let ps: [Double?] = results.map { r in
        guard r.refused == nil, let p = r.test.first?.p, p.isFinite else { return nil }
        return p
    }
    let adjusted = Stats.benjaminiHochberg(ps)
    var rows: [ScreenRow] = vars.indices.map { i in
        let r = results[i], t = r.test.first
        guard ps[i] != nil, let t else {
            return ScreenRow(variable: vars[i], kind: kinds[vars[i]] ?? .numeric, method: "", n: r.n, statistic: nil, df: nil, p: nil, pBH: nil,
                             note: r.refused ?? "No test could be made.")
        }
        return ScreenRow(variable: vars[i], kind: kinds[vars[i]] ?? .numeric, method: t.method, n: r.n, statistic: t.statistic, df: t.df,
                         p: ps[i], pBH: adjusted[i], note: t.note)
    }
    let order = vars.indices.sorted { a, b in
        switch (ps[a], ps[b]) {
        case let (x?, y?): return x != y ? x < y : a < b
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a < b
        }
    }
    rows = order.map { rows[$0] }
    return rows
}
