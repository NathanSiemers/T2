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

    // MARK: a quantized Y (UI-REWORK step 6) - same fixtures, Y role

    /// source X = NA wherever the fixture's x or y is NA, so the universe is the pinned 21 rows
    private var sx: [Double] { var v = (1...30).map(Double.init); for i in [5, 25, 7, 14, 21, 28] { v[i - 1] = .nan }; return v }
    private var yColumns: [String: Column] {
        ["sx": Column(name: "sx", type: "n", data: .numeric(sx)),
         "v": Column(name: "v", type: "n", data: .numeric((1...30).map(Double.init))),
         "z": Column(name: "z", type: "n", data: .numeric(z)),
         "grp": Column(name: "grp", type: "c", data: .categorical(levels: ["a", "b"], codes: (0..<30).map { $0 % 2 }))]
    }
    private func yc(_ name: String, _ k: Int, color: String = "", multi: Bool = false, survival: Bool = false) -> SelectCut.YColoring {
        SelectCut.yColoring(name: name, k: k, userColor: color, multiY: multi, survival: survival, columns: yColumns, keep: keep, x: "sx")
    }
    private func scene(_ r: SelectCut.YColoring, color: String = "") -> PlotScene {
        var cols = yColumns
        var colorName = color
        if let c = r.column { cols[c.name] = c; colorName = c.name }
        var s = PlotBuilder.build(PlotRequest(x: ["sx"], y: ["v"], color: colorName), columns: cols, keep: keep)
        s.warnings.append(contentsOf: r.notices)
        return s
    }

    func testYCutGroupSizesMatchPinnedFixtures() {
        // v = 1..30 over the same 21 rows as x above: halves 11/10, tertiles 7/7/7, quartiles 6/5/5/5
        for (k, sizes, labels) in [(2, [11, 10], ["Low", "High"]), (3, [7, 7, 7], ["Low", "Mid", "High"]), (4, [6, 5, 5, 5], ["Q1", "Q2", "Q3", "Q4"])] {
            let r = yc("v", k)
            guard case .categorical(let levels, let codes)? = r.column?.data else { return XCTFail("no groups for k=\(k)") }
            XCTAssertEqual(levels, labels)
            XCTAssertEqual((0..<levels.count).map { g in codes.filter { $0 == g }.count }, sizes)
            XCTAssertEqual(r.column?.name, SelectCut.label(name: "v", k: k))
        }
    }

    func testYCutSceneKeepsContinuousYAndColorsByGroups() {
        let s = scene(yc("v", 2))
        XCTAssertEqual(s.kind, .scatter)
        let p = s.panels[0].points
        XCTAssertEqual(p.count, 21)
        XCTAssertEqual(p.map(\.y), p.map { Double($0.sample + 1) })      // the continuous values
        XCTAssertEqual(s.legend.entries.map(\.label), ["Low", "High"])
        XCTAssertEqual(Set(p.map { "\($0.color)" }).count, 2)
        XCTAssertEqual(s.warnings, ["v: the plot keeps the continuous values; the groups color the plot (and are offered on the Analysis tab)."])
    }

    func testUserColorWinsOverYCut() {
        let r = yc("v", 3, color: "grp")
        XCTAssertNil(r.column)
        let s = scene(r, color: "grp")
        XCTAssertEqual(s.legend.entries.map(\.label), ["a", "b"])
        XCTAssertEqual(s.warnings, ["v: groups have no meaning as y; the plot uses the continuous values (the groups are offered on the Analysis tab)."])
    }

    func testMultiProbeAndSurvivalDemote() {
        let note = "v: groups have no meaning as y; the plot uses the continuous values (the groups are offered on the Analysis tab)."
        XCTAssertEqual(yc("v", 2, multi: true), SelectCut.YColoring(column: nil, notices: [note]))
        XCTAssertEqual(yc("v", 2, survival: true), SelectCut.YColoring(column: nil, notices: [note]))
    }

    func testRefusedYCutGivesContinuousYAndNoGroups() {
        let r = yc("z", 4)
        XCTAssertNil(r.column)
        XCTAssertEqual(r.notices, ["z cannot be split into 4 groups: the groups would hold only 7/5/5/4 samples (at least 5 are needed in each; many samples share one marker value). Try fewer groups; the plot uses the continuous values."])
        var cols = yColumns; cols["sx"] = Column(name: "sx", type: "n", data: .numeric(sx))
        let s = PlotBuilder.build(PlotRequest(x: ["sx"], y: ["z"]), columns: cols, keep: keep)
        XCTAssertTrue(s.legend.isEmpty)
    }

    func testNoCutIsNoOpAndNonNumericIgnored() {
        XCTAssertEqual(yc("v", 0), SelectCut.YColoring(column: nil, notices: []))
        XCTAssertEqual(yc("grp", 3), SelectCut.YColoring(column: nil, notices: []))
    }
}
