import SwiftUI
import T2Kit

@main
struct T2App: App {
    @State private var model = AppModel()
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
struct VariablePicker: View {
    let title: String
    let current: String
    var allowNone = true
    /// what the row shows while nothing is chosen
    var placeholder = "none"
    let choose: (String) -> Void

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
            VariableSearch(title: title, current: current, allowNone: allowNone) { name in
                open = false
                choose(name)
            }
        }
    }
}

struct VariableSearch: View {
    let title: String
    let current: String
    let allowNone: Bool
    let choose: (String) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [String] = []
    @State private var searching = false
    @State private var searchFailed = false

    var body: some View {
        NavigationStack {
            List {
                if allowNone, !current.isEmpty {
                    Button("None (remove \(current))", role: .destructive) { choose("") }
                }
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section("Sample and clinical annotation") {
                        ForEach(model.meta?.clinicalColumns ?? [], id: \.self) { name in row(name) }
                    }
                } else if searchFailed {
                    Label("The search did not reach the server. Check the connection.", systemImage: "wifi.exclamationmark")
                        .foregroundStyle(.secondary)
                } else if results.isEmpty, !searching {
                    Text("No variable of this dataset contains \u{201C}\(query)\u{201D}.").foregroundStyle(.secondary)
                        .accessibilityIdentifier("search-empty")
                } else {
                    Section("\(results.count) match\(results.count == 1 ? "" : "es")\(results.count >= 60 ? " shown; type more to narrow" : "")") {
                        ForEach(results, id: \.self) { name in row(name) }
                    }
                }
            }
            .overlay { if searching && results.isEmpty { ProgressView() } }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "gene, TP53.mut, clinical variable")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard !q.isEmpty else { results = []; searching = false; return }
                searching = true
                // wait for a pause in the typing before asking the server
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { return }
                let found = await model.search(q)
                if Task.isCancelled { return }
                searchFailed = found == nil
                results = found ?? []
                searching = false
            }
        }
    }

    private func row(_ name: String) -> some View {
        Button { choose(name) } label: {
            HStack {
                Text(name).foregroundStyle(Color.primary)
                Spacer()
                if name == current { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }
}

/// A list of extra variables (more X, more Y, covariates): each with a remove button, then
/// a row to add another.
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
        VariablePicker(title: title, current: "", allowNone: false, placeholder: "add") { v in
            Task { await model.add(v, to: slot) }
        }
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
        }
    }

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
                Picker("Data set", selection: Binding(get: { model.datasetName ?? "" },
                                                      set: { name in Task { await model.select(dataset: name) } })) {
                    ForEach(model.datasets) { Text($0.label).tag($0.name) }
                }
                .accessibilityIdentifier("dataset-picker")
                if let m = model.meta {
                    Text("\(m.title)\n\(m.nSamples.formatted()) samples, \(m.nProbes.formatted()) variables")
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
                if let levels = model.filter.columns["cohort"]?.levels, !levels.isEmpty {
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
                                if !p.description.isEmpty { Text(p.description).font(.footnote).foregroundStyle(.secondary) }
                            }
                        }
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
            Section {
                TextField("Service address", text: $model.baseURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                Button("Reconnect") { Task { await model.reconnect() } }
            } header: {
                Text("Server")
            } footer: {
                Text("Citing T2: \(t2Citation)")
            }
        }
        .overlay(alignment: .top) {
            if model.busy { ProgressView().padding(8).background(.regularMaterial, in: Capsule()).padding(.top, 4) }
        }
    }
}
