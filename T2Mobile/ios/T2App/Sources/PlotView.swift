import SwiftUI
import T2Kit

/// The plot of the current selections, with what the website prints around it: notes,
/// statistics, the sample counts; then the options and the appearance settings.
struct PlotView: View {
    @Environment(AppModel.self) private var model
    @State private var tableURL: URL?

    var body: some View {
        NavigationStack {
            Group {
                if model.meta == nil {
                    NoDatasetView()
                } else {
                    content
                }
            }
            .navigationTitle("Plot")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder private var content: some View {
        @Bindable var model = model
        let scene = model.scene(fitLine: model.style.showFit)
        List {
            Section {
                SceneCanvas(scene: scene, style: model.style)
                    .frame(height: plotHeight(scene))
                    .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4))
                    .accessibilityElement()
                    .accessibilityLabel(scene.kind == .empty ? scene.message : scene.title)
                    .accessibilityIdentifier("plot")
                Text(countLine(scene))
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("plot-count")
                if scene.kind == .empty, model.filter.filters.contains(where: \.isActive) {
                    Button("Remove all filters") { model.resetFilters() }
                        .accessibilityIdentifier("reset-filters")
                }
            }
            if !scene.warnings.isEmpty {
                Section("Notes") {
                    ForEach(scene.warnings, id: \.self) { Text($0).font(.footnote) }
                }
            }
            if !scene.stats.isEmpty {
                Section("Statistics") {
                    ForEach(scene.stats, id: \.label) { line in
                        LabeledContent(line.label) { Text(line.value).monospacedDigit() }
                    }
                }
            }
            if !scene.summary.isEmpty {
                Section("Samples") {
                    Text(scene.summary.joined(separator: "\n"))
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .accessibilityIdentifier("plot-summary")
                }
            }
            if model.isSurvival {
                Section("Survival") {
                    Stepper("Marker groups: \(model.kmGroups)", value: $model.kmGroups, in: 2...6)
                        .accessibilityIdentifier("km-groups")
                    Picker("Follow-up", selection: $model.kmMaxDays) {
                        Text("1 year").tag(365.0)
                        Text("2 years").tag(730.0)
                        Text("3 years").tag(1095.0)
                        Text("5 years").tag(1825.0)
                        Text("10 years").tag(3650.0)
                        Text("no limit").tag(0.0)
                    }
                }
            } else {
                Section("Options") {
                    Toggle("Z-score Y", isOn: $model.zscoreY)
                    Toggle("Flip X and Y", isOn: $model.flip)
                    Toggle("Waterfall (order categories by median)", isOn: $model.waterfall)
                    Toggle("Fit line", isOn: $model.style.showFit)
                }
            }
            Section {
                Button("Make the table (CSV)") { tableURL = model.writeTable() }
                    .accessibilityIdentifier("table-make")
                if let tableURL {
                    ShareLink(item: tableURL) { Label("Share or save the table", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("table-share")
                    Text(tableURL.lastPathComponent).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            } header: {
                Text("Table")
            } footer: {
                Text("The samples in use with the plotted variables, one row per sample: the numbers behind the plot.")
            }
            Section("Appearance") {
                LabeledContent("Point size") { Slider(value: $model.style.pointSize, in: 0...10) }
                LabeledContent("Transparency") { Slider(value: $model.style.alpha, in: 0.02...1) }
                Stepper("Title \(Int(model.style.titleSize)) pt", value: $model.style.titleSize, in: 0...40)
                Stepper("Axis titles \(Int(model.style.axisTitleSize)) pt", value: $model.style.axisTitleSize, in: 0...40)
                Stepper("Axis labels \(Int(model.style.axisTextSize)) pt", value: $model.style.axisTextSize, in: 0...40)
                Stepper("Legend \(Int(model.style.legendSize)) pt", value: $model.style.legendSize, in: 0...40)
                Toggle("Legend", isOn: $model.style.showLegend)
                Toggle("Source line", isOn: $model.style.showSourceLine)
            }
        }
        .overlay(alignment: .top) {
            if model.busy { ProgressView().padding(8).background(.regularMaterial, in: Capsule()).padding(.top, 4) }
        }
    }

    /// room for the plot: more for a grid of panels and for a survival plot's risk table
    private func plotHeight(_ scene: PlotScene) -> CGFloat {
        if scene.kind == .empty { return 220 }
        let n = scene.panels.count
        if n > 1 {
            let columns = n <= 4 ? 2 : n <= 9 ? 3 : 4
            let rows = (n + columns - 1) / columns
            return min(1400, CGFloat(rows) * 190 + 110)
        }
        return scene.kind == .survival ? 500 : 430
    }

    private func countLine(_ scene: PlotScene) -> String {
        let passing = model.filter.selectedCount(), all = model.filter.sampleCount
        if scene.kind == .empty { return "\(passing.formatted()) of \(all.formatted()) samples pass the filters" }
        return "\(scene.n.formatted()) samples plotted; \(passing.formatted()) of \(all.formatted()) pass the filters"
    }
}
