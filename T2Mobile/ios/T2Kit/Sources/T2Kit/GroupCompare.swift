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
        let tieSum = ties.values.reduce(0) { $0 + ($1 * $1 * $1 - $1) }
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
