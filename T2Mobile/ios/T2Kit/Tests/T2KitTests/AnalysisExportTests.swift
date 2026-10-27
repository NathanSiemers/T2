import XCTest
@testable import T2Kit

// The caption / stats .txt grammar of ANALYSIS-SPEC.md section 9a. The literals are the spec's
// (generated with R 4.5.3).

final class AnalysisExportTests: XCTestCase {
    private let xa: [Double] = [3, 1, 4, 1, 5, 5, 2, 6, 5, 3, 5, 8, 9, 7, 9, 3, 2, 3, 8, 4]
    private func two(_ a: Int, _ b: Int) -> GroupAssignment {
        GroupAssignment(group: [Int](repeating: 0, count: a) + [Int](repeating: 1, count: b), labels: ["Selected", "Excluded"], nUniverse: a + b)
    }
    private func cap(_ r: GroupTestResult, kind: GroupVariableKind, grouping: String = "Split: cohort", universe: Int, notes: [String] = [], maintained: [String] = []) -> [String] {
        AnalysisExport.caption(grouping: grouping, kind: kind, result: r, nUniverse: universe, maintained: maintained, dataset: "TCGA", notes: notes)
            .components(separatedBy: "\n")
    }

    /// the spec 9a numeric pins on the GroupCompareTests xa fixture (9 Selected / 11 Excluded), verified against R 4.5.3
    func testNumericComputedOnXaFixture() {
        var r = groupTest(values: .numeric(xa), kind: .numeric, assignment: two(9, 11), means: false, tte: nil, maxDays: .infinity)
        var lines = cap(r, kind: .numeric, universe: 20, maintained: ["age from 40 to 60", "sex is F"])
        XCTAssertEqual(lines[0], "Groups (Split: cohort): Selected n=9, Excluded n=11; universe n=20.")
        XCTAssertEqual(lines[1], "Wilcoxon rank-sum: W = 30, p = 0.145.")
        XCTAssertEqual(lines[2], "Maintained filters: age from 40 to 60; sex is F.")
        XCTAssertEqual(lines[3], "Data: TCGA.")
        r = groupTest(values: .numeric(xa), kind: .numeric, assignment: two(9, 11), means: true, tte: nil, maxDays: .infinity)
        lines = cap(r, kind: .numeric, universe: 20)
        XCTAssertEqual(lines[1], "Welch t-test: t = -1.939, df = 17.6, p = 0.0687.")
        XCTAssertEqual(lines[2], "Maintained filters: none.")
    }

    func testCategoricalPearson() {
        var group: [Int] = [], codes: [Int] = []
        for (g, row) in [[12, 30, 18], [25, 9, 6]].enumerated() { for (l, c) in row.enumerated() { group += [Int](repeating: g, count: c); codes += [Int](repeating: l, count: c) } }
        let a = GroupAssignment(group: group, labels: ["Low", "High"], nUniverse: group.count)
        let r = groupTest(values: .categorical(levels: ["a", "b", "c"], codes: codes), kind: .categorical, assignment: a, means: false, tte: nil, maxDays: .infinity)
        let lines = cap(r, kind: .categorical, grouping: "Stage", universe: 100)
        XCTAssertEqual(lines[0], "Groups (Stage): Low n=60, High n=40; universe n=100.")
        XCTAssertEqual(lines[1], "Pearson chi-squared: chi-squared = 18.62, df = 2, p = 9.1e-05.")
    }

    func testLogRankGehan() {
        let time: [Double] = [6,6,6,6,7,9,10,10,11,13,16,17,19,20,22,23,25,32,32,34,35, 1,1,2,2,3,4,4,5,5,8,8,8,8,11,11,12,12,15,17,22,23]
        let event: [Double] = [1,1,1,0,1,0,1,0,0,1,1,0,0,0,1,1,0,0,0,0,0] + [Double](repeating: 1, count: 21)
        let a = GroupAssignment(group: [Int](repeating: 0, count: 21) + [Int](repeating: 1, count: 21), labels: ["treatment", "control"], nUniverse: 42)
        let r = groupTest(values: nil, kind: .survival, assignment: a, means: false, tte: (time, event), maxDays: .infinity)
        let lines = cap(r, kind: .survival, grouping: "Arm", universe: 42)
        XCTAssertEqual(lines[0], "Groups (Arm): treatment n=21, control n=21; universe n=42.")
        XCTAssertEqual(lines[1], "Log-rank: chi-squared = 16.79, df = 1, p = 4.2e-05.")
    }

    func testStatnameMapAndNotes() {
        func line(_ m: String, _ s: Double?, _ df: Double?) -> String {
            var r = GroupTestResult(); r.groups = [GroupSummaryRow(group: "A", n: 5), GroupSummaryRow(group: "B", n: 5)]
            r.test = [GroupTestRow(term: "group", method: m, statistic: s, df: df, p: 0.01234, pBH: nil, note: nil)]
            return cap(r, kind: .numeric, universe: 10)[1]
        }
        XCTAssertEqual(line("Kruskal-Wallis", 10.6369838, 2), "Kruskal-Wallis: chi-squared = 10.64, df = 2, p = 0.0123.")
        XCTAssertEqual(line("Welch ANOVA", 3.14159, 2), "Welch ANOVA: F = 3.142, df = 2, p = 0.0123.")
        XCTAssertEqual(line("Fisher exact", nil, nil), "Fisher exact: p = 0.0123.")
        var r = GroupTestResult(); r.groups = [GroupSummaryRow(group: "A", n: 5)]
        let lines = cap(r, kind: .numeric, universe: 5, notes: ["Selected includes 3 samples missing age."])
        XCTAssertEqual(lines, ["Groups (Split: cohort): A n=5; universe n=5.", "Selected includes 3 samples missing age.", "Maintained filters: none.", "Data: TCGA."])
    }

    func testTextStructure() {
        let r = groupTest(values: .numeric(xa), kind: .numeric, assignment: two(9, 11), means: false, tte: nil, maxDays: .infinity)
        let t = AnalysisExport.text(grouping: "Split: cohort", kind: .numeric, result: r, nUniverse: 20, maintained: [], dataset: "TCGA", notes: [], date: "2026-10-27")
        let lines = t.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "# T2 analysis: TCGA, 2026-10-27.")
        XCTAssertEqual(lines[1], "")
        XCTAssertEqual(Array(lines[2...5]), cap(r, kind: .numeric, universe: 20))
        XCTAssertEqual(lines[6], "")
        XCTAssertTrue(lines[7].hasPrefix("group     n   median  q1"), lines[7])
        XCTAssertTrue(lines[8].hasPrefix("Selected  9   "), lines[8])
        XCTAssertEqual(lines[10], "")
        XCTAssertTrue(lines[11].hasPrefix("term   method"), lines[11])
        XCTAssertTrue(lines[11].hasSuffix("note  p_text"), lines[11])
        XCTAssertTrue(lines[12].hasSuffix("0.145"), lines[12])
        XCTAssertTrue(lines[12].hasPrefix("group  Wilcoxon rank-sum  30"), lines[12])
    }
}
