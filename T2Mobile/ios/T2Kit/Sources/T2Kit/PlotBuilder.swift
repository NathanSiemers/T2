import Foundation

// From the user's choices to a finished PlotScene. This is fun_plot1() of the website
// (lib.R), without the drawing: which samples are used, how several probes become one
// marker, what is plotted against what, the statistics and the sample counts.
//
// The rule the whole project stands on: a plotted value IS the value the service returned.
// Unless the user asked for a transformation (z-score, several probes combined, "remove
// influences of"), the x and y of every point are the column's own numbers, untouched;
// PlotBuilderTests checks that bit for bit.

public enum PlotBuilder {
    /// What the builder needs to know about the dataset.
    public struct Context: Sendable {
        /// the dataset's display name, for titles
        public var datasetLabel: String
        /// survival endpoints this dataset has (DatasetMeta.usableSurvivalEndpoints)
        public var survivalEndpoints: [String]
        /// the most panels a faceted plot may have
        public var maxPanels: Int
        public init(datasetLabel: String = "", survivalEndpoints: [String] = [], maxPanels: Int = 36) {
            self.datasetLabel = datasetLabel; self.survivalEndpoints = survivalEndpoints; self.maxPanels = maxPanels
        }
    }

    /// One axis variable after the user's transformations: numeric values or a categorical column.
    struct Variable {
        var name: String
        var numbers: [Double]?
        var levels: [String] = []
        var codes: [Int] = []
        var isNumeric: Bool { numbers != nil }
        func isMissing(_ i: Int) -> Bool { numbers.map { $0[i].isNaN } ?? (codes[i] < 0) }
    }

    // MARK: entry point

    /// - Parameters:
    ///   - columns: every loaded column by name (clinical columns and fetched probes)
    ///   - keep: the samples that pass the presets, the cohort choice and the Filter screen
    public static func build(_ request: PlotRequest, columns: [String: Column], keep: Mask, context: Context = Context()) -> PlotScene {
        let n = keep.count
        var warnings: [String] = []
        let xNames = request.x.filter { !$0.isEmpty }, yNames = request.y.filter { !$0.isEmpty }
        guard !xNames.isEmpty, !yNames.isEmpty else {
            return .empty(xNames.isEmpty && yNames.isEmpty ? "Choose X and Y on the Select tab." : xNames.isEmpty ? "Choose an X variable." : "Choose a Y variable.")
        }
        let absent = request.variables.filter { columns[$0] == nil }
        guard absent.isEmpty else { return .empty("Not loaded: \(absent.joined(separator: ", ")).") }
        guard request.variables.allSatisfy({ columns[$0]!.count == n }) else { return .empty("The loaded data do not match the dataset's sample list.") }

        let summary = sampleSummary(request, columns: columns, keep: keep)
        guard keep.contains(true) else {
            return .empty("No samples pass the filters.", summary: summary)
        }
        // a survival endpoint on X switches to time-to-event analysis, as on the website
        if xNames.count == 1, context.survivalEndpoints.contains(xNames[0]) {
            var scene = survival(request, endpoint: xNames[0], columns: columns, keep: keep, context: context)
            scene.summary = summary
            return scene
        }

        // z-scores and combined probes are worked out over the samples in use, as the website
        // does (its data frame only holds them): lib.R scales after gitr() has applied the
        // cohort, the exclusions and the Filter tab's survivors
        guard var x = combine(xNames, columns: columns, keep: keep, zscore: false, axis: "X", warnings: &warnings),
              var y = combine(yNames, columns: columns, keep: keep, zscore: request.zscoreY, axis: "Y", warnings: &warnings) else {
            return .empty("These variables cannot be combined.", summary: summary, warnings: warnings)
        }

        // colour and size are dropped when they cannot be used, as the website does
        var color: Column? = request.color.isEmpty ? nil : columns[request.color]
        var size: [Double]? = nil
        if !request.size.isEmpty {
            if let v = columns[request.size]?.numbers { size = v }
            else { warnings.append("Size needs a numeric variable; \(request.size) is not, so it is not used.") }
        }
        var facet: Column? = nil
        if !request.facet.isEmpty {
            if let f = columns[request.facet], !f.isNumeric { facet = f }
            else { warnings.append("\"Graph for each\" needs a categorical variable; \(request.facet) is numeric, so it is not used.") }
        }

        // which samples are drawn
        var required: [(Int) -> Bool] = [{ !x.isMissing($0) }, { !y.isMissing($0) }]
        if request.completeOnly {
            if let c = color { required.append { !c.isMissing($0) } }
            if let s = size { required.append { !s[$0].isNaN } }
            if let f = facet { required.append { !f.isMissing($0) } }
            // the website also asks for the dataset's cohort and sample type, when it has them
            for fixed in ["cohort", "sample_type"] { if let c = columns[fixed] { required.append { !c.isMissing($0) } } }
        }
        var rows = (0..<n).filter { i in keep[i] && required.allSatisfy { $0(i) } }
        // "remove influences of" comes after the samples are chosen (lib.R does it after the
        // complete-cases step): the fit uses exactly the samples that would be drawn, and a
        // sample without a covariate value drops out
        if applyConditioning(request, columns: columns, rows: rows, x: &x, y: &y, warnings: &warnings) {
            rows = rows.filter { !x.isMissing($0) && !y.isMissing($0) }
        }
        guard !rows.isEmpty else {
            return .empty("No samples have data for these variables. Some classifications only cover some tumor types, and some mutations are not present.",
                          summary: summary, warnings: warnings)
        }
        if let c = color, distinctCount(c, rows: rows) < 2 { color = nil }
        if let s = size, Set(rows.map { s[$0] }.filter { !$0.isNaN }).count < 2 { size = nil }

        // colours and sizes are decided once, over every sample drawn, so that they mean the
        // same in every panel
        let d = dress(color: color, colorName: request.color, size: size, sizeName: request.size, rows: rows)
        func one(_ rows: [Int]) -> PlotScene {
            if x.isNumeric && y.isNumeric { return scatter(request, x: x, y: y, dress: d, rows: rows) }
            if !x.isNumeric && y.isNumeric { return box(request, category: x, value: y, horizontal: false, dress: d, rows: rows) }
            if x.isNumeric && !y.isNumeric { return box(request, category: y, value: x, horizontal: true, dress: d, rows: rows) }
            return counts(x: x, y: y, rows: rows)
        }
        var scene: PlotScene
        if let f = facet, let codes = f.codes, let levels = f.levels {
            scene = faceted(by: levels, codes: codes, rows: rows, maxPanels: context.maxPanels, warnings: &warnings, one: one)
            if scene.legend.isEmpty { scene.legend = d.legend }
        } else {
            scene = one(rows)
        }
        if request.flip { flip(&scene) }
        scene.title = title(x: x.name, y: y.name, dataset: context.datasetLabel)
        scene.subtitle = subtitle(request, color: color, size: size, facet: facet, n: scene.n, dataset: context.datasetLabel)
        scene.summary = summary
        scene.warnings = warnings
        return scene
    }

    // MARK: preparing the variables

    /// One variable, or several numeric ones as the median of their z-scores.
    /// A transformation (z-score, combination) uses only the samples in `keep`; a single
    /// untransformed variable is returned as it is, value for value.
    static func combine(_ names: [String], columns: [String: Column], keep: Mask, zscore: Bool, axis: String, warnings: inout [String]) -> Variable? {
        func kept(_ v: [Double]) -> [Double] { v.indices.map { keep[$0] ? v[$0] : .nan } }
        var use = names
        if names.count > 1 {
            let notNumeric = names.filter { !(columns[$0]?.isNumeric ?? false) }
            if !notNumeric.isEmpty {
                warnings.append("Several \(axis) variables are combined, which needs numbers. Not used: \(notNumeric.joined(separator: ", ")).")
                use = names.filter { !notNumeric.contains($0) }
                if use.isEmpty { use = [names[0]] }
            }
        }
        guard let first = columns[use[0]] else { return nil }
        if use.count == 1 {
            switch first.data {
            case .numeric(let v): return Variable(name: use[0], numbers: zscore ? Stats.zscore(kept(v)) : v)
            case .categorical(let levels, let codes): return Variable(name: use[0], numbers: nil, levels: levels, codes: codes)
            }
        }
        var vectors = use.compactMap { columns[$0]?.numbers }.map(kept)
        guard vectors.count == use.count else { return nil }
        if zscore { vectors = vectors.map(Stats.zscore) }
        return Variable(name: use.joined(separator: "."), numbers: Stats.combineMedianZ(vectors))
    }

    /// "Remove influences of": replace numeric x and/or y by their residuals on the covariates,
    /// fitted over `rows` only (the samples about to be drawn). Returns true if anything changed.
    ///
    /// As lib.R does it: first keep the samples that have every conditioned variable and
    /// every covariate, then fit each conditioned variable on the covariates over those
    /// samples. A sample outside the fit is not drawn.
    static func applyConditioning(_ request: PlotRequest, columns: [String: Column], rows: [Int], x: inout Variable, y: inout Variable,
                                  warnings: inout [String]) -> Bool {
        let names = request.condition.filter { !$0.isEmpty }
        guard !names.isEmpty, request.conditionOn != .none else { return false }
        let notNumeric = names.filter { !(columns[$0]?.isNumeric ?? false) }
        guard notNumeric.isEmpty else {
            warnings.append("\"Remove influences of\" needs numeric variables; not numeric: \(notNumeric.joined(separator: ", ")). Nothing was removed.")
            return false
        }
        let onX = request.conditionOn == .x || request.conditionOn == .both
        let onY = request.conditionOn == .y || request.conditionOn == .both
        if onX && !x.isNumeric { warnings.append("\(x.name) is not numeric: influences cannot be removed from X.") }
        if onY && !y.isNumeric { warnings.append("\(y.name) is not numeric: influences cannot be removed from Y.") }
        let doX = onX && x.isNumeric, doY = onY && y.isNumeric
        guard doX || doY else { return false }

        let covariates = names.compactMap { columns[$0]?.numbers }
        let count = covariates.first?.count ?? 0
        var use = Mask(repeating: false, count: count)
        for r in rows where r < count {
            var ok = covariates.allSatisfy { !$0[r].isNaN }
            if doX, let v = x.numbers, v[r].isNaN { ok = false }
            if doY, let v = y.numbers, v[r].isNaN { ok = false }
            use[r] = ok
        }
        func only(_ v: [Double]) -> [Double] { v.indices.map { $0 < count && use[$0] ? v[$0] : .nan } }
        let masked = covariates.map(only)
        // the conditioned axes become residuals; an axis that is not conditioned keeps its
        // values, but loses the samples that are outside the fit
        if let v = x.numbers { x.numbers = doX ? Stats.residuals(only(v), on: masked) : only(v) }
        else { x.codes = x.codes.indices.map { $0 < count && use[$0] ? x.codes[$0] : -1 } }
        if let v = y.numbers { y.numbers = doY ? Stats.residuals(only(v), on: masked) : only(v) }
        else { y.codes = y.codes.indices.map { $0 < count && use[$0] ? y.codes[$0] : -1 } }
        return true
    }

    static func distinctCount(_ c: Column, rows: [Int]) -> Int {
        switch c.data {
        case .numeric(let v): return Set(rows.map { v[$0] }.filter { !$0.isNaN }).count
        case .categorical(_, let codes): return Set(rows.map { codes[$0] }.filter { $0 >= 0 }).count
        }
    }

    // MARK: colour and size of points

    struct Dress {
        var color: (Int) -> RGB = { _ in Palette.single }
        var size: (Int) -> Double = { _ in 1 }
        var legend = PlotLegend()
    }
    /// How the drawn samples are coloured and sized, and the legend that explains it.
    /// Categorical colours cover only the levels present among `rows` (droplevels), in level order.
    static func dress(color: Column?, colorName: String, size: [Double]?, sizeName: String, rows: [Int]) -> Dress {
        var d = Dress()
        if let c = color {
            d.legend.title = colorName
            switch c.data {
            case .categorical(let levels, let codes):
                let present = Set(rows.map { codes[$0] }.filter { $0 >= 0 })
                let order = levels.indices.filter { present.contains($0) }
                let colors = Palette.discrete(count: order.count)
                var byCode = [RGB?](repeating: nil, count: levels.count)
                for (k, code) in order.enumerated() { byCode[code] = colors[k] }
                d.legend.entries = order.enumerated().map { PlotLegend.Entry(label: levels[$1], color: colors[$0]) }
                d.color = { i in codes[i] >= 0 ? (byCode[codes[i]] ?? Palette.missing) : Palette.missing }
            case .numeric(let v):
                let present = rows.map { v[$0] }.filter { !$0.isNaN }
                if let lo = present.min(), let hi = present.max(), hi > lo {
                    d.legend.range = lo...hi
                    d.color = { i in v[i].isNaN ? Palette.missing : Palette.continuous((v[i] - lo) / (hi - lo)) }
                }
            }
        }
        if let s = size {
            let present = rows.map { s[$0] }.filter { !$0.isNaN }
            if let lo = present.min(), let hi = present.max(), hi > lo {
                d.legend.sizeTitle = sizeName; d.legend.sizeRange = lo...hi
                // ggplot's scale_size: AREA follows the value; T2 draws sizes from 0.5 to 3.5 times the point size
                d.size = { i in s[i].isNaN ? 0.5 : 0.5 + 3.0 * ((s[i] - lo) / (hi - lo)).squareRoot() }
            }
        }
        return d
    }

    // MARK: numeric against numeric

    static func scatter(_ request: PlotRequest, x: Variable, y: Variable, dress d: Dress, rows: [Int]) -> PlotScene {
        let xv = x.numbers!, yv = y.numbers!
        let xs = rows.map { xv[$0] }, ys = rows.map { yv[$0] }
        var panel = PlotPanel(title: "", xAxis: numericAxis(xs, title: x.name), yAxis: numericAxis(ys, title: y.name))
        panel.points = rows.map { PlotPoint(x: xv[$0], y: yv[$0], color: d.color($0), size: d.size($0), sample: $0) }
        panel.n = rows.count
        var stats: [StatLine] = [StatLine("Data points", "\(rows.count)")]
        if let line = Stats.regression(x: xs, y: ys) {
            if request.fitLine, let lo = xs.min(), let hi = xs.max() {
                panel.lines.append(PlotLine(xs: [lo, hi], ys: [line.intercept + line.slope * lo, line.intercept + line.slope * hi],
                                            color: Palette.single, width: 2))
            }
            if let p = Stats.pearson(x: xs, y: ys) {
                stats.append(StatLine("Pearson r", PlotFormat.number(p.r)))
                stats.append(StatLine("p (Pearson)", PlotFormat.pValue(p.p)))
            }
            if let s = Stats.spearman(x: xs, y: ys) {
                stats.append(StatLine("Spearman rho", PlotFormat.number(s.r)))
                stats.append(StatLine("p (Spearman)", PlotFormat.pValue(s.p)))
            }
            stats.append(StatLine("Fit line", "y = \(PlotFormat.number(line.intercept)) + \(PlotFormat.number(line.slope)) x"))
        }
        return PlotScene(kind: .scatter, panels: [panel], legend: d.legend, stats: stats, n: rows.count)
    }

    // MARK: categorical against numeric

    /// Boxes with the samples jittered over them. `horizontal`: the categories are on the Y axis.
    static func box(_ request: PlotRequest, category: Variable, value: Variable, horizontal: Bool, dress d: Dress, rows: [Int]) -> PlotScene {
        let v = value.numbers!, codes = category.codes
        // the levels that have samples, in the variable's own order (droplevels) ...
        var members: [Int: [Int]] = [:]
        for r in rows { members[codes[r], default: []].append(r) }
        var order = category.levels.indices.filter { members[$0] != nil }
        // ... or by the median of the values (waterfall)
        if request.waterfall {
            let med = Dictionary(uniqueKeysWithValues: order.map { ($0, Stats.median(members[$0]!.map { v[$0] })) })
            order.sort { request.waterfallDescending ? med[$0]! > med[$1]! : med[$0]! < med[$1]! }
        }
        let slot = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let categoryAxis = PlotAxis(kind: .categorical, lo: 0, hi: Double(order.count), ticks: order.indices.map { Double($0) + 0.5 },
                                    labels: order.map { category.levels[$0] }, title: category.name)
        let valueAxis = numericAxis(rows.map { v[$0] }, title: value.name)
        var panel = horizontal ? PlotPanel(title: "", xAxis: valueAxis, yAxis: categoryAxis) : PlotPanel(title: "", xAxis: categoryAxis, yAxis: valueAxis)
        for (k, level) in order.enumerated() {
            if let b = Stats.box(members[level]!.map { v[$0] }) {
                panel.boxes.append(PlotBox(position: Double(k) + 0.5, halfWidth: 0.375, stats: b, horizontal: horizontal, color: Palette.single))
            }
        }
        panel.points = rows.map { r in
            let along = Double(slot[codes[r]]!) + 0.5 + jitter(r) * 0.2
            return horizontal ? PlotPoint(x: v[r], y: along, color: d.color(r), size: d.size(r), sample: r)
                              : PlotPoint(x: along, y: v[r], color: d.color(r), size: d.size(r), sample: r)
        }
        panel.n = rows.count
        var stats: [StatLine] = [StatLine("Data points", "\(rows.count)"), StatLine("Groups", "\(order.count)")]
        if order.count >= 2, let kw = Stats.kruskalWallis(rows.map { v[$0] }, group: rows.map { codes[$0] }) {
            stats.append(StatLine("Kruskal-Wallis p", PlotFormat.pValue(kw.p)))
        }
        return PlotScene(kind: .box, panels: [panel], legend: d.legend, stats: stats, n: rows.count)
    }

    // MARK: categorical against categorical

    /// How many samples have each pair of levels: a circle per pair, its area following the count.
    static func counts(x: Variable, y: Variable, rows: [Int]) -> PlotScene {
        var table: [Int: [Int: Int]] = [:]
        for r in rows { table[x.codes[r], default: [:]][y.codes[r], default: 0] += 1 }
        let xOrder = x.levels.indices.filter { table[$0] != nil }
        let yPresent = Set(table.values.flatMap { $0.keys })
        let yOrder = y.levels.indices.filter { yPresent.contains($0) }
        func axis(_ v: Variable, _ order: [Int]) -> PlotAxis {
            PlotAxis(kind: .categorical, lo: 0, hi: Double(order.count), ticks: order.indices.map { Double($0) + 0.5 },
                     labels: order.map { v.levels[$0] }, title: v.name)
        }
        var panel = PlotPanel(title: "", xAxis: axis(x, xOrder), yAxis: axis(y, yOrder))
        let largest = table.values.flatMap { $0.values }.max() ?? 1
        for (i, xl) in xOrder.enumerated() {
            for (j, yl) in yOrder.enumerated() {
                guard let k = table[xl]?[yl], k > 0 else { continue }
                panel.bubbles.append(PlotBubble(x: Double(i) + 0.5, y: Double(j) + 0.5, count: k,
                                                radius: (Double(k) / Double(largest)).squareRoot(), color: Palette.single))
            }
        }
        panel.n = rows.count
        let stats = [StatLine("Samples", "\(rows.count)"), StatLine("Combinations with samples", "\(panel.bubbles.count) of \(xOrder.count * yOrder.count)")]
        return PlotScene(kind: .counts, panels: [panel], stats: stats, n: rows.count)
    }

    // MARK: one panel per level ("Graph for each")

    /// The same plot for every level of a categorical variable. Numeric axes are shared by
    /// all panels (facet_wrap's fixed scales); a categorical axis shows each panel's own levels.
    static func faceted(by levels: [String], codes: [Int], rows: [Int], maxPanels: Int, warnings: inout [String],
                        one: ([Int]) -> PlotScene) -> PlotScene {
        var groups: [Int: [Int]] = [:]
        for r in rows { groups[codes[r], default: []].append(r) }
        var order = levels.indices.filter { groups[$0] != nil }
        if order.count > maxPanels {
            warnings.append("\(order.count) graphs asked for; the first \(maxPanels) are drawn. Filter the samples to see the others.")
            order = Array(order.prefix(maxPanels))
        }
        var panels: [PlotPanel] = []
        var kind = PlotScene.Kind.empty
        var legend = PlotLegend()
        for level in order {
            let scene = one(groups[level]!)
            guard var panel = scene.panels.first else { continue }
            kind = scene.kind
            if legend.isEmpty { legend = scene.legend }
            panel.title = levels[level]
            // what the single plot shows as statistics goes into the panel, shortened
            var note = "n = \(panel.n)"
            if let r = scene.stats.first(where: { $0.label == "Pearson r" }) { note += ", r = \(r.value)" }
            if let p = scene.stats.first(where: { $0.label == "Kruskal-Wallis p" }) { note += ", p = \(p.value)" }
            panel.note = note
            panels.append(panel)
        }
        // shared numeric axes
        func share(_ path: WritableKeyPath<PlotPanel, PlotAxis>) {
            guard panels.allSatisfy({ $0[keyPath: path].kind == .numeric }), let first = panels.first else { return }
            let lo = panels.map { $0[keyPath: path].lo }.min() ?? first[keyPath: path].lo
            let hi = panels.map { $0[keyPath: path].hi }.max() ?? first[keyPath: path].hi
            let ticks = PlotFormat.ticks(lo, hi, target: panels.count > 4 ? 3 : 4)
            for i in panels.indices {
                panels[i][keyPath: path].lo = lo; panels[i][keyPath: path].hi = hi
                panels[i][keyPath: path].ticks = ticks; panels[i][keyPath: path].labels = ticks.map(PlotFormat.tickLabel)
            }
        }
        share(\.xAxis); share(\.yAxis)
        let total = panels.reduce(0) { $0 + $1.n }
        return PlotScene(kind: panels.isEmpty ? .empty : kind, panels: panels, legend: legend,
                         stats: [StatLine("Data points", "\(total)"), StatLine("Graphs", "\(panels.count)")], n: total)
    }

    /// The sideways offset of sample `i`, in -1 ... 1: the same every time the plot is drawn.
    static func jitter(_ i: Int) -> Double {
        // (i + 1: sample 0 would otherwise hash to 0 and always sit at the edge of its band)
        var h = (UInt64(truncatingIfNeeded: i) &+ 1) &* 0x9E3779B97F4A7C15
        h ^= h >> 31; h = h &* 0xBF58476D1CE4E5B9; h ^= h >> 29
        return Double(h >> 11) / Double(1 << 53) * 2 - 1
    }

    static func numericAxis(_ values: [Double], title: String) -> PlotAxis {
        let present = values.filter { !$0.isNaN }
        let (lo, hi) = PlotFormat.padded(present.min() ?? 0, present.max() ?? 1)
        let ticks = PlotFormat.ticks(lo, hi)
        return PlotAxis(kind: .numeric, lo: lo, hi: hi, ticks: ticks, labels: ticks.map(PlotFormat.tickLabel), title: title)
    }

    /// "Flip X and Y": everything turns a quarter, the numbers stay what they are.
    static func flip(_ scene: inout PlotScene) {
        for p in scene.panels.indices {
            let old = scene.panels[p]
            scene.panels[p].xAxis = old.yAxis; scene.panels[p].yAxis = old.xAxis
            scene.panels[p].points = old.points.map { PlotPoint(x: $0.y, y: $0.x, color: $0.color, size: $0.size, sample: $0.sample) }
            scene.panels[p].lines = old.lines.map { PlotLine(xs: $0.ys, ys: $0.xs, color: $0.color, width: $0.width, dashed: $0.dashed) }
            scene.panels[p].boxes = old.boxes.map { var b = $0; b.horizontal.toggle(); return b }
            scene.panels[p].bubbles = old.bubbles.map { PlotBubble(x: $0.y, y: $0.x, count: $0.count, radius: $0.radius, color: $0.color) }
        }
    }

    // MARK: words

    static func title(x: String, y: String, dataset: String) -> String {
        var s = "Relationship of \(x) and \(y)" + (dataset.isEmpty ? "" : " across \(dataset)")
        for (suffix, word) in [(".fmut", " mutation"), (".mut", " mutation"), (".cnv", " CNA")] {
            s = s.replacingOccurrences(of: suffix, with: word)
        }
        return s
    }
    static func subtitle(_ request: PlotRequest, color: Column?, size: [Double]?, facet: Column?, n: Int, dataset: String) -> String {
        var parts: [String] = []
        if color != nil { parts.append("Color: \(request.color)") }
        if size != nil { parts.append("Size: \(request.size)") }
        if facet != nil { parts.append("Graphs: \(request.facet).") }
        parts.append("Data points: \(n).")
        if !dataset.isEmpty { parts.append("\(dataset).") }
        return parts.joined(separator: " ")
    }

    /// The sample counts the website prints under a plot (plot_summary in lib.R).
    static func sampleSummary(_ request: PlotRequest, columns: [String: Column], keep: Mask) -> [String] {
        let rows = keep.indices.filter { keep[$0] }
        let total = rows.count
        var lines = ["Total samples after filters: \(total)"]
        guard total > 0 else { return lines }
        func have(_ names: [String]) -> Int { rows.filter { r in names.allSatisfy { !(columns[$0]?.isMissing(r) ?? true) } }.count }
        let vars = request.variables.filter { columns[$0] != nil }
        if !vars.isEmpty { lines.append("Samples with data per variable:") }
        for v in vars {
            let k = have([v])
            // (no "%@": a Swift String is not a format argument on Linux)
            lines.append("  \(v): \(k) / \(total) (\(String(format: "%.1f", 100 * Double(k) / Double(total)))%)")
        }
        let xy = (request.x + request.y).filter { !$0.isEmpty && columns[$0] != nil }
        if !xy.isEmpty {
            let k = have(xy)
            lines.append("Samples with data for both X and Y: \(k) / \(total)")
            lines.append("Samples missing X and/or Y: \(total - k)")
        }
        let aes = (request.x + request.y + [request.color, request.size, request.facet]).filter { !$0.isEmpty && columns[$0] != nil }
        if Set(aes).count > Set(xy).count { lines.append("Samples with all graph variables: \(have(aes)) / \(total)") }
        return lines
    }
}

public extension Palette {
    /// a sample whose colour variable has no value (drawn only when incomplete samples are kept)
    static let missing = RGB(r: 0.6, g: 0.6, b: 0.6)
}
