import XCTest
@testable import T2Kit

// Reference numbers: R 4.5.3 (wilcox.test, chisq.test, fisher.test, t.test, oneway.test,
// p.adjust, and fmtp from survival_prototype.R) on exactly these inputs. The script that
// printed them, and its output, are reproduced at the end of this file.

final class GroupCompareTests: XCTestCase {
    private func assertRelative(_ a: Double, _ b: Double, _ tolerance: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(abs(a - b) / abs(b), tolerance, "\(a) vs \(b)", file: file, line: line)
    }

    func testWilcoxonMatchesR() {
        // heavy ties; group 0 first, then the groups swapped (W flips to n1*n2 - W, p unchanged)
        let xa: [Double] = [3, 1, 4, 1, 5, 5, 2, 6, 5, 3, 5, 8, 9, 7, 9, 3, 2, 3, 8, 4]
        let ga = [Int](repeating: 0, count: 9) + [Int](repeating: 1, count: 11)
        let a = Stats.wilcoxon(xa, group: ga)!
        XCTAssertEqual(a.w, 30); assertRelative(a.p, 0.145044161163826, 1e-9)
        let a2 = Stats.wilcoxon(xa, group: ga.map { 1 - $0 })!
        XCTAssertEqual(a2.w, 69); assertRelative(a2.p, 0.145044161163826, 1e-9)
        // no ties, both directions
        let xb: [Double] = [1.1, 2.3, 0.4, 5.6, 3.2, 4.8, 7.7, 6.1, 9.4, 8.3, 10.5, 12.9]
        let gb = [Int](repeating: 0, count: 5) + [Int](repeating: 1, count: 7)
        let b = Stats.wilcoxon(xb, group: gb)!
        XCTAssertEqual(b.w, 1); assertRelative(b.p, 0.00936611163306672, 1e-9)
        let b2 = Stats.wilcoxon(xb, group: gb.map { 1 - $0 })!
        XCTAssertEqual(b2.w, 34); assertRelative(b2.p, 0.00936611163306672, 1e-9)
        // ties across the groups, group 0 clearly higher (W at its maximum)
        let xc: [Double] = [10, 12, 11, 15, 14, 13, 13, 12, 1, 2, 3, 2, 3, 1, 2]
        let gc = [Int](repeating: 0, count: 8) + [Int](repeating: 1, count: 7)
        let c = Stats.wilcoxon(xc, group: gc)!
        XCTAssertEqual(c.w, 56); assertRelative(c.p, 0.00134834943935521, 1e-9)
        let c2 = Stats.wilcoxon(xc, group: gc.map { 1 - $0 })!
        XCTAssertEqual(c2.w, 0); assertRelative(c2.p, 0.00134834943935521, 1e-9)
        // missing values and other groups are dropped; degenerate input is nil
        XCTAssertEqual(Stats.wilcoxon(xb + [.nan, 5], group: gb + [0, -1])!.w, 1)
        XCTAssertNil(Stats.wilcoxon([1, 1, 1, 1], group: [0, 0, 1, 1]))
        XCTAssertNil(Stats.wilcoxon([1, 2, 3], group: [0, 0, 0]))
    }

    func testChiSquareContingencyMatchesR() {
        let t34 = [[12, 5, 9, 7], [8, 14, 6, 10], [3, 9, 15, 4]]
        let c = Stats.chiSquareContingency(t34)!
        XCTAssertEqual(c.statistic, 15.9209659364528, accuracy: 1e-10)
        XCTAssertEqual(c.df, 6)
        assertRelative(c.p, 0.0141845206529683, 1e-9)
        XCTAssertEqual(c.expected[0][0], 7.44117647058824, accuracy: 1e-12)
        XCTAssertEqual(c.expected[1][2], 11.17647058823529, accuracy: 1e-12)
        XCTAssertEqual(c.expected[2][3], 6.38235294117647, accuracy: 1e-12)
        let d = Stats.chiSquareContingency([[20, 10], [8, 17]])!
        XCTAssertEqual(d.statistic, 6.55731922398589, accuracy: 1e-10)
        XCTAssertEqual(d.df, 1)
        assertRelative(d.p, 0.0104453608171268, 1e-9)
        // an all-zero row and column are dropped before the df
        let e = Stats.chiSquareContingency([[20, 0, 10], [0, 0, 0], [8, 0, 17]])!
        XCTAssertEqual(e.df, 1); XCTAssertEqual(e.statistic, d.statistic, accuracy: 1e-12)
        XCTAssertEqual(e.expected.count, 2); XCTAssertEqual(e.expected[0].count, 2)
        XCTAssertNil(Stats.chiSquareContingency([[5, 0], [3, 0]]))
    }

    func testFisherMatchesR() {
        // knife-edge: the tables with 0 and 4 in the corner are equally likely (the tolerance keeps both)
        assertRelative(Stats.fisher2x2(3, 1, 1, 3), 0.485714285714286, 1e-9)
        XCTAssertEqual(Stats.fisher2x2(5, 5, 5, 5), 1, accuracy: 1e-12)           // symmetric margins, observed is the mode
        assertRelative(Stats.fisher2x2(2, 8, 7, 3), 0.0697785186949273, 1e-9)
        assertRelative(Stats.fisher2x2(1, 9, 11, 3), 0.00275945618522008, 1e-9)
        assertRelative(Stats.fisher2x2(0, 6, 6, 0), 0.00216450216450217, 1e-9)    // two equal extremes
        assertRelative(Stats.fisher2x2(10, 0, 3, 7), 0.00309597523219814, 1e-9)
        assertRelative(Stats.fisher2x2(4, 12, 9, 2), 0.00632954936360509, 1e-9)
    }

    func testWelchTMatchesR() {
        let x: [Double] = [5.1, 4.8, 6.2, 5.9, 7.1, 6.6, 5.0]
        let y: [Double] = [7.9, 8.4, 6.9, 9.1, 8.8, 7.2, 10.3, 8.0, 9.5]
        let a = Stats.welchT(x, y)!
        XCTAssertEqual(a.t, -5.36101003352765, accuracy: 1e-10)
        XCTAssertEqual(a.df, 13.9631038819039, accuracy: 1e-10)
        assertRelative(a.p, 0.00010134764512264, 1e-8)
        let b = Stats.welchT(y + [.nan], x)!
        XCTAssertEqual(b.t, 5.36101003352765, accuracy: 1e-10)
        assertRelative(b.p, 0.00010134764512264, 1e-8)
        XCTAssertNil(Stats.welchT([1], [1, 2, 3]))
        XCTAssertNil(Stats.welchT([2, 2, 2], [2, 2]))
    }

    func testWelchAnovaMatchesR() {
        let x: [Double] = [5.1, 4.8, 6.2, 5.9, 7.1, 6.6, 5.0]
        let y: [Double] = [7.9, 8.4, 6.9, 9.1, 8.8, 7.2, 10.3, 8.0, 9.5]
        let z: [Double] = [3.1, 4.5, 2.2, 5.5, 6.0, 1.9, 3.8, 4.1]
        let w: [Double] = [9, 12, 15, 11, 14, 10]
        func groups(_ n: [Int]) -> [Int] { n.enumerated().flatMap { [Int](repeating: $0.offset, count: $0.element) } }
        let a = Stats.welchAnova(x + y + z, group: groups([7, 9, 8]))!
        XCTAssertEqual(a.f, 27.9693318919495, accuracy: 1e-9)
        XCTAssertEqual(a.df1, 2); XCTAssertEqual(a.df2, 13.6138251016623, accuracy: 1e-9)
        assertRelative(a.p, 1.50814311827103e-05, 1e-7)
        let b = Stats.welchAnova(x + y + z + w, group: groups([7, 9, 8, 6]))!
        XCTAssertEqual(b.f, 27.0654530121801, accuracy: 1e-9)
        XCTAssertEqual(b.df1, 3); XCTAssertEqual(b.df2, 12.9764691957912, accuracy: 1e-9)
        assertRelative(b.p, 7.4114307663957e-06, 1e-7)
        // two groups: F = t^2, same df and p as Welch's t
        let c = Stats.welchAnova(x + y, group: groups([7, 9]))!
        XCTAssertEqual(c.f, 28.7404285795841, accuracy: 1e-9)
        XCTAssertEqual(c.df2, 13.9631038819039, accuracy: 1e-9)
        assertRelative(c.p, 0.00010134764512264, 1e-7)
        let t = Stats.welchT(x, y)!
        XCTAssertEqual(c.f, t.t * t.t, accuracy: 1e-10); XCTAssertEqual(c.p, t.p, accuracy: 1e-14)
        XCTAssertNil(Stats.welchAnova(x, group: [Int](repeating: 0, count: 7)))
        XCTAssertNil(Stats.welchAnova([1, 2, 3, 4, 5], group: [0, 0, 0, 0, 1]))            // a group of one
    }

    func testFUpperTail() {
        // an F with df1 = 1 is a squared t: P(F > t^2) = P(|T| > t)
        XCTAssertEqual(Stats.fUpperTail(2.5 * 2.5, df1: 1, df2: 7), 0.0409922185857529, accuracy: 1e-12)
        XCTAssertEqual(Stats.fUpperTail(0, df1: 2, df2: 5), 1)
    }

    func testBenjaminiHochbergMatchesR() {
        let p: [Double?] = [0.01, 0.04, 0.03, 0.03, nil, 0.5, 0.001, 0.2, 0.04, 1]
        let want: [Double?] = [0.045, 0.06, 0.06, 0.06, nil, 0.5625, 0.009, 0.257142857142857, 0.06, 1]
        let got = Stats.benjaminiHochberg(p)
        XCTAssertEqual(got.count, want.count)
        for i in want.indices {
            if let w = want[i] { XCTAssertEqual(got[i]!, w, accuracy: 1e-14, "entry \(i)") } else { XCTAssertNil(got[i]) }
        }
        XCTAssertEqual(Stats.benjaminiHochberg([]).count, 0)
        XCTAssertNil(Stats.benjaminiHochberg([nil])[0])
    }

    func testPValueStringMatchesFmtp() {
        let p: [Double?] = [nil, 0, 1e-310, 2.3456e-5, 9.99e-4, 1e-3, 0.001234, 0.0456, 0.5, 1]
        let want = ["NA", "< 1e-300", "1.0e-310", "2.3e-05", "1.0e-03", "0.001", "0.00123", "0.0456", "0.5", "1"]
        XCTAssertEqual(p.map { Stats.pValueString($0) }, want)
        XCTAssertEqual(Stats.pValueString(.nan), "NA")
    }
}

/* The R script behind the reference numbers (R 4.5.3):

options(digits = 15)
   p <- function(...) { cat(...,"\n") }
   w <- function(x, g) { r <- wilcox.test(x ~ factor(g, levels=c(0,1)), exact = FALSE, correct = TRUE); p("W", r$statistic, "p", r$p.value) }
   # 1. wilcoxon
   xa <- c(3,1,4,1,5,5,2,6,5,3,5,8,9,7,9,3,2,3,8,4); ga <- c(rep(0,9), rep(1,11))
   w(xa, ga)                       # heavy ties, group 0 lower or higher?
   w(xa, 1 - ga)                   # other sign direction
   xb <- c(1.1,2.3,0.4,5.6,3.2,4.8,7.7,6.1,9.4,8.3,10.5,12.9); gb <- c(rep(0,5), rep(1,7))
   w(xb, gb); w(xb, 1 - gb)        # no ties
   xc <- c(10,12,11,15,14,13,13,12, 1,2,3,2,3,1,2); gc <- c(rep(0,8), rep(1,7)); w(xc, gc); w(xc, 1-gc)
   # 2. chisq
   t34 <- matrix(c(12,5,9,7, 8,14,6,10, 3,9,15,4), 3, 4, byrow = TRUE)
   r <- chisq.test(t34, correct = FALSE); p("chi3x4", r$statistic, r$parameter, r$p.value)
   print(r$expected)
   t22 <- matrix(c(20,10,8,17), 2, 2, byrow = TRUE)
   r <- chisq.test(t22, correct = FALSE); p("chi2x2", r$statistic, r$parameter, r$p.value)
   # 3. fisher
   f <- function(a,b,c,d) p("fisher", a,b,c,d, fisher.test(matrix(c(a,b,c,d),2,2,byrow=TRUE))$p.value)
   f(3,1,1,3); f(5,5,5,5); f(2,8,7,3); f(1,9,11,3); f(0,6,6,0); f(10,0,3,7); f(4,12,9,2)
   # 4. welch
   x <- c(5.1,4.8,6.2,5.9,7.1,6.6,5.0); y <- c(7.9,8.4,6.9,9.1,8.8,7.2,10.3,8.0,9.5)
   r <- t.test(x, y); p("welchT", r$statistic, r$parameter, r$p.value)
   r <- t.test(y, x); p("welchT rev", r$statistic, r$parameter, r$p.value)
   v <- c(x, y, c(3.1,4.5,2.2,5.5,6.0,1.9,3.8,4.1)); g <- c(rep(0,7), rep(1,9), rep(2,8))
   r <- oneway.test(v ~ factor(g), var.equal = FALSE); p("anova3", r$statistic, r$parameter, r$p.value)
   v4 <- c(v, c(9,12,15,11,14,10)); g4 <- c(g, rep(3,6))
   r <- oneway.test(v4 ~ factor(g4), var.equal = FALSE); p("anova4", r$statistic, r$parameter, r$p.value)
   v2 <- c(x,y); g2 <- c(rep(0,7), rep(1,9))
   r <- oneway.test(v2 ~ factor(g2), var.equal = FALSE); p("anova2", r$statistic, r$parameter, r$p.value)
   p("t2", t.test(x,y)$statistic^2)
   # 5. BH
   pv <- c(0.01, 0.04, 0.03, 0.03, NA, 0.5, 0.001, 0.2, 0.04, 1)
   q <- rep(NA_real_, length(pv)); ok <- !is.na(pv); q[ok] <- p.adjust(pv[ok], method = "BH")
   p("BH", q); p("BHfull", p.adjust(pv, method = "BH"))
   # 6. fmtp
   fmtp <- function(p) {
     if (is.na(p)) return("NA")
     if (p <= 0)   return("< 1e-300")
     if (p < 1e-3) return(sprintf("%.1e", p))
     sprintf("%.3g", p)
   }
   pp <- c(NA, 0, 1e-310, 2.3456e-5, 9.99e-4, 1e-3, 0.001234, 0.0456, 0.5, 1)
   print(sapply(pp, fmtp))
Output:

   W 30 p 0.145044161163826 
   W 69 p 0.145044161163826 
   W 1 p 0.00936611163306672 
   W 34 p 0.00936611163306672 
   W 56 p 0.00134834943935521 
   W 0 p 0.00134834943935521 
   chi3x4 15.9209659364528 6 0.0141845206529683 
                    [,1]              [,2]              [,3]             [,4]
   [1,] 7.44117647058824  9.05882352941176  9.70588235294118 6.79411764705882
   [2,] 8.56862745098039 10.43137254901961 11.17647058823529 7.82352941176471
   [3,] 6.99019607843137  8.50980392156863  9.11764705882353 6.38235294117647
   chi2x2 6.55731922398589 1 0.0104453608171268 
   fisher 3 1 1 3 0.485714285714286 
   fisher 5 5 5 5 1 
   fisher 2 8 7 3 0.0697785186949273 
   fisher 1 9 11 3 0.00275945618522008 
   fisher 0 6 6 0 0.00216450216450217 
   fisher 10 0 3 7 0.00309597523219814 
   fisher 4 12 9 2 0.00632954936360509 
   welchT -5.36101003352765 13.9631038819039 0.00010134764512264 
   welchT rev 5.36101003352765 13.9631038819039 0.00010134764512264 
   anova3 27.9693318919495 2 13.6138251016623 1.50814311827103e-05 
   anova4 27.0654530121801 3 12.9764691957912 7.4114307663957e-06 
   anova2 28.7404285795841 1 13.9631038819039 0.00010134764512264 
   t2 28.7404285795841 
   BH 0.045 0.06 0.06 0.06 NA 0.5625 0.009 0.257142857142857 0.06 1 
   BHfull 0.045 0.06 0.06 0.06 NA 0.5625 0.009 0.257142857142857 0.06 1 
    [1] "NA"       "< 1e-300" "1.0e-310" "2.3e-05"  "1.0e-03"  "0.001"   
    [7] "0.00123"  "0.0456"   "0.5"      "1"
*/
