import XCTest
@testable import T2Kit

// A dataset of 10 samples, small enough to check every number by hand.
//
//   sample   0     1     2     3     4      5     6     7     8     9
//   G1       1.5   2.25  NA    4     5.125  6     7.5   8     9.75  10
//   G2       2     1     4     NA    7      5     6     10    8     9.5
//   tissue   lung  lung  skin  skin  colon  colon lung  skin  NA    colon      (level "liver" has no sample)
//   grade    lo    lo    lo    lo    lo     lo    lo    lo    lo    lo         (one level only)
//   stype    T     T     T     T     T      T     T     NA    T     T          (the dataset's sample type)
//   kept     yes   yes   yes   yes   yes    yes   yes   yes   yes   no

final class PlotBuilderTests: XCTestCase {
    let g1: [Double] = [1.5, 2.25, .nan, 4, 5.125, 6, 7.5, 8, 9.75, 10]
    let g2: [Double] = [2, 1, 4, .nan, 7, 5, 6, 10, 8, 9.5]
    let tissueCodes = [0, 0, 1, 1, 2, 2, 0, 1, -1, 2]
    let keep: Mask = [true, true, true, true, true, true, true, true, true, false]

    var columns: [String: Column] {
        ["G1": Column(name: "G1", type: "rna", data: .numeric(g1)),
         "G2": Column(name: "G2", type: "rna", data: .numeric(g2)),
         "tissue": Column(name: "tissue", type: "clinical", data: .categorical(levels: ["lung", "skin", "colon", "liver"], codes: tissueCodes)),
         "grade": Column(name: "grade", type: "clinical", data: .categorical(levels: ["lo", "hi"], codes: [Int](repeating: 0, count: 10)))]
    }
    /// the same, with the dataset's sample-type column (sample 7 has none)
    var columnsWithSampleType: [String: Column] {
        var c = columns
        c["sample_type"] = Column(name: "sample_type", type: "clinical", data: .categorical(levels: ["T"], codes: [0, 0, 0, 0, 0, 0, 0, -1, 0, 0]))
        return c
    }
    let context = PlotBuilder.Context(datasetLabel: "Toy")

    private func bits(_ v: [Double]) -> [UInt64] { v.map(\.bitPattern) }

    // MARK: the values drawn are the values received

    func testScatterPointsAreTheColumnValuesBitForBit() {
        let s = PlotBuilder.build(PlotRequest(x: ["G1"], y: ["G2"]), columns: columns, keep: keep, context: context)
        XCTAssertEqual(s.kind, .scatter); XCTAssertEqual(s.panels.count, 1)
        let p = s.panels[0].points
        // kept, and both values present: samples 2 (no G1), 3 (no G2) and 9 (not kept) are out
        let rows = [0, 1, 4, 5, 6, 7, 8]
        XCTAssertEqual(p.map(\.sample), rows)
        XCTAssertEqual(bits(p.map(\.x)), bits(rows.map { g1[$0] }))
        XCTAssertEqual(bits(p.map(\.y)), bits(rows.map { g2[$0] }))
        XCTAssertEqual(s.n, 7); XCTAssertEqual(s.panels[0].n, 7)
        XCTAssertTrue(p.allSatisfy { $0.size == 1 && $0.color == Palette.single })
        XCTAssertTrue(s.legend.isEmpty); XCTAssertEqual(s.warnings, [])
        // the axes contain every point and are titled with the variables
        let xa = s.panels[0].xAxis, ya = s.panels[0].yAxis
        XCTAssertEqual(xa.kind, .numeric); XCTAssertEqual(xa.title, "G1"); XCTAssertEqual(ya.title, "G2")
        XCTAssertTrue(p.allSatisfy { $0.x >= xa.lo && $0.x <= xa.hi && $0.y >= ya.lo && $0.y <= ya.hi })
        XCTAssertEqual(xa.ticks.count, xa.labels.count)
    }

    func testScatterStatisticsAreThoseOfTheDrawnSamples() {
        let s = PlotBuilder.build(PlotRequest(x: ["G1"], y: ["G2"]), columns: columns, keep: keep, context: context)
        let rows = [0, 1, 4, 5, 6, 7, 8]
        let xs = rows.map { g1[$0] }, ys = rows.map { g2[$0] }
        let pearson = Stats.pearson(x: xs, y: ys)!, spearman = Stats.spearman(x: xs, y: ys)!, fit = Stats.regression(x: xs, y: ys)!
        func value(_ label: String) -> String? { s.stats.first { $0.label == label }?.value }
        XCTAssertEqual(value("Data points"), "7")
        XCTAssertEqual(value("Pearson r"), PlotFormat.number(pearson.r))
        XCTAssertEqual(value("p (Pearson)"), PlotFormat.pValue(pearson.p))
        XCTAssertEqual(value("Spearman rho"), PlotFormat.number(spearman.r))
        XCTAssertEqual(pearson.n, 7)
        // the fit line spans the drawn x range and lies on the regression
        let line = s.panels[0].lines[0]
        XCTAssertEqual(line.xs, [1.5, 9.75])
        XCTAssertEqual(line.ys[0], fit.intercept + fit.slope * 1.5, accuracy: 1e-12)
        XCTAssertEqual(line.ys[1], fit.intercept + fit.slope * 9.75, accuracy: 1e-12)
        var noFit = PlotRequest(x: ["G1"], y: ["G2"]); noFit.fitLine = false
        XCTAssertTrue(PlotBuilder.build(noFit, columns: columns, keep: keep).panels[0].lines.isEmpty)
    }

    /// The website's "only results with complete information": a sample also needs the
    /// dataset's sample type (and cohort) when the dataset has such a column.
    func testCompleteOnlyAlsoAsksForSampleType() {
        var r = PlotRequest(x: ["G1"], y: ["G2"])
        XCTAssertEqual(PlotBuilder.build(r, columns: columnsWithSampleType, keep: keep).panels[0].points.map(\.sample), [0, 1, 4, 5, 6, 8])
        r.completeOnly = false
        XCTAssertEqual(PlotBuilder.build(r, columns: columnsWithSampleType, keep: keep).panels[0].points.map(\.sample), [0, 1, 4, 5, 6, 7, 8])
    }

    // MARK: boxes

    func testBoxPlotIsSplitByACategoricalColour() {
        // colour by a two-level variable: every tissue gets one box per colour group, side by
        // side, each box over exactly the samples of that tissue AND that group (ggplot's dodge)
        var c = columns
        let grp = [0, 1, 0, 1, 0, 1, 1, 0, 0, 1]       // "a" / "b"
        c["grp"] = Column(name: "grp", type: "clinical", data: .categorical(levels: ["a", "b"], codes: grp))
        let s = PlotBuilder.build(PlotRequest(x: ["tissue"], y: ["G2"], color: "grp"), columns: c, keep: keep, context: context)
        let panel = s.panels[0]
        // lung: samples 0, 1, 6 -> a: {0}, b: {1, 6}; skin: 2, 7 -> a: {2, 7}; colon: 4, 5 -> a: {4}, b: {5}
        XCTAssertEqual(panel.boxes.count, 5)
        let lungA = panel.boxes.first { abs($0.position - (0.5 - 0.2)) < 1e-9 }
        let lungB = panel.boxes.first { abs($0.position - (0.5 + 0.2)) < 1e-9 }
        XCTAssertEqual(lungA?.stats, Stats.box([2]))
        XCTAssertEqual(lungB?.stats, Stats.box([1, 6]))
        XCTAssertEqual(panel.boxes.first { abs($0.position - (1.5 - 0.2)) < 1e-9 }?.stats, Stats.box([4, 10]))
        XCTAssertNil(panel.boxes.first { abs($0.position - (1.5 + 0.2)) < 1e-9 })      // no "b" in skin: no empty box
        XCTAssertNotEqual(lungA?.color, lungB?.color)                                      // the legend's colours
        XCTAssertEqual(s.legend.entries.map(\.label), ["a", "b"])
        for pt in panel.points {                                                            // points sit over their own box
            let centre = Double(tissueCodes[pt.sample]) + 0.5 + (grp[pt.sample] == 0 ? -0.2 : 0.2)
            XCTAssertLessThanOrEqual(abs(pt.x - centre), 0.4 * 0.3 + 1e-9)
        }
        // without a colour the boxes are as before
        XCTAssertEqual(PlotBuilder.build(PlotRequest(x: ["tissue"], y: ["G2"]), columns: c, keep: keep, context: context).panels[0].boxes.count, 3)
    }

    func testBoxPlotKeepsValuesAndDropsEmptyLevels() {
        let s = PlotBuilder.build(PlotRequest(x: ["tissue"], y: ["G2"]), columns: columns, keep: keep, context: context)
        XCTAssertEqual(s.kind, .box)
        let panel = s.panels[0]
        XCTAssertEqual(panel.xAxis.kind, .categorical)
        XCTAssertEqual(panel.xAxis.labels, ["lung", "skin", "colon"])                // "liver" has no sample
        XCTAssertEqual(panel.xAxis.lo, 0); XCTAssertEqual(panel.xAxis.hi, 3); XCTAssertEqual(panel.xAxis.ticks, [0.5, 1.5, 2.5])
        // kept, tissue and G2 present: 3 (no G2), 8 (no tissue), 9 (not kept) are out
        let rows = [0, 1, 2, 4, 5, 6, 7]
        XCTAssertEqual(panel.points.map(\.sample), rows)
        XCTAssertEqual(bits(panel.points.map(\.y)), bits(rows.map { g2[$0] }))        // the value axis is exact
        for pt in panel.points {                                                    // jittered around its level's centre
            let centre = Double(tissueCodes[pt.sample]) + 0.5
            XCTAssertLessThanOrEqual(abs(pt.x - centre), 0.2 + 1e-9)      // (rounding: 2.5 + 0.2 - 2.5 is not exactly 0.2)
        }
        XCTAssertEqual(panel.boxes.count, 3)
        XCTAssertEqual(panel.boxes.map(\.position), [0.5, 1.5, 2.5])
        XCTAssertEqual(panel.boxes[0].stats, Stats.box([2, 1, 6]))                   // lung: samples 0, 1, 6
        XCTAssertEqual(panel.boxes[1].stats, Stats.box([4, 10]))                     // skin: 2, 7
        XCTAssertEqual(panel.boxes[2].stats, Stats.box([7, 5]))                      // colon: 4, 5
        XCTAssertFalse(panel.boxes[0].horizontal)
        XCTAssertEqual(s.stats.first { $0.label == "Groups" }?.value, "3")
        let kw = Stats.kruskalWallis(rows.map { g2[$0] }, group: rows.map { tissueCodes[$0] })!
        XCTAssertEqual(s.stats.first { $0.label == "Kruskal-Wallis p" }?.value, PlotFormat.pValue(kw.p))
        // drawing it twice puts every point in the same place
        XCTAssertEqual(PlotBuilder.build(PlotRequest(x: ["tissue"], y: ["G2"]), columns: columns, keep: keep, context: context), s)
    }

    func testNumericXAgainstCategoricalYLaysTheBoxesFlat() {
        let s = PlotBuilder.build(PlotRequest(x: ["G2"], y: ["tissue"]), columns: columns, keep: keep)
        XCTAssertEqual(s.kind, .box)
        let panel = s.panels[0]
        XCTAssertEqual(panel.xAxis.kind, .numeric); XCTAssertEqual(panel.yAxis.kind, .categorical)
        XCTAssertEqual(panel.yAxis.labels, ["lung", "skin", "colon"])
        XCTAssertEqual(bits(panel.points.map(\.x)), bits([0, 1, 2, 4, 5, 6, 7].map { g2[$0] }))
        XCTAssertTrue(panel.boxes.allSatisfy(\.horizontal))
    }

    func testFlipTurnsThePlotAndKeepsTheNumbers() {
        var r = PlotRequest(x: ["G1"], y: ["G2"])
        let plain = PlotBuilder.build(r, columns: columns, keep: keep)
        r.flip = true
        let flipped = PlotBuilder.build(r, columns: columns, keep: keep)
        XCTAssertEqual(flipped.panels[0].xAxis.title, "G2"); XCTAssertEqual(flipped.panels[0].yAxis.title, "G1")
        XCTAssertEqual(bits(flipped.panels[0].points.map(\.x)), bits(plain.panels[0].points.map(\.y)))
        XCTAssertEqual(bits(flipped.panels[0].points.map(\.y)), bits(plain.panels[0].points.map(\.x)))
        XCTAssertEqual(flipped.panels[0].lines[0].xs, plain.panels[0].lines[0].ys)
        XCTAssertEqual(flipped.stats, plain.stats)                                   // the statistics do not change
        var b = PlotRequest(x: ["tissue"], y: ["G2"]); b.flip = true
        let fb = PlotBuilder.build(b, columns: columns, keep: keep)
        XCTAssertEqual(fb.panels[0].yAxis.kind, .categorical); XCTAssertTrue(fb.panels[0].boxes.allSatisfy(\.horizontal))
    }

    func testWaterfallOrdersLevelsByTheMedian() {
        // medians of G2: lung 2 (1, 2, 6), skin 7 (4, 10), colon 6 (5, 7)
        var r = PlotRequest(x: ["tissue"], y: ["G2"]); r.waterfall = true
        XCTAssertEqual(PlotBuilder.build(r, columns: columns, keep: keep).panels[0].xAxis.labels, ["lung", "colon", "skin"])
        r.waterfallDescending = true
        let s = PlotBuilder.build(r, columns: columns, keep: keep)
        XCTAssertEqual(s.panels[0].xAxis.labels, ["skin", "colon", "lung"])
        XCTAssertEqual(s.panels[0].boxes[0].stats, Stats.box([4, 10]))               // the boxes moved with their labels
        let lungPoint = s.panels[0].points.first { $0.sample == 0 }!
        XCTAssertLessThanOrEqual(abs(lungPoint.x - 2.5), 0.2 + 1e-9)
    }

    // MARK: colour and size

    func testColourLegendListsOnlyLevelsThatAreDrawn() {
        let s = PlotBuilder.build(PlotRequest(x: ["G1"], y: ["G2"], color: "tissue"), columns: columns, keep: keep)
        // drawn: 0, 1, 4, 5, 6, 7 (sample 8 has no tissue, so with complete samples only it is not drawn)
        XCTAssertEqual(s.panels[0].points.map(\.sample), [0, 1, 4, 5, 6, 7])
        XCTAssertEqual(s.legend.title, "tissue")
        XCTAssertEqual(s.legend.entries.map(\.label), ["lung", "skin", "colon"])
        XCTAssertEqual(s.legend.entries.map(\.color), Palette.discrete(count: 3))
        let byLevel = Dictionary(uniqueKeysWithValues: s.legend.entries.map { ($0.label, $0.color) })
        for pt in s.panels[0].points { XCTAssertEqual(pt.color, byLevel[["lung", "skin", "colon"][tissueCodes[pt.sample]]]) }
        // a colour variable with one value says nothing: it is not used (and no longer limits the samples' colours)
        let one = PlotBuilder.build(PlotRequest(x: ["G1"], y: ["G2"], color: "grade"), columns: columns, keep: keep)
        XCTAssertTrue(one.legend.isEmpty); XCTAssertTrue(one.panels[0].points.allSatisfy { $0.color == Palette.single })
        XCTAssertFalse(one.subtitle.contains("Color"))
    }

    func testNumericColourAndSize() {
        let s = PlotBuilder.build(PlotRequest(x: ["tissue"], y: ["G2"], color: "G1", size: "G1"), columns: columns, keep: keep)
        // tissue, G2 and G1 present, kept: 0, 1, 4, 5, 6, 7
        XCTAssertEqual(s.panels[0].points.map(\.sample), [0, 1, 4, 5, 6, 7])
        XCTAssertEqual(s.legend.range, 1.5...8); XCTAssertTrue(s.legend.entries.isEmpty)
        XCTAssertEqual(s.legend.sizeTitle, "G1"); XCTAssertEqual(s.legend.sizeRange, 1.5...8)
        let lowest = s.panels[0].points.first { $0.sample == 0 }!, highest = s.panels[0].points.first { $0.sample == 7 }!
        XCTAssertEqual(lowest.color, Palette.continuous(0)); XCTAssertEqual(highest.color, Palette.continuous(1))
        XCTAssertEqual(lowest.size, 0.5, accuracy: 1e-12); XCTAssertEqual(highest.size, 3.5, accuracy: 1e-12)
        // size needs numbers
        let bad = PlotBuilder.build(PlotRequest(x: ["G1"], y: ["G2"], size: "tissue"), columns: columns, keep: keep)
        XCTAssertNil(bad.legend.sizeRange); XCTAssertEqual(bad.warnings.count, 1); XCTAssertTrue(bad.warnings[0].contains("Size"))
        XCTAssertEqual(bad.panels[0].points.map(\.sample), [0, 1, 4, 5, 6, 7, 8])    // and does not limit the samples
    }

    // MARK: transformations the user asks for

    func testZScoreAndCombinedProbes() {
        // The website scales the data frame gitr() returned, which holds only the samples in
        // use (cohort, exclusions, Filter tab): mean and sd are those of the KEPT samples.
        // Sample 9 is not kept and has the largest values, so the two readings differ.
        func kept(_ v: [Double]) -> [Double] { v.indices.map { keep[$0] ? v[$0] : .nan } }
        var r = PlotRequest(x: ["tissue"], y: ["G2"]); r.zscoreY = true
        let z = Stats.zscore(kept(g2))
        let s = PlotBuilder.build(r, columns: columns, keep: keep)
        XCTAssertEqual(bits(s.panels[0].points.map(\.y)), bits([0, 1, 2, 4, 5, 6, 7].map { z[$0] }))
        XCTAssertNotEqual(z[0], Stats.zscore(g2)[0])                                 // not the whole column's z-score
        XCTAssertEqual(Stats.mean([0, 1, 2, 4, 5, 6, 7, 8].map { z[$0] }), 0, accuracy: 1e-12)   // centred on the kept samples
        // with every sample in use, it is the whole column's
        let allKept = PlotBuilder.build(r, columns: columns, keep: Mask(repeating: true, count: 10))
        XCTAssertEqual(bits(allKept.panels[0].points.map(\.y)), bits([0, 1, 2, 4, 5, 6, 7, 9].map { Stats.zscore(g2)[$0] }))
        // two probes on one axis: the median of their z-scores, named after both
        let c = PlotBuilder.build(PlotRequest(x: ["tissue"], y: ["G1", "G2"]), columns: columns, keep: keep, context: context)
        let combined = Stats.combineMedianZ([kept(g1), kept(g2)])
        XCTAssertEqual(c.panels[0].yAxis.title, "G1.G2")
        XCTAssertEqual(c.title, "Relationship of tissue and G1.G2 across Toy")
        // a sample with one of the two probes still has a value (the median ignores the missing one)
        XCTAssertEqual(c.panels[0].points.map(\.sample), [0, 1, 2, 3, 4, 5, 6, 7])
        XCTAssertEqual(bits(c.panels[0].points.map(\.y)), bits([0, 1, 2, 3, 4, 5, 6, 7].map { combined[$0] }))
        // a categorical variable cannot be part of a combination: it is left out, with a note
        let w = PlotBuilder.build(PlotRequest(x: ["tissue"], y: ["G2", "grade"]), columns: columns, keep: keep)
        XCTAssertEqual(w.panels[0].yAxis.title, "G2"); XCTAssertEqual(w.warnings.count, 1); XCTAssertTrue(w.warnings[0].contains("grade"))
        XCTAssertEqual(bits(w.panels[0].points.map(\.y)), bits([0, 1, 2, 4, 5, 6, 7].map { g2[$0] }))
    }

    func testRemoveInfluencesOf() {
        var r = PlotRequest(x: ["tissue"], y: ["G2"], condition: ["G1"], conditionOn: .y)
        // The website fits AFTER choosing the samples: of those that would be drawn
        // (0, 1, 2, 4, 5, 6, 7) the ones that also have the covariate. Sample 2 has no G1;
        // samples 8 (no tissue) and 9 (not kept) have G1 and G2 but take no part in the fit.
        let fitRows: Set<Int> = [0, 1, 4, 5, 6, 7]
        func fitted(_ v: [Double]) -> [Double] { v.indices.map { fitRows.contains($0) ? v[$0] : .nan } }
        let resid = Stats.residuals(fitted(g2), on: [fitted(g1)])
        let s = PlotBuilder.build(r, columns: columns, keep: keep)
        XCTAssertEqual(s.panels[0].points.map(\.sample), [0, 1, 4, 5, 6, 7])
        XCTAssertEqual(bits(s.panels[0].points.map(\.y)), bits([0, 1, 4, 5, 6, 7].map { resid[$0] }))
        XCTAssertNotEqual(resid[0], Stats.residuals(g2, on: [g1])[0])                // not a fit over every sample
        XCTAssertTrue(s.subtitle.hasSuffix("Conditioning: G1 on y."), s.subtitle)
        XCTAssertEqual(Stats.mean([0, 1, 4, 5, 6, 7].map { resid[$0] }), 0, accuracy: 1e-12)     // residuals of the drawn samples sum to 0
        // removing from X when X is categorical: said, and nothing changes
        var onX = r; onX.conditionOn = .x
        let wx = PlotBuilder.build(onX, columns: columns, keep: keep)
        XCTAssertEqual(wx.warnings.count, 1); XCTAssertTrue(wx.warnings[0].contains("tissue"))
        XCTAssertEqual(bits(wx.panels[0].points.map(\.y)), bits([0, 1, 2, 4, 5, 6, 7].map { g2[$0] }))
        // both axes numeric, removed from both: each is a residual over the same samples
        let both = PlotBuilder.build(PlotRequest(x: ["G1"], y: ["G2"], condition: ["G1"], conditionOn: .y), columns: columns, keep: keep)
        XCTAssertEqual(both.panels[0].points.map(\.sample), [0, 1, 4, 5, 6, 7, 8])
        XCTAssertEqual(bits(both.panels[0].points.map(\.x)), bits([0, 1, 4, 5, 6, 7, 8].map { g1[$0] }))   // X is not conditioned: its own values
        r.conditionOn = .none
        XCTAssertEqual(bits(PlotBuilder.build(r, columns: columns, keep: keep).panels[0].points.map(\.y)), bits([0, 1, 2, 4, 5, 6, 7].map { g2[$0] }))
        r.conditionOn = .y; r.condition = ["tissue"]                                 // not numeric: nothing removed, and said so
        let w = PlotBuilder.build(r, columns: columns, keep: keep)
        XCTAssertEqual(w.warnings.count, 1); XCTAssertEqual(bits(w.panels[0].points.map(\.y)), bits([0, 1, 2, 4, 5, 6, 7].map { g2[$0] }))
    }

    // MARK: nothing to draw, and the words around a plot

    func testEmptyStatesSayWhy() {
        XCTAssertEqual(PlotBuilder.build(PlotRequest(), columns: columns, keep: keep).message, "Choose X and Y on the Select tab.")
        XCTAssertEqual(PlotBuilder.build(PlotRequest(x: ["G1"]), columns: columns, keep: keep).message, "Choose a Y variable.")
        XCTAssertEqual(PlotBuilder.build(PlotRequest(y: ["G1"]), columns: columns, keep: keep).message, "Choose an X variable.")
        let notLoaded = PlotBuilder.build(PlotRequest(x: ["G1"], y: ["NOPE"]), columns: columns, keep: keep)
        XCTAssertEqual(notLoaded.kind, .empty); XCTAssertTrue(notLoaded.message.contains("NOPE"))
        let none = PlotBuilder.build(PlotRequest(x: ["G1"], y: ["G2"]), columns: columns, keep: Mask(repeating: false, count: 10))
        XCTAssertEqual(none.kind, .empty); XCTAssertEqual(none.message, "No samples pass the filters.")
        XCTAssertEqual(none.summary, ["Total samples after filters: 0"]); XCTAssertTrue(none.panels.isEmpty)
        // samples pass, but none has both values: only samples 2 (no G1) and 3 (no G2)
        var only: Mask = Mask(repeating: false, count: 10); only[2] = true; only[3] = true
        let noData = PlotBuilder.build(PlotRequest(x: ["G1"], y: ["G2"]), columns: columns, keep: only)
        XCTAssertEqual(noData.kind, .empty); XCTAssertTrue(noData.message.hasPrefix("No samples have data"))
        XCTAssertEqual(noData.summary.first, "Total samples after filters: 2")
        // a mask of the wrong length is refused, not indexed
        XCTAssertEqual(PlotBuilder.build(PlotRequest(x: ["G1"], y: ["G2"]), columns: columns, keep: [true, true]).kind, .empty)
    }

    func testTitleSubtitleAndSampleCounts() {
        let s = PlotBuilder.build(PlotRequest(x: ["G1"], y: ["G2"], color: "tissue"), columns: columns, keep: keep, context: context)
        XCTAssertEqual(s.title, "Relationship of G1 and G2 across Toy")
        XCTAssertEqual(s.subtitle, "Color: tissue Data points: 6. Toy.")
        XCTAssertEqual(s.summary, [
            "Total samples after filters: 9",
            "Samples with data per variable:",
            "  G1: 8 / 9 (88.9%)",
            "  G2: 8 / 9 (88.9%)",
            "  tissue: 8 / 9 (88.9%)",
            "Samples with data for both X and Y: 7 / 9",
            "Samples missing X and/or Y: 2",
            "Samples with all graph variables: 6 / 9"])
        XCTAssertEqual(PlotBuilder.title(x: "TP53.mut", y: "CDKN2A.cnv", dataset: "TCGA"), "Relationship of TP53 mutation and CDKN2A CNA across TCGA")
        XCTAssertEqual(PlotBuilder.title(x: "KRAS.fmut", y: "CD8A", dataset: ""), "Relationship of KRAS mutation and CD8A")
    }

    func testJitterIsBoundedSpreadAndRepeatable() {
        let j = (0..<2000).map(PlotBuilder.jitter)
        XCTAssertTrue(j.allSatisfy { $0 >= -1 && $0 <= 1 })
        XCTAssertEqual(j, (0..<2000).map(PlotBuilder.jitter))
        XCTAssertEqual(j.reduce(0, +) / 2000, 0, accuracy: 0.05)                     // centred
        XCTAssertGreaterThan(j.filter { $0 > 0.5 }.count, 400); XCTAssertGreaterThan(j.filter { $0 < -0.5 }.count, 400)   // spread to both sides
    }
}
