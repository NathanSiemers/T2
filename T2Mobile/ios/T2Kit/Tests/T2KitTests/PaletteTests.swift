import XCTest
@testable import T2Kit

// Reference colours: viridisLite 0.4.3 (plasma) and grDevices::colorRampPalette in R 4.5.3.
// The map is 33 interpolated anchors, so plasma colours are compared within 3/255 per
// channel (the measured maximum error against plasma(256) is 2.99).

final class PaletteTests: XCTestCase {
    private func assertClose(_ c: RGB, _ hex: UInt32, units: Int, file: StaticString = #filePath, line: UInt = #line) {
        let a = c.bytes, b = RGB(hex: hex).bytes
        let worst = max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
        XCTAssertLessThanOrEqual(worst, units, "\(c.hexString) vs \(RGB(hex: hex).hexString)", file: file, line: line)
    }

    func testRGBConversions() {
        let c = RGB(hex: 0x3B7DB4)
        XCTAssertEqual(c.bytes.r, 0x3B); XCTAssertEqual(c.bytes.g, 0x7D); XCTAssertEqual(c.bytes.b, 0xB4)
        XCTAssertEqual(c.hexString, "#3B7DB4")
        XCTAssertEqual(RGB(13, 8, 135).hexString, "#0D0887")
        XCTAssertEqual(RGB.black.mixed(with: .white, 0.5).hexString, "#808080")
        XCTAssertEqual(c.mixed(with: .white, 0), c); XCTAssertEqual(c.mixed(with: .white, 1), .white)
    }

    func testPlasmaMatchesViridis() {
        // plasma(101)[c(1, 26, 51, 81, 101)]
        assertClose(Palette.plasma(0), 0x0D0887, units: 0)
        assertClose(Palette.plasma(0.25), 0x7E03A8, units: 3)
        assertClose(Palette.plasma(0.5), 0xCC4678, units: 3)
        assertClose(Palette.plasma(0.8), 0xFCA636, units: 3)
        assertClose(Palette.plasma(1), 0xF0F921, units: 0)
        // outside 0 ... 1 is clamped; a missing value gets the dark end
        XCTAssertEqual(Palette.plasma(-2), Palette.plasma(0)); XCTAssertEqual(Palette.plasma(7), Palette.plasma(1))
        XCTAssertEqual(Palette.plasma(.nan), Palette.plasma(0))
        XCTAssertEqual(Palette.single, Palette.plasma(0))
    }

    func testDiscreteColoursMatchScaleColourViridis() {
        // plasma(n, end = 0.7) = viridis_pal(end = 0.7, option = "plasma")(n)
        let five: [UInt32] = [0x0D0887, 0x6100A7, 0xA11B9B, 0xD14E72, 0xF1844B]
        let got5 = Palette.discrete(count: 5)
        XCTAssertEqual(got5.count, 5)
        for (c, h) in zip(got5, five) { assertClose(c, h, units: 3) }
        let four: [UInt32] = [0x0D0887, 0x7701A8, 0xC33D80, 0xF1844B]
        for (c, h) in zip(Palette.discrete(count: 4), four) { assertClose(c, h, units: 3) }
        let two = Palette.discrete(count: 2)
        assertClose(two[0], 0x0D0887, units: 0); assertClose(two[1], 0xF1844B, units: 3)
        XCTAssertEqual(Palette.discrete(count: 1), [Palette.plasma(0)])       // plasma(1, end = 0.7) = "#0D0887"
        XCTAssertEqual(Palette.discrete(count: 0), [])
        // 33 TCGA cohorts: all different, dark to light
        let many = Palette.discrete(count: 33)
        XCTAssertEqual(Set(many.map(\.hexString)).count, 33)
        XCTAssertLessThan(many[0].r, many[32].r)
    }

    func testContinuousScaleEndsAtPointEight() {
        // plasma(3, end = 0.8): the lowest, middle and highest value of a numeric colour variable
        assertClose(Palette.continuous(0), 0x0D0887, units: 0)
        assertClose(Palette.continuous(0.5), 0xB12A90, units: 3)
        assertClose(Palette.continuous(1), 0xFCA636, units: 3)
        XCTAssertEqual(Palette.continuous(3), Palette.continuous(1)); XCTAssertEqual(Palette.continuous(-1), Palette.continuous(0))
    }

    func testSurvivalColoursMatchT2KmPalette() {
        XCTAssertEqual(Palette.survival(count: 0), [])
        XCTAssertEqual(Palette.survival(count: 1).map(\.hexString), ["#3B7DB4"])
        XCTAssertEqual(Palette.survival(count: 2).map(\.hexString), ["#3B7DB4", "#C0392B"])
        XCTAssertEqual(Palette.survival(count: 3).map(\.hexString), ["#3B7DB4", "#E3A93A", "#C0392B"])
        // colorRampPalette(c("#2C6FAD", "#2E9E88", "#E3A93A", "#C0392B"))(n); R rounds a
        // channel ending in .5 the other way, hence one unit of tolerance
        XCTAssertEqual(Palette.survival(count: 4).map(\.hexString), ["#2C6FAD", "#2E9E88", "#E3A93A", "#C0392B"])
        let five: [UInt32] = [0x2C6FAD, 0x2D9291, 0x88A361, 0xDA8C36, 0xC0392B]
        for (c, h) in zip(Palette.survival(count: 5), five) { assertClose(c, h, units: 1) }
        let six: [UInt32] = [0x2C6FAD, 0x2D8B96, 0x52A078, 0xBEA649, 0xD47C34, 0xC0392B]
        let got6 = Palette.survival(count: 6)
        XCTAssertEqual(got6.count, 6)
        for (c, h) in zip(got6, six) { assertClose(c, h, units: 1) }
    }
}
