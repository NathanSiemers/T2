// NOT YET COMPILED: written on a machine without Xcode. Expect small fixes on first build.
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
                SelectView().tabItem { Label("Select", systemImage: "list.bullet") }.tag("select")
                PlotView().tabItem { Label("Plot", systemImage: "chart.dots.scatter") }.tag("plot")
                FilterView().tabItem { Label("Filter", systemImage: "slider.horizontal.3") }.tag("filter")
                PublishView().tabItem { Label("Publish", systemImage: "square.and.arrow.up") }.tag("publish")
            }
            .environment(model)
            .task { await model.start() }
        }
    }
}

/// Type a few letters, pick a variable (the server searches the dataset's variable names).
struct VariablePicker: View {
    let title: String
    let current: String
    let choose: (String) -> Void
    @Environment(AppModel.self) private var model
    @State private var open = false
    @State private var query = ""
    @State private var results: [String] = []

    var body: some View {
        Button { open = true } label: {
            HStack { Text(title); Spacer(); Text(current.isEmpty ? "none" : current).foregroundStyle(.secondary) }
        }
        .sheet(isPresented: $open) {
            NavigationStack {
                List {
                    if !current.isEmpty { Button("None", role: .destructive) { choose(""); open = false } }
                    ForEach(results, id: \.self) { name in Button(name) { choose(name); open = false } }
                }
                .navigationTitle(title)
                .searchable(text: $query, prompt: "gene, mutation (TP53.mut), clinical variable")
                .task(id: query) { results = await model.search(query) }
            }
        }
    }
}

struct SelectView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section("Data set") {
                    Picker("Data set", selection: Binding(get: { model.datasetName ?? "" },
                                                          set: { name in Task { await model.select(dataset: name) } })) {
                        ForEach(model.datasets) { Text($0.label).tag($0.name) }
                    }
                    if let m = model.meta { Text("\(m.nSamples) samples, \(m.nProbes) variables").font(.footnote).foregroundStyle(.secondary) }
                }
                Section("Variables") {
                    VariablePicker(title: "X", current: model.x) { v in Task { await model.setVariable(\.x, to: v) } }
                    VariablePicker(title: "Y", current: model.y) { v in Task { await model.setVariable(\.y, to: v) } }
                    VariablePicker(title: "Color", current: model.color) { v in Task { await model.setVariable(\.color, to: v) } }
                }
                // the dataset's ready-made subsets (its default_filters table)
                if let presets = model.meta?.presets, !presets.isEmpty {
                    Section("Samples") {
                        ForEach(presets) { p in
                            Toggle(isOn: Binding(get: { model.activePresets.contains(p.label) }, set: { _ in model.toggle(preset: p.label) })) {
                                VStack(alignment: .leading) { Text(p.label); Text(p.description).font(.footnote).foregroundStyle(.secondary) }
                            }
                        }
                        Text("\(model.filter.selectedCount()) of \(model.filter.sampleCount) samples selected").font(.footnote)
                    }
                }
                Section("Server") {
                    TextField("Service address", text: $model.baseURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Reconnect") { Task { await model.start() } }
                }
                if !model.status.isEmpty { Section { Text(model.status).font(.footnote) } }
            }
            .navigationTitle("T2")
            .overlay { if model.busy { ProgressView() } }
        }
    }
}

struct PlotView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                if let data = model.plotData() {
                    PlotCanvas(data: data, style: model.style).frame(height: 420).padding(.horizontal, 4)
                    Text("\(data.selected) of \(data.universe) samples pass the filters").font(.footnote).foregroundStyle(.secondary)
                    if let xv = data.x.numbers {
                        let rows = data.keep.indices.filter { data.keep[$0] }
                        if let l = Stats.regression(x: rows.map { xv[$0] }, y: rows.map { data.y[$0] }) {
                            Text(String(format: "n = %d   r = %.3f   slope = %.3g", l.n, l.r, l.slope)).font(.footnote.monospaced())
                        }
                    }
                } else {
                    ContentUnavailableView("Nothing to plot", systemImage: "chart.dots.scatter",
                                           description: Text("Choose X and a numeric Y on the Select tab."))
                }
                Form {
                    Section("Appearance") {
                        LabeledContent("Point size") { Slider(value: $model.style.pointSize, in: 0...10) }
                        LabeledContent("Transparency") { Slider(value: $model.style.alpha, in: 0.02...1) }
                        Stepper("Title \(Int(model.style.titleSize)) pt", value: $model.style.titleSize, in: 0...40)
                        Stepper("Axis titles \(Int(model.style.axisTitleSize)) pt", value: $model.style.axisTitleSize, in: 0...40)
                        Stepper("Axis labels \(Int(model.style.axisTextSize)) pt", value: $model.style.axisTextSize, in: 0...40)
                        Toggle("Legend", isOn: $model.style.showLegend)
                        Toggle("Fit line", isOn: $model.style.showFit)
                    }
                }
                .frame(height: 420)
            }
            .navigationTitle("Plot")
        }
    }
}
