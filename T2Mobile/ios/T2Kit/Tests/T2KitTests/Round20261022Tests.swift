import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import T2Kit

/// Review round of 2026-10-22: p-values in the far tail, KM median as R's survival gives it,
/// category limits, 0/1 survival markers, decoding checks, API errors, CSV safety.
final class Round20261022Tests: XCTestCase {
    // MARK: D1-3 chi-square tail

    func testChiSquareFarTailKeepsItsDigits() {
        XCTAssertEqual(Stats.chiSquareUpperTail(80, df: 2) / 4.248354255291589e-18, 1, accuracy: 1e-9)   // exp(-40)
        XCTAssertEqual(Stats.chiSquareUpperTail(200, df: 1) / 2.0885e-45, 1, accuracy: 2e-3)             // 2 * pnorm(-sqrt(200))
        // df = 2: p = exp(-x/2) exactly, over the whole range
        for x in stride(from: 0.5, through: 400, by: 7.3) {
            let exact = exp(-x / 2)
            XCTAssertEqual(Stats.chiSquareUpperTail(x, df: 2) / exact, 1, accuracy: 1e-9, "x = \(x)")
        }
        // the moderate cases are unchanged (pchisq(3.84, 1, lower = FALSE) = 0.05, pchisq(16.79, 1, lower = FALSE) = 4.1753e-05)
        XCTAssertEqual(Stats.chiSquareUpperTail(3.841458820694124, df: 1), 0.05, accuracy: 1e-12)
        XCTAssertEqual(Stats.chiSquareUpperTail(16.79, df: 1), 4.175275138919785e-05, accuracy: 1e-12)
        XCTAssertEqual(Stats.chiSquareUpperTail(5.991464547107979, df: 2), 0.05, accuracy: 1e-12)
        // lower and upper tails add up
        for (a, x) in [(0.5, 0.3), (1.0, 2.0), (3.0, 1.0), (2.5, 9.0)] {
            XCTAssertEqual(Stats.regularizedLowerGamma(a, x) + Stats.regularizedUpperGamma(a, x), 1, accuracy: 1e-13)
        }
        // far tail on the plot's text: no "< 1e-300"
        XCTAssertGreaterThan(Stats.chiSquareUpperTail(150, df: 3), 0)
    }

    // MARK: D1-15 KM median

    func testMedianIsTheMidpointWhenSurvivalIsExactlyHalf() {
        let time = (1...10).map(Double.init)
        let km = Stats.kaplanMeier(time: time, event: [Double](repeating: 1, count: 10))
        XCTAssertEqual(km.medianTime, 5.5)                         // survfit: median 5.5
        let band = Stats.kaplanMeierBand(time: time, event: [Double](repeating: 1, count: 10))
        XCTAssertEqual(band.medianTime, 5.5)
        // not exactly half: the first time below it
        let nine = Stats.kaplanMeier(time: Array(time.prefix(9)), event: [Double](repeating: 1, count: 9))
        XCTAssertEqual(nine.medianTime, 5)
        // never reaches one half
        XCTAssertNil(Stats.kaplanMeier(time: [1, 2, 3, 4], event: [1, 0, 0, 0]).medianTime)
        // minmin's tolerance
        XCTAssertEqual(Stats.minmin([1, 2, 3], [0.9, 0.5 + 1e-9, 0.2]), 2.5)
    }

    // MARK: D1-4 category limits

    func testTooManyCategoriesGiveTheEmptyScene() {
        let n = 301
        let cols: [String: Column] = [
            "id": Column(name: "id", type: "clinical", data: .categorical(levels: (0..<n).map { "P\($0)" }, codes: Array(0..<n))),
            "G": Column(name: "G", type: "rna", data: .numeric((0..<n).map(Double.init))),
            "H": Column(name: "H", type: "rna", data: .numeric((0..<n).map { Double($0 % 7) })),
        ]
        let keep = Mask(repeating: true, count: n)
        for request in [PlotRequest(x: ["id"], y: ["G"]), PlotRequest(x: ["G"], y: ["id"])] {
            let s = PlotBuilder.build(request, columns: cols, keep: keep)
            XCTAssertEqual(s.kind, .empty)
            XCTAssertTrue(s.message.hasPrefix("id has 301 categories; the limit is 300"), s.message)
        }
        var colored = PlotRequest(x: ["G"], y: ["H"]); colored.color = "id"
        let c = PlotBuilder.build(colored, columns: cols, keep: keep)
        XCTAssertEqual(c.kind, .empty)
        XCTAssertTrue(c.message.hasPrefix("id has 301 categories; the limit is 200"), c.message)
        // at the limit it still draws
        let m = 300
        let ok: [String: Column] = [
            "id": Column(name: "id", type: "clinical", data: .categorical(levels: (0..<m).map { "P\($0)" }, codes: Array(0..<m))),
            "G": Column(name: "G", type: "rna", data: .numeric((0..<m).map(Double.init))),
        ]
        XCTAssertEqual(PlotBuilder.build(PlotRequest(x: ["id"], y: ["G"]), columns: ok, keep: Mask(repeating: true, count: m)).kind, .box)
    }

    // MARK: D1-16 a 0/1 marker in a survival plot

    func testBinaryNumericMarkerMakesOneGroupPerValue() {
        let n = 40
        let time = (0..<n).map { Double($0 + 1) }
        let event = (0..<n).map { $0 % 5 == 4 ? 0.0 : 1.0 }
        let mut = (0..<n).map { Double($0 % 2) }
        let cols: [String: Column] = [
            "OS": Column(name: "OS", type: "clinical", data: .numeric(event)),
            "OS.time": Column(name: "OS.time", type: "clinical", data: .numeric(time)),
            "TP53": Column(name: "TP53", type: "mut", data: .numeric(mut)),
        ]
        let ctx = PlotBuilder.Context(datasetLabel: "T", tte: [TTEVariable(name: "OS", label: "Overall Survival", eventCol: "OS", timeCol: "OS.time")])
        var r = PlotRequest(x: ["OS"], y: ["TP53"]); r.kmGroups = 3; r.kmMaxDays = 0
        let s = PlotBuilder.build(r, columns: cols, keep: Mask(repeating: true, count: n), context: ctx)
        XCTAssertEqual(s.kind, .survival, s.message)
        XCTAssertEqual(s.panels[0].riskTable?.groups, ["= 0", "= 1"])
        XCTAssertEqual(s.panels[0].lines.count, 2)
        XCTAssertNotNil(s.stats.first { $0.label == "Log-rank p" })
        XCTAssertEqual(PlotBuilder.valueLabels([0, 1]), ["0", "1"])
        XCTAssertEqual(PlotBuilder.valueLabels([0.5, 1, 2.25]), ["0.50", "1.00", "2.25"])
        // a constant marker still has no groups
        var constant = cols; constant["TP53"] = Column(name: "TP53", type: "mut", data: .numeric([Double](repeating: 1, count: n)))
        XCTAssertEqual(PlotBuilder.build(r, columns: constant, keep: Mask(repeating: true, count: n), context: ctx).kind, .empty)
    }

    // MARK: D1-21 decoding checks

    func testColumnsWithCodesOutsideTheirLevelsDoNotDecode() throws {
        let good = #"{"name":"a","kind":"cat","levels":["x","y"],"codes":[0,1,-1]}"#
        XCTAssertEqual(try APIClient.decoder.decode(Column.self, from: Data(good.utf8)).codes, [0, 1, -1])
        for bad in [#"{"name":"a","kind":"cat","levels":["x","y"],"codes":[0,2]}"#,
                    #"{"name":"a","kind":"cat","levels":[],"codes":[0]}"#,
                    #"{"name":"a","kind":"cat","levels":["x"],"codes":[-2]}"#] {
            XCTAssertThrowsError(try APIClient.decoder.decode(Column.self, from: Data(bad.utf8)), bad) { e in
                XCTAssertTrue(e is DecodingError)
            }
        }
    }

    func testAColumnShorterThanTheSampleListDoesNotDecode() {
        let short = #"{"dataset":"d","n":3,"samples":["a","b","c"],"columns":[{"name":"v","kind":"num","values":[1,2]}]}"#
        XCTAssertThrowsError(try APIClient.decoder.decode(Clinical.self, from: Data(short.utf8)))
        let ok = #"{"dataset":"d","n":2,"samples":["a","b"],"columns":[{"name":"v","kind":"num","values":[1,null]}]}"#
        XCTAssertEqual(try APIClient.decoder.decode(Clinical.self, from: Data(ok.utf8)).columns.count, 1)
        let values = #"{"dataset":"d","version":"v1","n":3,"columns":[{"name":"v","kind":"num","values":[1,2]}],"missing":[],"fill_options":["na","zero"]}"#
        XCTAssertThrowsError(try APIClient.decoder.decode(Values.self, from: Data(values.utf8)))
        let fine = #"{"dataset":"d","version":"v1","n":2,"columns":[{"name":"v","kind":"num","values":[1,2]}],"missing":[],"fill_options":["na","zero"]}"#
        XCTAssertEqual(try APIClient.decoder.decode(Values.self, from: Data(fine.utf8)).fillOptions, ["na", "zero"])
    }

    // MARK: D1-13 errors

    func testApiErrorsReadWell() {
        let cases: [APIClient.APIError] = [.badURL, .http(500, "boom"), .http(503, ""), .transport(.notConnectedToInternet, "offline"),
                                           .transport(nil, "no HTTP response"), .versionChanged]
        let words = ["bad URL", "server answered 500: boom", "server answered 503", "offline", "no HTTP response", "the database on the server was updated"]
        for (e, w) in zip(cases, words) {
            XCTAssertEqual(e.localizedDescription, w)
            XCTAssertFalse(e.localizedDescription.contains("operation couldn"))
        }
        XCTAssertTrue(APIClient.APIError.transport(.notConnectedToInternet, "x").isOffline)
        XCTAssertTrue(APIClient.APIError.transport(.timedOut, "x").isOffline)
        XCTAssertTrue(APIClient.APIError.transport(.cannotFindHost, "x").isOffline)
        XCTAssertFalse(APIClient.APIError.transport(.badServerResponse, "x").isOffline)
        XCTAssertFalse(APIClient.APIError.http(500, "").isOffline)
    }

    func testUserAgentNamesTheApp() {
        XCTAssertTrue(APIClient.userAgent.hasPrefix("T2 iOS "), APIClient.userAgent)
        XCTAssertTrue(APIClient.userAgent.contains("("))
    }

    // MARK: D1-24 CSV

    func testSpreadsheetFormulasAreDefused() {
        XCTAssertEqual(TableExport.quoted("=1+1"), "'=1+1")
        XCTAssertEqual(TableExport.quoted("+cmd"), "'+cmd")
        XCTAssertEqual(TableExport.quoted("-2"), "'-2")
        XCTAssertEqual(TableExport.quoted("@SUM(A1)"), "'@SUM(A1)")
        XCTAssertEqual(TableExport.quoted("lung"), "lung")
        let tissue = Column(name: "t", type: "clinical", data: .categorical(levels: ["=HYPERLINK(\"x\")"], codes: [0]))
        let num = Column(name: "g", type: "rna", data: .numeric([-0.5]))
        let csv = TableExport.csv(samples: ["S1"], columns: [tissue, num], keep: [true])
        XCTAssertEqual(csv, "sample,t,g\nS1,\"'=HYPERLINK(\"\"x\"\")\",-0.5\n")        // numbers are not touched
    }
}
