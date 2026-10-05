import XCTest
@testable import T2Kit

final class PlotFormatTests: XCTestCase {
    private func assertTicks(_ got: [Double], _ want: [Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.count, want.count, "\(got) vs \(want)", file: file, line: line)
        for (a, b) in zip(got, want) { XCTAssertEqual(a, b, accuracy: 1e-9, file: file, line: line) }
    }

    func testTicksAreRoundAndInsideTheRange() {
        assertTicks(PlotFormat.ticks(0, 10), [0, 2, 4, 6, 8, 10])
        assertTicks(PlotFormat.ticks(-0.3, 12.7), [0, 2, 4, 6, 8, 10, 12])
        assertTicks(PlotFormat.ticks(0, 1), [0, 0.2, 0.4, 0.6, 0.8, 1.0])
        // 6.3 wide / 5 = 1.26 per tick -> a step of 1 (steps are 1, 2, 5 or 10 times a power of ten)
        assertTicks(PlotFormat.ticks(-3.2, 3.1), [-3, -2, -1, 0, 1, 2, 3])
        assertTicks(PlotFormat.ticks(-3.2, 5.1), [-2, 0, 2, 4])           // 8.3 / 5 = 1.66 -> a step of 2
        assertTicks(PlotFormat.ticks(0, 1825), [0, 500, 1000, 1500])
        assertTicks(PlotFormat.ticks(1e-5, 6e-5), [1e-5, 2e-5, 3e-5, 4e-5, 5e-5, 6e-5])
        // every tick lies inside the range it was asked for
        for (lo, hi) in [(-7.31, 15.2), (0.001, 0.0093), (-1e6, 3.3e6), (10.5, 11.5), (-0.52, 14.9)] {
            let t = PlotFormat.ticks(lo, hi)
            XCTAssertTrue(t.count >= 3 && t.count <= 12, "\(lo) ... \(hi): \(t)")
            XCTAssertTrue(t.allSatisfy { $0 >= lo - 1e-9 * (hi - lo) && $0 <= hi + 1e-9 * (hi - lo) }, "\(t)")
            XCTAssertEqual(t, t.sorted())
        }
        // a range with no extent, and a missing bound
        XCTAssertEqual(PlotFormat.ticks(5, 5), [5])
        XCTAssertEqual(PlotFormat.ticks(.nan, 1), [])
        XCTAssertEqual(PlotFormat.ticks(3, 1), [3])
    }

    func testTickLabelsAreShortAndExact() {
        XCTAssertEqual(PlotFormat.tickLabel(0), "0")
        XCTAssertEqual(PlotFormat.tickLabel(2), "2")
        XCTAssertEqual(PlotFormat.tickLabel(-2.5), "-2.5")
        XCTAssertEqual(PlotFormat.tickLabel(0.6000000000000001), "0.6")      // 3 x 0.2 in floating point
        XCTAssertEqual(PlotFormat.tickLabel(1500), "1500")
        XCTAssertEqual(PlotFormat.tickLabel(0.005), "0.005")
        XCTAssertEqual(PlotFormat.tickLabel(1e7), "1e+07")
        XCTAssertEqual(PlotFormat.tickLabel(2e-5), "2e-05")
        XCTAssertEqual(PlotFormat.ticks(0, 1).map(PlotFormat.tickLabel), ["0", "0.2", "0.4", "0.6", "0.8", "1"])
    }

    func testNumbersAndPValues() {
        XCTAssertEqual(PlotFormat.number(0.61234), "0.612")
        XCTAssertEqual(PlotFormat.number(12.345), "12.3")
        XCTAssertEqual(PlotFormat.number(-0.0456), "-0.0456")
        XCTAssertEqual(PlotFormat.number(0), "0")
        XCTAssertEqual(PlotFormat.number(.nan), "NA")
        XCTAssertEqual(PlotFormat.number(1.2e-8), "1.20e-08")
        // fmtp() in survival_prototype.R
        XCTAssertEqual(PlotFormat.pValue(0.0314159), "0.0314")
        XCTAssertEqual(PlotFormat.pValue(0.5), "0.5")
        XCTAssertEqual(PlotFormat.pValue(1.2e-6), "1.2e-06")
        XCTAssertEqual(PlotFormat.pValue(0), "< 1e-300")
        XCTAssertEqual(PlotFormat.pValue(.nan), "NA")
    }

    func testPaddedRangeAndAxisFraction() {
        let p = PlotFormat.padded(0, 10)
        XCTAssertEqual(p.lo, -0.4, accuracy: 1e-12); XCTAssertEqual(p.hi, 10.4, accuracy: 1e-12)
        let flat = PlotFormat.padded(3, 3)                  // one distinct value still gets a range
        XCTAssertLessThan(flat.lo, 3); XCTAssertGreaterThan(flat.hi, 3)
        let zero = PlotFormat.padded(0, 0)
        XCTAssertLessThan(zero.lo, 0); XCTAssertGreaterThan(zero.hi, 0)
        let axis = PlotAxis(kind: .numeric, lo: 2, hi: 6, ticks: [2, 4, 6], labels: ["2", "4", "6"], title: "x")
        XCTAssertEqual(axis.fraction(2), 0); XCTAssertEqual(axis.fraction(6), 1); XCTAssertEqual(axis.fraction(3), 0.25)
    }

    func testRequestListsItsVariablesOnce() {
        let r = PlotRequest(x: ["cohort"], y: ["CD8A", "FOXP3"], color: "cohort", size: "", facet: "gender", condition: ["CD8A", "TMB"])
        XCTAssertEqual(r.variables, ["cohort", "CD8A", "FOXP3", "gender", "TMB"])
        XCTAssertEqual(PlotRequest().variables, [])
        XCTAssertTrue(PlotRequest().completeOnly); XCTAssertEqual(PlotRequest().kmGroups, 3); XCTAssertEqual(PlotRequest().kmMaxDays, 1825)
    }
}
