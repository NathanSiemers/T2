import XCTest
@testable import T2Kit

/// Count plots, "graph for each", and survival plots. The statistics inside are T2Kit's own
/// functions, which are checked against R elsewhere; here the question is whether the
/// builder hands them the right samples and reports what they return.
final class PlotBuilderMoreTests: XCTestCase {
    // the 10-sample dataset of PlotBuilderTests, plus a second categorical variable
    let g1: [Double] = [1.5, 2.25, .nan, 4, 5.125, 6, 7.5, 8, 9.75, 10]
    let g2: [Double] = [2, 1, 4, .nan, 7, 5, 6, 10, 8, 9.5]
    let tissueCodes = [0, 0, 1, 1, 2, 2, 0, 1, -1, 2]
    let sexCodes = [0, 1, 0, 1, 0, 1, 1, 1, 0, -1]
    let keep: Mask = [true, true, true, true, true, true, true, true, true, false]
    var columns: [String: Column] {
        ["G1": Column(name: "G1", type: "rna", data: .numeric(g1)),
         "G2": Column(name: "G2", type: "rna", data: .numeric(g2)),
         "tissue": Column(name: "tissue", type: "clinical", data: .categorical(levels: ["lung", "skin", "colon", "liver"], codes: tissueCodes)),
         "sex": Column(name: "sex", type: "clinical", data: .categorical(levels: ["F", "M"], codes: sexCodes))]
    }

    func testTwoCategoricalVariablesGiveCounts() {
        let s = PlotBuilder.build(PlotRequest(x: ["tissue"], y: ["sex"]), columns: columns, keep: keep)
        XCTAssertEqual(s.kind, .counts)
        let p = s.panels[0]
        XCTAssertEqual(p.xAxis.labels, ["lung", "skin", "colon"]); XCTAssertEqual(p.yAxis.labels, ["F", "M"])
        // kept with both: 0 lung F, 1 lung M, 2 skin F, 3 skin M, 4 colon F, 5 colon M, 6 lung M, 7 skin M
        func count(_ x: Double, _ y: Double) -> Int? { p.bubbles.first { $0.x == x && $0.y == y }?.count }
        XCTAssertEqual(count(0.5, 0.5), 1); XCTAssertEqual(count(0.5, 1.5), 2)
        XCTAssertEqual(count(1.5, 0.5), 1); XCTAssertEqual(count(1.5, 1.5), 2)
        XCTAssertEqual(count(2.5, 0.5), 1); XCTAssertEqual(count(2.5, 1.5), 1)
        XCTAssertEqual(p.bubbles.reduce(0) { $0 + $1.count }, 8); XCTAssertEqual(s.n, 8)
        XCTAssertEqual(p.bubbles.map(\.radius).max(), 1)                              // the largest count fills its cell
        XCTAssertEqual(p.bubbles.first { $0.count == 1 }!.radius, (0.5).squareRoot(), accuracy: 1e-12)   // area follows the count
        var r = PlotRequest(x: ["tissue"], y: ["sex"]); r.flip = true
        let f = PlotBuilder.build(r, columns: columns, keep: keep)
        XCTAssertEqual(f.panels[0].xAxis.labels, ["F", "M"])
        XCTAssertEqual(f.panels[0].bubbles.first { $0.x == 1.5 && $0.y == 0.5 }?.count, 2)   // M, lung
    }

    func testGraphForEachLevel() {
        let s = PlotBuilder.build(PlotRequest(x: ["G1"], y: ["G2"], facet: "sex"), columns: columns, keep: keep)
        XCTAssertEqual(s.kind, .scatter)
        XCTAssertEqual(s.panels.map(\.title), ["F", "M"])
        // kept, G1, G2 and sex present: F = 0, 4, 8; M = 1, 5, 6, 7
        XCTAssertEqual(s.panels[0].points.map(\.sample), [0, 4, 8]); XCTAssertEqual(s.panels[1].points.map(\.sample), [1, 5, 6, 7])
        XCTAssertEqual(s.panels[1].points.map(\.y), [1, 5, 6, 10])                    // the values themselves
        XCTAssertEqual(s.n, 7)
        // numeric axes are the same in every panel and hold every point
        XCTAssertEqual(s.panels[0].xAxis, s.panels[1].xAxis); XCTAssertEqual(s.panels[0].yAxis, s.panels[1].yAxis)
        for p in s.panels { for pt in p.points { XCTAssertTrue(pt.x >= p.xAxis.lo && pt.x <= p.xAxis.hi && pt.y >= p.yAxis.lo && pt.y <= p.yAxis.hi) } }
        // each panel has its own fit and says how many samples it shows
        XCTAssertEqual(s.panels[0].lines.count, 1); XCTAssertTrue(s.panels[0].note.hasPrefix("n = 3")); XCTAssertTrue(s.panels[1].note.hasPrefix("n = 4"))
        XCTAssertEqual(s.stats.first { $0.label == "Graphs" }?.value, "2")
        XCTAssertTrue(s.subtitle.contains("Graphs: sex."))
        // boxes: a panel shows only its own categories
        let b = PlotBuilder.build(PlotRequest(x: ["tissue"], y: ["G2"], color: "tissue", facet: "sex"), columns: columns, keep: keep)
        XCTAssertEqual(b.panels[0].xAxis.labels, ["lung", "skin", "colon"])           // F: 0 lung, 2 skin, 4 colon
        XCTAssertEqual(b.panels[1].xAxis.labels, ["lung", "skin", "colon"])           // M: 1, 6 lung; 7 skin; 5 colon
        XCTAssertEqual(b.panels[0].yAxis, b.panels[1].yAxis)
        // colours mean the same in both panels
        let lungF = b.panels[0].points.first { $0.sample == 0 }!.color, lungM = b.panels[1].points.first { $0.sample == 1 }!.color
        XCTAssertEqual(lungF, lungM); XCTAssertEqual(b.legend.entries.map(\.label), ["lung", "skin", "colon"])
        // a numeric variable cannot be the "graph for each" variable; too many panels are cut, and said
        let w = PlotBuilder.build(PlotRequest(x: ["tissue"], y: ["G2"], facet: "G1"), columns: columns, keep: keep)
        XCTAssertEqual(w.panels.count, 1); XCTAssertEqual(w.warnings.count, 1)
        let cut = PlotBuilder.build(PlotRequest(x: ["G1"], y: ["G2"], facet: "tissue"), columns: columns, keep: keep,
                                    context: PlotBuilder.Context(maxPanels: 2))
        XCTAssertEqual(cut.panels.map(\.title), ["lung", "skin"]); XCTAssertEqual(cut.warnings.count, 1)
    }

    // MARK: survival

    // the 6-MP leukemia trial (Gehan 1965): 21 treated, then 21 controls; plus a marker
    let time: [Double] = [6,6,6,6,7,9,10,10,11,13,16,17,19,20,22,23,25,32,32,34,35, 1,1,2,2,3,4,4,5,5,8,8,8,8,11,11,12,12,15,17,22,23]
    let event: [Double] = [1,1,1,0,1,0,1,0,0,1,1,0,0,0,1,1,0,0,0,0,0] + [Double](repeating: 1, count: 21)
    let z: [Double] = [0.3,-1.2,0.8,1.5,-0.4,0.1,2.0,-0.7,0.9,-1.5,0.2,1.1,-0.3,0.6,-0.9,1.8,-0.1,0.4,-1.1,0.7,1.3,
                       -0.5,1.0,-1.4,0.5,-0.2,1.6,-0.8,0.0,1.2,-1.0,0.35,-0.6,1.4,-1.3,0.75,-0.15,1.7,-0.45,0.95,-1.6,0.25]
    var trial: [String: Column] {
        ["OS": Column(name: "OS", type: "clinical", data: .numeric(event)),
         "OS.time": Column(name: "OS.time", type: "clinical", data: .numeric(time)),
         "M": Column(name: "M", type: "rna", data: .numeric(z)),
         "arm": Column(name: "arm", type: "clinical", data: .categorical(levels: ["6-MP", "control"], codes: (0..<42).map { $0 < 21 ? 0 : 1 }))]
    }
    let all = Mask(repeating: true, count: 42)
    let survivalContext = PlotBuilder.Context(datasetLabel: "Trial", survivalEndpoints: ["OS"])

    func testSurvivalByCategoricalMarkerMatchesSurvdiff() {
        var r = PlotRequest(x: ["OS"], y: ["arm"]); r.kmMaxDays = 0             // no limit on follow-up
        let s = PlotBuilder.build(r, columns: trial, keep: all, context: survivalContext)
        XCTAssertEqual(s.kind, .survival); XCTAssertEqual(s.n, 42)
        XCTAssertEqual(s.title, "Overall Survival by arm groups")
        XCTAssertEqual(s.legend.entries.map(\.label), ["6-MP (med 23d)", "control (med 8d)"])     // survfit: medians 23 and 8
        XCTAssertEqual(s.legend.entries.map(\.color), Palette.survival(count: 2))
        // survdiff(Surv(time, event) ~ arm): chisq 16.79, p 4.17e-05 (the R value of StatsTests)
        XCTAssertEqual(s.stats.first { $0.label == "Log-rank p" }?.value, "4.2e-05")
        XCTAssertNil(s.stats.first { $0.label == "Cox HR per SD" })                  // no numeric marker, no hazard ratio per SD
        // the treated arm's curve: starts at 1, steps at the event times, ends at the last follow-up
        let curve = s.panels[0].lines[0]
        XCTAssertEqual(curve.xs.first, 0); XCTAssertEqual(curve.ys.first, 1)
        XCTAssertEqual(Array(curve.xs.prefix(3)), [0, 6, 6])
        XCTAssertEqual(curve.ys[1], 1); XCTAssertEqual(curve.ys[2], 0.857142857142857, accuracy: 1e-12)
        XCTAssertEqual(curve.xs.last, 35); XCTAssertEqual(curve.ys.last!, 0.448179271708683, accuracy: 1e-12)
        // its confidence band holds the curve
        let band = s.panels[0].bands[0]
        XCTAssertEqual(band.xs, curve.xs)
        for i in curve.xs.indices { XCTAssertTrue(band.lower[i] <= curve.ys[i] + 1e-12 && band.upper[i] >= curve.ys[i] - 1e-12) }
        XCTAssertEqual(band.upper[2], 1, accuracy: 1e-12); XCTAssertEqual(band.lower[2], 0.71981708391627, accuracy: 1e-11)
        // numbers at risk at the axis ticks, per group
        let risk = s.panels[0].riskTable!
        XCTAssertEqual(risk.groups, ["6-MP", "control"]); XCTAssertEqual(risk.times.first, 0)
        XCTAssertEqual(risk.rows[0][0], 21); XCTAssertEqual(risk.rows[1][0], 21)
        for (k, t) in risk.times.enumerated() { XCTAssertEqual(risk.rows[0][k], time[0..<21].filter { $0 >= t }.count) }
        XCTAssertEqual(s.panels[0].xAxis.title, "Time (days)"); XCTAssertEqual(s.panels[0].yAxis.title, "OS probability")
    }

    func testSurvivalByNumericMarkerGroupsFollowUpLimitAndCox() {
        var r = PlotRequest(x: ["OS"], y: ["M"]); r.kmGroups = 2; r.kmMaxDays = 20
        let s = PlotBuilder.build(r, columns: trial, keep: all, context: survivalContext)
        XCTAssertEqual(s.kind, .survival)
        XCTAssertEqual(s.title, "Overall Survival by M halves")
        XCTAssertTrue(s.subtitle.contains("follow-up \u{2264} 20d")); XCTAssertTrue(s.subtitle.hasPrefix("n = 42"))
        // what survival_km() does, by hand: censor at 20 days, halves of the marker, then the tests
        var t = time, e = event
        for i in t.indices where t[i] > 20 { e[i] = 0; t[i] = 20 }
        let halves = Stats.quantileGroupsUnique(z, groups: 2)
        XCTAssertEqual(halves.count, 2)
        let lr = Stats.logRank(time: t, event: e, group: halves.group)!
        let cox = Stats.cox(time: t, event: e, covariate: Stats.zscore(z))!
        XCTAssertEqual(s.stats.first { $0.label == "Log-rank p" }?.value, PlotFormat.pValue(lr.p))
        XCTAssertEqual(s.stats.first { $0.label == "Cox HR per SD" }?.value,
                       String(format: "%.2f (%.2f\u{2013}%.2f)", cox.hazardRatio, cox.lower, cox.upper))
        XCTAssertEqual(s.stats.first { $0.label == "Events" }?.value, "\(e.filter { $0 != 0 }.count)")
        XCTAssertEqual(s.legend.entries.count, 2); XCTAssertTrue(s.legend.entries[0].label.hasPrefix("Low")); XCTAssertTrue(s.legend.entries[1].label.hasPrefix("High"))
        // no curve goes beyond the limit
        XCTAssertTrue(s.panels[0].lines.allSatisfy { ($0.xs.max() ?? 0) <= 20 })
        XCTAssertEqual(s.panels[0].xAxis.hi, 20 * 1.02, accuracy: 1e-9)
        // the low group's curve is the Kaplan-Meier estimate of exactly its members
        let low = halves.group.indices.filter { halves.group[$0] == 0 }
        let km = Stats.kaplanMeier(time: low.map { t[$0] }, event: low.map { e[$0] })
        XCTAssertEqual(s.panels[0].lines[0].ys.last!, km.survival.last!, accuracy: 1e-12)
        // tertiles by default, named Low / Mid / High
        let three = PlotBuilder.build(PlotRequest(x: ["OS"], y: ["M"]), columns: trial, keep: all, context: survivalContext)
        XCTAssertEqual(three.title, "Overall Survival by M tertiles"); XCTAssertEqual(three.legend.entries.count, 3)
        XCTAssertTrue(three.legend.entries[1].label.hasPrefix("Mid"))
    }

    func testSurvivalRefusals() {
        // without the endpoint in the context, OS is an ordinary numeric variable
        XCTAssertEqual(PlotBuilder.build(PlotRequest(x: ["OS"], y: ["M"]), columns: trial, keep: all).kind, .scatter)
        // fewer than 20 complete samples
        var few = Mask(repeating: false, count: 42); for i in 0..<15 { few[i] = true }
        let a = PlotBuilder.build(PlotRequest(x: ["OS"], y: ["M"]), columns: trial, keep: few, context: survivalContext)
        XCTAssertEqual(a.kind, .empty); XCTAssertTrue(a.message.contains("(15)"))
        // a marker that cannot be split
        var flat = trial; flat["M"] = Column(name: "M", type: "rna", data: .numeric([Double](repeating: 0, count: 40) + [1, 2]))
        let b = PlotBuilder.build(PlotRequest(x: ["OS"], y: ["M"]), columns: flat, keep: all, context: survivalContext)
        XCTAssertEqual(b.kind, .empty); XCTAssertTrue(b.message.contains("too few distinct values"))
        // the time column is missing
        var noTime = trial; noTime["OS.time"] = nil
        XCTAssertEqual(PlotBuilder.build(PlotRequest(x: ["OS"], y: ["M"]), columns: noTime, keep: all, context: survivalContext).kind, .empty)
        // samples with a time of 0, or without the marker, take no part
        var zeroTime = trial; var tt = time; tt[0] = 0
        zeroTime["OS.time"] = Column(name: "OS.time", type: "clinical", data: .numeric(tt))
        XCTAssertEqual(PlotBuilder.build(PlotRequest(x: ["OS"], y: ["arm"]), columns: zeroTime, keep: all, context: survivalContext).n, 41)
    }
}
