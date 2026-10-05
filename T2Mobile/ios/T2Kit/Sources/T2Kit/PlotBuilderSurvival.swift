import Foundation

// Survival plots: survival_km() of the website (survival_prototype.R) without the drawing.
// X is a time-to-event endpoint (OS, PFI, DSS, DFI: an event column and "<endpoint>.time"
// in days); the Y marker is cut into equal-count groups; one Kaplan-Meier curve per group
// with its confidence band, the median survival per group, the log-rank test and the Cox
// hazard ratio per standard deviation of the marker.
//
// Where the app differs from the website (on purpose, and said to the user in `warnings`
// where it matters):
//   - a CATEGORICAL marker (TP53.mut, gender) is stratified by its own levels; the website
//     turns it into numbers and cuts those (a 0/1 marker cannot be cut into tertiles);
//   - no faceted survival grids yet.

extension PlotBuilder {
    static let endpointNames = ["OS": "Overall Survival", "PFI": "Progression-Free Interval",
                                "DSS": "Disease-Specific Survival", "DFI": "Disease-Free Interval"]
    /// the most groups a categorical marker may have
    static let maxSurvivalGroups = 8

    static func survival(_ request: PlotRequest, endpoint: String, columns: [String: Column], keep: Mask, context: Context) -> PlotScene {
        var warnings: [String] = []
        guard let eventAll = columns[endpoint]?.numbers, let timeAll = columns[endpoint + ".time"]?.numbers,
              eventAll.count == keep.count, timeAll.count == keep.count else {
            return .empty("\(endpoint) needs the numeric columns \(endpoint) and \(endpoint).time, which this dataset does not provide.")
        }
        let yNames = request.y.filter { !$0.isEmpty }
        let numericNames = yNames.filter { columns[$0]?.isNumeric ?? false }
        var categorical: Column? = nil
        if numericNames.isEmpty {
            guard let c = columns[yNames[0]] else { return .empty("Not loaded: \(yNames[0]).") }
            categorical = c
            if yNames.count > 1 { warnings.append("Categorical markers are not combined: only \(yNames[0]) is used.") }
        } else if numericNames.count < yNames.count {
            warnings.append("Several Y variables are combined, which needs numbers. Not used: \(yNames.filter { !numericNames.contains($0) }.joined(separator: ", ")).")
        }
        let markerName = categorical != nil ? yNames[0]
            : numericNames.count > 1 ? "median-z(\(numericNames.joined(separator: ", ")))" : numericNames[0]
        if !request.facet.isEmpty { warnings.append("\"Graph for each\" is not available for survival plots in the app yet; one plot is drawn.") }

        // "remove influences of" adjusts the marker when it is asked for Y
        var covariates: [[Double]] = []
        let conditionNames = request.condition.filter { !$0.isEmpty }
        if !conditionNames.isEmpty, request.conditionOn == .y || request.conditionOn == .both {
            if categorical != nil {
                warnings.append("\(markerName) is not numeric: influences cannot be removed from it.")
            } else if conditionNames.allSatisfy({ columns[$0]?.isNumeric ?? false }) {
                covariates = conditionNames.compactMap { columns[$0]?.numbers }
            } else {
                warnings.append("\"Remove influences of\" needs numeric variables in the app; nothing was removed.")
            }
        }

        // the samples: in use, with time, event, marker (and covariates), and a positive time
        let probes = numericNames.compactMap { columns[$0]?.numbers }
        let rows = keep.indices.filter { i in
            keep[i] && !timeAll[i].isNaN && !eventAll[i].isNaN && timeAll[i] > 0
                && probes.allSatisfy { !$0[i].isNaN } && covariates.allSatisfy { !$0[i].isNaN }
                && !(categorical?.isMissing(i) ?? false)
        }
        guard rows.count >= 20 else {
            return .empty("Too few samples with complete survival data (\(rows.count)) for \(markerName) and \(endpoint).", warnings: warnings)
        }

        // follow-up: administratively censor at the limit rather than drop anyone
        var time = rows.map { timeAll[$0] }, event = rows.map { eventAll[$0] }
        let capped = request.kmMaxDays.isFinite && request.kmMaxDays > 0
        if capped {
            for i in time.indices where time[i] > request.kmMaxDays { event[i] = 0; time[i] = request.kmMaxDays }
        }
        let xMax = capped ? request.kmMaxDays : (time.max() ?? 1)

        // the groups
        var group: [Int]
        var labels: [String]
        var marker: [Double]? = nil
        var groupWord = "groups"
        if let c = categorical, let codes = c.codes, let levels = c.levels {
            let present = Set(rows.map { codes[$0] })
            let order = levels.indices.filter { present.contains($0) }
            guard order.count >= 2 else { return .empty("\(markerName) has one value among these samples: there are no groups to compare.", warnings: warnings) }
            guard order.count <= maxSurvivalGroups else {
                return .empty("\(markerName) has \(order.count) values among these samples; a survival plot compares at most \(maxSurvivalGroups) groups. Filter the samples, or choose another marker.", warnings: warnings)
            }
            let index = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            group = rows.map { index[codes[$0]] ?? -1 }
            labels = order.map { levels[$0] }
        } else {
            // one probe is used as it is; several become the median of their z-scores over these samples
            var m = Stats.combineMedianZ(probes.map { p in rows.map { p[$0] } })
            if !covariates.isEmpty { m = Stats.residuals(m, on: covariates.map { c in rows.map { c[$0] } }) }
            let asked = max(2, request.kmGroups)
            let cut = Stats.quantileGroupsUnique(m, groups: asked)
            guard cut.count >= 2 else {
                return .empty("\(markerName) has too few distinct values to be split into \(asked) groups (many samples share one value). Try 2 groups.", warnings: warnings)
            }
            group = cut.group
            labels = Stats.groupLabels(asked: asked, made: cut.count)
            marker = m
            groupWord = asked == 2 ? "halves" : asked == 3 ? "tertiles" : asked == 4 ? "quartiles" : asked == 5 ? "quintiles" : "\(asked) groups"
        }

        // one curve per group
        let colors = Palette.survival(count: labels.count)
        var ticks: [Double] = stride(from: 0.0, through: xMax, by: 365).map { $0 }
        if ticks.count > 8 || ticks.count < 3 { ticks = PlotFormat.ticks(0, xMax) }
        let xAxis = PlotAxis(kind: .numeric, lo: 0, hi: xMax * 1.02, ticks: ticks, labels: ticks.map(PlotFormat.tickLabel), title: "Time (days)")
        let yTicks = [0, 0.25, 0.5, 0.75, 1.0]
        let yAxis = PlotAxis(kind: .numeric, lo: 0, hi: 1.03, ticks: yTicks, labels: yTicks.map(PlotFormat.tickLabel), title: "\(endpoint) probability")
        var panel = PlotPanel(title: "", xAxis: xAxis, yAxis: yAxis)
        var legend = PlotLegend(title: "\(markerName) group")
        var risk = RiskTable(times: ticks, rows: [], groups: labels, colors: colors)
        var stats: [StatLine] = [StatLine("Samples", "\(rows.count)"), StatLine("Events", "\(event.filter { $0 != 0 }.count)")]
        var medians: [String] = []
        for g in labels.indices {
            let members = group.indices.filter { group[$0] == g }
            let km = Stats.kaplanMeierBand(time: members.map { time[$0] }, event: members.map { event[$0] })
            // a step function from (0, 1): flat until an event time, then down
            var xs = [0.0], ys = [1.0], lower = [1.0], upper = [1.0]
            var s = 1.0, lo = 1.0, hi = 1.0
            for i in km.times.indices {
                let newLo = km.lower[i].isNaN ? km.survival[i] : km.lower[i]
                let newHi = km.upper[i].isNaN ? km.survival[i] : km.upper[i]
                xs += [km.times[i], km.times[i]]; ys += [s, km.survival[i]]
                lower += [lo, newLo]; upper += [hi, newHi]
                s = km.survival[i]; lo = newLo; hi = newHi
            }
            if let last = km.observed.last, last > (xs.last ?? 0) {      // flat to the last follow-up
                xs.append(last); ys.append(s); lower.append(lo); upper.append(hi)
            }
            panel.bands.append(PlotBand(xs: xs, lower: lower, upper: upper, color: colors[g], opacity: 0.16))
            panel.lines.append(PlotLine(xs: xs, ys: ys, color: colors[g], width: 2))
            let median = km.medianTime.map { "\(Int($0.rounded()))d" } ?? "NR"
            medians.append("\(labels[g]) \(median)")
            legend.entries.append(PlotLegend.Entry(label: "\(labels[g]) (med \(median))", color: colors[g]))
            risk.rows.append(ticks.map { km.atRisk(at: $0) })
            stats.append(StatLine(labels[g], "n \(km.n), events \(km.events), median \(median)"))
        }
        panel.riskTable = risk
        panel.n = rows.count

        var note: [String] = []
        if let lr = Stats.logRank(time: time, event: event, group: group) {
            stats.append(StatLine("Log-rank p", PlotFormat.pValue(lr.p)))
            note.append("Log-rank p = \(PlotFormat.pValue(lr.p))")
        }
        if let m = marker, let cox = Stats.cox(time: time, event: event, covariate: Stats.zscore(m)) {
            let hr = String(format: "%.2f (%.2f\u{2013}%.2f)", cox.hazardRatio, cox.lower, cox.upper)
            stats.append(StatLine("Cox HR per SD", hr))
            stats.append(StatLine("p (Cox)", PlotFormat.pValue(cox.p)))
            note.append("Cox HR/SD = \(hr), p = \(PlotFormat.pValue(cox.p))")
        }
        panel.note = note.joined(separator: "\n")

        let endpointName = endpointNames[endpoint] ?? endpoint
        var subtitle = "n = \(rows.count)   median \(endpoint): \(medians.joined(separator: " | "))"
        if capped { subtitle += "   follow-up \u{2264} \(Int(request.kmMaxDays))d" }
        if !covariates.isEmpty { subtitle += "   adj: \(conditionNames.joined(separator: ", "))" }
        if !context.datasetLabel.isEmpty { subtitle += "   \(context.datasetLabel)." }
        return PlotScene(kind: .survival, title: "\(endpointName) by \(markerName) \(groupWord)", subtitle: subtitle,
                         panels: [panel], legend: legend, stats: stats, warnings: warnings, n: rows.count)
    }
}
