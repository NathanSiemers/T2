import Foundation
import T2Kit

// The Analysis tab's state and work (docs/ANALYSIS-SPEC.md): the grouping (what the filters or a
// variable split the samples into), the variable tested across the groups, the result, and the
// clinical screen. All computation is local (T2Kit's makeGrouping / groupTest / groupScreen).

/// What the Analysis tab holds. One value in AppModel (`analysis`), so Observation sees every change.
struct AnalysisState {
    var grouping: Grouping?
    var variable = ""
    /// "Means-based tests (Welch t / ANOVA)"
    var means = false
    var running = false
    /// a problem to show (a variable that could not be loaded, a grouping that cannot be made)
    var message: String?
    var outcome: AnalysisOutcome?
    var screen: AnalysisScreen?
    /// moves with every run: an answer that arrives after a newer request is dropped
    var runID = 0
}

/// One finished comparison, with everything the screen and the CSV need.
struct AnalysisOutcome {
    var groupingName: String
    var variable: String
    var kind: GroupVariableKind
    var assignment: GroupAssignment
    var result: GroupTestResult
    /// the existing plot of these groups (PlotBuilder), nil when the comparison was refused
    var scene: PlotScene?
    var means: Bool
    /// the filters that stayed in force (spec 1: all other filtering is maintained)
    var maintained: [String]
    var filterRevision: Int
}

struct AnalysisScreen {
    var groupingName: String
    var rows: [ScreenRow]
    var means: Bool
    var filterRevision: Int
}

extension AppModel {
    // MARK: names

    /// the filters in force (the Filter screen's rules that restrict something)
    var activeFilters: [ColumnFilter] { filter.filters.filter(\.isActive) }

    /// the display name of a grouping (spec 2: display only)
    func groupingName(_ g: Grouping) -> String {
        switch g {
        case .filterSplit(let column?): return "Split: \(column)"
        case .filterSplit(nil): return "Split: all filters"
        case .quantized(let name, let k): return "\(name) (\(k == 2 ? "halves" : k == 3 ? "tertiles" : "quartiles"))"
        case .categorical(let name): return name
        }
    }
    /// the column a grouping is made from: left out of the screen as circular (spec 4)
    func sourceColumn(of g: Grouping) -> String? {
        switch g {
        case .filterSplit(let c): return c
        case .quantized(let name, _): return name
        case .categorical(let name): return name
        }
    }
    /// one filter rule in plain words: "age from 40 to 60", "sex is F"
    func describe(_ f: ColumnFilter) -> String {
        var s: String
        switch f.value {
        case .range(let lo, let hi)?:
            switch (lo.isFinite, hi.isFinite) {
            case (true, true): s = "\(f.column) from \(PlotFormat.tickLabel(lo)) to \(PlotFormat.tickLabel(hi))"
            case (true, false): s = "\(f.column) at least \(PlotFormat.tickLabel(lo))"
            case (false, true): s = "\(f.column) at most \(PlotFormat.tickLabel(hi))"
            default: s = f.column
            }
        case .levels(let set)?:
            let names = set.sorted()
            s = names.count <= 3 ? "\(f.column) is \(names.joined(separator: " or "))" : "\(f.column) is one of \(names.count) values"
        case nil:
            s = f.column
        }
        if !f.includeMissing { s += ", missing excluded" }
        return s
    }
    /// what kind of variable a name is: a number, a category, or a survival endpoint; nil when not loaded
    func analysisKind(_ name: String) -> GroupVariableKind? {
        if isTTE(name) { return .survival }
        guard let c = column(name) else { return nil }
        return c.isNumeric ? .numeric : .categorical
    }
    /// the variables of the clinical screen: the dataset's clinical columns and handles (never probes)
    var screenVariables: [String] {
        guard let m = meta else { return [] }
        return (m.clinicalColumns + m.handleColumns).uniqued().filter { column($0) != nil }
    }

    // MARK: running

    /// One comparison: `variable` across the groups of `grouping`, the filters all kept.
    /// `method` is the seam for model mode (ANALYSIS-SPEC section 6): round 1 has only .auto.
    func runAnalysis(grouping: Grouping, variable: String, means: Bool, method: AnalysisMethod = .auto) async {
        guard let m = meta else { return }
        analysis.runID += 1
        let id = analysis.runID
        analysis.running = true
        analysis.message = nil
        defer { if analysis.runID == id { analysis.running = false } }
        let entry = m.tte.first { $0.name == variable }
        do {
            try await ensureLoaded([variable, sourceColumn(of: grouping) ?? ""] + (entry.map { [$0.eventCol, $0.timeCol] } ?? []))
        } catch {
            guard analysis.runID == id else { return }
            analysis.message = "Could not load the variables: \(error.localizedDescription)"
            return
        }
        guard analysis.runID == id else { return }
        guard let kind = analysisKind(variable) else { analysis.message = "\(variable) is not available in this dataset."; return }
        guard let assignment = makeGrouping(grouping, filter: filter, column: { self.column($0) }) else {
            analysis.message = "\(groupingName(grouping)) cannot be made: the variable is not available, or no filter is active on it."
            return
        }
        // truncation as the Kaplan-Meier plot: the follow-up limit is in days, so only a variable timed in days is capped
        let maxDays = entry?.timeUnit == "days" ? kmMaxDays : 0
        var tte: (time: [Double], event: [Double])? = nil
        if let entry, let t = column(entry.timeCol)?.numbers, let e = column(entry.eventCol)?.numbers { tte = (t, e) }
        let values = kind == .survival ? nil : column(variable)?.data
        let result = await Task.detached(priority: .userInitiated) {
            groupTest(values: values, kind: kind, assignment: assignment, means: means, tte: tte, maxDays: maxDays, method: method)
        }.value
        guard analysis.runID == id else { return }
        let name = groupingName(grouping)
        analysis.outcome = AnalysisOutcome(
            groupingName: name, variable: variable, kind: kind, assignment: assignment, result: result,
            scene: result.refused == nil ? analysisScene(name: name, variable: variable, kind: kind, assignment: assignment, result: result, maxDays: maxDays) : nil,
            means: means, maintained: activeFilters.map { describe($0) }, filterRevision: filter.revision)
    }

    /// The clinical screen: the grouping against every clinical column and handle, BH-adjusted together.
    func runScreen(grouping: Grouping, means: Bool) async {
        guard meta != nil else { return }
        analysis.runID += 1
        let id = analysis.runID
        analysis.running = true
        analysis.message = nil
        defer { if analysis.runID == id { analysis.running = false } }
        do { try await ensureLoaded([sourceColumn(of: grouping) ?? ""]) } catch {
            guard analysis.runID == id else { return }
            analysis.message = "Could not load the variable: \(error.localizedDescription)"
            return
        }
        guard analysis.runID == id else { return }
        guard let assignment = makeGrouping(grouping, filter: filter, column: { self.column($0) }) else {
            analysis.message = "\(groupingName(grouping)) cannot be made: the variable is not available, or no filter is active on it."
            return
        }
        if let why = assignment.refused { analysis.message = why; return }
        let source = sourceColumn(of: grouping)
        let vars = screenVariables.filter { $0 != source }
        let columns = filter.columns
        var kinds: [String: GroupVariableKind] = [:]
        for v in vars { kinds[v] = columns[v]?.isNumeric == true ? .numeric : .categorical }
        let kindsNow = kinds
        let rows = await Task.detached(priority: .userInitiated) {
            groupScreen(vars: vars, column: { columns[$0] }, kinds: kindsNow, assignment: assignment, means: means, tteSpecs: [:], maxDays: 0)
        }.value
        guard analysis.runID == id else { return }
        analysis.screen = AnalysisScreen(groupingName: groupingName(grouping), rows: rows, means: means, filterRevision: filter.revision)
    }

    // MARK: the plot

    /// The plot of a comparison, by the existing PlotBuilder: the groups become a categorical
    /// column, and the request is the one a user would make on the Select tab (the group on X
    /// and the variable on Y: boxes or counts; for a survival endpoint, the endpoint on X and
    /// the groups as the marker: Kaplan-Meier curves). Nothing in PlotBuilder is changed.
    private func analysisScene(name: String, variable: String, kind: GroupVariableKind, assignment: GroupAssignment,
                               result: GroupTestResult, maxDays: Double) -> PlotScene? {
        guard let m = meta else { return nil }
        let kept = result.groups.map(\.group)               // the groups that were tested, in order
        let index = Dictionary(uniqueKeysWithValues: kept.enumerated().map { ($1, $0) })
        let codes = assignment.group.map { $0 >= 0 ? (index[assignment.labels[$0]] ?? -1) : -1 }
        let key = name == variable ? name + " (groups)" : name
        var columns = filter.columns
        columns[key] = Column(name: key, type: "virtual", data: .categorical(levels: kept, codes: codes))
        let keep = codes.map { $0 >= 0 }
        var request = kind == .survival ? PlotRequest(x: [variable], y: [key], color: "", size: "", facet: "")
                                        : PlotRequest(x: [key], y: [variable], color: "", size: "", facet: "")
        request.kmMaxDays = maxDays
        let context = PlotBuilder.Context(datasetLabel: PlotBuilder.sourceWord(dataset: m.label, part: fixedPreset),
                                          tte: m.tte, typeLabels: m.typeWords, handleColumns: [], filters: filterNote, fills: FillNote())
        return PlotBuilder.build(request, columns: columns, keep: keep, context: context)
    }

    // MARK: the table

    /// The comparison as CSV (spec 5): a header line, the groups block, a blank line, the test block.
    func analysisCSV(_ o: AnalysisOutcome) -> String {
        func q(_ s: String) -> String {
            var t = s
            if let f = t.first, "=+-@\t\r".contains(f) { t = "'" + t }
            if t.isEmpty || t == "NA" || t.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
                return "\"" + t.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return t
        }
        func num(_ v: Double?) -> String {
            guard let v, !v.isNaN else { return "NA" }
            if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
            return "\(v)"
        }
        let kept = o.maintained.isEmpty ? "none" : o.maintained.joined(separator: "; ")
        var out = "# T2 analysis. Grouping: \(o.groupingName). Variable: \(o.variable). Samples in the universe: \(o.assignment.nUniverse). Filters maintained: \(kept)\n"
        switch o.kind {
        case .numeric:
            out += "group,n,median,q1,q3\n"
            for g in o.result.groups { out += [q(g.group), String(g.n), num(g.median), num(g.q1), num(g.q3)].joined(separator: ",") + "\n" }
        case .categorical:
            out += "group,level,count,prop\n"
            for l in o.result.levels { out += [q(l.group), q(l.level), String(l.count), num(l.prop)].joined(separator: ",") + "\n" }
        case .survival:
            out += "group,n,events,median_survival\n"
            for g in o.result.groups { out += [q(g.group), String(g.n), g.events.map(String.init) ?? "NA", q(g.medianSurvival ?? "NA")].joined(separator: ",") + "\n" }
        }
        out += "\nterm,method,statistic,df,p,p_bh,note\n"
        for t in o.result.test {
            out += [q(t.term), q(t.method), num(t.statistic), num(t.df), num(t.p), num(t.pBH), q(t.note ?? "")].joined(separator: ",") + "\n"
        }
        if let why = o.result.refused { out += "# Not compared: \(why)\n" }
        return out
    }

    /// the CSV in a new file in the temporary folder, to share
    func writeAnalysisTable() async -> URL? {
        guard let m = meta, let o = analysis.outcome else { return nil }
        let csv = analysisCSV(o)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let file = "T2_analysis_\(m.dataset)_\(stamp.string(from: Date())).csv"
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(file)
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            do { try csv.write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
            return url
        }.value
    }
}
