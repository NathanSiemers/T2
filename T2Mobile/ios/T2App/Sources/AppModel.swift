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
    /// the preset that defines the chosen data SOURCE (a named part of a dataset, e.g. "GTEx
    /// normal tissues" of TCGA-TARGET-GTEx): always on, not offered as a switch
    var fixedPreset: String?
    var samples: [String] = []
    var filter = CrossFilter(sampleCount: 0)
    var activePresets: Set<String> = []
    /// the samples of every preset of the open dataset, by label (worked out once per dataset)
    private var presetMasks: [String: Mask] = [:]

    // what is plotted
    var x = ""
    var y = ""
    var color = ""
    var size = ""
    /// "Graph for each": one panel per level of this categorical variable
    var facet = ""
    /// more numeric variables on an axis: combined with the first into the median of their z-scores
    var xMore: [String] = []
    var yMore: [String] = []
    /// several Y probes plotted each on their own (the website's "Plot Y probes individually")
    /// rather than combined; the colour then tells the probes apart unless one is chosen
    var yIndividually = false
    /// the colour chosen before "individually" took it over, given back when it is switched off
    private var colorBeforeIndividual = ""
    /// "Remove influences of": numeric covariates, and the axis they are removed from
    var condition: [String] = []
    var conditionOn = PlotRequest.ConditionTarget.y
    /// survival plots: number of marker groups, and the follow-up limit in days (0 = none)
    var kmGroups = 3
    var kmMaxDays = 1825.0
    var zscoreY = false
    var flip = false
    var waterfall = false

    /// what is going on, for the user: "Loading CD8A...", or the last problem
    var status = ""
    /// the error of the last failed operation (for the explanation when nothing could be loaded)
    var lastError: Error?
    /// what to tell the user when the service could not be reached: their phone, or our server
    var outageText: String {
        if let e = lastError as? URLError,
           [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff].contains(e.code) {
            return "Your phone seems to be offline. T2 needs an internet connection to fetch its data."
        }
        return "The T2 data service is not answering at the moment \u{2014} it may be down for maintenance or a power cut at its home. Please try again in a little while; nothing is wrong with your phone or the app."
    }
    var busy = false
    /// the service could not be reached or the dataset could not be opened
    var failed = false

    /// the plot's appearance on screen, and the figure (with its own print-scale appearance)
    var style = PlotStyle()
    var figure = FigureSpec()

    var datasetName: String? { meta?.dataset }

    /// What the "Data set" menu offers: every dataset, and for a dataset that is really several
    /// collections, each collection on its own (one of the dataset's presets, always on, with
    /// the cohort list and the counts restricted to it).
    struct DataSource: Identifiable, Equatable {
        let dataset: String
        let preset: String?
        let label: String
        var id: String { preset.map { "\(dataset)|\($0)" } ?? dataset }
    }
    /// The parts of a dataset offered as data sources of their own come from the service
    /// (`sources` of /v1/datasets and /meta: a part is the whole of a study, declared in the
    /// dataset's own metadata — GTEx includes its EBV-transformed lymphocyte and cultured
    /// fibroblast "cell lines", the only cell lines in any of the databases, so "Exclude cell
    /// lines" applies to it; TCGA's Toil re-processing is not a part, its data belong to the
    /// TCGA dataset). Until 2026-10-10 the app defined these itself; now nothing about a
    /// dataset is written here.
    var sources: [DataSource] {
        datasets.filter { !$0.isDemo }.flatMap { d -> [DataSource] in
            [DataSource(dataset: d.name, preset: nil, label: d.label)] +
            d.parts.map { DataSource(dataset: d.name, preset: $0.label, label: "\(d.label): \($0.label)") }
        }
    }
    /// the open dataset's presets: the service's parts of it (each a preset that is always
    /// on while it is the data source) and its own (default_filters)
    var allPresets: [Preset] {
        guard let m = meta else { return [] }
        let parts = (m.sources ?? []).filter { !$0.isWhole }.map(\.asPreset)
        let partLabels = Set(parts.map(\.label))
        return parts + m.presets.filter { !partLabels.contains($0.label) }
    }
    var sourceID: String { meta.map { m in fixedPreset.map { "\(m.dataset)|\($0)" } ?? m.dataset } ?? "" }
    var sourceLabel: String { sources.first { $0.id == sourceID }?.label ?? (meta?.label ?? "") }

    func select(source id: String) async {
        guard id != sourceID, let src = sources.first(where: { $0.id == id }) else { return }
        await run("Opening \(src.label)") { try await self.open(src.dataset, preset: src.preset) }
    }

    /// the cohorts that have samples in the chosen data source (all of them for a whole dataset)
    var availableCohorts: [String] {
        guard let col = filter.columns["cohort"], case .categorical(let levels, let codes) = col.data else { return [] }
        guard let mask = filter.baseMask else { return levels }
        var seen = Set<Int>()
        for i in codes.indices where mask[i] && codes[i] >= 0 { seen.insert(codes[i]) }
        return levels.indices.filter { seen.contains($0) }.map { levels[$0] }
    }
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
        lastError = nil
        await run("Loading datasets") {
            self.datasets = try await self.api.datasets()
            let wanted = UserDefaults.standard.string(forKey: "t2Dataset")
            let offered = self.datasets.filter { !$0.isDemo }
            let first = offered.first { $0.name == wanted } ?? offered.first
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
    /// what the user had set up before a dataset switch: kept where the new dataset has the names
    private struct Carried {
        var x = "", y = "", color = "", size = "", facet = ""
        var xMore: [String] = [], yMore: [String] = [], condition: [String] = []
        var conditionOn = PlotRequest.ConditionTarget.y
        var zscoreY = false, flip = false, waterfall = false, yIndividually = false
        var filters: [ColumnFilter] = []
        var names: [String] { [x, y, color, size, facet] + xMore + yMore + condition + filters.map(\.column) }
    }

    func open(_ name: String, launch: Bool = false, preset: String? = nil) async throws {
        // selections and filters are sticky across a switch: everything whose name the new
        // dataset has is kept (filter levels are kept where they exist too); the rest falls
        // back to the new dataset's defaults
        var carried: Carried? = nil
        if meta != nil, !launch {
            carried = Carried(x: x, y: y, color: color, size: size, facet: facet, xMore: xMore, yMore: yMore, condition: condition,
                              conditionOn: conditionOn, zscoreY: zscoreY, flip: flip, waterfall: waterfall, yIndividually: yIndividually, filters: filter.filters)
        }
        var m = try await api.meta(name)
        var clin: Clinical
        do {
            clin = try await api.clinical(name, version: m.version)
        } catch APIClient.APIError.versionChanged {
            // the database was replaced between the two requests: ask once more
            m = try await api.meta(name)
            clin = try await api.clinical(name, version: m.version)
        }
        var cf = CrossFilter(sampleCount: clin.n)
        cf.load(clin.columns)
        meta = m
        samples = clin.samples
        filter = cf
        let presets = allPresets
        presetMasks = Dictionary(presets.map { ($0.label, $0.mask(columns: cf.columns, sampleCount: cf.sampleCount)) }, uniquingKeysWith: { a, _ in a })
        fixedPreset = preset.flatMap { label in presets.contains { $0.label == label } ? label : nil }
        if preset != nil && fixedPreset == nil { status = "This dataset has no part called \u{201C}\(preset ?? "")\u{201D}; showing all of it." }
        activePresets = Set(presets.filter(\.isDefault).map(\.label)).union(fixedPreset.map { [$0] } ?? [])
        func first(_ key: String, _ argument: String) -> String {
            (launch ? UserDefaults.standard.string(forKey: argument) : nil) ?? m.defaults[key] ?? ""
        }
        x = first("x", "t2X")
        y = first("y", "t2Y")
        color = first("color", "t2Color")
        size = first("size", "t2Size")
        facet = (launch ? UserDefaults.standard.string(forKey: "t2Facet") : nil) ?? ""
        xMore = []
        yMore = []
        condition = []
        conditionOn = .y
        zscoreY = false
        flip = false
        waterfall = false
        yIndividually = false
        applyPresets()
        if let c = carried {
            // one request for every carried name; the ones the dataset does not have come back
            // missing (a failure here only means nothing is carried over)
            try? await ensureLoaded(c.names)
            let has = { (n: String) in !n.isEmpty && self.column(n) != nil }
            if has(c.x) { x = c.x }
            if has(c.y) { y = c.y }
            if has(c.color) || c.color.isEmpty { color = c.color }
            if has(c.size) || c.size.isEmpty { size = c.size }
            if has(c.facet) || c.facet.isEmpty { facet = c.facet }
            xMore = c.xMore.filter(has); yMore = c.yMore.filter(has); condition = c.condition.filter(has)
            conditionOn = c.conditionOn; zscoreY = c.zscoreY; flip = c.flip; waterfall = c.waterfall
            yIndividually = c.yIndividually && yMore.count >= 1
        }
        try await ensureLoaded([x, y, color, size, facet])
        // a variable the dataset does not have is not kept as a selection
        if column(x) == nil { x = "" }
        if column(y) == nil { y = "" }
        if column(color) == nil { color = "" }
        if column(size) == nil { size = "" }
        if column(facet) == nil { facet = "" }
        for v in [x, y, color, size] { filter.add(v) }     // plotted variables are filterable from the start
        // the dataset's opening cohorts (TCGA: nine of 33, a plot of all of them is too busy),
        // unless the user's own cohort choice comes along from the previous dataset
        if !(carried?.filters.contains { $0.column == "cohort" } ?? false) { applyDefaultCohorts() }
        if let c = carried {
            // the filter panels and their settings, where the names and the levels exist
            for f in c.filters where column(f.column) != nil {
                filter.add(f.column)
                switch f.value {
                case .levels(let s)?:
                    let present = Set(filter.levelsPresent(f.column).map { filter.columns[f.column]!.levels![$0] })
                    let kept = s.intersection(present)
                    filter.set(f.column, value: kept.isEmpty || kept == present ? nil : .levels(kept), includeMissing: f.includeMissing)
                case .range(let lo, let hi)?:
                    filter.set(f.column, value: .range(lo: lo, hi: hi), includeMissing: f.includeMissing)
                case nil:
                    filter.set(f.column, value: nil, includeMissing: f.includeMissing)
                }
            }
        }
    }

    func select(dataset name: String) async {
        await select(source: name)
    }

    /// fetch any of these variables that are not on the device yet
    func ensureLoaded(_ names: [String]) async throws {
        guard let ds = datasetName else { return }
        let need = Array(Set(names.filter { !$0.isEmpty && filter.columns[$0] == nil })).sorted()
        guard !need.isEmpty else { return }
        let r: (columns: [Column], missing: [String])
        do {
            r = try await api.values(ds, probes: need, version: meta?.version)
        } catch APIClient.APIError.versionChanged {
            // the database was replaced on the server: what is on the device (the sample
            // order above all) belongs to the old one, so start this dataset afresh
            try await open(ds)
            status = "The database on the server was updated. The dataset was reloaded: choose the variables again."
            return
        }
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
    enum ListSlot { case xMore, yMore, condition }

    /// add a variable to one of the lists (more X, more Y, covariates)
    func add(_ name: String, to slot: ListSlot) async {
        guard !name.isEmpty else { return }
        await run("Loading \(name)") {
            try await self.ensureLoaded([name])
            guard self.filter.columns[name] != nil else { return }
            switch slot {
            case .xMore: if name != self.x, !self.xMore.contains(name) { self.xMore.append(name) }
            case .yMore: if name != self.y, !self.yMore.contains(name) { self.yMore.append(name) }
            case .condition: if !self.condition.contains(name) { self.condition.append(name) }
            }
        }
    }
    func remove(_ name: String, from slot: ListSlot) {
        switch slot {
        case .xMore: xMore.removeAll { $0 == name }
        case .yMore:
            yMore.removeAll { $0 == name }
            if yMore.isEmpty, yIndividually { setIndividualY(false) }     // one Y left: nothing to tell apart
        case .condition: condition.removeAll { $0 == name }
        }
    }

    /// "Plot Y probes individually": on, the colour becomes the probe (as the website's colour
    /// menu switches to "probe"), unless the user then picks a colour of their own, which
    /// gives one graph per probe instead; off, the colour from before comes back.
    func setIndividualY(_ on: Bool) {
        guard on != yIndividually else { return }
        yIndividually = on
        if on {
            colorBeforeIndividual = color
            color = ""
        } else if color.isEmpty {
            color = column(colorBeforeIndividual) != nil ? colorBeforeIndividual : ""
        }
    }
    /// what the Color row shows: the probe, while individual Y probes are told apart by colour
    var colorLabel: String { color.isEmpty && yIndividually && !yMore.isEmpty ? "Y probe" : color }

    func addFilterColumn(_ name: String) async { await addFilterColumns([name]) }
    /// several at once: one request for all of them, then a panel each
    func addFilterColumns(_ names: [String]) async {
        let wanted = names.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return }
        await run("Loading \(wanted.joined(separator: ", "))") {
            try await self.ensureLoaded(wanted)
            // at the top of the Filter screen, where they are seen (the cohort panel is long)
            for n in wanted.reversed() where self.filter.columns[n] != nil { self.filter.add(n, first: true) }
        }
    }
    /// the contact form's message, through the server
    func sendContactMessage(_ m: APIClient.ContactMessage) async throws {
        try await api.sendContact(m)
    }
    /// names matching `query` (the best 200: exact, then starting with, then containing the
    /// letters) and how many match in all; nil when the search itself failed
    func search(_ query: String) async -> (names: [String], total: Int)? {
        guard let ds = datasetName else { return ([], 0) }
        guard let r = try? await api.searchProbes(ds, query: query, limit: 200) else { return nil }
        return (r.probes, r.totalMatches)
    }

    // MARK: samples

    // The dataset's presets are of two kinds. A GROUP picks a set of samples ("GTEx normal
    // tissues", "Primary tumors only": a rule with `in`); groups are alternatives, so one at
    // most is in use. An EXCLUSION only removes samples ("Exclude cell lines", "Exclude
    // tumors of heme origin": every rule a `not in`); any number can be on. A choice is
    // offered only where it changes the samples in use: a group that is empty within the
    // data source, or is the whole of it, is not offered, and nor is an exclusion that would
    // remove nothing, or everything, from the source and the chosen group.

    /// a preset that only removes samples
    static func isExclusion(_ p: Preset) -> Bool { !p.rules.isEmpty && p.rules.allSatisfy { $0.op == "not in" } }

    /// the samples of the data source: the fixed preset's, or all of them
    private var sourceMask: Mask {
        fixedPreset.flatMap { presetMasks[$0] } ?? Mask(repeating: true, count: filter.sampleCount)
    }
    /// how many samples the data source has (the "of" in "n of N samples in use")
    var sourceCount: Int { fixedPreset == nil ? filter.sampleCount : sourceMask.reduce(0) { $0 + ($1 ? 1 : 0) } }
    /// does this preset keep some, but not all, of `base`?
    private func narrows(_ label: String, within base: Mask) -> Bool {
        guard let pm = presetMasks[label], pm.count == base.count else { return false }
        var inBase = 0, kept = 0
        for i in base.indices where base[i] {
            inBase += 1
            if pm[i] { kept += 1 }
        }
        return kept > 0 && kept < inBase
    }
    /// the groups a user can choose from within the data source. A group that comes to the
    /// same samples as an exclusion offered here (within GTEx, "GTEx normal tissues" is
    /// exactly "Exclude cell lines") is left to the exclusion, the clearer control.
    var groupChoices: [Preset] {
        let base = sourceMask
        let exclusions = allPresets.filter { $0.label != fixedPreset && Self.isExclusion($0) && narrows($0.label, within: base) }
        return allPresets.filter { p in
            guard p.label != fixedPreset, !Self.isExclusion(p), narrows(p.label, within: base), let pm = presetMasks[p.label] else { return false }
            return !exclusions.contains { e in
                guard let em = presetMasks[e.label] else { return false }
                return base.indices.allSatisfy { !base[$0] || pm[$0] == em[$0] }
            }
        }
    }
    /// the group in use, if any
    var chosenGroup: String? {
        groupChoices.first { activePresets.contains($0.label) }?.label
    }
    /// the exclusions that would make a difference to the source and the chosen group
    var exclusionChoices: [Preset] {
        var base = sourceMask
        if let g = chosenGroup, let gm = presetMasks[g] { base = zip(base, gm).map { $0 && $1 } }
        return allPresets.filter { $0.label != fixedPreset && Self.isExclusion($0) && narrows($0.label, within: base) }
    }

    func choose(group label: String?) {
        for p in groupChoices { activePresets.remove(p.label) }
        if let label { activePresets.insert(label) }
        applyPresets()
    }
    func toggle(preset label: String) {
        if label == fixedPreset { return }       // the data source itself: always on
        if activePresets.contains(label) { activePresets.remove(label) } else { activePresets.insert(label) }
        applyPresets()
    }
    /// the universe = samples in every active preset. A preset that is no longer offered
    /// (an exclusion that would empty the set after a change of group) is switched off.
    private func applyPresets() {
        guard meta != nil else { return }
        let groups = Set(groupChoices.map(\.label))
        if let g = chosenGroup { activePresets.subtract(groups.subtracting([g])) }   // one group at most
        let offered = groups.union(exclusionChoices.map(\.label)).union(fixedPreset.map { [$0] } ?? [])
        activePresets = activePresets.intersection(offered)
        var mask: Mask? = nil
        for p in allPresets where activePresets.contains(p.label) {
            guard let pm = presetMasks[p.label] else { continue }
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
        var request = PlotRequest(x: [x] + xMore, y: [y] + yMore, color: color, size: size, facet: facet)
        request.condition = condition
        request.conditionOn = condition.isEmpty ? .none : conditionOn
        request.kmGroups = kmGroups
        request.kmMaxDays = kmMaxDays
        request.zscoreY = zscoreY
        request.yIndividually = yIndividually && !yMore.isEmpty
        request.flip = flip
        request.waterfall = waterfall
        request.fitLine = fitLine
        let context = PlotBuilder.Context(datasetLabel: m.label, survivalEndpoints: m.usableSurvivalEndpoints)
        return PlotBuilder.build(request, columns: filter.columns, keep: filter.mask(), context: context)
    }

    /// is X a survival endpoint of this dataset (so the plot is a Kaplan-Meier plot)?
    var isSurvival: Bool { meta?.usableSurvivalEndpoints.contains(x) ?? false }

    /// The columns of the export table: every probe the user has asked for in this dataset
    /// (the plotted ones first, then the other filter columns and anything else loaded), then
    /// all of the dataset's clinical columns, in its order. A clinical column that is also
    /// plotted is written once, in its plotted place.
    var tableColumns: [String] {
        guard let m = meta else { return [] }
        let clinical = Set(m.clinicalColumns)
        // (built step by step: Xcode 16 cannot type-check one long chain of `+` on arrays)
        var wanted: [String] = [x]
        wanted.append(contentsOf: xMore)
        wanted.append(y)
        wanted.append(contentsOf: yMore)
        wanted.append(contentsOf: [color, size, facet])
        wanted.append(contentsOf: condition)
        wanted.append(contentsOf: filter.filters.map(\.column))
        wanted.append(contentsOf: filter.columns.keys.filter { !clinical.contains($0) }.sorted())
        wanted.append(contentsOf: m.clinicalColumns)
        var names: [String] = []
        for v in wanted where !v.isEmpty && filter.columns[v] != nil && !names.contains(v) { names.append(v) }
        return names
    }

    /// how many of the table's columns are probes (not clinical columns)
    var tableProbeCount: Int {
        let clinical = Set(meta?.clinicalColumns ?? [])
        return tableColumns.filter { !clinical.contains($0) }.count
    }

    /// The export table (the website's "Download Table"): one row per sample in use, exactly
    /// as the presets and the filters leave them, with `tableColumns`, written to a new CSV
    /// file. Returns nil if there is nothing to write.
    func writeTable() -> URL? {
        guard let m = meta else { return nil }
        let names = tableColumns
        let csv = TableExport.csv(samples: samples, columns: names.compactMap { filter.columns[$0] }, keep: filter.mask())
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let file = "T2_table_\(m.dataset)_\(filter.selectedCount())samples_\(names.count)columns_\(stamp.string(from: Date())).csv"
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
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
    /// the cohorts the dataset says to show first (`defaults.cohorts`), where they exist; a
    /// dataset without that default (or whose named cohorts are not there) starts with all
    func applyDefaultCohorts() {
        guard let wanted = meta?.defaults["cohorts"], !wanted.isEmpty else { return }
        let present = Set(wanted.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            .intersection(availableCohorts)
        guard !present.isEmpty else { return }
        setCohorts(present)
    }

    func setCohorts(_ chosen: Set<String>?) {
        let all = availableCohorts
        guard !all.isEmpty else { return }
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
            lastError = error
            status = "\(what) failed: \(error.localizedDescription)"
        }
        busy = false
    }
}
