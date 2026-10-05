import Foundation
import Observation
import T2Kit

/// Everything the screens share: the chosen dataset, its loaded columns, the variable
/// selections, the active presets and the cross-filter. All computation is local (T2Kit);
/// the server is asked only for columns (APIClient).
///
/// Launch arguments (used by mac_setup.sh and the UI tests; `-name value`):
///   -t2Reset YES      ignore the saved service address
///   -t2Tab plot       the tab shown first (select | plot | filter | publish); read in T2App
///   -t2Dataset DEMO   the dataset opened first
///   -t2X, -t2Y, -t2Color, -t2Size   variables instead of the dataset's defaults
///   -t2Service URL    another service address for this launch
func initialServiceAddress() -> String {
    let defaults = UserDefaults.standard
    if let forThisLaunch = defaults.string(forKey: "t2Service"), !forThisLaunch.isEmpty { return forThisLaunch }
    if !defaults.bool(forKey: "t2Reset"), let saved = defaults.string(forKey: "baseURL"), !saved.isEmpty { return saved }
    return t2DefaultService
}

@MainActor @Observable
final class AppModel {
    // (one stored property per line: @Observable cannot track `var a = "", b = ""`)

    /// where the query service is; kept between launches (saved by reconnect())
    var baseURL: String = initialServiceAddress()
    private var api: APIClient { APIClient(baseURL: URL(string: baseURL) ?? URL(string: t2DefaultService)!) }

    var datasets: [DatasetSummary] = []
    var meta: DatasetMeta?
    var samples: [String] = []
    var filter = CrossFilter(sampleCount: 0)
    var activePresets: Set<String> = []

    // what is plotted
    var x = ""
    var y = ""
    var color = ""
    var size = ""
    /// "Graph for each": one panel per level of this categorical variable
    var facet = ""
    /// survival plots: number of marker groups, and the follow-up limit in days (0 = none)
    var kmGroups = 3
    var kmMaxDays = 1825.0
    var zscoreY = false
    var flip = false
    var waterfall = false

    /// what is going on, for the user: "Loading CD8A...", or the last problem
    var status = ""
    var busy = false
    /// the service could not be reached or the dataset could not be opened
    var failed = false

    /// the plot's appearance on screen, and the figure (with its own print-scale appearance)
    var style = PlotStyle()
    var figure = FigureSpec()

    var datasetName: String? { meta?.dataset }
    func column(_ name: String) -> Column? { name.isEmpty ? nil : filter.columns[name] }

    // MARK: loading

    /// the user changed the service address (or wants to try again)
    func reconnect() async {
        baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseURL.isEmpty { baseURL = t2DefaultService }
        UserDefaults.standard.set(baseURL, forKey: "baseURL")
        meta = nil
        datasets = []
        filter = CrossFilter(sampleCount: 0)
        await start()
    }

    func start() async {
        failed = false
        await run("Loading datasets") {
            self.datasets = try await self.api.datasets()
            let wanted = UserDefaults.standard.string(forKey: "t2Dataset")
            let first = self.datasets.first { $0.name == wanted } ?? self.datasets.first
            if let first, self.meta == nil { try await self.open(first.name, launch: true) }
        }
        failed = meta == nil
        // one line on standard output when the first data are on screen (or could not be
        // loaded): mac_setup.sh waits for it before taking a picture. Written unbuffered:
        // print() would sit in a buffer when the output goes to a file.
        let line = meta != nil ? "T2-READY \(meta?.dataset ?? "")\n" : "T2-FAILED \(status)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
    }

    /// switch dataset: everything about the previous one is dropped (its variables may not exist here)
    func open(_ name: String, launch: Bool = false) async throws {
        let m = try await api.meta(name)
        let clin = try await api.clinical(name)
        var cf = CrossFilter(sampleCount: clin.n)
        cf.load(clin.columns)
        meta = m
        samples = clin.samples
        filter = cf
        activePresets = Set(m.presets.filter(\.isDefault).map(\.label))
        func first(_ key: String, _ argument: String) -> String {
            (launch ? UserDefaults.standard.string(forKey: argument) : nil) ?? m.defaults[key] ?? ""
        }
        x = first("x", "t2X")
        y = first("y", "t2Y")
        color = first("color", "t2Color")
        size = first("size", "t2Size")
        facet = (launch ? UserDefaults.standard.string(forKey: "t2Facet") : nil) ?? ""
        zscoreY = false
        flip = false
        waterfall = false
        applyPresets()
        try await ensureLoaded([x, y, color, size, facet])
        // a variable the dataset does not have is not kept as a selection
        if column(x) == nil { x = "" }
        if column(y) == nil { y = "" }
        if column(color) == nil { color = "" }
        if column(size) == nil { size = "" }
        if column(facet) == nil { facet = "" }
        for v in [x, y, color, size] { filter.add(v) }     // plotted variables are filterable from the start
    }

    func select(dataset name: String) async {
        guard name != datasetName else { return }
        await run("Opening \(name)") { try await self.open(name) }
    }

    /// fetch any of these variables that are not on the device yet
    func ensureLoaded(_ names: [String]) async throws {
        guard let ds = datasetName else { return }
        let need = Array(Set(names.filter { !$0.isEmpty && filter.columns[$0] == nil })).sorted()
        guard !need.isEmpty else { return }
        let r = try await api.values(ds, probes: need)
        filter.load(r.columns)
        if !r.missing.isEmpty { status = "Not in this dataset: \(r.missing.joined(separator: ", "))" }
    }

    enum Slot { case x, y, color, size, facet }

    func setVariable(_ slot: Slot, to name: String) async {
        await run(name.isEmpty ? "Updating" : "Loading \(name)") {
            try await self.ensureLoaded([name])
            guard name.isEmpty || self.filter.columns[name] != nil else { return }
            switch slot {
            case .x: self.x = name
            case .y: self.y = name
            case .color: self.color = name
            case .size: self.size = name
            case .facet: self.facet = name
            }
            self.filter.add(name)
        }
    }
    func addFilterColumn(_ name: String) async {
        await run("Loading \(name)") {
            try await self.ensureLoaded([name])
            self.filter.add(name)
        }
    }
    /// names matching `query`; nil when the search itself failed
    func search(_ query: String) async -> [String]? {
        guard let ds = datasetName else { return [] }
        return try? await api.searchProbes(ds, query: query, limit: 60).probes
    }

    // MARK: samples

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
            if let old = mask { mask = zip(old, pm).map { $0 && $1 } } else { mask = pm }
        }
        filter.baseMask = mask
    }
    func resetFilters() {
        for f in filter.filters { filter.set(f.column, value: nil, includeMissing: true) }
    }

    // MARK: the plot

    /// The current plot, worked out by T2Kit (PlotBuilder) from the selections and the samples in use.
    func scene(fitLine: Bool) -> PlotScene {
        guard let m = meta else { return .empty(busy ? "Loading\u{2026}" : (status.isEmpty ? "No dataset is open." : status)) }
        var request = PlotRequest(x: [x], y: [y], color: color, size: size, facet: facet)
        request.kmGroups = kmGroups
        request.kmMaxDays = kmMaxDays
        request.zscoreY = zscoreY
        request.flip = flip
        request.waterfall = waterfall
        request.fitLine = fitLine
        let context = PlotBuilder.Context(datasetLabel: m.label, survivalEndpoints: m.usableSurvivalEndpoints)
        return PlotBuilder.build(request, columns: filter.columns, keep: filter.mask(), context: context)
    }

    /// is X a survival endpoint of this dataset (so the plot is a Kaplan-Meier plot)?
    var isSurvival: Bool { meta?.usableSurvivalEndpoints.contains(x) ?? false }

    /// The table behind the plot (the website's "Download Table"): the samples in use, with
    /// the plotted variables, written to a CSV file. Returns nil if there is nothing to write.
    func writeTable() -> URL? {
        guard let m = meta else { return nil }
        var names: [String] = []
        for v in ["cohort", "sample_type", x, y, color, size, facet] + (isSurvival ? [x + ".time"] : [])
        where !v.isEmpty && filter.columns[v] != nil && !names.contains(v) { names.append(v) }
        let csv = TableExport.csv(samples: samples, columns: names.compactMap { filter.columns[$0] }, keep: filter.mask())
        let file = "T2_\(m.dataset)_\(x)_\(y).csv".replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(file)
        do { try csv.write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
        return url
    }

    // MARK: cohorts (the website's Cohort box: a filter on the dataset's cohort column)

    /// the cohorts in use; nil = all
    var chosenCohorts: Set<String>? {
        if case .levels(let s)? = filter.filter("cohort")?.value { return s }
        return nil
    }
    func setCohorts(_ chosen: Set<String>?) {
        guard let all = filter.columns["cohort"]?.levels else { return }
        filter.add("cohort")
        if let chosen, chosen.count < all.count { filter.set("cohort", value: .levels(chosen)) }
        else { filter.set("cohort", value: nil) }
    }

    private func run(_ what: String, _ work: @escaping () async throws -> Void) async {
        busy = true
        status = what + "\u{2026}"
        do {
            try await work()
            if status == what + "\u{2026}" { status = "" }
        } catch {
            status = "\(what) failed: \(error)"
        }
        busy = false
    }
}
