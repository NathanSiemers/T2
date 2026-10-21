import XCTest
@testable import T2Kit

/// The 2026-10-20 round: hidden datasets, the title's source word, the "Filtered: ..." caption,
/// the survival hint.
final class Round20261020Tests: XCTestCase {
    // MARK: item 1, hidden

    private func summary(_ extra: String, name: String = "cptac", title: String = "T") throws -> DatasetSummary {
        let json = """
        {"name":"\(name)","title":"\(title)","label":"L","n_samples":1,"n_probes":1,"version":"v",
         "roles":{"cohort_col":"cohort","subtype_col":"","sampletype_col":"","normal_label":[],"heme_values":[],"sampletype_levels":[]},
         "defaults":{}\(extra)}
        """
        return try APIClient.decoder.decode(DatasetSummary.self, from: Data(json.utf8))
    }

    func testHiddenFlagDecodesAndHides() throws {
        let absent = try summary("")                       // a service before the flag
        XCTAssertNil(absent.hidden); XCTAssertFalse(absent.isHidden)
        let no = try summary(#","hidden":false"#)
        XCTAssertEqual(no.hidden, false); XCTAssertFalse(no.isHidden)
        let yes = try summary(#","hidden":true"#)
        XCTAssertEqual(yes.hidden, true); XCTAssertTrue(yes.isHidden)
        // the older rule still hides the synthetic dataset when the service says nothing
        XCTAssertTrue(try summary("", name: "DEMO").isHidden)
        XCTAssertTrue(try summary("", title: "Synthetic (not real data)").isHidden)
    }

    // MARK: item 3, the title's data source

    func testSourceWordIsThePartWithTheProcessing() {
        XCTAssertEqual(PlotBuilder.sourceWord(dataset: "TCGA-TARGET-GTEx (Toil)", part: nil), "TCGA-TARGET-GTEx (Toil)")
        XCTAssertEqual(PlotBuilder.sourceWord(dataset: "TCGA-TARGET-GTEx (Toil)", part: "GTEx"), "GTEx (Toil)")
        XCTAssertEqual(PlotBuilder.sourceWord(dataset: "TCGA-TARGET-GTEx (Toil)", part: "GTEx (Toil)"), "GTEx (Toil)")
        XCTAssertEqual(PlotBuilder.sourceWord(dataset: "CPTAC Pan-Cancer", part: "Kidney"), "Kidney")
    }

    func testTitleNamesTheSelectedSource() {
        let columns = ["G1": Column(name: "G1", type: "rna", data: .numeric([1, 2, 3, 4])),
                       "G2": Column(name: "G2", type: "rna", data: .numeric([2, 1, 4, 3]))]
        let keep = Mask(repeating: true, count: 4)
        let word = PlotBuilder.sourceWord(dataset: "TCGA-TARGET-GTEx (Toil)", part: "GTEx")
        let s = PlotBuilder.build(PlotRequest(x: ["G1"], y: ["G2"]), columns: columns, keep: keep, context: PlotBuilder.Context(datasetLabel: word))
        XCTAssertEqual(s.title, "Relationship of G1 and G2 across GTEx (Toil)")
        XCTAssertFalse(s.title.contains("TCGA-TARGET"))
    }

    // MARK: item 5, the caption

    func testNothingFilteredNoCaption() {
        XCTAssertEqual(FilterNote().text, "")
        XCTAssertEqual(FilterNote(cohorts: nil, cohortTotal: 0, rules: [ColumnFilter(column: "age")]).text, "")   // an inactive rule
        let columns = ["G1": Column(name: "G1", type: "rna", data: .numeric([1, 2, 3, 4])),
                       "G2": Column(name: "G2", type: "rna", data: .numeric([2, 1, 4, 3]))]
        let s = PlotBuilder.build(PlotRequest(x: ["G1"], y: ["G2"]), columns: columns, keep: Mask(repeating: true, count: 4))
        XCTAssertEqual(s.caption, "")
    }

    func testCaptionDescribesEveryKindOfFilter() {
        let note = FilterNote(groups: ["Primary tumors only"], exclusions: ["Exclude cell lines", "Exclude tumors of heme origin"],
                              cohorts: ["LUAD", "BRCA"], cohortTotal: 33,
                              rules: [ColumnFilter(column: "age", value: .range(lo: 40, hi: 60)),
                                      ColumnFilter(column: "sex", value: .levels(["F"])),
                                      ColumnFilter(column: "grade", value: nil, includeMissing: false),
                                      ColumnFilter(column: "stage", value: .range(lo: 2, hi: .infinity)),
                                      ColumnFilter(column: "idle")])
        XCTAssertEqual(note.text, "Filtered: Primary tumors only; Exclude cell lines, Exclude tumors of heme origin; cohorts: BRCA, LUAD; age from 40 to 60; sex is F; grade has a value; stage at least 2.")
    }

    func testCaptionCohortsAllCountOrNames() {
        XCTAssertEqual(FilterNote(exclusions: ["Exclude cell lines"], cohorts: nil, cohortTotal: 33).text, "Filtered: Exclude cell lines; all cohorts.")
        XCTAssertEqual(FilterNote(cohorts: ["a", "b", "c", "d"], cohortTotal: 33).text, "Filtered: cohorts: 4 of 33.")
        XCTAssertEqual(FilterNote(cohorts: ["c", "a", "b"], cohortTotal: 33).text, "Filtered: cohorts: a, b, c.")
        XCTAssertEqual(FilterNote(cohorts: [], cohortTotal: 33).text, "Filtered: cohorts: 0 of 33.")
        XCTAssertEqual(FilterNote(rules: [ColumnFilter(column: "t", value: .levels(["a", "b", "c", "d"]))]).text, "Filtered: t is one of 4 values.")
    }

    func testSceneCarriesTheCaptionOnlyWhenThereIsAPlot() {
        let columns = ["G1": Column(name: "G1", type: "rna", data: .numeric([1, 2, 3, 4])),
                       "G2": Column(name: "G2", type: "rna", data: .numeric([2, 1, 4, 3]))]
        let ctx = PlotBuilder.Context(datasetLabel: "Toy", filters: FilterNote(groups: ["Tumors"]))
        let s = PlotBuilder.build(PlotRequest(x: ["G1"], y: ["G2"]), columns: columns, keep: Mask(repeating: true, count: 4), context: ctx)
        XCTAssertEqual(s.kind, .scatter); XCTAssertEqual(s.caption, "Filtered: Tumors.")
        let none = PlotBuilder.build(PlotRequest(x: ["G1"], y: ["G2"]), columns: columns, keep: Mask(repeating: false, count: 4), context: ctx)
        XCTAssertEqual(none.kind, .empty); XCTAssertEqual(none.caption, "")
    }

    // MARK: item 4, the hint

    func testSurvivalHintNamesComeFromTheData() throws {
        func meta(_ tte: String) throws -> DatasetMeta {
            let json = """
            {"name":"d","title":"T","label":"L","n_samples":1,"n_probes":1,"version":"v","dataset":"d",
             "roles":{"cohort_col":"cohort","subtype_col":"","sampletype_col":"","normal_label":[],"heme_values":[],"sampletype_levels":[]},
             "defaults":{},"presets":[],"clinical_columns":[],"survival_endpoints":[]\(tte)}
            """
            return try APIClient.decoder.decode(DatasetMeta.self, from: Data(json.utf8))
        }
        func tteJSON(_ names: [String]) -> String {
            ",\"tte_variables\":[" + names.map { "{\"name\":\"\($0)\",\"event_col\":\"e\",\"time_col\":\"t\"}" }.joined(separator: ",") + "]"
        }
        let four = try meta(tteJSON(["OS", "PFI", "DSS", "DFI"]))
        XCTAssertEqual(four.survivalHint, "Survival curves: choose OS, PFI, DSS or DFI as X to draw Kaplan-Meier curves by groups of Y.")
        XCTAssertEqual(four.survivalHintShort, "Survival: choose OS, PFI, DSS or DFI as X for Kaplan-Meier curves.")
        XCTAssertTrue(try meta(tteJSON(["OS", "PFI"])).survivalHint.contains("choose OS or PFI as X"))
        XCTAssertTrue(try meta(tteJSON(["OS"])).survivalHint.contains("choose OS as X"))
        XCTAssertEqual(try meta(tteJSON([])).survivalHint, "")
        XCTAssertEqual(try meta("").survivalHintShort, "")
    }

    // MARK: item 7, not-detected values

    func testValuesAnswersDecodeWithAndWithoutFill() throws {
        let old = #"{"dataset":"d","version":"v","n":2,"columns":[{"name":"A","kind":"num","type":"rna","values":[1,null]}],"missing":[]}"#
        let a = try APIClient.decoder.decode(Values.self, from: Data(old.utf8))
        XCTAssertNil(a.fillOptions); XCTAssertNil(a.fill)
        XCTAssertEqual(ValuesInfo.merge([a]), ValuesInfo())
        let new = #"{"dataset":"cptac","version":"v","n":2,"columns":[{"name":"P.prot","kind":"num","type":"prot","values":[0,3]}],"missing":[],"fill_options":["na","zero","floor"],"fill":"zero","filled":{"P.prot":1},"tested_n":{"P.prot":2}}"#
        let b = try APIClient.decoder.decode(Values.self, from: Data(new.utf8))
        XCTAssertEqual(b.fillOptions, ["na", "zero", "floor"]); XCTAssertEqual(b.fill, "zero")
        XCTAssertEqual(b.filled?.values.first, 1); XCTAssertEqual(b.testedN?.values.first, 2)
        let plain = try APIClient.decoder.decode(Values.self, from: Data(#"{"dataset":"tcga","n":1,"columns":[],"missing":[],"fill_options":["na"]}"#.utf8))
        // chunks: the union of the options, in the order na, zero, floor; a fill applied in any chunk counts
        let m = ValuesInfo.merge([plain, b])
        XCTAssertEqual(m.fillOptions, ["na", "zero", "floor"]); XCTAssertEqual(m.fill, "zero"); XCTAssertTrue(m.anyFilled)
        XCTAssertEqual(ValuesInfo.merge([plain]).fillOptions, ["na"])
    }

    func testFillCaptionText() {
        func scene(_ note: FillNote, vars: [String]) -> PlotScene {
            var cols: [String: Column] = [:]
            for v in vars { cols[v] = Column(name: v, type: "prot", data: .numeric([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])) }
            let keep: Mask = [true, true, true, true, true, true, true, true, false, false]    // 8 shown
            return PlotBuilder.build(PlotRequest(x: [vars[0]], y: [vars[1]]), columns: cols, keep: keep,
                                     context: PlotBuilder.Context(datasetLabel: "Toy", filters: FilterNote(groups: ["Tumors"]), fills: note))
        }
        func mask(_ idx: [Int]) -> [Bool] { (0..<10).map { idx.contains($0) } }
        // one probe: its own count among the 8 samples shown (sample 9 is filtered out)
        let one = FillNote(fill: "zero", probes: [.init(name: "A.prot", word: "protein", filledMask: mask([0, 1, 9]))])
        let s1 = scene(one, vars: ["A.prot", "G"])
        XCTAssertEqual(s1.caption, "Filtered: Tumors.\nNot-detected protein values set to 0 (2 of 8 samples shown)")
        XCTAssertTrue(s1.stats.contains(StatLine("Not detected, A.prot", "set to 0 in 2 of 8")))
        // a probe that is not plotted, or has no filled sample among those shown, is not named
        XCTAssertEqual(scene(FillNote(fill: "zero", probes: [.init(name: "Z", word: "protein", filledMask: mask([0]))]), vars: ["A.prot", "G"]).caption, "Filtered: Tumors.")
        // floor, two probes with two words, then three
        let two = FillNote(fill: "floor", probes: [.init(name: "A.prot", word: "protein", filledMask: mask([0, 1])),
                                                   .init(name: "B.phospho", word: "phosphosite", filledMask: mask([2]))])
        XCTAssertEqual(scene(two, vars: ["A.prot", "B.phospho"]).caption,
                       "Filtered: Tumors.\nNot-detected protein/phosphosite values set to the detection floor, per cohort: A.prot (2 of 8), B.phospho (1 of 8)")
        // none filtered and no fill: no caption at all
        let bare = PlotBuilder.build(PlotRequest(x: ["A"], y: ["B"]), columns: ["A": Column(name: "A", type: "rna", data: .numeric([1, 2])), "B": Column(name: "B", type: "rna", data: .numeric([2, 1]))],
                                     keep: [true, true], context: PlotBuilder.Context(fills: FillNote(fill: "zero", probes: [])))
        XCTAssertEqual(bare.caption, "")
        let (cap3, _) = FillNote(fill: "zero", probes: ["A", "B", "C"].map { .init(name: $0, word: "protein", filledMask: mask([0, 1])) })
            .describe(shown: Array(0..<8), plotted: ["A", "B", "C"])
        XCTAssertEqual(cap3, "6 not-detected values set to 0 (3 variables)")
    }

    // MARK: crash hardening

    func testUniquedKeepsFirstOccurrenceInOrder() {
        XCTAssertEqual(["b", "a", "b", "c", "a"].uniqued(), ["b", "a", "c"])
    }

    func testColumnIndexOutOfRangeIsMissing() {
        let short = Column(name: "s", type: "rna", data: .numeric([1, 2]))
        XCTAssertTrue(short.isMissing(5)); XCTAssertFalse(short.isMissing(1))
        let cat = Column(name: "c", type: "clinical", data: .categorical(levels: ["a"], codes: [0, 7]))
        XCTAssertTrue(cat.isMissing(9)); XCTAssertNil(cat.level(9)); XCTAssertNil(cat.level(1)); XCTAssertEqual(cat.level(0), "a")
        // a column of the wrong length is not loaded into the filter
        var f = CrossFilter(sampleCount: 3)
        f.load([short, Column(name: "ok", type: "rna", data: .numeric([1, 2, 3]))])
        XCTAssertNil(f.columns["s"]); XCTAssertNotNil(f.columns["ok"])
    }

    func testWaterfallPutsNaNMediansLast() {
        let med: [Int: Double] = [0: 3, 1: .nan, 2: 1, 3: 2]
        XCTAssertEqual(PlotBuilder.waterfallOrder([0, 1, 2, 3], medians: med, descending: false), [2, 3, 0, 1])
        XCTAssertEqual(PlotBuilder.waterfallOrder([0, 1, 2, 3], medians: med, descending: true), [0, 3, 2, 1])
    }

    func testStackedProbeWithAShortColumnDoesNotTrap() {
        var cols: [String: Column] = ["A": Column(name: "A", type: "rna", data: .numeric([1, 2, 3, 4])),
                                      "B": Column(name: "B", type: "rna", data: .numeric([4, 3, 2, 1])),
                                      "C": Column(name: "C", type: "rna", data: .numeric([1, 2]))]       // too short
        cols["X"] = Column(name: "X", type: "rna", data: .numeric([1, 2, 3, 5]))
        var req = PlotRequest(x: ["X"], y: ["A", "B", "C"]); req.yIndividually = true
        _ = PlotBuilder.build(req, columns: cols, keep: Mask(repeating: true, count: 4))
    }
}
