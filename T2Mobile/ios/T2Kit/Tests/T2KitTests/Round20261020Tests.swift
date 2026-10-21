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
}
