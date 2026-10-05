// NOT YET COMPILED: written on a machine without Xcode. Expect small fixes on first build.
import Foundation
import Observation
import T2Kit

/// Everything the screens share: the chosen dataset, its loaded columns, the variable
/// selections, the active presets and the cross-filter. All computation is local; the
/// server is asked only for columns (APIClient).
@MainActor @Observable
final class AppModel {
    // where the query service is. Development: an SSH tunnel to the server, e.g.
    //   ssh -L 3860:127.0.0.1:3860 <server>      then http://localhost:3860
    var baseURL = UserDefaults.standard.string(forKey: "baseURL") ?? "http://localhost:3860" {
        didSet { UserDefaults.standard.set(baseURL, forKey: "baseURL") }
    }
    private var api: APIClient { APIClient(baseURL: URL(string: baseURL) ?? URL(string: "http://localhost:3860")!) }

    var datasets: [DatasetSummary] = []
    var meta: DatasetMeta?
    var samples: [String] = []
    var filter = CrossFilter(sampleCount: 0)
    var activePresets: Set<String> = []
    var x = "", y = "", color = ""
    var status = ""
    var busy = false

    /// the plot's appearance (shared by the screen and, with its own values, a figure)
    var style = PlotStyle()
    var figure = FigureSpec()

    var datasetName: String? { meta?.dataset }
    func column(_ name: String) -> Column? { name.isEmpty ? nil : filter.columns[name] }

    func start() async {
        await run("Loading datasets") {
            self.datasets = try await self.api.datasets()
            if let first = self.datasets.first, self.meta == nil { try await self.open(first.name) }
        }
    }

    /// switch dataset: everything about the previous one is dropped (its fields may not exist here)
    func open(_ name: String) async throws {
        let m = try await api.meta(name)
        let clin = try await api.clinical(name)
        var cf = CrossFilter(sampleCount: clin.n)
        cf.load(clin.columns)
        meta = m; samples = clin.samples; filter = cf
        activePresets = Set(m.presets.filter(\.isDefault).map(\.label))
        x = m.defaults["x"] ?? ""; y = m.defaults["y"] ?? ""; color = m.defaults["color"] ?? ""
        applyPresets()
        try await ensureLoaded([x, y, color])
        for v in [x, y, color] { filter.add(v) }     // plotted variables are filterable from the start
    }

    func select(dataset name: String) async { await run("Opening \(name)") { try await self.open(name) } }

    /// fetch any of these variables that are not on the device yet
    func ensureLoaded(_ names: [String]) async throws {
        guard let ds = datasetName else { return }
        let need = Array(Set(names.filter { !$0.isEmpty && filter.columns[$0] == nil }))
        guard !need.isEmpty else { return }
        let r = try await api.values(ds, probes: need)
        filter.load(r.columns)
        if !r.missing.isEmpty { status = "Not in this dataset: \(r.missing.joined(separator: ", "))" }
    }

    func setVariable(_ keyPath: ReferenceWritableKeyPath<AppModel, String>, to name: String) async {
        await run("Loading \(name)") {
            try await self.ensureLoaded([name])
            self[keyPath: keyPath] = name
            self.filter.add(name)
        }
    }
    func addFilterColumn(_ name: String) async {
        await run("Loading \(name)") { try await self.ensureLoaded([name]); self.filter.add(name) }
    }
    func search(_ query: String) async -> [String] {
        guard let ds = datasetName else { return [] }
        return (try? await api.searchProbes(ds, query: query, limit: 60).probes) ?? []
    }

    func toggle(preset label: String) {
        if activePresets.contains(label) { activePresets.remove(label) } else { activePresets.insert(label) }
        applyPresets()
    }
    /// the universe = samples in every active preset
    private func applyPresets() {
        guard let m = meta else { return }
        var mask: Mask? = nil
        for p in m.presets where activePresets.contains(p.label) {
            let pm = p.mask(columns: filter.columns, sampleCount: filter.sampleCount)
            mask = mask.map { zip($0, pm).map { $0 && $1 } } ?? pm
        }
        filter.baseMask = mask
    }

    /// the data behind the current plot: rows that pass the filters and have x and y
    func plotData() -> PlotData? {
        guard let xc = column(x), let yc = column(y), let yv = yc.numbers else { return nil }
        let keep = filter.mask()
        return PlotData(x: xc, y: yv, color: column(color), keep: keep, xName: x, yName: y,
                        dataset: meta?.label ?? "", selected: keep.filter { $0 }.count, universe: filter.universeCount())
    }

    private func run(_ what: String, _ work: @escaping () async throws -> Void) async {
        busy = true; status = what + "..."
        do { try await work(); if status == what + "..." { status = "" } }
        catch { status = "\(what) failed: \(error)" }
        busy = false
    }
}
