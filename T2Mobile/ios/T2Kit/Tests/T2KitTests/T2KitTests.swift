import XCTest
@testable import T2Kit

// Reference numbers in the statistics tests were computed with R 4.5 (quantile, lm, cor,
// survival::survfit / survdiff, pchisq) on the same inputs.

final class DecodingTests: XCTestCase {
    func testColumnsDecodeWithMissingValues() throws {
        let json = #"""
        {"dataset":"TCGA","n":4,"columns":[
          {"name":"CD8A","kind":"num","type":"rna","values":[8.01,null,0,-1.5e-3]},
          {"name":"TP53.mut","kind":"cat","type":"mut","levels":["0","1"],"codes":[-1,0,1,1]}],
         "missing":["nope"]}
        """#
        let v = try APIClient.decoder.decode(Values.self, from: Data(json.utf8))
        XCTAssertEqual(v.columns.count, 2)
        XCTAssertEqual(v.missing, ["nope"])
        let num = v.columns[0].numbers!
        XCTAssertEqual(num[0], 8.01); XCTAssertTrue(num[1].isNaN); XCTAssertEqual(num[2], 0); XCTAssertEqual(num[3], -0.0015)
        XCTAssertEqual(v.columns[0].missingCount, 1)
        XCTAssertEqual(v.columns[1].levels, ["0", "1"])
        XCTAssertEqual(v.columns[1].codes, [-1, 0, 1, 1])
        XCTAssertNil(v.columns[1].level(0)); XCTAssertEqual(v.columns[1].level(2), "1")
        XCTAssertTrue(v.columns[0].isNumeric); XCTAssertFalse(v.columns[1].isNumeric)
    }

    func testMetaDecodesPresetsAndRoles() throws {
        let json = #"""
        {"dataset":"tcgatargetgtex","title":"T","label":"L","version":"abc","n_samples":3,"n_probes":9,
         "roles":{"cohort_col":"disease","subtype_col":"study","sampletype_col":"sample_type",
                  "normal_label":["Normal Tissue"],"heme_values":[],"sampletype_levels":["Primary Tumor","Normal Tissue"]},
         "defaults":{"x":"cohort","y":"CD8A","color":"study","size":"","condition":""},
         "presets":[{"label":"GTEx normal tissues","description":"d","default":true,"source":"database",
                     "rules":[{"column":"study","op":"in","values":["GTEX"]},
                              {"column":"sample_type","op":"in","values":["Normal Tissue"]}]}],
         "clinical_columns":["study","sample_type"],"survival_endpoints":["OS"],
         "cohorts":[],"types":[],"datatypes":{"rna":"numeric"}}
        """#
        let m = try APIClient.decoder.decode(DatasetMeta.self, from: Data(json.utf8))
        XCTAssertEqual(m.nSamples, 3)
        XCTAssertEqual(m.roles.sampletypeCol, "sample_type")
        XCTAssertEqual(m.defaults["y"], "CD8A")
        XCTAssertEqual(m.presets.count, 1)
        XCTAssertTrue(m.presets[0].isDefault)
        XCTAssertEqual(m.presets[0].rules[1].values, ["Normal Tissue"])
    }

    /// meta as the live service sends it (2026-10-05): cohort names, and the same four
    /// survival endpoints for every dataset whether or not it has the columns
    func testMetaCohortNamesAndUsableSurvivalEndpoints() throws {
        func meta(clinical: String, cohorts: String) throws -> DatasetMeta {
            let json = """
            {"dataset":"D","title":"T","label":"L","version":"v","n_samples":3,"n_probes":9,
             "roles":{"cohort_col":"tumtype","subtype_col":"s","sampletype_col":"sample_type",
                      "normal_label":[],"heme_values":[],"sampletype_levels":[]},
             "defaults":{"x":"cohort","y":"CD8A"},"presets":[],
             "clinical_columns":\(clinical),"survival_endpoints":["OS","PFI","DSS","DFI"]\(cohorts)}
            """
            return try APIClient.decoder.decode(DatasetMeta.self, from: Data(json.utf8))
        }
        let tcga = try meta(clinical: #"["gender","OS","OS.time","PFI","PFI.time","DSS","DFI.time"]"#,
                            cohorts: #","cohorts":[{"cohort":"BRCA","cohortstring":"breast invasive carcinoma ( BRCA )","lcohort":"breast invasive carcinoma"},{"cohort":"XX","cohortstring":null}]"#)
        XCTAssertEqual(tcga.usableSurvivalEndpoints, ["OS", "PFI"])          // DSS has no time, DFI no event
        XCTAssertEqual(tcga.cohorts?.count, 2)
        XCTAssertEqual(tcga.cohortTitle("BRCA"), "breast invasive carcinoma ( BRCA )")
        XCTAssertEqual(tcga.cohortTitle("XX"), "XX")                         // a null name: the value itself
        XCTAssertEqual(tcga.cohortTitle("LUAD"), "LUAD")                     // not listed
        // tcgatargetgtex and DEMO list the endpoints but have no such columns
        let gtex = try meta(clinical: #"["study","disease","sample_type","gender"]"#, cohorts: "")
        XCTAssertEqual(gtex.usableSurvivalEndpoints, [])
        XCTAssertNil(gtex.cohorts)                                           // a service without the field
        XCTAssertEqual(gtex.cohortTitle("Whole Blood"), "Whole Blood")
    }

    func testUnknownColumnKindIsAnError() {
        let json = #"{"name":"x","kind":"blob","type":"t"}"#
        XCTAssertThrowsError(try APIClient.decoder.decode(Column.self, from: Data(json.utf8)))
    }
}

final class FilteringTests: XCTestCase {
    // 8 samples
    let study = Column(name: "study", type: "clinical",
                       data: .categorical(levels: ["GTEX", "TARGET", "TCGA"], codes: [0, 0, 2, 2, 2, 1, -1, 0]))
    let stype = Column(name: "sample_type", type: "clinical",
                       data: .categorical(levels: ["Cell Line", "Normal Tissue", "Primary Tumor", "Solid Tissue Normal"],
                                          codes: [1, 0, 2, 3, 2, 2, 2, 1]))
    let gene = Column(name: "G", type: "rna", data: .numeric([1, 2, 3, 4, 5, 6, .nan, 8]))

    func testPresetRulesAreAndedAndValuesAreAlternatives() {
        let cols = ["study": study, "sample_type": stype]
        let gtexNormal = Preset(label: "GTEx normal tissues", rules: [
            .init(column: "study", op: "in", values: ["GTEX"]),
            .init(column: "sample_type", op: "in", values: ["Normal Tissue"])])
        XCTAssertEqual(gtexNormal.mask(columns: cols, sampleCount: 8), [true, false, false, false, false, false, false, true])
        let tcgaTumor = Preset(label: "TCGA tumors", rules: [
            .init(column: "study", op: "in", values: ["TCGA"]),
            .init(column: "sample_type", op: "not in", values: ["Solid Tissue Normal", "Cell Line"])])
        XCTAssertEqual(tcgaTumor.mask(columns: cols, sampleCount: 8), [false, false, true, false, true, false, false, false])
        // "in" never matches a missing value; "not in" keeps it (as %in% does in gitr)
        let notGtex = Preset(label: "x", rules: [.init(column: "study", op: "not in", values: ["GTEX"])])
        XCTAssertEqual(notGtex.mask(columns: cols, sampleCount: 8)[6], true)
        let unknown = Preset(label: "y", rules: [.init(column: "no_such", op: "in", values: ["a"])])
        XCTAssertEqual(unknown.mask(columns: cols, sampleCount: 8), [Bool](repeating: true, count: 8))
    }

    func testRangeAndLevelFiltersWithMissingValues() {
        var f = ColumnFilter(column: "G", value: .range(lo: 2, hi: 5))
        XCTAssertEqual(f.mask(for: gene), [false, true, true, true, true, false, true, false])   // NaN kept by default
        f.includeMissing = false
        XCTAssertEqual(f.mask(for: gene), [false, true, true, true, true, false, false, false])
        let open = ColumnFilter(column: "G", value: .range(lo: -.infinity, hi: 3))
        XCTAssertEqual(open.mask(for: gene), [true, true, true, false, false, false, true, false])
        XCTAssertFalse(ColumnFilter(column: "G", value: .range(lo: -.infinity, hi: .infinity)).isActive)
        XCTAssertTrue(ColumnFilter(column: "G", includeMissing: false).isActive)
        let lv = ColumnFilter(column: "study", value: .levels(["TCGA", "TARGET"]), includeMissing: false)
        XCTAssertEqual(lv.mask(for: study), [false, false, true, true, true, true, false, false])
        XCTAssertEqual(ColumnFilter(column: "study", value: .levels([])).mask(for: study)[6], true)   // none ticked: only missing pass
    }

    func testCrossFilterLeaveOneOutMatchesBruteForce() {
        var cf = CrossFilter(sampleCount: 8)
        cf.load([study, stype, gene])
        cf.baseMask = [true, true, true, true, true, true, true, false]      // universe: drop the last sample
        cf.add("G"); cf.add("study"); cf.add("no_such"); cf.add("G")
        XCTAssertEqual(cf.filters.map(\.column), ["G", "study"])
        XCTAssertEqual(cf.selectedCount(), 7)                                // nothing restricted yet
        cf.set("G", value: .range(lo: 2, hi: 6))
        cf.set("study", value: .levels(["TCGA"]), includeMissing: false)
        let expectAll = (0..<8).map { i -> Bool in
            let g = gene.numbers![i]
            return cf.baseMask![i] && (g.isNaN || (g >= 2 && g <= 6)) && study.level(i) == "TCGA"
        }
        XCTAssertEqual(cf.mask(), expectAll)
        XCTAssertEqual(cf.mask(), [false, false, true, true, true, false, false, false])
        // leave-one-out for G: universe AND study only
        XCTAssertEqual(cf.mask(excluding: "G"), [false, false, true, true, true, false, false, false])
        XCTAssertEqual(cf.mask(excluding: "study"), [false, true, true, true, true, true, true, false])
        // histogram of study: counts of samples passing G's filter and the universe, split by its own
        let h = cf.histogram("study")!
        XCTAssertEqual(h.labels, ["GTEX", "TARGET", "TCGA"])
        XCTAssertEqual(h.shown, [1, 1, 3]); XCTAssertEqual(h.selected, [0, 0, 3])
        XCTAssertEqual(h.shownTotal, 6); XCTAssertEqual(h.selectedTotal, 3)   // the sample with no study is shown, not binned
        let hg = cf.histogram("G", bins: 7)!                                  // bins of width 1 from 1 to 8
        XCTAssertEqual(hg.shown.reduce(0, +), 3); XCTAssertEqual(hg.selected.reduce(0, +), 3)
        XCTAssertEqual(hg.edges.first, 1); XCTAssertEqual(hg.width, 1)
        cf.remove("G")
        XCTAssertEqual(cf.selectedCount(), 3); XCTAssertNil(cf.filter("G"))
        XCTAssertEqual(cf.universeCount(), 7)
    }
}

final class StatsTests: XCTestCase {
    func testQuantilesMatchR() {
        let x: [Double] = [1, 2, 3, 4, 10, .nan, 7.5]
        XCTAssertEqual(Stats.quantile(x, 0.25), 2.25, accuracy: 1e-12)
        XCTAssertEqual(Stats.median(x), 3.5, accuracy: 1e-12)
        XCTAssertEqual(Stats.quantile(x, 0.9), 8.75, accuracy: 1e-12)
        XCTAssertEqual(Stats.sd(x), 3.47011046894284, accuracy: 1e-12)
        XCTAssertTrue(Stats.median([.nan]).isNaN)
    }
    func testRegressionMatchesLm() {
        let x: [Double] = [1, 2, 3, 4, 5, 6, .nan, 8], y: [Double] = [2.1, 3.9, 6.2, 7.8, 10.1, 12.2, 5, .nan]
        let l = Stats.regression(x: x, y: y)!
        XCTAssertEqual(l.slope, 2.02, accuracy: 1e-12)
        XCTAssertEqual(l.intercept, -0.02, accuracy: 1e-10)
        XCTAssertEqual(l.r, 0.999104932480818, accuracy: 1e-12)
        XCTAssertEqual(l.n, 6)
        XCTAssertNil(Stats.regression(x: [1, 1, 1], y: [1, 2, 3]))
    }
    func testBoxAndGroupsAndCombinedMarker() {
        let b = Stats.box([1, 2, 3, 4, 5, 6, 7, 8, 9, 50])!
        XCTAssertEqual(b.q1, 3.25, accuracy: 1e-12); XCTAssertEqual(b.median, 5.5, accuracy: 1e-12); XCTAssertEqual(b.q3, 7.75, accuracy: 1e-12)
        XCTAssertEqual(b.lowerWhisker, 1); XCTAssertEqual(b.upperWhisker, 9)     // 50 is beyond 1.5 x IQR
        let m: [Double] = [5, 1, 9, 3, 7, 2, 8, 4, 6, .nan, 10, 11]
        XCTAssertEqual(Stats.quantileGroups(m, groups: 3), [1, 0, 2, 0, 1, 0, 2, 0, 1, -1, 2, 2])
        let z = Stats.combineMedianZ([[1, 2, 3, 4], [10, 30, 20, 40]])
        XCTAssertEqual(z[0], -1.16189500386223, accuracy: 1e-12); XCTAssertEqual(z[1], 0, accuracy: 1e-12)
        XCTAssertEqual(z[3], 1.16189500386223, accuracy: 1e-12)
    }
    // the 6-MP leukemia trial (Gehan 1965): treatment then control
    let time: [Double] = [6,6,6,6,7,9,10,10,11,13,16,17,19,20,22,23,25,32,32,34,35, 1,1,2,2,3,4,4,5,5,8,8,8,8,11,11,12,12,15,17,22,23]
    let event: [Double] = [1,1,1,0,1,0,1,0,0,1,1,0,0,0,1,1,0,0,0,0,0] + [Double](repeating: 1, count: 21)

    func testKaplanMeierMatchesSurvfit() {
        let km = Stats.kaplanMeier(time: Array(time[0..<21]), event: Array(event[0..<21]))
        XCTAssertEqual(km.times, [6, 7, 10, 13, 16, 22, 23])
        let ref = [0.857142857142857, 0.80672268907563, 0.752941176470588, 0.690196078431372, 0.627450980392157, 0.53781512605042, 0.448179271708683]
        for (a, b) in zip(km.survival, ref) { XCTAssertEqual(a, b, accuracy: 1e-12) }
        XCTAssertEqual(km.atRisk, [21, 17, 15, 12, 11, 7, 6])
        XCTAssertEqual(km.medianTime, 23); XCTAssertEqual(km.n, 21); XCTAssertEqual(km.events, 9)
        XCTAssertEqual(Stats.kaplanMeier(time: Array(time[21...]), event: Array(event[21...])).medianTime, 8)
    }
    func testLogRankMatchesSurvdiff() {
        let two = Stats.logRank(time: time, event: event, group: (0..<42).map { $0 < 21 ? 0 : 1 })!
        XCTAssertEqual(two.chiSquare, 16.7929409892165, accuracy: 1e-9); XCTAssertEqual(two.df, 1)
        XCTAssertEqual(two.p, 4.16880910933453e-05, accuracy: 1e-12)
        let three = Stats.logRank(time: time, event: event, group: (0..<42).map { $0 % 3 })!
        XCTAssertEqual(three.chiSquare, 0.716380589169184, accuracy: 1e-9); XCTAssertEqual(three.df, 2)
        XCTAssertEqual(three.p, 0.698940057842742, accuracy: 1e-10)
        XCTAssertNil(Stats.logRank(time: time, event: event, group: [Int](repeating: 0, count: 42)))
    }
    func testChiSquareTail() {
        XCTAssertEqual(Stats.chiSquareUpperTail(3.84, df: 1), 0.0500435212487052, accuracy: 1e-12)
        XCTAssertEqual(Stats.chiSquareUpperTail(10, df: 4), 0.0404276819945128, accuracy: 1e-12)
        XCTAssertEqual(Stats.chiSquareUpperTail(0.5, df: 3), 0.918891411654676, accuracy: 1e-12)
    }

    func testValuesCarryTheDatabaseVersion() throws {
        let with = #"{"dataset":"DEMO","version":"3a0006ac4","n":2,"columns":[],"missing":["x"]}"#
        let without = #"{"dataset":"DEMO","n":2,"columns":[],"missing":[]}"#
        XCTAssertEqual(try APIClient.decoder.decode(Values.self, from: Data(with.utf8)).version, "3a0006ac4")
        XCTAssertNil(try APIClient.decoder.decode(Values.self, from: Data(without.utf8)).version)
        XCTAssertEqual(APIClient.maxProbesPerRequest, 100)
        XCTAssertEqual("\(APIClient.APIError.versionChanged)", "the database on the server was updated")
    }

    func testLevelsPresentFollowTheUniverse() {
        var cf = CrossFilter(sampleCount: 6)
        cf.load([Column(name: "study", type: "clinical", data: .categorical(levels: ["GTEX", "TARGET", "TCGA"], codes: [0, 0, 1, 2, 2, -1]))])
        XCTAssertEqual(cf.levelsPresent("study"), [0, 1, 2])
        cf.baseMask = [true, true, false, false, false, true]        // the GTEx part
        XCTAssertEqual(cf.levelsPresent("study"), [0])
        XCTAssertEqual(cf.levelsPresent("nope"), [])
    }
}
