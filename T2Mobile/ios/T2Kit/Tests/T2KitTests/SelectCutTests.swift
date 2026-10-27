import XCTest
@testable import T2Kit

/// Watchlist 14: the Select-tab cut universe equals the web's plotted-complete-rows rule.
/// Expected group sizes: R `quantile(type = 7)` + right-closed cut on the same rows, computed
/// (python/numpy linear percentiles, identical to type 7) for this fixture:
///   x <- as.numeric(1:30); x[c(5, 25)] <- NA; y <- as.numeric(1:30); y[c(7, 14, 21, 28)] <- NA
///   keep <- seq_len(30) > 3;  u <- keep & !is.na(x) & !is.na(y)      # 21 rows
///   z <- (7 * (1:30)) %% 11                                            # ties
///   x: halves 11/10, tertiles 7/7/7, quartiles 6/5/5/5
///   z: halves 12/9,  tertiles 7/8/6, quartiles 7/5/5/4 (refused: a group under 5)
final class SelectCutTests: XCTestCase {
    private let n = 30
    private var x: [Double] { var v = (1...30).map(Double.init); v[4] = .nan; v[24] = .nan; return v }
    private var y: [Double] { var v = (1...30).map(Double.init); for i in [7, 14, 21, 28] { v[i - 1] = .nan }; return v }
    private var z: [Double] { (1...30).map { Double(($0 * 7) % 11) } }
    private var keep: Mask { (1...30).map { $0 > 3 } }

    private func universe() -> Mask {
        SelectCut.universe(keep: keep, required: [Column(name: "x", type: "n", data: .numeric(x)), Column(name: "y", type: "n", data: .numeric(y))])
    }

    func testUniverseIsMaskAndCompleteXY() {
        XCTAssertEqual(universe().filter { $0 }.count, 21)
    }

    func testXCutSizesMatchR() {
        let u = universe()
        XCTAssertEqual(SelectCut.resolve(name: "x", k: 2, values: x, universe: u).sizes, [11, 10])
        let t = SelectCut.resolve(name: "x", k: 3, values: x, universe: u)
        XCTAssertEqual(t.sizes, [7, 7, 7]); XCTAssertEqual(t.levels, ["Low", "Mid", "High"]); XCTAssertEqual(t.label, "x (tertiles)")
        XCTAssertEqual(SelectCut.resolve(name: "x", k: 4, values: x, universe: u).sizes, [6, 5, 5, 5])
        // outside the universe: no group
        XCTAssertEqual(t.codes[0], -1); XCTAssertEqual(t.codes[4], -1); XCTAssertEqual(t.codes[6], -1)
    }

    func testColorCutUsesPlottedRowsOnly() {
        let u = universe()
        XCTAssertEqual(SelectCut.resolve(name: "z", k: 2, values: z, universe: u).sizes, [12, 9])
        XCTAssertEqual(SelectCut.resolve(name: "z", k: 3, values: z, universe: u).sizes, [7, 8, 6])
        let q = SelectCut.resolve(name: "z", k: 4, values: z, universe: u)
        XCTAssertEqual(q.levels, [])
        XCTAssertEqual(q.notice, "z cannot be split into 4 groups: the groups would hold only 7/5/5/4 samples (at least 5 are needed in each; many samples share one marker value). Try fewer groups; the plot uses the continuous values.")
        // the mask alone (not the web rule) would give different sizes
        let maskOnly = SelectCut.resolve(name: "z", k: 3, values: z, universe: keep)
        XCTAssertNotEqual(maskOnly.sizes, [7, 8, 6])
    }

    func testConstantColumnRefused() {
        let r = SelectCut.resolve(name: "c", k: 3, values: [Double](repeating: 1, count: 30), universe: universe())
        XCTAssertEqual(r.notice, "c cannot be split into 3 groups: it has fewer than 2 distinct values among the plotted samples; the plot uses the continuous values.")
    }
}
