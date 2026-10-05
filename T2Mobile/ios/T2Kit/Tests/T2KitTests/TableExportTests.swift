import XCTest
@testable import T2Kit

final class TableExportTests: XCTestCase {
    func testCsvHasTheSamplesInUseAndExactNumbers() {
        let samples = ["S1", "S2", "S,3", "S4"]
        let gene = Column(name: "CD8A", type: "rna", data: .numeric([8.01, .nan, 0, -0.0015]))
        let tissue = Column(name: "tissue, site", type: "clinical", data: .categorical(levels: ["lung", "say \"x\"", "NA"], codes: [0, 1, -1, 2]))
        let csv = TableExport.csv(samples: samples, columns: [gene, tissue], keep: [true, true, true, true])
        let expected = [
            "sample,CD8A,\"tissue, site\"",
            "S1,8.01,lung",
            "S2,NA,\"say \"\"x\"\"\"",
            "\"S,3\",0,NA",
            "S4,-0.0015,\"NA\"",
            ""].joined(separator: "\n")
        XCTAssertEqual(csv, expected)
        // only the samples in use
        XCTAssertEqual(TableExport.csv(samples: samples, columns: [gene], keep: [false, false, false, true]), "sample,CD8A\nS4,-0.0015\n")
        XCTAssertEqual(TableExport.csv(samples: samples, columns: [], keep: [false, false, false, false]), "sample\n")
    }

    func testNumbersReadBackAsTheSameValue() {
        for v in [0.1, 1.0 / 3.0, 12.345678901234567, 1e-7, 6.02214076e23, -2.5, 100, 13.287712379549449, 5e-324] {
            XCTAssertEqual(Double(TableExport.number(v)), v, TableExport.number(v))
        }
        XCTAssertEqual(TableExport.number(100), "100"); XCTAssertEqual(TableExport.number(-3), "-3")
        XCTAssertEqual(TableExport.number(.nan), "NA"); XCTAssertEqual(TableExport.number(.infinity), "Inf")
    }
}
