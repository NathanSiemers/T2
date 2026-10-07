import Foundation

// A plot, fully worked out but not yet drawn.
//
// PlotBuilder turns the user's choices (PlotRequest) and the loaded columns into a
// PlotScene: panels with axes and marks in DATA coordinates, a legend, the statistics and
// the sample counts. The app's renderer only maps data coordinates to points on the
// screen or the page. Everything numerical is therefore here, where it is unit-tested on
// Linux and macOS, and the same scene serves the screen, the preview and the exported file.
//
// Coordinates: a numeric axis uses the data's own values. A categorical axis with n levels
// runs from 0 to n; level k sits at k + 0.5 (jittered points lie around that centre).

/// What the user asked to see. The website's Select and Appearance tabs, as a value.
public struct PlotRequest: Sendable, Equatable {
    /// one or more variables; several numeric ones are combined into the median of their z-scores
    public var x: [String]
    public var y: [String]
    /// colour by this variable ("" = none); categorical or numeric
    public var color: String
    /// size points by this numeric variable ("" = none)
    public var size: String
    /// one panel per level of this categorical variable ("" = none): "Graph for each"
    public var facet: String
    /// z-score the numeric Y variables first
    public var zscoreY: Bool
    /// draw X on the vertical axis and Y on the horizontal one
    public var flip: Bool
    /// order the levels of a categorical X by the median of Y
    public var waterfall: Bool
    public var waterfallDescending: Bool
    /// several Y probes each on their own (the website's "Plot Y probes individually") instead
    /// of combined into one marker
    public var yIndividually: Bool = false
    /// least-squares line when both axes are numeric
    public var fitLine: Bool
    /// use only samples that have every plotted variable (the website's default)
    public var completeOnly: Bool
    /// survival plots: how many groups the Y marker is cut into, and where follow-up is cut off (days; 0 = no limit)
    public var kmGroups: Int
    public var kmMaxDays: Double
    /// "Remove influences of": numeric covariates whose linear effect is taken out of ...
    public var condition: [String]
    public var conditionOn: ConditionTarget

    public enum ConditionTarget: String, Sendable, Equatable, CaseIterable { case none, x, y, both }

    public init(x: [String] = [], y: [String] = [], color: String = "", size: String = "", facet: String = "",
                zscoreY: Bool = false, flip: Bool = false, waterfall: Bool = false, waterfallDescending: Bool = false,
                fitLine: Bool = true, completeOnly: Bool = true, kmGroups: Int = 3, kmMaxDays: Double = 1825,
                condition: [String] = [], conditionOn: ConditionTarget = .none) {
        self.x = x; self.y = y; self.color = color; self.size = size; self.facet = facet
        self.zscoreY = zscoreY; self.flip = flip; self.waterfall = waterfall; self.waterfallDescending = waterfallDescending
        self.fitLine = fitLine; self.completeOnly = completeOnly; self.kmGroups = kmGroups; self.kmMaxDays = kmMaxDays
        self.condition = condition; self.conditionOn = conditionOn
    }

    /// every variable this request needs loaded
    public var variables: [String] {
        var seen = Set<String>(), out: [String] = []
        for v in x + y + [color, size, facet] + condition where !v.isEmpty && seen.insert(v).inserted { out.append(v) }
        return out
    }
}

/// One axis of a panel.
public struct PlotAxis: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case numeric, categorical }
    public var kind: Kind
    /// the drawn range, in data coordinates (categorical: 0 ... number of levels)
    public var lo: Double
    public var hi: Double
    /// where the tick marks and grid lines go, with their labels
    public var ticks: [Double]
    public var labels: [String]
    public var title: String

    public init(kind: Kind, lo: Double, hi: Double, ticks: [Double], labels: [String], title: String) {
        self.kind = kind; self.lo = lo; self.hi = hi; self.ticks = ticks; self.labels = labels; self.title = title
    }
    /// position of `v` along the axis: 0 at `lo`, 1 at `hi`
    public func fraction(_ v: Double) -> Double { hi > lo ? (v - lo) / (hi - lo) : 0.5 }
}

/// One sample drawn as a point.
public struct PlotPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var color: RGB
    /// radius relative to the chosen point size (1 = that size)
    public var size: Double
    /// which sample this is: its index in the dataset's sample order
    public var sample: Int
    public init(x: Double, y: Double, color: RGB, size: Double = 1, sample: Int) {
        self.x = x; self.y = y; self.color = color; self.size = size; self.sample = sample
    }
}

/// A box of a box plot, in data coordinates. `position` is along the categorical axis,
/// the five numbers along the value axis; `horizontal` = the value axis is X.
public struct PlotBox: Sendable, Equatable {
    public var position: Double
    public var halfWidth: Double
    public var stats: Stats.Box
    public var horizontal: Bool
    public var color: RGB
    public init(position: Double, halfWidth: Double, stats: Stats.Box, horizontal: Bool, color: RGB) {
        self.position = position; self.halfWidth = halfWidth; self.stats = stats; self.horizontal = horizontal; self.color = color
    }
}

/// A connected line through data coordinates (a fit line, a survival curve).
public struct PlotLine: Sendable, Equatable {
    public var xs: [Double]
    public var ys: [Double]
    public var color: RGB
    /// line width relative to the plot's rule width (1 = normal)
    public var width: Double
    public var dashed: Bool
    public init(xs: [Double], ys: [Double], color: RGB, width: Double = 1, dashed: Bool = false) {
        self.xs = xs; self.ys = ys; self.color = color; self.width = width; self.dashed = dashed
    }
}

/// A filled region between a lower and an upper curve over the same x values (a confidence band).
public struct PlotBand: Sendable, Equatable {
    public var xs: [Double]
    public var lower: [Double]
    public var upper: [Double]
    public var color: RGB
    public var opacity: Double
    public init(xs: [Double], lower: [Double], upper: [Double], color: RGB, opacity: Double) {
        self.xs = xs; self.lower = lower; self.upper = upper; self.color = color; self.opacity = opacity
    }
}

/// A count drawn as a circle with its number (categorical X against categorical Y).
public struct PlotBubble: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var count: Int
    /// radius as a fraction of half a cell: 1 = the largest count in the plot
    public var radius: Double
    public var color: RGB
    public init(x: Double, y: Double, count: Int, radius: Double, color: RGB) {
        self.x = x; self.y = y; self.count = count; self.radius = radius; self.color = color
    }
}

/// The numbers-at-risk table under a survival plot.
public struct RiskTable: Sendable, Equatable {
    public var times: [Double]
    /// one row per group, one count per time
    public var rows: [[Int]]
    public var groups: [String]
    public var colors: [RGB]
    public init(times: [Double], rows: [[Int]], groups: [String], colors: [RGB]) {
        self.times = times; self.rows = rows; self.groups = groups; self.colors = colors
    }
}

/// One set of axes with its marks. A plot has one panel, or one per facet level.
public struct PlotPanel: Sendable, Equatable {
    /// the facet level ("" when the plot is not faceted)
    public var title: String
    public var xAxis: PlotAxis
    public var yAxis: PlotAxis
    public var points: [PlotPoint] = []
    public var boxes: [PlotBox] = []
    public var lines: [PlotLine] = []
    public var bands: [PlotBand] = []
    public var bubbles: [PlotBubble] = []
    public var riskTable: RiskTable?
    /// short text inside the panel (a faceted survival plot's p-value)
    public var note: String = ""
    /// how many samples are drawn in this panel
    public var n: Int = 0
    public init(title: String, xAxis: PlotAxis, yAxis: PlotAxis) { self.title = title; self.xAxis = xAxis; self.yAxis = yAxis }
}

/// What the colours (and sizes) mean.
public struct PlotLegend: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var label: String
        public var color: RGB
        public init(label: String, color: RGB) { self.label = label; self.color = color }
    }
    public var title: String
    /// a categorical variable's levels (only those present in the plot)
    public var entries: [Entry]
    /// a numeric variable's range, drawn as a colour bar; nil for a categorical one
    public var range: ClosedRange<Double>?
    /// title and range of the size variable, if points are sized
    public var sizeTitle: String
    public var sizeRange: ClosedRange<Double>?
    public init(title: String = "", entries: [Entry] = [], range: ClosedRange<Double>? = nil,
                sizeTitle: String = "", sizeRange: ClosedRange<Double>? = nil) {
        self.title = title; self.entries = entries; self.range = range; self.sizeTitle = sizeTitle; self.sizeRange = sizeRange
    }
    public var isEmpty: Bool { entries.isEmpty && range == nil && sizeRange == nil }
}

/// One line of statistics shown with a plot: "Pearson r" / "0.612".
public struct StatLine: Sendable, Equatable {
    public var label: String
    public var value: String
    public init(_ label: String, _ value: String) { self.label = label; self.value = value }
}

public struct PlotScene: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        /// numeric X, numeric Y
        case scatter
        /// categorical X, numeric Y (or numeric X, categorical Y: boxes lie flat)
        case box
        /// categorical X, categorical Y: counts
        case counts
        /// X is a survival endpoint: Kaplan-Meier curves by groups of Y
        case survival
        /// nothing can be drawn; `message` says why
        case empty
    }
    public var kind: Kind
    public var title: String
    public var subtitle: String
    public var panels: [PlotPanel]
    public var legend: PlotLegend
    /// statistics for the plot as a whole (per-panel values are in the panels' notes)
    public var stats: [StatLine]
    /// the sample counts behind the plot, as the website prints them under it
    public var summary: [String]
    /// things the user should know: a dropped variable, an option that does not apply
    public var warnings: [String]
    /// why there is no plot (kind == .empty)
    public var message: String
    /// points drawn, over all panels: one per sample, or one per sample and Y probe when
    /// the probes are plotted individually
    public var n: Int
    /// Y probes plotted individually (each sample drawn once per probe); 0 otherwise
    public var probesStacked: Int = 0
    /// what `n` counts, for the screen: "4,312 samples" or "8,624 points (4,312 samples x 2 probes)"
    public var countText: String {
        guard probesStacked > 1 else { return "\(n.formatted()) samples" }
        return "\(n.formatted()) points (\((n / probesStacked).formatted()) samples \u{00D7} \(probesStacked) probes)"
    }

    public init(kind: Kind, title: String = "", subtitle: String = "", panels: [PlotPanel] = [], legend: PlotLegend = PlotLegend(),
                stats: [StatLine] = [], summary: [String] = [], warnings: [String] = [], message: String = "", n: Int = 0) {
        self.kind = kind; self.title = title; self.subtitle = subtitle; self.panels = panels; self.legend = legend
        self.stats = stats; self.summary = summary; self.warnings = warnings; self.message = message; self.n = n
    }
    public static func empty(_ message: String, summary: [String] = [], warnings: [String] = []) -> PlotScene {
        PlotScene(kind: .empty, summary: summary, warnings: warnings, message: message)
    }
}

/// Round numbers for axes and text.
public enum PlotFormat {
    /// about `target` round tick values covering lo ... hi (both inside the range)
    public static func ticks(_ lo: Double, _ hi: Double, target: Int = 5) -> [Double] {
        guard lo.isFinite, hi.isFinite, hi > lo, target > 0 else { return lo.isFinite ? [lo] : [] }
        let raw = (hi - lo) / Double(target)
        let mag = pow(10, floor(log10(raw)))
        let f = raw / mag
        let step = (f < 1.5 ? 1 : f < 3 ? 2 : f < 7 ? 5 : 10) * mag
        var out: [Double] = []
        var k = (lo / step).rounded(.up)
        while k * step <= hi + step * 1e-9 && out.count < 50 {
            let v = k * step
            out.append(abs(v) < step * 1e-9 ? 0 : v)
            k += 1
        }
        return out
    }
    /// a tick label: as short as possible without losing the tick's value
    public static func tickLabel(_ v: Double) -> String {
        if v == 0 { return "0" }
        let a = abs(v)
        if a >= 1e6 || a < 1e-4 { return String(format: "%.3g", v) }
        var s = String(format: "%.6f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
    /// a statistic to three significant digits ("0.612", "12.3", "1.2e-08")
    public static func number(_ v: Double) -> String {
        if v.isNaN { return "NA" }
        if v == 0 { return "0" }
        let a = abs(v)
        if a < 1e-3 || a >= 1e6 { return String(format: "%.2e", v) }
        return String(format: "%.3g", v)
    }
    /// a p-value as the website prints it (fmtp in survival_prototype.R)
    public static func pValue(_ p: Double) -> String {
        if p.isNaN { return "NA" }
        if p <= 0 { return "< 1e-300" }
        if p < 1e-3 { return String(format: "%.1e", p) }
        return String(format: "%.3g", p)
    }
    /// a range with a little room at both ends, as ggplot expands a continuous axis (4% here)
    public static func padded(_ lo: Double, _ hi: Double) -> (lo: Double, hi: Double) {
        let span = hi > lo ? hi - lo : (lo == 0 ? 1 : abs(lo) * 0.1)
        return (lo - span * 0.04, hi + span * 0.04)
    }
}
