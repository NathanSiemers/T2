import Foundation

// The statistics T2 shows with its plots. Plain functions over arrays; `Double.nan` is a
// missing value and is ignored (pairs are dropped if either member is missing).

public enum Stats {
    public static func mean(_ x: [Double]) -> Double {
        let v = x.filter { !$0.isNaN }
        return v.isEmpty ? .nan : v.reduce(0, +) / Double(v.count)
    }
    /// sample standard deviation (n - 1)
    public static func sd(_ x: [Double]) -> Double {
        let v = x.filter { !$0.isNaN }
        guard v.count > 1 else { return .nan }
        let m = v.reduce(0, +) / Double(v.count)
        return (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count - 1)).squareRoot()
    }
    /// quantile, R's default method (type 7)
    public static func quantile(_ x: [Double], _ p: Double) -> Double {
        let v = x.filter { !$0.isNaN }.sorted()
        guard !v.isEmpty else { return .nan }
        let h = Double(v.count - 1) * min(max(p, 0), 1)
        let lo = Int(h.rounded(.down)), hi = min(lo + 1, v.count - 1)
        return v[lo] + (h - Double(lo)) * (v[hi] - v[lo])
    }
    public static func median(_ x: [Double]) -> Double { quantile(x, 0.5) }
    /// z-score, ignoring missing values (a constant vector is only centred), as in marker_ops.R
    public static func zscore(_ x: [Double]) -> [Double] {
        let m = mean(x), s = sd(x)
        return x.map { $0.isNaN ? .nan : (s.isNaN || s == 0 ? $0 - m : ($0 - m) / s) }
    }
    /// several probes as ONE marker: per sample, the median of the per-probe z-scores
    /// (combine_markers_median_z in marker_ops.R); a single probe is returned unchanged
    public static func combineMedianZ(_ probes: [[Double]]) -> [Double] {
        guard probes.count > 1, let n = probes.first?.count else { return probes.first ?? [] }
        let z = probes.map(zscore)
        return (0..<n).map { i in median(z.map { $0[i] }) }
    }

    /// the five numbers of a box plot: quartiles, and whiskers at the most extreme values
    /// within 1.5 x IQR of the box (ggplot's geom_boxplot)
    public struct Box: Sendable, Equatable { public let lowerWhisker, q1, median, q3, upperWhisker: Double; public let n: Int }
    public static func box(_ x: [Double]) -> Box? {
        let v = x.filter { !$0.isNaN }
        guard !v.isEmpty else { return nil }
        let q1 = quantile(v, 0.25), q3 = quantile(v, 0.75), iqr = q3 - q1
        let lw = v.filter { $0 >= q1 - 1.5 * iqr }.min() ?? q1
        let uw = v.filter { $0 <= q3 + 1.5 * iqr }.max() ?? q3
        return Box(lowerWhisker: lw, q1: q1, median: median(v), q3: q3, upperWhisker: uw, n: v.count)
    }

    /// least-squares line y = intercept + slope * x, with Pearson r
    public struct Line: Sendable, Equatable { public let slope, intercept, r: Double; public let n: Int }
    public static func regression(x: [Double], y: [Double]) -> Line? {
        var sx = 0.0, sy = 0.0, n = 0.0
        for i in 0..<min(x.count, y.count) where !x[i].isNaN && !y[i].isNaN { sx += x[i]; sy += y[i]; n += 1 }
        guard n >= 3 else { return nil }
        let mx = sx / n, my = sy / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for i in 0..<min(x.count, y.count) where !x[i].isNaN && !y[i].isNaN {
            sxx += (x[i] - mx) * (x[i] - mx); syy += (y[i] - my) * (y[i] - my); sxy += (x[i] - mx) * (y[i] - my)
        }
        guard sxx > 0 else { return nil }
        let slope = sxy / sxx
        return Line(slope: slope, intercept: my - slope * mx, r: syy > 0 ? sxy / (sxx * syy).squareRoot() : .nan, n: Int(n))
    }

    /// equal-count groups of a marker (tertiles for 3): group index per sample, -1 = missing.
    /// Cut points are quantiles, intervals closed on the right, as cut() does in survival_km.
    public static func quantileGroups(_ x: [Double], groups: Int) -> [Int] {
        let g = max(2, groups)
        let cuts = (1..<g).map { quantile(x, Double($0) / Double(g)) }
        return x.map { v in v.isNaN ? -1 : cuts.reduce(0) { $0 + (v > $1 ? 1 : 0) } }
    }

    /// One Kaplan-Meier curve: survival just after each distinct event time.
    public struct KMCurve: Sendable, Equatable {
        public let times: [Double]
        public let survival: [Double]
        public let atRisk: [Int]
        public let n: Int
        public let events: Int
        /// first time survival is <= 0.5, or nil ("not reached")
        public var medianTime: Double? { zip(times, survival).first { $0.1 <= 0.5 }?.0 }
    }
    /// `event`: 1 = event, 0 = censored. Samples with a missing time or event are dropped.
    public static func kaplanMeier(time: [Double], event: [Double]) -> KMCurve {
        let obs = zip(time, event).filter { !$0.0.isNaN && !$0.1.isNaN }.sorted { $0.0 < $1.0 }
        var times: [Double] = [], surv: [Double] = [], risk: [Int] = []
        var s = 1.0, i = 0, nEvents = 0
        while i < obs.count {
            let t = obs[i].0, atRisk = obs.count - i
            var d = 0, j = i
            while j < obs.count && obs[j].0 == t { if obs[j].1 != 0 { d += 1 }; j += 1 }
            if d > 0 {
                s *= 1 - Double(d) / Double(atRisk)
                times.append(t); surv.append(s); risk.append(atRisk); nEvents += d
            }
            i = j
        }
        return KMCurve(times: times, survival: surv, atRisk: risk, n: obs.count, events: nEvents)
    }

    /// Log-rank test across groups (`group[i]` >= 0; negative = not used). Returns the
    /// chi-square statistic, its degrees of freedom and the p-value (survdiff's default).
    public static func logRank(time: [Double], event: [Double], group: [Int]) -> (chiSquare: Double, df: Int, p: Double)? {
        let rows = (0..<min(time.count, event.count, group.count))
            .filter { !time[$0].isNaN && !event[$0].isNaN && group[$0] >= 0 }
        let k = (rows.map { group[$0] }.max() ?? -1) + 1
        guard k >= 2 else { return nil }
        let eventTimes = Set(rows.filter { event[$0] != 0 }.map { time[$0] }).sorted()
        var o = [Double](repeating: 0, count: k), e = o
        var v = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
        for t in eventTimes {
            var n = [Double](repeating: 0, count: k), d = n
            for r in rows where time[r] >= t {
                n[group[r]] += 1
                if time[r] == t && event[r] != 0 { d[group[r]] += 1 }
            }
            let nt = n.reduce(0, +), dt = d.reduce(0, +)
            guard nt > 0 else { continue }
            for g in 0..<k {
                o[g] += d[g]; e[g] += dt * n[g] / nt
                guard nt > 1 else { continue }
                let c = dt * (nt - dt) / (nt * nt * (nt - 1))
                for h in 0..<k { v[g][h] += c * n[g] * ((g == h ? nt : 0) - n[h]) }
            }
        }
        // statistic over the first k-1 groups: (O-E)' V^-1 (O-E)
        let m = k - 1
        var a = (0..<m).map { g in Array(v[g][0..<m]) + [o[g] - e[g]] }
        for c in 0..<m {       // Gauss-Jordan with partial pivoting
            guard let piv = (c..<m).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[piv][c]) > 1e-12 else { return nil }
            a.swapAt(c, piv)
            for r in 0..<m where r != c {
                let f = a[r][c] / a[c][c]
                for q in c...m { a[r][q] -= f * a[c][q] }
            }
        }
        let chi = (0..<m).reduce(0.0) { $0 + (o[$1] - e[$1]) * a[$1][m] / a[$1][$1] }
        return (chi, m, chiSquareUpperTail(chi, df: m))
    }

    /// P(X > x) for a chi-square variable with `df` degrees of freedom
    public static func chiSquareUpperTail(_ x: Double, df: Int) -> Double {
        guard x > 0, df > 0 else { return 1 }
        return 1 - regularizedLowerGamma(Double(df) / 2, x / 2)
    }
    // regularized lower incomplete gamma P(a, x): series for x < a + 1, continued fraction otherwise
    static func regularizedLowerGamma(_ a: Double, _ x: Double) -> Double {
        let lg = log(tgamma(a))     // (lgamma is ambiguous between platforms; a = df/2 is small)
        if x < a + 1 {
            var term = 1 / a, sum = term, n = a
            for _ in 0..<500 { n += 1; term *= x / n; sum += term; if abs(term) < abs(sum) * 1e-15 { break } }
            return sum * exp(-x + a * log(x) - lg)
        }
        var b = x + 1 - a, c = 1 / 1e-300, d = 1 / b, h = d
        for i in 1..<500 {
            let an = -Double(i) * (Double(i) - a)
            b += 2
            d = an * d + b; if abs(d) < 1e-300 { d = 1e-300 }
            c = b + an / c; if abs(c) < 1e-300 { c = 1e-300 }
            d = 1 / d
            let delta = d * c
            h *= delta
            if abs(delta - 1) < 1e-15 { break }
        }
        return 1 - exp(-x + a * log(x) - lg) * h
    }
}
