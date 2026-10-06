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
    // the tab shown first can be chosen at launch (-t2Tab select|plot|filter|publish):
    // mac_setup.sh and the UI tests use it to photograph each screen
    @State private var tab = UserDefaults.standard.string(forKey: "t2Tab") ?? "select"

    var body: some Scene {
        WindowGroup {
            TabView(selection: $tab) {
                SelectView(showPlot: { tab = "plot" })
                    .tabItem { Label("Select", systemImage: "list.bullet") }.tag("select")
                PlotView()
                    .tabItem { Label("Plot", systemImage: "chart.dots.scatter") }.tag("plot")
                FilterView()
                    .tabItem { Label("Filter", systemImage: "slider.horizontal.3") }.tag("filter")
                PublishView()
                    .tabItem { Label("Publish", systemImage: "square.and.arrow.up") }.tag("publish")
            }
            .environment(model)
            .task { await model.start() }
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
                Label("Cannot reach T2", systemImage: "wifi.exclamationmark")
            } description: {
                Text(model.status.isEmpty ? "The data service did not answer." : model.status)
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

    @Environment(AppModel.self) private var model
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
            VariableSearch(title: title, current: current, allowNone: allowNone, multiple: multiple) { names in
                open = false
                if multiple { chooseMany(names) } else if let n = names.first { choose(n) }
            }
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

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [String] = []
    @State private var total = 0
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
                        ForEach(chosen, id: \.self) { name in
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
                        ForEach(model.meta?.clinicalColumns ?? [], id: \.self) { name in row(name) }
                    } else if searchFailed {
                        Label("The search did not reach the server. Check the connection.", systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.secondary)
                    } else if results.isEmpty, !searching {
                        Text("No variable of this dataset contains \u{201C}\(q)\u{201D}.").foregroundStyle(.secondary)
                            .accessibilityIdentifier("search-empty")
                    } else {
                        ForEach(results, id: \.self) { name in row(name) }
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

    private func row(_ name: String) -> some View {
        Button {
            if multiple {
                if !chosen.contains(name) { chosen.append(name) }
                query = ""
                typing = true
            } else {
                done([name])
            }
        } label: {
            HStack {
                Text(name).foregroundStyle(Color.primary)
                Spacer()
                if multiple, chosen.contains(name) { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                else if name == current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
        .accessibilityIdentifier(name)
    }
}

struct ExtraRows: View {
    let title: String
    let names: [String]
    let slot: AppModel.ListSlot
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(names, id: \.self) { name in
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

    private var variablesHelp: String {
        var s = "Genes, mutations (TP53.mut), copy number, signatures or clinical annotation. Two numbers give a scatter plot; a category on X gives box plots."
        if let endpoints = model.meta?.usableSurvivalEndpoints, !endpoints.isEmpty {
            s += " A survival endpoint on X (\(endpoints.joined(separator: ", "))) gives Kaplan-Meier curves by groups of Y."
        }
        return s
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
                if let m = model.meta {
                    let n = model.fixedPreset == nil ? m.nSamples : model.filter.selectedCount()
                    Text("\(m.title)\n\(n.formatted()) samples, \(m.nProbes.formatted()) variables")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("dataset-summary")
                }
            }
            Section {
                VariablePicker(title: "X", current: model.x, allowNone: false) { v in Task { await model.setVariable(.x, to: v) } }
                VariablePicker(title: "Y", current: model.y, allowNone: false) { v in Task { await model.setVariable(.y, to: v) } }
                VariablePicker(title: "Color", current: model.color) { v in Task { await model.setVariable(.color, to: v) } }
                VariablePicker(title: "Size", current: model.size) { v in Task { await model.setVariable(.size, to: v) } }
                VariablePicker(title: "Graph for each", current: model.facet) { v in Task { await model.setVariable(.facet, to: v) } }
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
            // the dataset's ready-made subsets (its default_filters table)
            if let presets = model.meta?.presets, !presets.isEmpty {
                Section {
                    ForEach(presets) { p in
                        Toggle(isOn: Binding(get: { model.activePresets.contains(p.label) }, set: { _ in model.toggle(preset: p.label) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.label)
                                if p.label == model.fixedPreset {
                                    Text("The chosen data set; always on.").font(.footnote).foregroundStyle(.secondary)
                                } else if !p.description.isEmpty { Text(p.description).font(.footnote).foregroundStyle(.secondary) }
                            }
                        }
                        .disabled(p.label == model.fixedPreset)
                        .accessibilityIdentifier("preset-\(p.label)")
                    }
                } header: {
                    Text("Samples")
                } footer: {
                    Text("\(model.filter.selectedCount().formatted()) of \(model.filter.sampleCount.formatted()) samples in use. Narrow them further on the Filter tab.")
                        .accessibilityIdentifier("select-count")
                }
            }
            Section {
                ExtraRows(title: "Add to X", names: model.xMore, slot: .xMore)
                ExtraRows(title: "Add to Y", names: model.yMore, slot: .yMore)
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
                Text("Several numeric variables on one axis are combined into one marker: the median of their z-scores. \u{201C}Remove influences of\u{201D} replaces X or Y by what a linear fit on the chosen numeric variables leaves unexplained.")
            }
        }
        .overlay(alignment: .top) {
            if model.busy { ProgressView().padding(8).background(.regularMaterial, in: Capsule()).padding(.top, 4) }
        }
    }
}
