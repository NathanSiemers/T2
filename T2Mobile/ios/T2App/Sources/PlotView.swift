import SwiftUI
import T2Kit

/// The plot of the current selections, with what the website prints around it: notes,
/// statistics, the sample counts; then the options and the appearance settings.
struct PlotView: View {
    @Environment(AppModel.self) private var model
    @State private var tableURL: URL?
    @State private var fullScreen = false
    /// what the screen showed last: a changed plot is shown from its top again
    @State private var lastShown = ""

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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { fullScreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                        .accessibilityLabel("Plot full screen").accessibilityIdentifier("plot-fullscreen")
                        .disabled(model.meta == nil)
                }
            }
            .fullScreenCover(isPresented: $fullScreen) { FullScreenPlot() }
        }
    }

    @ViewBuilder private var content: some View {
        @Bindable var model = model
        let scene = model.scene(fitLine: model.style.showFit)
        // the plot is the point of the app: it takes the whole visible screen (full width, the
        // height left under the bars, in either orientation); the notes and settings follow
        GeometryReader { geo in
        ScrollViewReader { proxy in
        List {
            Section {
                // the count first: it stays on screen however tall the plot and its legend are
                Text(countLine(scene))
                    .font(.footnote).foregroundStyle(.secondary)
                    .listRowSeparator(.hidden)
                    .accessibilityIdentifier("plot-count")
                    .id("plot-top")
                SceneCanvas(scene: scene, style: model.style, legendRoom: true)
                    .frame(height: plotHeight(scene, visible: geo.size))
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .accessibilityElement()
                    .accessibilityLabel(scene.kind == .empty ? scene.message : scene.title)
                    .accessibilityIdentifier("plot")
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
                if scene.panels.count > 1 {
                    Stepper(model.style.facetColumns == 0 ? "Panels per row: automatic (\(SceneDrawing.panelColumns(scene.panels.count, model.style)))" : "Panels per row: \(model.style.facetColumns)",
                            value: $model.style.facetColumns, in: 0...8)
                        .accessibilityIdentifier("facet-columns")
                }
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
        .listStyle(.plain)
        .overlay(alignment: .top) {
            if model.busy { ProgressView().padding(8).background(.regularMaterial, in: Capsule()).padding(.top, 4) }
        }
        .onAppear {
            // coming back to a NEW plot (other variables, other samples): start at its top, not
            // where the options of the previous one were left
            let key = "\(scene.title)|\(scene.n)|\(scene.panels.count)"
            if key != lastShown {
                lastShown = key
                proxy.scrollTo("plot-top", anchor: .top)
            }
        }
        }
        }
    }

    /// Room for the plot: the visible screen (less a line for the count), more for a grid of
    /// many panels, for a survival plot's risk table, and for a legend that goes under the
    /// panel (every entry is shown; the screen scrolls).
    private func plotHeight(_ scene: PlotScene, visible: CGSize) -> CGFloat {
        if scene.kind == .empty { return 220 }
        let screen = max(240, visible.height - 44)   // less the count line above
        let n = scene.panels.count
        var h = screen
        if n > 1 {
            let columns = SceneDrawing.panelColumns(n, model.style)
            let rows = (n + columns - 1) / columns
            // every panel at least about a third of the screen high
            h = max(screen, min(4000, CGFloat(rows) * max(170, screen / 3) + 60))
        } else if scene.kind == .survival {
            h = max(screen, 500)
        }
        return h + SceneDrawing.legendHeightBelow(scene, model.style, width: visible.width)
    }

    private func countLine(_ scene: PlotScene) -> String {
        let passing = model.filter.selectedCount(), all = model.filter.sampleCount
        if scene.kind == .empty { return "\(passing.formatted()) of \(all.formatted()) samples pass the filters" }
        return "\(scene.n.formatted()) samples plotted; \(passing.formatted()) of \(all.formatted()) pass the filters"
    }
}

/// Only the plot, as large as the screen allows (turn the phone for a wide figure). The
/// close button fades out after a moment so that a screenshot shows the plot alone, and
/// comes back at the next touch.
struct FullScreenPlot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showClose = true
    @State private var hide: Task<Void, Never>?

    var body: some View {
        let scene = model.scene(fitLine: model.style.showFit)
        ZStack(alignment: .topTrailing) {
            Color(.systemBackground).ignoresSafeArea()
            SceneCanvas(scene: scene, style: model.style)
                .padding(10)
                .accessibilityElement()
                .accessibilityLabel(scene.kind == .empty ? scene.message : scene.title)
                .accessibilityIdentifier("plot-full")
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.secondary)
                    .padding(12).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(showClose ? 1 : 0)
            .animation(.easeInOut(duration: 0.4), value: showClose)
            .accessibilityLabel("Close").accessibilityIdentifier("plot-fullscreen-close")
            .accessibilityHidden(!showClose)
        }
        .contentShape(Rectangle())
        .onTapGesture { reveal() }
        .onAppear { reveal() }
        .onDisappear { hide?.cancel() }
    }

    /// show the close button, and hide it again after a short while
    private func reveal() {
        showClose = true
        hide?.cancel()
        hide = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { showClose = false }
        }
    }
}
