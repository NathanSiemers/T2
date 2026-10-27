import SwiftUI
import T2Kit

/// The Analysis tab: how the samples are put into groups (the filters, or a variable), what is
/// compared across them, and the answer: a plot, the statistics, a CSV, and a screen of the
/// clinical variables. The method and the numbers are T2Kit's (docs/ANALYSIS-SPEC.md).
struct AnalysisView: View {
    @Environment(AppModel.self) private var model
    @State private var tableURL: URL?
    @State private var textURL: URL?
    @State private var groupsOpen = false
    @State private var sourcesOpen = false
    /// a number chosen as the grouping from the list: asks how many groups
    @State private var cutName: String?

    var body: some View {
        NavigationStack {
            Group {
                if model.meta == nil { NoDatasetView() } else { content }
            }
            .navigationTitle("Analysis")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder private var content: some View {
        @Bindable var model = model
        let a = model.analysis
        List {
            groupingSection
            Section {
                VariablePicker(title: "Test variable", current: a.variable, allowNone: false, placeholder: "choose") { v in
                    model.analysis.variable = v
                }
                ForEach(model.meta?.tte ?? []) { t in
                    GroupRow(label: t.label, description: "Survival: log-rank test of the curves", isOn: a.variable == t.name) { model.analysis.variable = t.name }
                        .accessibilityIdentifier("analysis-survival-\(t.name)")
                }
                Toggle("Means-based tests (Welch t / ANOVA)", isOn: $model.analysis.means)
                    .accessibilityIdentifier("analysis-means")
            } header: {
                Text("Compare")
            } footer: {
                Text("A number is compared by ranks (Wilcoxon, Kruskal-Wallis), or by means when the switch is on; a category by a chi-squared or Fisher exact test; a survival endpoint by the log-rank test.")
            }
            Section {
                Button { run() } label: { Label("Compare", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .disabled(a.grouping == nil || a.variable.isEmpty || a.running)
                    .accessibilityIdentifier("analysis-run")
                Button { screen() } label: { Label("Screen clinical variables", systemImage: "list.number").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .disabled(a.grouping == nil || a.running)
                    .accessibilityIdentifier("analysis-screen")
                if let message = a.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("analysis-message")
                }
            }
            if let o = a.outcome { results(o) }
            if let s = a.screen { screenSection(s) }
        }
        .overlay(alignment: .top) {
            if a.running || model.busy { ProgressView().padding(8).background(.regularMaterial, in: Capsule()).padding(.top, 4) }
        }
        .sheet(isPresented: $groupsOpen) {
            // (a number may be cut into groups from its row's arrow; a tap on the name asks how many)
            VariableSearch(title: "Groups by", current: "", allowNone: false, done: { names in
                groupsOpen = false
                if let n = names.first { chooseVariableGroups(n) }
            }, quantize: { name, k in
                groupsOpen = false
                model.analysis.grouping = .quantized(name: name, k: k)
                Task { try? await model.ensureLoaded([name]) }
            })
        }
        .confirmationDialog("Split \(cutName ?? "") into", isPresented: Binding(get: { cutName != nil }, set: { if !$0 { cutName = nil } }), titleVisibility: .visible) {
            ForEach(2...4, id: \.self) { k in
                Button("\(k) groups") { if let n = cutName { model.analysis.grouping = .quantized(name: n, k: k) }; cutName = nil }
            }
        }
    }

    // MARK: grouping

    /// the grouping rows for the current Select picks (x, quantized y, color, graph-for-each), each once
    private var selectGroupings: [(Grouping, String)] {
        var out: [(Grouping, String)] = []
        // (Y only when it was quantized: a plain Y is not a grouping)
        var picks = [(model.x, model.xCut), (model.color, model.colorCut), (model.facet, model.facetCut)]
        if (2...4).contains(model.yCut) { picks.insert((model.y, model.yCut), at: 1) }
        for (v, cut) in picks where !v.isEmpty {
            guard let col = model.column(v) else { continue }
            let grouping: Grouping = col.isNumeric ? .quantized(name: v, k: (2...4).contains(cut) ? cut : 3) : .categorical(v)
            guard !out.contains(where: { $0.0 == grouping }) else { continue }
            out.append((grouping, "\(model.groupingName(grouping)) - from Select"))
        }
        return out
    }

    @ViewBuilder private var groupingSection: some View {
        let active = model.activeFilters
        let g = model.analysis.grouping
        Section {
            ForEach(active, id: \.column) { f in
                GroupRow(label: "Split: \(f.column)", description: model.describe(f), isOn: g == .filterSplit(column: f.column)) {
                    model.analysis.grouping = .filterSplit(column: f.column)
                }
                .accessibilityIdentifier("analysis-split-\(f.column)")
            }
            if active.count >= 2 {
                GroupRow(label: "Split: all filters", description: "Samples passing every filter, against the rest of the chosen samples.", isOn: g == .filterSplit(column: nil)) {
                    model.analysis.grouping = .filterSplit(column: nil)
                }
                .accessibilityIdentifier("analysis-split-all")
            }
            if let g, !isFilterSplit(g) {
                GroupRow(label: model.groupingName(g), description: "Groups of a variable", isOn: true) {}
                    .accessibilityIdentifier("analysis-variable-grouping")
            }
            // spec 9b: the Select tab's picks, ready made (numbers cut with that slot's chip, default 3)
            ForEach(selectGroupings, id: \.1) { grouping, label in
                GroupRow(label: label, description: "Groups of a variable", isOn: g == grouping) {
                    model.analysis.grouping = grouping
                    Task { try? await model.ensureLoaded([model.sourceColumn(of: grouping) ?? ""]) }
                }
                .accessibilityIdentifier("analysis-select-\(model.groupingName(grouping))")
            }
            Button { groupsOpen = true } label: {
                HStack {
                    Text("Variable groups\u{2026}").foregroundStyle(Color.primary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondary.opacity(0.6))
                }
            }
            .accessibilityIdentifier("analysis-variable-groups")
        } header: {
            Text("Groups")
        } footer: {
            Text(active.isEmpty
                 ? "Set a filter on the Filter tab to compare the samples it keeps with the others, or choose a variable: a category is used as it is, a number is cut into 2 to 4 equal-count groups. Every filter stays in force."
                 : "A filter splits the samples into those it keeps and those it removes, the other filters staying in force. Or choose a variable: a category is used as it is, a number is cut into 2 to 4 equal-count groups.")
        }
    }

    private func isFilterSplit(_ g: Grouping) -> Bool { if case .filterSplit = g { return true } else { return false } }

    /// a variable chosen from the list: a category is the grouping; a number asks how many groups
    private func chooseVariableGroups(_ name: String) {
        Task {
            try? await model.ensureLoaded([name])
            guard let c = model.column(name) else { model.analysis.message = "\(name) is not available in this dataset."; return }
            if c.isNumeric { cutName = name } else { model.analysis.grouping = .categorical(name) }
        }
    }

    private func run() {
        guard let g = model.analysis.grouping else { return }
        let v = model.analysis.variable, means = model.analysis.means
        Task { await model.runAnalysis(grouping: g, variable: v, means: means) }
    }
    private func screen() {
        guard let g = model.analysis.grouping else { return }
        let means = model.analysis.means
        Task { await model.runScreen(grouping: g, means: means) }
    }

    // MARK: results

    @ViewBuilder private func results(_ o: AnalysisOutcome) -> some View {
        if o.filterRevision != model.filter.revision {
            Section { Text("The filters changed after this comparison. Compare again to update it.").font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("analysis-stale") }
        }
        if let scene = o.scene {
            Section {
                if scene.kind == .empty {
                    Text(scene.message).font(.footnote).foregroundStyle(.secondary)
                } else {
                    SceneCanvas(scene: scene, style: model.style, legendRoom: true)
                        .frame(height: plotHeight(scene))
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .accessibilityElement()
                        .accessibilityLabel(scene.title)
                        .accessibilityIdentifier("analysis-plot")
                }
            } header: {
                Text("\(o.variable) by \(o.groupingName)")
            }
        }
        let notes = [o.assignment.note, o.result.refused, o.result.test.first?.note].compactMap { $0 }
        if !notes.isEmpty {
            Section("Notes") {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, n in Text(n).font(.footnote) }
            }
        }
        Section("Statistics") {
            ForEach(Array(statLines(o).enumerated()), id: \.offset) { _, line in
                LabeledContent(line.label) { Text(line.value).monospacedDigit().multilineTextAlignment(.trailing) }
            }
            Button { sourcesOpen = true } label: {
                Label("Methods and sources", systemImage: "books.vertical").font(.footnote)
            }
            .accessibilityIdentifier("analysis-methods-sources")
            .sheet(isPresented: $sourcesOpen) { SourcesSheet(scrollTo: "methods") }
        }
        Section {
            Button("Export the comparison (CSV)") { Task { tableURL = await model.writeAnalysisTable() } }
                .accessibilityIdentifier("analysis-table-make")
            if let tableURL {
                ShareLink(item: tableURL) { Label("Share or save the comparison", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("analysis-table-share")
                    .id(tableURL)
                Text(tableURL.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Button("Export the statistics (text)") { Task { textURL = await model.writeAnalysisText() } }
                .accessibilityIdentifier("analysis-text-make")
            if let textURL {
                ShareLink(item: textURL) { Label("Share or save the statistics", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("analysis-text-share")
                    .id(textURL)
                Text(textURL.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        } header: {
            Text("Table")
        } footer: {
            Text("The groups, then the test, as CSV; or the figure caption sentences and the same tables as text.")
        }
    }

    private func plotHeight(_ scene: PlotScene) -> CGFloat {
        scene.kind == .survival ? 520 : 360
    }

    /// the Statistics rows: counts and spread per group, then the test (the way the Plot tab's rows read)
    private func statLines(_ o: AnalysisOutcome) -> [StatLine] {
        var lines: [StatLine] = [StatLine("Grouping", o.groupingName)]
        func g(_ v: Double?) -> String { v.map { String(format: "%.4g", $0) } ?? "NA" }
        let unit = model.meta?.tte.first { $0.name == o.variable }?.unitSuffix ?? ""
        if o.result.refused == nil {
            lines.append(StatLine("Samples compared", "\(o.result.n.formatted()) of \(o.assignment.nUniverse.formatted())"))
        }
        switch o.kind {
        case .numeric:
            for r in o.result.groups {
                lines.append(StatLine("\(r.group) (n = \(r.n.formatted()))", "median \(g(r.median)), IQR \(g(r.q1)) to \(g(r.q3))"))
            }
        case .categorical:
            for r in o.result.groups {
                let parts = o.result.levels.filter { $0.group == r.group && $0.count > 0 }
                    .map { "\($0.level) \($0.count) (\(String(format: "%.0f", $0.prop * 100))%)" }
                lines.append(StatLine("\(r.group) (n = \(r.n.formatted()))", parts.joined(separator: ", ")))
            }
        case .survival:
            for r in o.result.groups {
                let median = r.medianSurvival == "NR" ? "NR" : (r.medianSurvival ?? "NA") + unit
                lines.append(StatLine("\(r.group) (n = \(r.n.formatted()))", "\(r.events ?? 0) events, median \(median)"))
            }
        }
        for t in o.result.test {
            lines.append(StatLine(t.term == "group" ? "Test" : t.term, t.method))
            if let s = t.statistic { lines.append(StatLine(statisticName(t.method), g(s))) }
            if let df = t.df { lines.append(StatLine("df", t.method.hasPrefix("Welch") ? String(format: "%.3g", df) : String(Int(df.rounded())))) }
            lines.append(StatLine("p", Stats.pValueString(t.p)))
        }
        return lines
    }
    private func statisticName(_ method: String) -> String {
        switch method {
        case "Wilcoxon rank-sum": return "W"
        case "Welch t-test": return "t"
        case "Welch ANOVA": return "F"
        default: return "Chi-squared"
        }
    }

    // MARK: the screen

    @ViewBuilder private func screenSection(_ s: AnalysisScreen) -> some View {
        Section {
            if s.filterRevision != model.filter.revision {
                Text("The filters changed after this screen. Screen again to update it.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(s.rows, id: \.variable) { r in
                Button {
                    model.analysis.variable = r.variable
                    run()
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.variable).foregroundStyle(Color.primary)
                            Text(subtitle(r)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if r.p != nil {
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("p \(Stats.pValueString(r.p))").monospacedDigit()
                                Text("BH \(Stats.pValueString(r.pBH))").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .foregroundStyle(Color.primary)
                        }
                    }
                }
                .accessibilityIdentifier("screen-\(r.variable)")
            }
        } header: {
            Text("Screen: \(s.groupingName)")
        } footer: {
            Text("Every clinical variable against these groups, ranked by p; BH is the false-discovery-adjusted p over all the tests that gave one. Variables that could not be tested are last. Tap one to compare it.")
        }
    }

    private func subtitle(_ r: ScreenRow) -> String {
        var parts: [String] = []
        parts.append(r.p == nil ? (r.note ?? "not tested") : "\(r.method), n = \(r.n.formatted())")
        if model.activeFilters.contains(where: { $0.column == r.variable }) { parts.append("also filtered") }
        return parts.joined(separator: "; ")
    }
}
