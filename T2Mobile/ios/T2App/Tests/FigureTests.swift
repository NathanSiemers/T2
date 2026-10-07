import XCTest
import SwiftUI
import T2Kit
@testable import T2

/// The drawing of a figure (SceneDrawing / SceneCanvas), rendered to pixels in the simulator:
/// the appearance settings must change what is drawn, every legend entry must be placed, and
/// the panels-per-row setting must take effect. (T2Kit's own tests cover the numbers; these
/// cover the drawing, which only exists on Apple platforms.)
@MainActor
final class FigureTests: XCTestCase {

    // MARK: a small dataset: 120 samples, 6 cohorts, 3 colours, a numeric Y

    private func columns(cohorts: Int = 6) -> [String: Column] {
        let n = 120
        var cohortCodes: [Int] = [], colorCodes: [Int] = [], y: [Double] = []
        var seed: UInt64 = 7
        for i in 0..<n {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let r = Double(seed >> 11) / Double(1 << 53)
            cohortCodes.append(i % cohorts)
            colorCodes.append(i % 3)
            y.append(Double(i % cohorts) + r * 2)
        }
        return [
            "cohort": Column(name: "cohort", type: "virtual", data: .categorical(levels: (0..<cohorts).map { "COHORT\($0)" }, codes: cohortCodes)),
            "group": Column(name: "group", type: "clinical", data: .categorical(levels: ["alpha", "beta", "gamma"], codes: colorCodes)),
            "GENE": Column(name: "GENE", type: "rna", data: .numeric(y)),
        ]
    }

    private func scene(facet: String = "", cohorts: Int = 6) -> PlotScene {
        let cols = columns(cohorts: cohorts)
        let request = PlotRequest(x: ["cohort"], y: ["GENE"], color: "group", facet: facet)
        let keep = Mask(repeating: true, count: 120)
        return PlotBuilder.build(request, columns: cols, keep: keep, context: PlotBuilder.Context(datasetLabel: "Test", survivalEndpoints: []))
    }

    // MARK: rendering

    /// the figure as grey levels (0 = black, 255 = white), `width` x `height` points at 2 pixels per point
    private func render(_ scene: PlotScene, _ style: PlotStyle, width: CGFloat = 400, height: CGFloat = 300) -> (pixels: [UInt8], w: Int, h: Int) {
        let renderer = ImageRenderer(content: SceneCanvas(scene: scene, style: style).frame(width: width, height: height))
        renderer.scale = 2
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { XCTFail("no image"); return ([], 0, 0) }
        let w = image.width, h = image.height
        var grey = [UInt8](repeating: 255, count: w * h)
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: &grey, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            XCTFail("no context"); return ([], 0, 0)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (grey, w, h)
    }

    /// how much ink (darkness) there is in a band of rows (top-down, in pixels)
    private func ink(_ r: (pixels: [UInt8], w: Int, h: Int), rows: Range<Int>? = nil) -> Double {
        let rows = rows ?? 0..<r.h
        var total = 0.0
        for y in rows where y < r.h {
            for x in 0..<r.w { total += Double(255 - Int(r.pixels[y * r.w + x])) }
        }
        return total / 255
    }

    func testSameSceneAndStyleDrawTheSamePixels() {
        let s = scene()
        XCTAssertEqual(render(s, .forPrint).pixels, render(s, .forPrint).pixels)
    }

    /// a style with no marks and no text at all; a test switches on the one thing it measures
    /// (the panel's axis lines and grid stay: a few hundred ink units, the same in every variant)
    private var bare: PlotStyle {
        var s = PlotStyle()
        s.pointSize = 0; s.titleSize = 0; s.subtitleSize = 0; s.axisTitleSize = 0; s.axisTextSize = 0; s.legendSize = 0
        s.showLegend = false; s.showSourceLine = false
        return s
    }

    func testTitleSizeIsRespected() {
        let s = scene()
        var small = bare; small.titleSize = 10
        var large = bare; large.titleSize = 20
        // the top band holds the title: a larger title puts clearly more ink there
        let band = 0..<70
        let none = ink(render(s, bare), rows: band)
        let a = ink(render(s, small), rows: band), b = ink(render(s, large), rows: band)
        XCTAssertGreaterThan(a, none + 100, "a 10 pt title adds no ink at the top (\(none) -> \(a))")
        XCTAssertGreaterThan(b, a + 100, "a 20 pt title (\(b)) is not clearly larger than a 10 pt one (\(a))")
    }

    /// each text size on its own: more points, more ink; 0 = none
    func testAxisAndLegendSizesAreRespected() {
        let s = scene()
        let none = ink(render(s, bare))
        func inkWith(_ change: (inout PlotStyle) -> Void) -> Double {
            var st = bare; change(&st); return ink(render(s, st))
        }
        let labels6 = inkWith { $0.axisTextSize = 6 }, labels14 = inkWith { $0.axisTextSize = 14 }
        XCTAssertGreaterThan(labels6, none + 50, "6 pt axis labels add no ink")
        // (the ink the text itself adds, over the bare figure's axes, grid and boxes)
        XCTAssertGreaterThan(labels14 - none, (labels6 - none) * 1.5, "14 pt axis labels (\(labels14 - none)) are not clearly more than 6 pt ones (\(labels6 - none))")
        let titles7 = inkWith { $0.axisTitleSize = 7 }, titles16 = inkWith { $0.axisTitleSize = 16 }
        XCTAssertGreaterThan(titles7, none + 50, "7 pt axis titles add no ink")
        XCTAssertGreaterThan(titles16 - none, (titles7 - none) * 1.5, "16 pt axis titles (\(titles16 - none)) are not clearly more than 7 pt ones (\(titles7 - none))")
        let legend6 = inkWith { $0.showLegend = true; $0.legendSize = 6 }, legend14 = inkWith { $0.showLegend = true; $0.legendSize = 14 }
        XCTAssertGreaterThan(legend6, none + 50, "a 6 pt legend adds no ink")
        XCTAssertGreaterThan(legend14 - none, (legend6 - none) * 1.5, "a 14 pt legend (\(legend14 - none)) is not clearly more than a 6 pt one (\(legend6 - none))")
        let source = inkWith { $0.showSourceLine = true; $0.axisTextSize = 8 } - inkWith { $0.axisTextSize = 8 }
        XCTAssertGreaterThan(source, 50, "the source line adds no ink")
        // the print preset against the same with every text removed
        var noText = PlotStyle.forPrint
        noText.titleSize = 0; noText.subtitleSize = 0; noText.axisTitleSize = 0; noText.axisTextSize = 0; noText.legendSize = 0; noText.showSourceLine = false
        XCTAssertLessThan(ink(render(s, noText)), ink(render(s, .forPrint)) * 0.7, "removing every text leaves most of the ink")
    }

    func testPointSizeIsRespected() {
        let s = scene()
        var fine = bare; fine.pointSize = 0.8
        var coarse = bare; coarse.pointSize = 4
        XCTAssertGreaterThan(ink(render(s, fine)), ink(render(s, bare)) + 20, "0.8 pt points add no ink")
        XCTAssertGreaterThan(ink(render(s, coarse)), ink(render(s, fine)) * 1.5)
    }

    // MARK: legend

    func testEveryLegendEntryIsPlacedHoweverLittleRoomThereIs() {
        let entries = (0..<40).map { PlotLegend.Entry(label: "Level number \($0)", color: RGB(r: 0.2, g: 0.4, b: 0.6)) }
        let legend = PlotLegend(title: "group", entries: entries)
        for (width, height) in [(CGFloat(380), CGFloat(120)), (170, 60), (700, 40), (300, 2000)] {
            let plan = SceneDrawing.legendPlan(legend, PlotStyle(), width: width, maxHeight: height, shrink: true)
            XCTAssertEqual(plan.swatches.count, 40, "\(width)x\(height): entries dropped")
            XCTAssertGreaterThanOrEqual(plan.fontSize, 5)
            XCTAssertLessThanOrEqual(plan.height, height + CGFloat(plan.fontSize * 1.35) * 2, "\(width)x\(height): the legend overflows its room by more than two rows")
            for sw in plan.swatches {
                XCTAssertFalse(sw.text.isEmpty)
                XCTAssertLessThan(sw.rect.maxX, width + 1, "a swatch lies outside the legend's width")
            }
            let texts = plan.swatches.map(\.text)
            XCTAssertTrue(texts.allSatisfy { $0.hasPrefix("Level") || $0.hasPrefix("Lev") || $0.hasPrefix("L") }, "labels unreadable: \(texts.prefix(3))")
        }
        // with room to spare nothing is shortened and the type keeps its size
        let roomy = SceneDrawing.legendPlan(legend, PlotStyle(), width: 400, maxHeight: 2000, shrink: true)
        XCTAssertEqual(roomy.fontSize, PlotStyle().legendSize)
        XCTAssertEqual(roomy.swatches.map(\.text), entries.map(\.label))
    }

    func testNoMoreCountInTheLegend() {
        // 60 cohorts in a phone-sized plot: all 60 drawn, none summarised as "+ N more"
        let s = scene(cohorts: 60)
        XCTAssertEqual(s.legend.entries.count, 3)   // colour has three levels; the cohorts are on the axis
        let legend = PlotLegend(title: "cohort", entries: (0..<60).map { PlotLegend.Entry(label: "C\($0)", color: RGB(r: 0, g: 0, b: 0)) })
        let plan = SceneDrawing.legendPlan(legend, PlotStyle(), width: 380, maxHeight: 160, shrink: true)
        XCTAssertEqual(plan.swatches.count, 60)
        XCTAssertTrue(plan.lines.allSatisfy { !$0.text.contains("more") })
        XCTAssertGreaterThan(SceneDrawing.legendHeightBelow(PlotScene(kind: .box, panels: s.panels, legend: legend), PlotStyle(), width: 380), 0)
    }

    // MARK: panels per row

    func testFacetColumnsSettingTakesEffect() {
        let s = scene(facet: "group")
        XCTAssertEqual(s.panels.count, 3)
        XCTAssertEqual(SceneDrawing.panelColumns(3, PlotStyle()), 2)
        var one = PlotStyle(); one.facetColumns = 1
        var three = PlotStyle(); three.facetColumns = 3
        var ten = PlotStyle(); ten.facetColumns = 10
        XCTAssertEqual(SceneDrawing.panelColumns(3, one), 1)
        XCTAssertEqual(SceneDrawing.panelColumns(3, three), 3)
        XCTAssertEqual(SceneDrawing.panelColumns(3, ten), 3, "more columns than panels")
        XCTAssertEqual(SceneDrawing.panelColumns(1, three), 1, "a single panel is never split")
        let a = render(s, one, width: 600, height: 600), b = render(s, three, width: 600, height: 600)
        XCTAssertNotEqual(a.pixels, b.pixels, "the panels-per-row setting changes nothing in the drawing")
        // three panels side by side: the middle third of the figure's height carries ink across
        // its whole width; stacked, the top rows carry ink only in the first panel's area
        let topBand = ink(a, rows: 0..<a.h / 6), topBandSide = ink(b, rows: 0..<b.h / 6)
        XCTAssertGreaterThan(topBandSide, topBand, "side-by-side panels do not use the top of the figure more")
    }
}
