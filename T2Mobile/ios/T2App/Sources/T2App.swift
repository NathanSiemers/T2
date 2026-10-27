import SwiftUI
import UIKit
import T2Kit

@main
struct T2App: App {
    @State private var model = AppModel()
    init() {
        // the system slider knob is white: on a white row it was barely visible (seen on the
        // Filter screen's range sliders); give every slider a knob in the app's accent colour
        UISlider.appearance().thumbTintColor = UIColor(named: "AccentColor") ?? .systemPurple
    }
    // the tab shown first can be chosen at launch (-t2Tab select|plot|filter|analysis|publish):
    // mac_setup.sh and the UI tests use it to photograph each screen
    @State private var tab = UserDefaults.standard.string(forKey: "t2Tab") ?? "select"
    // the one-time research-use notice (ResearchNoticeView.swift)
    @State private var showNotice = researchNoticeNeeded()

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                SelectView(showPlot: { tab = "plot" })
                    .tabItem { Label("Select", systemImage: "list.bullet") }.tag("select")
                PlotView()
                    .tabItem { Label("Plot", systemImage: "chart.dots.scatter") }.tag("plot")
                FilterView()
                    .tabItem { Label("Filter", systemImage: "slider.horizontal.3") }.tag("filter")
                AnalysisView()
                    .tabItem { Label("Analysis", systemImage: "chart.bar.xaxis") }.tag("analysis")
                PublishView()
                    .tabItem { Label("Publish", systemImage: "square.and.arrow.up") }.tag("publish")
            }
            .environment(model)
            .task { await model.start() }
            .sheet(isPresented: $showNotice) { ResearchNoticeView() }
        }
    }
}

/// What a screen shows instead of its content while there is no dataset: progress, or the
/// problem and a way to try again.
struct NoDatasetView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        if model.failed {
            ContentUnavailableView {
                Label("T2 is not available right now", systemImage: "wifi.exclamationmark")
            } description: {
                VStack(spacing: 8) {
                    Text(model.outageText)
                    if !model.status.isEmpty { Text(model.status).font(.caption2).foregroundStyle(.tertiary) }
                }
            } actions: {
                Button("Try again") { Task { await model.reconnect() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("retry")
            }
            .accessibilityIdentifier("no-connection")
        } else {
            VStack(spacing: 12) {
                ProgressView()
                Text(model.status.isEmpty ? "Loading\u{2026}" : model.status).font(.footnote).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Type a few letters, pick a variable. The server searches the dataset's variable names;
/// before anything is typed, the dataset's clinical columns are offered.
/// With `multiple`, every tap adds a name to a list and the field is ready for the next few
/// letters; one "Add" at the end hands the whole list over (the web site's quick way of
/// naming a handful of probes to filter by).
struct VariablePicker: View {
    let title: String
    let current: String
    var allowNone = true
    /// what the row shows while nothing is chosen
    var placeholder = "none"
    var multiple = false
    var choose: (String) -> Void = { _ in }
    var chooseMany: ([String]) -> Void = { _ in }
    /// optional: numeric rows get the chevron menu (2 / 3 / 4 groups); see VariableSearch
    var quantize: ((String, Int) -> Void)? = nil

    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack {
                Text(title).foregroundStyle(Color.primary)
                Spacer(minLength: 12)
                Text(current.isEmpty ? placeholder : current)
                    .foregroundStyle(Color.secondary).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.secondary.opacity(0.6))
            }
        }
        .accessibilityIdentifier("pick-\(title)")
        .sheet(isPresented: $open) {
            VariableSearch(title: title, current: current, allowNone: allowNone, multiple: multiple, done: { names in
                open = false
                if multiple { chooseMany(names) } else if let n = names.first { choose(n) }
            }, quantize: quantize.map { q in { name, k in open = false; q(name, k) } })
        }
    }
}

struct VariableSearch: View {
    let title: String
    let current: String
    let allowNone: Bool
    var multiple = false
    /// the chosen names (one, or the list in `multiple` mode; [""] = "none")
    let done: ([String]) -> Void
    /// when set, a numeric row gets a small down-arrow menu: "2 / 3 / 4 groups" hands the name and
    /// the number of quantile groups over (a continuous variable used as a derived category).
    /// Nothing is shown on a row whose kind is not known to be numeric.
    var quantize: ((String, Int) -> Void)? = nil

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [String] = []
    @State private var total = 0
    /// what the service says each hit is (section, type, kind), shown under the name
    @State private var hits: [String: TypedHit] = [:]
    @State private var searching = false
    @State private var searchFailed = false
    @State private var chosen: [String] = []
    @FocusState private var typing: Bool

    private var q: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            // ONE list whose sections never come and go: the keyboard keeps its focus while
            // the rows below the field change (with .searchable and a List that switched
            // between different sections, typing stopped after the first letter)
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(multiple ? "type a few letters, tap a name, type the next" : "gene, TP53.mut, clinical variable", text: $query)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($typing)
                            .submitLabel(.search)
                            .accessibilityIdentifier("variable-search")
                        if !query.isEmpty {
                            Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain).accessibilityLabel("Clear")
                        }
                        if searching { ProgressView().controlSize(.small) }
                    }
                    if multiple, !chosen.isEmpty {
                        ForEach(chosen.uniqued(), id: \.self) { name in
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                                Text(name)
                                Spacer()
                                Button { chosen.removeAll { $0 == name } } label: { Image(systemName: "minus.circle").foregroundStyle(.secondary) }
                                    .buttonStyle(.plain).accessibilityLabel("Remove \(name)")
                            }
                            .accessibilityIdentifier("chosen-\(name)")
                        }
                    }
                    if allowNone, !current.isEmpty, !multiple {
                        Button("None (remove \(current))", role: .destructive) { done([""]) }
                    }
                } footer: {
                    if multiple { Text(chosen.isEmpty ? "Each name you tap is kept here; \u{201C}Add\u{201D} puts them all on the Filter screen." : "\(chosen.count) chosen. Keep typing, or tap Add.") }
                }
                Section(header: Text(header)) {
                    if q.isEmpty {
                        ForEach((model.meta?.clinicalColumns ?? []).uniqued(), id: \.self) { name in row(name) }
                    } else if searchFailed {
                        Label("The search did not reach the server. Check the connection.", systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.secondary)
                    } else if results.isEmpty, !searching {
                        Text("No variable of this dataset contains \u{201C}\(q)\u{201D}.").foregroundStyle(.secondary)
                            .accessibilityIdentifier("search-empty")
                    } else {
                        ForEach(results.uniqued(), id: \.self) { name in row(name) }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if multiple {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(chosen.isEmpty ? "Add" : "Add \(chosen.count)") { done(chosen) }
                            .disabled(chosen.isEmpty)
                            .accessibilityIdentifier("add-chosen")
                    }
                }
            }
            .onAppear { typing = true }
            .task(id: query) {
                guard !q.isEmpty else { results = []; searching = false; return }
                searching = true
                // wait for a pause in the typing before asking the server
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                let found = await model.search(q)
                if Task.isCancelled { return }
                searchFailed = found == nil
                results = found?.names ?? []
                hits = found?.hits ?? [:]
                total = found?.total ?? 0
                searching = false
            }
        }
    }

    private var header: String {
        if q.isEmpty { return "Sample and clinical annotation" }
        if searchFailed || (results.isEmpty && !searching) { return "Search" }
        if total > results.count { return "\(results.count) of \(total.formatted()) matching names; type more letters to narrow" }
        return "\(results.count) match\(results.count == 1 ? "" : "es")"
    }

    /// "mutation, categorical": what the service says a search hit is (its `hits_typed`); nothing for a name it did not type
    private func kindLine(_ name: String) -> String? {
        guard !q.isEmpty, let h = hits[name] else { return nil }
        let what: String
        switch h.section {
        case "handle": what = "sample grouping"
        case "clinical": what = "clinical"
        default: what = model.meta?.typeLabel(for: h.type) ?? h.type
        }
        return "\(what), \(h.isNumeric ? "numeric" : "categorical")"
    }

    /// is this row a number for certain? A search hit says so (`kind`); a clinical column listed
    /// before any typing is known once it is loaded.
    private func isNumeric(_ name: String) -> Bool {
        if !q.isEmpty { return hits[name]?.isNumeric ?? false }
        return model.column(name)?.isNumeric ?? false
    }

    @ViewBuilder private func row(_ name: String) -> some View {
        if let quantize, isNumeric(name) {
            HStack {
                Button { pick(name) } label: {
                    HStack {
                        rowText(name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(name)
                Menu {
                    ForEach(2...4, id: \.self) { k in Button("\(k) groups") { quantize(name, k) } }
                } label: {
                    Image(systemName: "chevron.down").font(.footnote.weight(.semibold)).padding(.horizontal, 8).padding(.vertical, 6)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Split \(name) into groups").accessibilityIdentifier("quantize-\(name)")
                if (multiple && chosen.contains(name)) || name == current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        } else {
            Button { pick(name) } label: {
                HStack {
                    rowText(name)
                    Spacer()
                    if (multiple && chosen.contains(name)) || name == current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                }
            }
            .accessibilityIdentifier(name)
        }
    }

    private func rowText(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).foregroundStyle(Color.primary)
            if let kind = kindLine(name) { Text(kind).font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private func pick(_ name: String) {
        if multiple {
            if !chosen.contains(name) { chosen.append(name) }
            query = ""
            typing = true
        } else {
            done([name])
        }
    }
}

struct ExtraRows: View {
    let title: String
    let names: [String]
    let slot: AppModel.ListSlot
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(names.uniqued(), id: \.self) { name in
            HStack {
                Text(name)
                Spacer()
                Text(slot == .condition ? "removed" : "combined").font(.footnote).foregroundStyle(.secondary)
                Button { model.remove(name, from: slot) } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(Color.red)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(name)")
                .accessibilityIdentifier("remove-\(name)")
            }
        }
        VariablePicker(title: title, current: "", allowNone: false, placeholder: "add", multiple: true,
                       chooseMany: { names in Task { for v in names { await model.add(v, to: slot) } } })
    }
}

/// One of the sample groups to choose from: a row with a check mark on the one in use.
struct GroupRow: View {
    let label: String
    let description: String
    let isOn: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).foregroundStyle(.primary)
                    if !description.isEmpty { Text(description).font(.footnote).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            }
            .contentShape(Rectangle())  // the whole row takes the tap, not just the text
        }
        .buttonStyle(.plain)        // (a List button is otherwise all accent colour)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "chosen" : "not chosen")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct SelectView: View {
    let showPlot: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.meta == nil {
                    NoDatasetView()
                } else {
                    form
                }
            }
            .navigationTitle("T2")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { about = true } label: { Image(systemName: "questionmark.circle") }
                        .accessibilityLabel("About T2").accessibilityIdentifier("about")
                }
            }
            .sheet(isPresented: $about) { AboutView() }
        }
    }
    @State private var about = false

    // (the survival hint has its own line under the X picker)
    private let variablesHelp = "Genes, mutations (TP53.mut), copy number, signatures or clinical annotation. Two numbers give a scatter plot; a category on X gives box plots."

    /// the words of the "Not detected" control (the service's option names)
    private static func fillName(_ option: String) -> String {
        switch option {
        case "na": return "Missing"
        case "zero": return "Zero"
        case "floor": return "Floor"
        default: return option
        }
    }

    /// the quantize chip under a row: shown only while the slot's variable is a number
    @ViewBuilder private func cutChip(_ name: String, cut: Int, id: String, set: @escaping (Int) -> Void) -> some View {
        if !name.isEmpty, model.column(name)?.isNumeric == true {
            Picker("Use as", selection: Binding(get: { cut }, set: set)) {
                Text("values").tag(0)
                ForEach(2...4, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Groups of \(name)")
            .accessibilityIdentifier(id)
        }
    }

    @ViewBuilder private var form: some View {
        @Bindable var model = model
        Form {
            Section("Data set") {
                // a dataset, or one collection of a dataset that holds several (TCGA-TARGET-GTEx:
                // GTEx normal tissues, TARGET pediatric cancers, TCGA tumors)
                Picker("Data set", selection: Binding(get: { model.sourceID },
                                                      set: { id in Task { await model.select(source: id) } })) {
                    ForEach(model.sources) { Text($0.label).tag($0.id) }
                }
                .accessibilityIdentifier("dataset-picker")
                .disabled(model.busy)      // (one opening at a time)
                if let m = model.meta {
                    let n = model.fixedPreset == nil ? m.nSamples : model.selectedCount()
                    Text("\(m.title)\n\(n.formatted()) samples, \(m.nProbes.formatted()) variables")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("dataset-summary")
                }
            }
            Section {
                VariablePicker(title: "X", current: model.x, allowNone: false, choose: { v in Task { await model.setVariable(.x, to: v) } },
                               quantize: { v, k in Task { await model.setVariable(.x, to: v, cut: k) } })
                cutChip(model.x, cut: model.xCut, id: "quant-x") { model.xCut = $0 }
                // survival is the app's strongest analysis: say where it is, when the dataset has time-to-event variables
                if let hint = model.meta?.survivalHintShort, !hint.isEmpty {
                    Text(hint).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("survival-hint-select")
                }
                VariablePicker(title: "Y", current: model.y, allowNone: false, choose: { v in Task { await model.setVariable(.y, to: v) } },
                               quantize: { v, k in Task { await model.setVariable(.y, to: v, cut: k) } })
                cutChip(model.y, cut: model.yCut, id: "quant-y") { model.yCut = $0 }
                VariablePicker(title: "Color", current: model.colorLabel, choose: { v in Task { await model.setVariable(.color, to: v) } },
                               quantize: { v, k in Task { await model.setVariable(.color, to: v, cut: k) } })
                cutChip(model.color, cut: model.colorCut, id: "quant-color") { model.colorCut = $0 }
                VariablePicker(title: "Size", current: model.size) { v in Task { await model.setVariable(.size, to: v) } }
                VariablePicker(title: "Graph for each", current: model.facet, choose: { v in Task { await model.setVariable(.facet, to: v) } },
                               quantize: { v, k in Task { await model.setVariable(.facet, to: v, cut: k) } })
                cutChip(model.facet, cut: model.facetCut, id: "quant-facet") { model.facetCut = $0 }
                // "Not detected": only where the values answer for the plotted variables offers more than missing
                if model.fillOptions.count > 1 {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Not detected", selection: Binding(get: { model.fill }, set: { f in Task { await model.setFill(f) } })) {
                            ForEach(model.fillOptions, id: \.self) { Text(Self.fillName($0)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("fill-picker")
                        Text("Tested samples without a measured value; samples never analyzed stay missing.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if !model.availableCohorts.isEmpty {
                    let levels = model.availableCohorts
                    NavigationLink {
                        CohortChooser()
                    } label: {
                        LabeledContent("Cohorts", value: model.chosenCohorts.map { "\($0.count) of \(levels.count)" } ?? "all \(levels.count)")
                    }
                    .accessibilityIdentifier("cohorts")
                }
            } header: {
                Text("Variables")
            } footer: {
                Text(variablesHelp)
            }
            Section {
                Button { showPlot() } label: { Label("Plot", systemImage: "chart.dots.scatter").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("plot-button")
            }
            if !model.status.isEmpty {
                Section { Text(model.status).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("status") }
            }
            // the dataset's ready-made subsets (its default_filters table): the groups one can
            // choose from (one at a time), then the exclusions (any number); only the choices
            // that make a difference within the chosen data source are shown
            let groups = model.groupChoices
            let exclusions = model.exclusionChoices
            if !groups.isEmpty || !exclusions.isEmpty {
                Section {
                    if !groups.isEmpty {
                        GroupRow(label: "All samples", description: model.fixedPreset.map { "Everything in \($0)." } ?? "", isOn: model.chosenGroup == nil) { model.choose(group: nil) }
                            .accessibilityIdentifier("group-all")
                        ForEach(groups) { p in
                            GroupRow(label: p.label, description: p.description, isOn: model.chosenGroup == p.label) { model.choose(group: p.label) }
                                .accessibilityIdentifier("group-\(p.label)")
                        }
                    }
                    ForEach(exclusions) { p in
                        Toggle(isOn: Binding(get: { model.activePresets.contains(p.label) }, set: { _ in model.toggle(preset: p.label) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.label)
                                if !p.description.isEmpty { Text(p.description).font(.footnote).foregroundStyle(.secondary) }
                            }
                        }
                        .accessibilityIdentifier("preset-\(p.label)")
                    }
                } header: {
                    Text("Samples")
                } footer: {
                    Text("\(model.selectedCount().formatted()) of \(model.sourceCount.formatted()) samples in use. Narrow them further on the Filter tab.")
                        .accessibilityIdentifier("select-count")
                }
            } else {
                Section {
                    Text("\(model.selectedCount().formatted()) of \(model.sourceCount.formatted()) samples in use. Narrow them on the Filter tab.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("select-count")
                } header: {
                    Text("Samples")
                }
            }
            Section {
                ExtraRows(title: "Add to X", names: model.xMore, slot: .xMore)
                ExtraRows(title: "Add to Y", names: model.yMore, slot: .yMore)
                if !model.yMore.isEmpty {
                    Toggle("Plot Y probes individually", isOn: Binding(get: { model.yIndividually }, set: { model.setIndividualY($0) }))
                        .accessibilityIdentifier("y-individually")
                }
                ExtraRows(title: "Remove influences of", names: model.condition, slot: .condition)
                if !model.condition.isEmpty {
                    Picker("Remove them from", selection: $model.conditionOn) {
                        Text("X").tag(PlotRequest.ConditionTarget.x)
                        Text("Y").tag(PlotRequest.ConditionTarget.y)
                        Text("both").tag(PlotRequest.ConditionTarget.both)
                    }
                    .pickerStyle(.segmented)
                }
            } header: {
                Text("Combine and adjust")
            } footer: {
                Text("Several numeric variables on one axis are combined into one marker: the median of their z-scores. Plotted individually, every sample appears once per Y probe, with the probe as the colour; choose a colour of your own and there is one graph per probe instead. \u{201C}Remove influences of\u{201D} replaces X or Y by what a linear fit on the chosen numeric variables leaves unexplained.")
            }
        }
        .overlay(alignment: .top) {
            if model.busy { ProgressView().padding(8).background(.regularMaterial, in: Capsule()).padding(.top, 4) }
        }
    }
}
