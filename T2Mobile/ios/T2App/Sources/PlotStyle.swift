import SwiftUI
import T2Kit

/// How a plot is drawn. Sizes are in points, as on the T2 website's Appearance tab
/// (0 = do not show that item).
struct PlotStyle: Equatable {
    var pointSize: Double = 3
    var alpha: Double = 0.35
    var titleSize: Double = 14
    var subtitleSize: Double = 10
    var axisTitleSize: Double = 13
    var axisTextSize: Double = 10
    var legendSize: Double = 10
    var showLegend = true
    var showFit = true
    var showSourceLine = true
    /// panels side by side in a faceted plot ("Graph for each"); 0 = chosen by their number
    var facetColumns = 0
}

/// A figure of a real size: inches and dots per inch, as on the website's Publish tab.
struct FigureSpec: Equatable {
    var widthIn: Double = 3.5
    var heightIn: Double = 3.2
    var dpi: Double = 300
    /// print-scale appearance, kept separately from the on-screen one
    var style = PlotStyle.forPrint
    var pixelWidth: Int { Int((widthIn * dpi).rounded()) }
    var pixelHeight: Int { Int((heightIn * dpi).rounded()) }
}

extension PlotStyle {
    /// the website's print defaults (figure_export.R: text 5-8 pt at final size, small points)
    static let forPrint = PlotStyle(pointSize: 1.2, alpha: 0.4, titleSize: 8, subtitleSize: 6, axisTitleSize: 7, axisTextSize: 6, legendSize: 6)
    /// for a 16:9 slide
    static let forSlide = PlotStyle(pointSize: 4, alpha: 0.4, titleSize: 24, subtitleSize: 16, axisTitleSize: 20, axisTextSize: 16, legendSize: 16)
}

/// The sizes offered on the Publish tab, as on the website (T2_FIG_PRESETS). A US-letter
/// page (8.5 x 11 in) with 0.75 in margins has a 7 x 9.5 in text area: half of its width
/// is 3.5 in, a third of its height 3.2 in (3.17), half of its height 4.75 in.
struct FigurePreset: Identifiable, Equatable {
    let id: String
    let label: String
    let widthIn: Double
    let heightIn: Double
    let dpi: Double
    let style: PlotStyle

    static let all: [FigurePreset] = [
        FigurePreset(id: "half_third", label: "Half page wide, 1/3 page high (3.5 x 3.2 in)", widthIn: 3.5, heightIn: 3.2, dpi: 300, style: .forPrint),
        FigurePreset(id: "full_half", label: "Full page wide, half page high (7 x 4.75 in)", widthIn: 7, heightIn: 4.75, dpi: 300, style: .forPrint),
        FigurePreset(id: "nature1", label: "Nature single column (89 x 80 mm)", widthIn: 89 / 25.4, heightIn: 80 / 25.4, dpi: 450, style: .forPrint),
        FigurePreset(id: "nature2", label: "Nature double column (183 x 110 mm)", widthIn: 183 / 25.4, heightIn: 110 / 25.4, dpi: 450, style: .forPrint),
        FigurePreset(id: "slide", label: "Slide 16:9 (13.33 x 7.5 in)", widthIn: 13.33, heightIn: 7.5, dpi: 150, style: .forSlide),
    ]
}

let t2Citation = "T2 Database and Search Tool, Nathan O. Siemers, Ph.D., https://www.fiveprime.org"
let t2DefaultService = "https://www.fiveprime.org/api/t2"
