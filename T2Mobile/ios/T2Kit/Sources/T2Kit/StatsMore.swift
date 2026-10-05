import Foundation

// More of the statistics T2 shows with its plots: tests of association, confidence limits
// for Kaplan-Meier curves, the Cox hazard ratio, and residuals ("remove influences of").
// Every function is checked against R in the unit tests (cor.test, kruskal.test,
// survival::survfit / coxph, lm); see Tests/T2KitTests/StatsMoreTests.swift.

public extension Stats {

    // MARK: distributions

    /// log of the gamma function (Lanczos, g = 7): accurate to ~1e-14 for x > 0.
    /// (`lgamma` is ambiguous between Linux and Apple platforms, so it is not used.)
    static func logGamma(_ x: Double) -> Double {
        let c: [Double] = [0.99999999999980993, 676.5203681218851, -1259.1392167224028, 771.32342877765313,
                           -176.61502916214059, 12.507343278686905, -0.13857109526572012,
                           9.9843695780195716e-6, 1.5056327351493116e-7]
        if x < 0.5 { return log(Double.pi / abs(sin(Double.pi * x))) - logGamma(1 - x) }
        let z = x - 1
        var a = c[0]
        let t = z + 7.5
        for i in 1..<9 { a += c[i] / (z + Double(i)) }
        return 0.5 * log(2 * Double.pi) + (z + 0.5) * log(t) - t + log(a)
    }

    /// regularized incomplete beta function I_x(a, b) (continued fraction, Lentz)
    static func regularizedBeta(_ x: Double, _ a: Double, _ b: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let front = exp(logGamma(a + b) - logGamma(a) - logGamma(b) + a * log(x) + b * log(1 - x))
        // the fraction converges fast for x < (a + 1) / (a + b + 2); otherwise use symmetry
        if x > (a + 1) / (a + b + 2) { return 1 - regularizedBeta(1 - x, b, a) }
        let tiny = 1e-300
        var c = 1.0, d = 1 - (a + b) * x / (a + 1)
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d
        for m in 1..<400 {
            let dm = Double(m)
            var num = dm * (b - dm) * x / ((a + 2 * dm - 1) * (a + 2 * dm))
            d = 1 + num * d; if abs(d) < tiny { d = tiny }
            c = 1 + num / c; if abs(c) < tiny { c = tiny }
            d = 1 / d; h *= d * c
            num = -(a + dm) * (a + b + dm) * x / ((a + 2 * dm) * (a + 2 * dm + 1))
            d = 1 + num * d; if abs(d) < tiny { d = tiny }
            c = 1 + num / c; if abs(c) < tiny { c = tiny }
            d = 1 / d
            let delta = d * c
            h *= delta
            if abs(delta - 1) < 1e-15 { break }
        }
        return front * h / a
    }

    /// P(|T| > |t|) for Student's t with `df` degrees of freedom
    static func tTwoSided(_ t: Double, df: Double) -> Double {
        guard df > 0, !t.isNaN else { return .nan }
        if t.isInfinite { return 0 }
        return regularizedBeta(df / (df + t * t), df / 2, 0.5)
    }
    /// P(|Z| > |z|) for a standard normal
    static func normalTwoSided(_ z: Double) -> Double { z.isNaN ? .nan : erfc(abs(z) / 2.0.squareRoot()) }

    // MARK: association

    /// Pearson correlation with its t test (R: cor.test(x, y)). Pairs with a missing member are dropped.
    struct Correlation: Sendable, Equatable { public let r, statistic, p: Double; public let n: Int }
    static func pearson(x: [Double], y: [Double]) -> Correlation? {
        guard let line = regression(x: x, y: y), !line.r.isNaN else { return nil }
        let df = Double(line.n - 2)
        let r = line.r
        let t = abs(r) >= 1 ? (r > 0 ? Double.infinity : -Double.infinity) : r * (df / (1 - r * r)).squareRoot()
        return Correlation(r: r, statistic: t, p: tTwoSided(t, df: df), n: line.n)
    }

    /// ranks from 1, ties get the mean of their ranks (R: rank()); the input must not contain NaN
    static func ranks(_ v: [Double]) -> [Double] {
        let order = v.indices.sorted { v[$0] < v[$1] }
        var out = [Double](repeating: 0, count: v.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count && v[order[j + 1]] == v[order[i]] { j += 1 }
            let mean = Double(i + j) / 2 + 1
            for k in i...j { out[order[k]] = mean }
            i = j + 1
        }
        return out
    }
    /// Spearman's rho: the Pearson correlation of the ranks, with the t approximation for p
    /// (R: cor.test(x, y, method = "spearman", exact = FALSE))
    static func spearman(x: [Double], y: [Double]) -> Correlation? {
        let rows = (0..<min(x.count, y.count)).filter { !x[$0].isNaN && !y[$0].isNaN }
        guard rows.count >= 3 else { return nil }
        return pearson(x: ranks(rows.map { x[$0] }), y: ranks(rows.map { y[$0] }))
    }

    /// Kruskal-Wallis rank sum test across groups (R: kruskal.test), with the correction for ties.
    /// `group[i]` >= 0; a negative group or a missing value drops the sample. Empty groups are ignored.
    static func kruskalWallis(_ v: [Double], group: [Int]) -> (statistic: Double, df: Int, p: Double)? {
        let rows = (0..<min(v.count, group.count)).filter { !v[$0].isNaN && group[$0] >= 0 }
        let n = Double(rows.count)
        guard rows.count >= 2 else { return nil }
        let values = rows.map { v[$0] }
        let r = ranks(values)
        var sum: [Int: Double] = [:], count: [Int: Double] = [:]
        for (k, row) in rows.enumerated() { sum[group[row], default: 0] += r[k]; count[group[row], default: 0] += 1 }
        guard sum.count >= 2 else { return nil }
        var h = 0.0
        for (g, s) in sum { h += s * s / count[g]! }
        h = 12 / (n * (n + 1)) * h - 3 * (n + 1)
        var ties: [Double: Double] = [:]
        for x in values { ties[x, default: 0] += 1 }
        let correction = 1 - ties.values.reduce(0) { $0 + ($1 * $1 * $1 - $1) } / (n * n * n - n)
        guard correction > 0 else { return nil }           // every value identical
        h /= correction
        let df = sum.count - 1
        return (h, df, chiSquareUpperTail(h, df: df))
    }

    // MARK: survival

    /// A Kaplan-Meier curve with what a plot needs: the estimate after every event time,
    /// Greenwood's standard error, and 95% limits of survfit's default type ("log":
    /// exp(log S +- 1.96 se / S), cut at 1).
    struct KMBand: Sendable, Equatable {
        public let times: [Double]
        public let survival: [Double]
        public let stdErr: [Double]
        public let lower: [Double]
        public let upper: [Double]
        public let atRisk: [Int]
        /// every observation time with its censoring flag, for censor marks and the risk table
        public let observed: [Double]
        public let n: Int
        public let events: Int
        /// first time the estimate is <= 0.5, or nil ("not reached")
        public var medianTime: Double? { zip(times, survival).first { $0.1 <= 0.5 }?.0 }
        /// how many are still at risk at time `t` (observation time >= t)
        public func atRisk(at t: Double) -> Int { observed.reduce(0) { $0 + ($1 >= t ? 1 : 0) } }
    }
    static func kaplanMeierBand(time: [Double], event: [Double], z: Double = 1.959963984540054) -> KMBand {
        let obs = zip(time, event).filter { !$0.0.isNaN && !$0.1.isNaN }.sorted { $0.0 < $1.0 }
        var times: [Double] = [], surv: [Double] = [], se: [Double] = [], lo: [Double] = [], hi: [Double] = [], risk: [Int] = []
        var s = 1.0, greenwood = 0.0, i = 0, nEvents = 0
        while i < obs.count {
            let t = obs[i].0, atRisk = obs.count - i
            var d = 0, j = i
            while j < obs.count && obs[j].0 == t { if obs[j].1 != 0 { d += 1 }; j += 1 }
            if d > 0 {
                s *= 1 - Double(d) / Double(atRisk)
                if atRisk > d { greenwood += Double(d) / (Double(atRisk) * Double(atRisk - d)) } else { greenwood = .infinity }
                let seLog = greenwood.squareRoot()                 // standard error of log S
                times.append(t); surv.append(s); risk.append(atRisk); nEvents += d
                se.append(s * seLog)
                if s > 0 && seLog.isFinite {
                    lo.append(s * exp(-z * seLog)); hi.append(min(1, s * exp(z * seLog)))
                } else { lo.append(.nan); hi.append(.nan) }
            }
            i = j
        }
        return KMBand(times: times, survival: surv, stdErr: se, lower: lo, upper: hi, atRisk: risk,
                      observed: obs.map { $0.0 }, n: obs.count, events: nEvents)
    }

    /// Equal-count groups of a marker the way T2's survival view makes them (survival_km):
    /// breaks = the UNIQUE quantiles at 0, 1/n ... 1, the outer two opened to infinity,
    /// intervals closed on the right. With many tied values there are fewer groups than
    /// asked for; fewer than two means the marker cannot be stratified.
    /// Returns the group of every sample (-1 = missing) and how many groups there are.
    static func quantileGroupsUnique(_ x: [Double], groups: Int) -> (group: [Int], count: Int) {
        let g = max(2, groups)
        var breaks: [Double] = []
        for k in 0...g {
            let q = quantile(x, Double(k) / Double(g))
            if q.isNaN { return (x.map { _ in -1 }, 0) }
            if breaks.last != q { breaks.append(q) }
        }
        guard breaks.count >= 2 else { return (x.map { $0.isNaN ? -1 : 0 }, breaks.isEmpty ? 0 : 1) }
        let inner = Array(breaks[1..<(breaks.count - 1)])
        let group = x.map { v in v.isNaN ? -1 : inner.reduce(0) { $0 + (v > $1 ? 1 : 0) } }
        return (group, breaks.count - 1)
    }
    /// the names T2 gives such groups: Low / High, Low / Mid / High, otherwise Q1 ...
    static func groupLabels(asked: Int, made: Int) -> [String] {
        let all: [String] = asked == 2 ? ["Low", "High"] : asked == 3 ? ["Low", "Mid", "High"] : (1...max(1, asked)).map { "Q\($0)" }
        return Array(all.prefix(max(0, made)))
    }

    /// Cox proportional hazards with ONE covariate, Efron's method for ties (coxph's default).
    struct Cox: Sendable, Equatable {
        public let coef, se, hazardRatio, lower, upper, p: Double
        public let n: Int, events: Int
    }
    static func cox(time: [Double], event: [Double], covariate: [Double]) -> Cox? {
        let rows = (0..<min(time.count, event.count, covariate.count))
            .filter { !time[$0].isNaN && !event[$0].isNaN && !covariate[$0].isNaN }
            .sorted { time[$0] > time[$1] }                      // latest first: risk sets grow
        let nEvents = rows.reduce(0) { $0 + (event[$1] != 0 ? 1 : 0) }
        guard rows.count >= 3, nEvents >= 1 else { return nil }
        let zs = rows.map { covariate[$0] }
        let mean = zs.reduce(0, +) / Double(zs.count)
        guard zs.contains(where: { $0 != zs[0] }) else { return nil }
        // score and information at beta (covariate centred for numerical comfort)
        func derivatives(_ beta: Double) -> (u: Double, info: Double) {
            var u = 0.0, info = 0.0
            var s0 = 0.0, s1 = 0.0, s2 = 0.0
            var i = 0
            while i < rows.count {
                let t = time[rows[i]]
                var j = i
                var d = 0.0, d0 = 0.0, d1 = 0.0, d2 = 0.0, dz = 0.0
                while j < rows.count && time[rows[j]] == t {
                    let z = covariate[rows[j]] - mean, w = exp(beta * z)
                    s0 += w; s1 += w * z; s2 += w * z * z
                    if event[rows[j]] != 0 { d += 1; d0 += w; d1 += w * z; d2 += w * z * z; dz += z }
                    j += 1
                }
                if d > 0 {
                    u += dz
                    var k = 0.0
                    while k < d {
                        let f = k / d
                        let a0 = s0 - f * d0, a1 = s1 - f * d1, a2 = s2 - f * d2
                        u -= a1 / a0
                        info += a2 / a0 - (a1 / a0) * (a1 / a0)
                        k += 1
                    }
                }
                i = j
            }
            return (u, info)
        }
        var beta = 0.0
        for _ in 0..<50 {
            let (u, info) = derivatives(beta)
            guard info > 0, info.isFinite else { return nil }
            let stepSize = u / info
            beta += stepSize
            if abs(stepSize) < 1e-12 { break }
            if abs(beta) > 50 { return nil }                     // not converging (separation)
        }
        let info = derivatives(beta).info
        guard info > 0, info.isFinite else { return nil }
        let se = 1 / info.squareRoot(), z = 1.959963984540054
        return Cox(coef: beta, se: se, hazardRatio: exp(beta), lower: exp(beta - z * se), upper: exp(beta + z * se),
                   p: normalTwoSided(beta / se), n: rows.count, events: nEvents)
    }

    // MARK: residuals

    /// "Remove influences of": the residuals of the least-squares fit of `y` on the
    /// covariates (with an intercept), as residualize_on() in marker_ops.R: a sample missing
    /// y or any covariate gets NaN; if the fit is not possible `y` is returned unchanged.
    static func residuals(_ y: [Double], on covariates: [[Double]]) -> [Double] {
        guard !covariates.isEmpty, covariates.allSatisfy({ $0.count == y.count }) else { return y }
        let rows = y.indices.filter { i in !y[i].isNaN && covariates.allSatisfy { !$0[i].isNaN } }
        let p = covariates.count + 1
        guard rows.count >= covariates.count + 2 else { return y }
        // centre everything (the intercept then drops out of the normal equations)
        let n = Double(rows.count)
        let my = rows.reduce(0.0) { $0 + y[$1] } / n
        let mx = covariates.map { c in rows.reduce(0.0) { $0 + c[$1] } / n }
        let q = p - 1
        var a = [[Double]](repeating: [Double](repeating: 0, count: q + 1), count: q)
        for r in rows {
            for i in 0..<q {
                let xi = covariates[i][r] - mx[i]
                for j in 0..<q { a[i][j] += xi * (covariates[j][r] - mx[j]) }
                a[i][q] += xi * (y[r] - my)
            }
        }
        for c in 0..<q {            // Gauss-Jordan with partial pivoting
            guard let piv = (c..<q).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[piv][c]) > 1e-12 * max(1, abs(a[c][c])) else { return y }
            a.swapAt(c, piv)
            for r in 0..<q where r != c {
                let f = a[r][c] / a[c][c]
                for k in c...q { a[r][k] -= f * a[c][k] }
            }
        }
        let beta = (0..<q).map { a[$0][q] / a[$0][$0] }
        var out = [Double](repeating: .nan, count: y.count)
        for r in rows {
            var fit = my
            for i in 0..<q { fit += beta[i] * (covariates[i][r] - mx[i]) }
            out[r] = y[r] - fit
        }
        return out
    }
}
