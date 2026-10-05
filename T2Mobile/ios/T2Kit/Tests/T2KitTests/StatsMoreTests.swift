import XCTest
@testable import T2Kit

// Reference numbers: R 4.5.3 with survival 3.8.6 (cor.test, kruskal.test, survfit, coxph,
// quantile + cut, lm, pt, pnorm) on exactly these inputs. The script that printed them is
// reproduced at the end of this file.

final class StatsMoreTests: XCTestCase {
    /// |a - b| relative to b: for p-values that are far from 1
    private func assertRelative(_ a: Double, _ b: Double, _ tolerance: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(abs(a - b) / abs(b), tolerance, "\(a) vs \(b)", file: file, line: line)
    }

    func testTailProbabilitiesMatchR() {
        XCTAssertEqual(Stats.tTwoSided(2.5, df: 7), 0.0409922185857529, accuracy: 1e-12)
        XCTAssertEqual(Stats.tTwoSided(-2.5, df: 7), 0.0409922185857529, accuracy: 1e-12)
        XCTAssertEqual(Stats.tTwoSided(0.3, df: 3), 0.783763292039919, accuracy: 1e-12)
        assertRelative(Stats.tTwoSided(12, df: 40), 7.824171304256e-15, 1e-8)
        XCTAssertEqual(Stats.normalTwoSided(1.96), 0.0499957902964409, accuracy: 1e-14)
        assertRelative(Stats.normalTwoSided(-4.5), 6.79534624946012e-06, 1e-11)
        XCTAssertEqual(Stats.tTwoSided(0, df: 5), 1, accuracy: 1e-12)
        XCTAssertEqual(Stats.tTwoSided(.infinity, df: 5), 0)
        // log-gamma against known values: Gamma(5) = 24, Gamma(1/2) = sqrt(pi)
        XCTAssertEqual(Stats.logGamma(5), log(24), accuracy: 1e-12)
        XCTAssertEqual(Stats.logGamma(0.5), 0.5 * log(Double.pi), accuracy: 1e-12)
    }

    func testPearsonMatchesCorTest() {
        let x: [Double] = [1, 2, 3, 4, 5, 6, .nan, 8], y: [Double] = [2.1, 3.9, 6.2, 7.8, 10.1, 12.2, 5, .nan]
        let c = Stats.pearson(x: x, y: y)!
        XCTAssertEqual(c.r, 0.999104932480818, accuracy: 1e-12)
        XCTAssertEqual(c.statistic, 47.2384245080186, accuracy: 1e-8)
        assertRelative(c.p, 1.20136025602182e-06, 1e-9)
        XCTAssertEqual(c.n, 6)
        let c2 = Stats.pearson(x: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], y: [2, 1, 4, 3, 7, 5, 6, 10, 8, 9.5])!
        XCTAssertEqual(c2.r, 0.90998620437424, accuracy: 1e-12)
        XCTAssertEqual(c2.statistic, 6.20740596368867, accuracy: 1e-10)
        assertRelative(c2.p, 0.000257343930152403, 1e-9)
        let c3 = Stats.pearson(x: [1, 2, 3, 4, 5, 6, 7, 8], y: [3, 1, 4, 1, 5, 9, 2, 6])!
        XCTAssertEqual(c3.r, 0.477455260559423, accuracy: 1e-12)
        XCTAssertEqual(c3.p, 0.231519832073695, accuracy: 1e-11)
        XCTAssertNil(Stats.pearson(x: [1, 2], y: [1, 2]))               // fewer than 3 pairs
        XCTAssertNil(Stats.pearson(x: [1, 2, 3], y: [5, 5, 5]))         // constant y: r undefined
    }

    func testRanksAndSpearmanMatchR() {
        let sx: [Double] = [1, 2, 2, 4, 5, 5, 7, 8, 9, 10], sy: [Double] = [2, 1, 4, 4, 7, 5, 6, 10, 8, 8]
        XCTAssertEqual(Stats.ranks(sx), [1, 2.5, 2.5, 4, 5.5, 5.5, 7, 8, 9, 10])
        XCTAssertEqual(Stats.ranks(sy), [2, 1, 3.5, 3.5, 7, 5, 6, 10, 8.5, 8.5])
        let s = Stats.spearman(x: sx, y: sy)!
        XCTAssertEqual(s.r, 0.911042944785276, accuracy: 1e-12)
        assertRelative(s.p, 0.000245792456003906, 1e-9)
        // a missing member drops the pair before ranking
        let withGap = Stats.spearman(x: sx + [.nan, 3], y: sy + [4, .nan])!
        XCTAssertEqual(withGap.r, s.r, accuracy: 1e-15); XCTAssertEqual(withGap.n, 10)
    }

    func testKruskalWallisMatchesR() {
        let v: [Double] = [1, 2, 2, 3, 5, 4, 4, 6, 7, 9, 8, 8, 10, 12, 11]
        let g = (0..<15).map { $0 / 5 }
        let k = Stats.kruskalWallis(v, group: g)!
        XCTAssertEqual(k.statistic, 10.6369838420108, accuracy: 1e-10)
        XCTAssertEqual(k.df, 2)
        XCTAssertEqual(k.p, 0.00490013795095669, accuracy: 1e-12)
        // dropped: a missing value, a sample in no group; group numbers need not be contiguous
        let k2 = Stats.kruskalWallis(v + [.nan, 99], group: g.map { $0 * 3 } + [0, -1])!
        XCTAssertEqual(k2.statistic, k.statistic, accuracy: 1e-12); XCTAssertEqual(k2.df, 2)
        XCTAssertNil(Stats.kruskalWallis(v, group: [Int](repeating: 0, count: 15)))     // one group
        XCTAssertNil(Stats.kruskalWallis([3, 3, 3, 3], group: [0, 0, 1, 1]))            // all tied
    }

    // the 6-MP leukemia trial (Gehan 1965): treatment then control
    let time: [Double] = [6,6,6,6,7,9,10,10,11,13,16,17,19,20,22,23,25,32,32,34,35, 1,1,2,2,3,4,4,5,5,8,8,8,8,11,11,12,12,15,17,22,23]
    let event: [Double] = [1,1,1,0,1,0,1,0,0,1,1,0,0,0,1,1,0,0,0,0,0] + [Double](repeating: 1, count: 21)

    func testKaplanMeierBandMatchesSurvfit() {
        let km = Stats.kaplanMeierBand(time: Array(time[0..<21]), event: Array(event[0..<21]))
        XCTAssertEqual(km.times, [6, 7, 10, 13, 16, 22, 23])
        let surv = [0.857142857142857, 0.80672268907563, 0.752941176470588, 0.690196078431372, 0.627450980392157, 0.53781512605042, 0.448179271708683]
        let se = [0.0763603548321213, 0.0869352851800572, 0.0963496529943205, 0.10681470777501, 0.114053865256753, 0.128233751693034, 0.13459145675576]
        let lower = [0.71981708391627, 0.653124218462171, 0.585918982029694, 0.50961309910178, 0.439393924968767, 0.337036616157685, 0.24878822681766]
        let upper = [1, 0.996443675908659, 0.967574754552297, 0.93476919553613, 0.895994938535082, 0.858200848044665, 0.807372045529077]
        XCTAssertEqual(km.survival.count, 7)
        for i in 0..<7 {
            XCTAssertEqual(km.survival[i], surv[i], accuracy: 1e-12)
            XCTAssertEqual(km.stdErr[i], se[i], accuracy: 1e-12)
            XCTAssertEqual(km.lower[i], lower[i], accuracy: 1e-11)
            XCTAssertEqual(km.upper[i], upper[i], accuracy: 1e-11)
        }
        XCTAssertEqual(km.atRisk, [21, 17, 15, 12, 11, 7, 6])
        XCTAssertEqual(km.n, 21); XCTAssertEqual(km.events, 9); XCTAssertEqual(km.medianTime, 23)
        // the same estimate as the plain curve that was already tested
        XCTAssertEqual(km.survival, Stats.kaplanMeier(time: Array(time[0..<21]), event: Array(event[0..<21])).survival)
        // numbers at risk for the table under the plot
        XCTAssertEqual(km.atRisk(at: 0), 21); XCTAssertEqual(km.atRisk(at: 10), 15); XCTAssertEqual(km.atRisk(at: 36), 0)
        // everyone has the event: the curve ends at 0, where the limits are not defined
        let all = Stats.kaplanMeierBand(time: [1, 2, 3], event: [1, 1, 1])
        XCTAssertEqual(all.survival.last, 0); XCTAssertTrue(all.lower.last!.isNaN)
    }

    func testCoxMatchesCoxph() {
        let z: [Double] = [0.3,-1.2,0.8,1.5,-0.4,0.1,2.0,-0.7,0.9,-1.5,0.2,1.1,-0.3,0.6,-0.9,1.8,-0.1,0.4,-1.1,0.7,1.3,
                           -0.5,1.0,-1.4,0.5,-0.2,1.6,-0.8,0.0,1.2,-1.0,0.35,-0.6,1.4,-1.3,0.75,-0.15,1.7,-0.45,0.95,-1.6,0.25]
        let c = Stats.cox(time: time, event: event, covariate: z)!
        XCTAssertEqual(c.coef, -0.104309387918678, accuracy: 1e-8)
        XCTAssertEqual(c.se, 0.18494454451237, accuracy: 1e-8)
        XCTAssertEqual(c.p, 0.572751685759674, accuracy: 1e-7)
        XCTAssertEqual(c.hazardRatio, 0.900946512330769, accuracy: 1e-8)
        XCTAssertEqual(c.lower, 0.627009219506585, accuracy: 1e-7)
        XCTAssertEqual(c.upper, 1.29456568233516, accuracy: 1e-7)
        XCTAssertEqual(c.n, 42); XCTAssertEqual(c.events, 30)
        // per standard deviation, as T2 reports it: the covariate z-scored first
        let perSD = Stats.cox(time: time, event: event, covariate: Stats.zscore(z))!
        XCTAssertEqual(perSD.hazardRatio, 0.901301714302993, accuracy: 1e-8)
        XCTAssertEqual(perSD.lower, 0.628116224776929, accuracy: 1e-7)
        XCTAssertEqual(perSD.upper, 1.29330329031703, accuracy: 1e-7)
        XCTAssertEqual(perSD.p, 0.572751685759674, accuracy: 1e-7)
        XCTAssertNil(Stats.cox(time: time, event: event, covariate: [Double](repeating: 1, count: 42)))   // constant
        XCTAssertNil(Stats.cox(time: [1, 2, 3], event: [0, 0, 0], covariate: [1, 2, 3]))                  // no events
    }

    func testQuantileGroupsAsSurvivalKmMakesThem() {
        let m1: [Double] = [5, 1, 9, 3, 7, 2, 8, 4, 6, .nan, 10, 11]
        let g3 = Stats.quantileGroupsUnique(m1, groups: 3)
        XCTAssertEqual(g3.group, [1, 0, 2, 0, 1, 0, 2, 0, 1, -1, 2, 2]); XCTAssertEqual(g3.count, 3)
        let g4 = Stats.quantileGroupsUnique(m1, groups: 4)
        XCTAssertEqual(g4.group, [1, 0, 3, 0, 2, 0, 2, 1, 1, -1, 3, 3]); XCTAssertEqual(g4.count, 4)
        // many tied values: the quantiles coincide, R keeps the unique breaks -> ONE group
        let ties = Stats.quantileGroupsUnique([0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 0, 0], groups: 3)
        XCTAssertEqual(ties.count, 1); XCTAssertEqual(ties.group, [Int](repeating: 0, count: 12))
        // a 0/1 marker: tertiles cannot split it, halves can
        let binary: [Double] = [0, 0, 0, 0, 1, 1, 1, 1]
        XCTAssertEqual(Stats.quantileGroupsUnique(binary, groups: 3).count, 1)
        let halves = Stats.quantileGroupsUnique(binary, groups: 2)
        XCTAssertEqual(halves.group, [0, 0, 0, 0, 1, 1, 1, 1]); XCTAssertEqual(halves.count, 2)
        XCTAssertEqual(Stats.quantileGroupsUnique([.nan, .nan], groups: 3).count, 0)
        XCTAssertEqual(Stats.groupLabels(asked: 3, made: 3), ["Low", "Mid", "High"])
        XCTAssertEqual(Stats.groupLabels(asked: 2, made: 2), ["Low", "High"])
        XCTAssertEqual(Stats.groupLabels(asked: 3, made: 2), ["Low", "Mid"])            // R: labs[seq_len(length(br) - 1)]
        XCTAssertEqual(Stats.groupLabels(asked: 4, made: 4), ["Q1", "Q2", "Q3", "Q4"])
    }

    func testResidualsMatchLm() {
        let y: [Double] = [2.1, 3.9, 6.2, 7.8, 10.1, 12.2, 5.0, 9.4, 11.0, 4.4]
        let a: [Double] = [1, 2, 3, 4, 5, 6, 2.5, 4.5, 5.5, 1.5]
        let b: [Double] = [0.5, 0.1, 0.9, 0.3, 0.7, 0.2, 0.8, 0.4, 0.6, 1.0]
        let ab = [-0.165607476635515, -0.0254205607476629, -0.293644859813084, -0.202056074766354, -0.167476635514019,
                  0.34841121495327, -0.436635514018691, 0.340934579439253, -0.173084112149533, 0.774579439252337]
        let onlyA = [-0.296363636363638, -0.421818181818182, -0.0472727272727267, -0.372727272727272, 0.00181818181818169,
                     0.176363636363636, -0.284545454545454, 0.264545454545455, -0.0609090909090908, 1.04090909090909]
        let r2 = Stats.residuals(y, on: [a, b]), r1 = Stats.residuals(y, on: [a])
        for i in 0..<10 {
            XCTAssertEqual(r2[i], ab[i], accuracy: 1e-11)
            XCTAssertEqual(r1[i], onlyA[i], accuracy: 1e-11)
        }
        // a sample missing y or a covariate is left out of the fit and comes back missing
        let gap = Stats.residuals(y + [7, .nan], on: [a + [.nan, 3], b + [0.5, 0.5]])
        XCTAssertEqual(gap.count, 12); XCTAssertTrue(gap[10].isNaN); XCTAssertTrue(gap[11].isNaN)
        for i in 0..<10 { XCTAssertEqual(gap[i], ab[i], accuracy: 1e-11) }
        // no covariates, or a fit that is not possible: y unchanged (residualize_on does the same)
        XCTAssertEqual(Stats.residuals(y, on: []), y)
        XCTAssertEqual(Stats.residuals([1, 2], on: [[1, 2]]), [1, 2])                              // too few rows
        XCTAssertEqual(Stats.residuals(y, on: [[Double](repeating: 3, count: 10)]), y)             // constant covariate
    }
}

/* The R script behind the reference numbers (R 4.5.3, survival 3.8.6):

   library(survival)
   x <- c(1,2,3,4,5,6,NA,8); y <- c(2.1,3.9,6.2,7.8,10.1,12.2,5,NA);  cor.test(x, y)
   cor.test(1:10, c(2,1,4,3,7,5,6,10,8,9.5));  cor.test(1:8, c(3,1,4,1,5,9,2,6))
   sx <- c(1,2,2,4,5,5,7,8,9,10); sy <- c(2,1,4,4,7,5,6,10,8,8)
   rank(sx); rank(sy); cor.test(sx, sy, method = "spearman", exact = FALSE)
   kruskal.test(c(1,2,2,3,5,4,4,6,7,9,8,8,10,12,11), factor(rep(c("a","b","c"), each = 5)))
   time / event: as in the test (Gehan 1965)
   summary(survfit(Surv(time[1:21], event[1:21]) ~ 1))        # surv, std.err, lower, upper
   summary(coxph(Surv(time, event) ~ z));  summary(coxph(Surv(time, event) ~ as.numeric(scale(z))))
   grp <- function(m, n) { br <- unique(quantile(m, seq(0, 1, length.out = n + 1), na.rm = TRUE))
                           br[1] <- -Inf; br[length(br)] <- Inf
                           as.integer(cut(m, breaks = br, include.lowest = TRUE)) - 1L }
   residuals(lm(ry ~ ra + rb));  residuals(lm(ry ~ ra))
   2 * pt(c(2.5, 0.3, 12), c(7, 3, 40), lower.tail = FALSE);  2 * pnorm(c(1.96, 4.5), lower.tail = FALSE)
*/
