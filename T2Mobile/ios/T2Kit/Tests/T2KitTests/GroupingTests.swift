import XCTest
@testable import T2Kit

// The grouping model and the test dispatcher behind the Analysis panel (ANALYSIS-SPEC sections
// 2, 3, 4). Numbers that are not hand-counted come from the R calls named in the spec; the
// log-rank reference (R 4.5.3, survival as in the rstudio:2026.03 image) is
//
//   i <- 0:29; time <- (i * 37) %% 500 + 10; event <- as.numeric(i %% 3 != 0)
//   grp <- factor(ifelse(i < 15, "A", "B")); mx <- 200
//   tt <- pmin(time, mx); ee <- ifelse(time > mx, 0, event)
//   survdiff(Surv(tt, ee) ~ grp)    # chisq 0.180624055390819, df 1, p 0.670837484864805
//   survdiff(Surv(time, event) ~ grp)  # untruncated: 0.0650263544029557, p 0.798721048090921
//
// The Wilcoxon / chi-square / Fisher numbers reuse the tables pinned in GroupCompareTests.

final class GroupingTests: XCTestCase {
    private let n = 40
    // a: 0...39 with 5, 6, 7 missing; b: a permutation of 0...39; sex: F/M by parity;
    // stage: served order III, I, II (+ IV, never used), sample 39 missing
    private func fixture(base: Mask? = nil) -> CrossFilter {
        var f = CrossFilter(sampleCount: n)
        let a = (0..<n).map { [5, 6, 7].contains($0) ? Double.nan : Double($0) }
        let b = (0..<n).map { Double(($0 * 7) % 40) }
        f.load([Column(name: "a", type: "clinical", data: .numeric(a)),
                Column(name: "b", type: "clinical", data: .numeric(b)),
                Column(name: "sex", type: "clinical", data: .categorical(levels: ["F", "M"], codes: (0..<n).map { $0 % 2 })),
                Column(name: "stage", type: "clinical", data: .categorical(levels: ["III", "I", "II", "IV"], codes: (0..<n).map { $0 == 39 ? -1 : $0 % 3 }))])
        f.baseMask = base
        return f
    }
    private func count(_ m: Mask) -> Int { m.filter { $0 }.count }
    private func lookup(_ f: CrossFilter) -> (String) -> Column? { { f.columns[$0] } }

    func testLeaveOneOutSplitCountsBothIncludeMissingSettings() {
        var f = fixture()
        f.add("a"); f.add("sex")
        f.set("sex", value: .levels(["F"]))
        f.set("a", value: .range(lo: 10, hi: 29), includeMissing: true)
        // universe = the 20 even samples; a passes 10...28 even (10) and the missing 6 (include-missing ON)
        var s = f.splitMasks(on: "a")!
        XCTAssertEqual(count(s.selected), 11); XCTAssertEqual(count(s.excluded), 9)
        XCTAssertTrue(s.selected[6]); XCTAssertFalse(s.excluded[6])
        XCTAssertFalse(zip(s.selected, s.excluded).contains { $0 && $1 })          // disjoint
        XCTAssertEqual(zip(s.selected, s.excluded).filter { $0 || $1 }.count, 20)  // union = U
        XCTAssertEqual(s.selected.indices.filter { s.selected[$0] || s.excluded[$0] }, stride(from: 0, to: 40, by: 2).map { $0 })
        var g = makeGrouping(.filterSplit(column: "a"), filter: f, column: lookup(f))!
        XCTAssertEqual(g.labels, ["Selected", "Excluded"]); XCTAssertEqual(g.nUniverse, 20)
        XCTAssertEqual(g.note, "Selected includes 1 samples missing a.")
        // OFF: the missing sample is excluded
        f.set("a", value: .range(lo: 10, hi: 29), includeMissing: false)
        s = f.splitMasks(on: "a")!
        XCTAssertEqual(count(s.selected), 10); XCTAssertEqual(count(s.excluded), 10)
        XCTAssertTrue(s.excluded[6])
        g = makeGrouping(.filterSplit(column: "a"), filter: f, column: lookup(f))!
        XCTAssertEqual(g.note, "Excluded includes 1 samples missing a.")
        XCTAssertEqual(g.group[6], 1); XCTAssertEqual(g.group[12], 0); XCTAssertEqual(g.group[13], -1)
        // the other filter's leave-one-out: universe = the a filter (OFF) only
        let t = f.splitMasks(on: "sex")!
        XCTAssertEqual(count(t.selected), 10)       // even samples in 10...29 (a is not missing)
        XCTAssertEqual(count(t.selected) + count(t.excluded), 20)
        // no active filter on the column: nil
        XCTAssertNil(f.splitMasks(on: "b")); XCTAssertNil(f.splitMasks(on: "nope"))
        XCTAssertNil(makeGrouping(.filterSplit(column: "b"), filter: f, column: lookup(f)))
    }

    func testWholeFilterSplitAndOneActiveFilterInvariant() {
        let base = (0..<n).map { $0 < 36 }
        var f = fixture(base: base)
        f.add("a"); f.add("sex")
        f.set("sex", value: .levels(["F"]))
        f.set("a", value: .range(lo: 10, hi: 29), includeMissing: true)
        let w = f.splitMasks(on: nil)!
        XCTAssertEqual(w.selected, f.mask())
        XCTAssertEqual(w.excluded, (0..<n).map { base[$0] && !f.mask()[$0] })
        XCTAssertEqual(count(w.selected), 11); XCTAssertEqual(count(w.excluded), 25)
        let g = makeGrouping(.filterSplit(column: nil), filter: f, column: lookup(f))!
        XCTAssertEqual(g.nUniverse, 36); XCTAssertEqual(g.note, "Filters: a, sex")
        // exactly one active filter: whole == leave-one-out (watchlist 10)
        for missing in [true, false] {
            var one = fixture(base: base)
            one.add("a"); one.set("a", value: .range(lo: 10, hi: 29), includeMissing: missing)
            let x = one.splitMasks(on: nil)!, y = one.splitMasks(on: "a")!
            XCTAssertEqual(x.selected, y.selected); XCTAssertEqual(x.excluded, y.excluded)
        }
    }

    func testQuantizedGroupingKeepsTheFilters() {
        var f = fixture()
        let open = makeGrouping(.quantized(name: "b", k: 2), filter: f, column: lookup(f))!
        XCTAssertEqual(open.labels, ["Low", "High"]); XCTAssertEqual(open.nUniverse, 40)
        XCTAssertEqual(open.group.filter { $0 == 0 }.count, 20)
        XCTAssertEqual(open.group[3], 1)                      // b = 21: above the cut 19.5
        // with b itself filtered to 0...19 the cut is over those 20 samples (median 9.5)
        f.add("b"); f.set("b", value: .range(lo: 0, hi: 19))
        let g = makeGrouping(.quantized(name: "b", k: 2), filter: f, column: lookup(f))!
        XCTAssertEqual(g.nUniverse, 20)
        XCTAssertEqual(g.group.filter { $0 == 0 }.count, 10); XCTAssertEqual(g.group.filter { $0 == 1 }.count, 10)
        let b = f.columns["b"]!.numbers!
        for i in 0..<n {
            XCTAssertEqual(g.group[i], b[i] > 19 ? -1 : (b[i] <= 9 ? 0 : 1))
        }
        XCTAssertEqual(makeGrouping(.quantized(name: "b", k: 3), filter: f, column: lookup(f))!.labels, ["Low", "Mid", "High"])
        XCTAssertEqual(makeGrouping(.quantized(name: "b", k: 4), filter: f, column: lookup(f))!.labels, ["Q1", "Q2", "Q3", "Q4"])
        // min-n refusal: 12 samples in 4 groups of 3
        f.set("b", value: .range(lo: 0, hi: 11))
        let r = makeGrouping(.quantized(name: "b", k: 4), filter: f, column: lookup(f))!
        XCTAssertNotNil(r.refused); XCTAssertEqual(r.nUniverse, 12); XCTAssertTrue(r.group.allSatisfy { $0 == -1 })
        XCTAssertNil(makeGrouping(.quantized(name: "stage", k: 2), filter: f, column: lookup(f)))   // not numeric
        XCTAssertNil(makeGrouping(.quantized(name: "b", k: 5), filter: f, column: lookup(f)))
    }

    func testCategoricalGroupingDropsLevelsAndRefuses() {
        var f = fixture()
        f.add("sex"); f.set("sex", value: .levels(["F"]))          // the even samples
        let g = makeGrouping(.categorical("stage"), filter: f, column: lookup(f))!
        XCTAssertEqual(g.labels, ["III", "I", "II"])               // served order, IV dropped
        XCTAssertEqual(g.nUniverse, 20)
        XCTAssertEqual(g.group[0], 0); XCTAssertEqual(g.group[4], 1); XCTAssertEqual(g.group[2], 2); XCTAssertEqual(g.group[1], -1)
        // a filter that leaves one level: refused
        f.add("stage"); f.set("stage", value: .levels(["I"]))
        let one = makeGrouping(.categorical("stage"), filter: f, column: lookup(f))!
        XCTAssertNotNil(one.refused)
        // a level served first but absent from the universe does not shift the others
        var h = fixture(); h.baseMask = (0..<n).map { $0 % 3 != 0 }
        XCTAssertEqual(makeGrouping(.categorical("stage"), filter: h, column: lookup(h))!.labels, ["I", "II"])
    }

    // MARK: dispatcher

    private let xa: [Double] = [3, 1, 4, 1, 5, 5, 2, 6, 5, 3, 5, 8, 9, 7, 9, 3, 2, 3, 8, 4]
    private func two(_ a: Int, _ b: Int, labels: [String] = ["Selected", "Excluded"]) -> GroupAssignment {
        GroupAssignment(group: [Int](repeating: 0, count: a) + [Int](repeating: 1, count: b), labels: labels, nUniverse: a + b)
    }

    func testNumericDispatch() {
        let g = two(9, 11)
        var r = groupTest(values: .numeric(xa), kind: .numeric, assignment: g, means: false, tte: nil, maxDays: .infinity)
        XCTAssertNil(r.refused); XCTAssertEqual(r.n, 20); XCTAssertEqual(r.analysisMethod, .auto)
        XCTAssertEqual(r.test.count, 1); XCTAssertEqual(r.test[0].term, "group")
        XCTAssertEqual(r.test[0].method, "Wilcoxon rank-sum"); XCTAssertEqual(r.test[0].statistic, 30)
        XCTAssertEqual(r.test[0].p!, 0.145044161163826, accuracy: 1e-12)
        XCTAssertNil(r.test[0].df); XCTAssertNil(r.test[0].pBH)
        XCTAssertEqual(r.groups.map { $0.n }, [9, 11]); XCTAssertEqual(r.groups[0].median, Stats.median(Array(xa[0..<9])))
        XCTAssertEqual(r.groups[1].q3, Stats.quantile(Array(xa[9...]), 0.75))
        // the order of the groups carries the sign of W
        let swapped = GroupAssignment(group: g.group.map { 1 - $0 }, labels: g.labels, nUniverse: 20)
        r = groupTest(values: .numeric(xa), kind: .numeric, assignment: swapped, means: false, tte: nil, maxDays: .infinity)
        XCTAssertEqual(r.test[0].statistic, 69)
        // means: Welch t
        r = groupTest(values: .numeric(xa), kind: .numeric, assignment: g, means: true, tte: nil, maxDays: .infinity)
        let t = Stats.welchT(Array(xa[0..<9]), Array(xa[9...]))!
        XCTAssertEqual(r.test[0].method, "Welch t-test"); XCTAssertEqual(r.test[0].statistic, t.t); XCTAssertEqual(r.test[0].df, t.df); XCTAssertEqual(r.test[0].p, t.p)
        // three groups: Kruskal-Wallis, Welch ANOVA
        let g3 = GroupAssignment(group: (0..<20).map { $0 % 3 }, labels: ["x", "y", "z"], nUniverse: 20)
        r = groupTest(values: .numeric(xa), kind: .numeric, assignment: g3, means: false, tte: nil, maxDays: .infinity)
        let kw = Stats.kruskalWallis(xa, group: g3.group)!
        XCTAssertEqual(r.test[0].method, "Kruskal-Wallis"); XCTAssertEqual(r.test[0].statistic, kw.statistic); XCTAssertEqual(r.test[0].df, 2); XCTAssertEqual(r.test[0].p, kw.p)
        r = groupTest(values: .numeric(xa), kind: .numeric, assignment: g3, means: true, tte: nil, maxDays: .infinity)
        let an = Stats.welchAnova(xa, group: g3.group)!
        XCTAssertEqual(r.test[0].method, "Welch ANOVA"); XCTAssertEqual(r.test[0].statistic!, an.f, accuracy: 1e-9); XCTAssertEqual(r.test[0].df, 2); XCTAssertEqual(r.test[0].p!, an.p, accuracy: 1e-9)
        // missing values and samples in no group are left out
        var withGaps = xa; withGaps[0] = .nan
        var gg = g; gg.group[1] = -1
        r = groupTest(values: .numeric(withGaps), kind: .numeric, assignment: gg, means: false, tte: nil, maxDays: .infinity)
        XCTAssertEqual(r.n, 18)
        // a constant variable cannot be compared; a wrong kind of data is refused
        XCTAssertNotNil(groupTest(values: .numeric([Double](repeating: 1, count: 20)), kind: .numeric, assignment: g, means: false, tte: nil, maxDays: .infinity).refused)
        XCTAssertNotNil(groupTest(values: .categorical(levels: ["a"], codes: [Int](repeating: 0, count: 20)), kind: .numeric, assignment: g, means: false, tte: nil, maxDays: .infinity).refused)
    }

    func testMinNDropAndRefusal() {
        // three groups of 9, 11 and 4: the small one is dropped with a note, the rest is the pinned Wilcoxon
        let g = GroupAssignment(group: [Int](repeating: 0, count: 9) + [Int](repeating: 1, count: 11) + [Int](repeating: 2, count: 4),
                                labels: ["a", "b", "c"], nUniverse: 24)
        let r = groupTest(values: .numeric(xa + [1, 2, 3, 4]), kind: .numeric, assignment: g, means: false, tte: nil, maxDays: .infinity)
        XCTAssertNil(r.refused); XCTAssertEqual(r.test[0].method, "Wilcoxon rank-sum"); XCTAssertEqual(r.test[0].statistic, 30)
        XCTAssertEqual(r.test[0].p!, 0.145044161163826, accuracy: 1e-12)
        XCTAssertEqual(r.test[0].note, "Dropped (fewer than 5 samples with a value): c (n = 4).")
        XCTAssertEqual(r.groups.map { $0.group }, ["a", "b"])
        // complete cases decide: NAs shrink group b below the floor too
        var x = xa + [1, 2, 3, 4]
        for i in 9..<16 { x[i] = .nan }
        let r2 = groupTest(values: .numeric(x), kind: .numeric, assignment: g, means: false, tte: nil, maxDays: .infinity)
        XCTAssertNotNil(r2.refused); XCTAssertTrue(r2.test.isEmpty)
        // a refused grouping is passed on
        var bad = g; bad.refused = "no groups"
        XCTAssertEqual(groupTest(values: .numeric(x), kind: .numeric, assignment: bad, means: false, tte: nil, maxDays: .infinity).refused, "no groups")
    }

    private func table(_ t: [[Int]]) -> (assignment: GroupAssignment, data: Column.Data) {
        var group: [Int] = [], codes: [Int] = []
        for (g, row) in t.enumerated() { for (l, c) in row.enumerated() { group += [Int](repeating: g, count: c); codes += [Int](repeating: l, count: c) } }
        return (GroupAssignment(group: group, labels: t.indices.map { "g\($0)" }, nUniverse: group.count),
                .categorical(levels: (0..<t[0].count).map { "L\($0)" }, codes: codes))
    }

    func testCategoricalDispatchAndFisherSwitch() {
        // 2x2, all expected counts >= 5: chi-squared (pinned in GroupCompareTests)
        var t = table([[20, 10], [8, 17]])
        var r = groupTest(values: t.data, kind: .categorical, assignment: t.assignment, means: true, tte: nil, maxDays: .infinity)
        XCTAssertEqual(r.test[0].method, "Chi-squared"); XCTAssertEqual(r.test[0].statistic!, 6.55731922398589, accuracy: 1e-10)
        XCTAssertEqual(r.test[0].df, 1); XCTAssertEqual(r.test[0].p!, 0.0104453608171268, accuracy: 1e-12)
        XCTAssertEqual(r.levels.count, 4); XCTAssertEqual(r.levels[0].prop, 20.0 / 30)
        XCTAssertEqual(r.groups.map { $0.n }, [30, 25])
        // 2x2 with an expected count of 4.5: Fisher (R: fisher.test(matrix(c(2,8,7,3)...)) 0.0697785186949273)
        t = table([[2, 8], [7, 3]])
        r = groupTest(values: t.data, kind: .categorical, assignment: t.assignment, means: false, tte: nil, maxDays: .infinity)
        XCTAssertEqual(r.test[0].method, "Fisher exact"); XCTAssertEqual(r.test[0].p!, 0.0697785186949273, accuracy: 1e-12)
        XCTAssertNil(r.test[0].statistic); XCTAssertNil(r.test[0].df)
        // a larger table is never Fisher
        t = table([[12, 5, 9, 7], [8, 14, 6, 10], [3, 9, 15, 4]])
        r = groupTest(values: t.data, kind: .categorical, assignment: t.assignment, means: false, tte: nil, maxDays: .infinity)
        XCTAssertEqual(r.test[0].method, "Chi-squared"); XCTAssertEqual(r.test[0].df, 6)
        XCTAssertEqual(r.test[0].statistic!, 15.9209659364528, accuracy: 1e-10); XCTAssertEqual(r.test[0].p!, 0.0141845206529683, accuracy: 1e-12)
        // a level nobody has is not a column: 2x2 after dropping, same as the plain 2x2
        let gaps = Column.Data.categorical(levels: ["L0", "unused", "L1"], codes: { if case .categorical(_, let c) = table([[20, 10], [8, 17]]).data { return c.map { $0 == 1 ? 2 : 0 } }; return [] }())
        r = groupTest(values: gaps, kind: .categorical, assignment: table([[20, 10], [8, 17]]).assignment, means: false, tte: nil, maxDays: .infinity)
        XCTAssertEqual(r.test[0].statistic!, 6.55731922398589, accuracy: 1e-10)
        XCTAssertEqual(r.levels.map { $0.level }, ["L0", "L1", "L0", "L1"])
    }

    private var tteTime: [Double] { (0..<30).map { Double(($0 * 37) % 500 + 10) } }
    private var tteEvent: [Double] { (0..<30).map { $0 % 3 != 0 ? 1 : 0 } }

    func testSurvivalDispatchTruncatesAtMaxDays() {
        let g = two(15, 15, labels: ["A", "B"])
        let r = groupTest(values: nil, kind: .survival, assignment: g, means: true, tte: (tteTime, tteEvent), maxDays: 200)
        XCTAssertNil(r.refused); XCTAssertEqual(r.test[0].method, "Log-rank"); XCTAssertEqual(r.test[0].df, 1)
        // R: survdiff on the censored-at-200 data
        XCTAssertEqual(r.test[0].statistic!, 0.180624055390819, accuracy: 1e-10)
        XCTAssertEqual(r.test[0].p!, 0.670837484864805, accuracy: 1e-10)
        // the same as Stats.logRank after the plot's truncation, done by hand
        var time = tteTime, event = tteEvent
        for i in time.indices where time[i] > 200 { time[i] = 200; event[i] = 0 }
        let lr = Stats.logRank(time: time, event: event, group: g.group)!
        XCTAssertEqual(r.test[0].p, lr.p); XCTAssertEqual(r.test[0].statistic, lr.chiSquare)
        // no cap (infinite or zero): the untruncated p
        for cap in [Double.infinity, 0] {
            let u = groupTest(values: nil, kind: .survival, assignment: g, means: false, tte: (tteTime, tteEvent), maxDays: cap)
            XCTAssertEqual(u.test[0].p!, 0.798721048090921, accuracy: 1e-10)
        }
        // group summaries: n, events, median ("NR" when the curve stays above one half)
        XCTAssertEqual(r.groups.map { $0.n }, [15, 15])
        XCTAssertEqual(r.groups[0].events, event[0..<15].filter { $0 != 0 }.count)
        XCTAssertNotNil(r.groups[0].medianSurvival)
        XCTAssertNotNil(groupTest(values: nil, kind: .survival, assignment: g, means: false, tte: nil, maxDays: 200).refused)
        // a group of fewer than 5 with a positive time and no missing event is dropped
        var t2 = tteTime; for i in 0..<12 { t2[i] = .nan }
        XCTAssertNotNil(groupTest(values: nil, kind: .survival, assignment: g, means: false, tte: (t2, tteEvent), maxDays: 200).refused)
    }

    func testScreenRanksAdjustsAndLeavesRefusalsLast() {
        let g = two(9, 11)
        let cols: [String: Column] = [
            "x": Column(name: "x", type: "clinical", data: .numeric(xa)),
            "flat": Column(name: "flat", type: "clinical", data: .numeric([Double](repeating: 2, count: 20))),
            "y": Column(name: "y", type: "clinical", data: .numeric(xa.reversed())),
            "z": Column(name: "z", type: "clinical", data: .numeric((0..<20).map { Double(($0 * 7) % 20) })),
            "c": Column(name: "c", type: "clinical", data: table([[8, 1], [1, 10]]).data.withCodes(count: 20))]
        // categorical c: first 9 samples mostly L0, last 11 mostly L1
        let rows = groupScreen(vars: ["flat", "x", "c", "y", "z", "absent"], column: { cols[$0] },
                               kinds: ["flat": .numeric, "x": .numeric, "c": .categorical, "y": .numeric, "z": .numeric, "absent": .numeric],
                               assignment: g, means: false, tteSpecs: [:], maxDays: .infinity)
        XCTAssertEqual(rows.count, 6)
        let valid = rows.filter { $0.p != nil }
        XCTAssertEqual(valid.count, 4)
        XCTAssertEqual(valid.map { $0.p! }, valid.map { $0.p! }.sorted())
        XCTAssertEqual(Set(rows.suffix(2).map { $0.variable }), ["flat", "absent"])
        XCTAssertEqual(rows.suffix(2).map { $0.variable }, ["flat", "absent"])      // refused keep the given order
        XCTAssertTrue(rows.suffix(2).allSatisfy { $0.p == nil && $0.pBH == nil && $0.note != nil })
        // BH over the 4 valid p-values only (m = 4, not 6)
        let expected = Stats.benjaminiHochberg(valid.map { $0.p })
        XCTAssertEqual(valid.map { $0.pBH }, expected)
        XCTAssertEqual(valid[0].pBH!, min(1, valid[0].p! * 4), accuracy: 1e-12)
        XCTAssertEqual(rows.first { $0.variable == "x" }!.method, "Wilcoxon rank-sum")
        XCTAssertEqual(rows.first { $0.variable == "x" }!.p!, 0.145044161163826, accuracy: 1e-12)
        XCTAssertEqual(rows.first { $0.variable == "c" }!.n, 20)
    }
}

private extension Column.Data {
    // the codes of a built table, cut or padded to `count`
    func withCodes(count: Int) -> Column.Data {
        guard case .categorical(let l, let c) = self else { return self }
        return .categorical(levels: l, codes: Array(c.prefix(count)))
    }
}
