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

/// The service does not describe the dataset the way the app needs (the dataset contract's
/// `handles` and `tte_variables`). The app derives nothing itself, so it says so.
struct ServiceTooOld: LocalizedError {
    var errorDescription: String? {
        "This T2 data service is older than the app expects: it does not say which columns hold the cohorts and the survival times. Please try again later, or update the app if a newer one is available."
    }
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

    // What a screen asks for on every redraw is worked out once per real change and kept: the
    // plot scene, the mask and the count of samples in use, the cohort list, the preset
    // choices. `filter.revision` moves on every change of the filter; `datasetRevision`
    // moves when a dataset is opened (its meta, its preset masks and its source change).
    // (`let` caches: not tracked by Observation; the values they are keyed by are read in the
    // key, so a screen still redraws when any of them changes.)
    private var datasetRevision = 0
    private struct SceneKey: Equatable {
        var x: String, y: String, color: String, size: String, facet: String
        var xMore: [String], yMore: [String], condition: [String]
        var conditionOn: PlotRequest.ConditionTarget
        var kmGroups: Int, kmMaxDays: Double
        var zscoreY: Bool, flip: Bool, waterfall: Bool, yIndividually: Bool, fitLine: Bool
        var filterRevision: Int, datasetRevision: Int
        var fill: String
    }
    private struct ChoicesKey: Equatable { var datasetRevision: Int, fixed: String?, version: String? }
    private let sceneCache = KeyedCache<SceneKey, PlotScene>()
    private let maskCache = KeyedCache<[Int], Mask>()
    private let countCache = KeyedCache<[Int], Int>()
    private let cohortCache = KeyedCache<[Int], [String]>()
    private let sourceMaskCache = KeyedCache<ChoicesKey, Mask>()
    private let groupCache = KeyedCache<ChoicesKey, [Preset]>()
    private let exclusionCache = KeyedCache<ExclusionKey, [Preset]>()
    private struct ExclusionKey: Equatable { var choices: ChoicesKey, group: String? }
    private var choicesKey: ChoicesKey { ChoicesKey(datasetRevision: datasetRevision, fixed: fixedPreset, version: meta?.version) }

    /// the samples passing the presets and every filter; worked out once per change
    func currentMask() -> Mask {
        maskCache.get([filter.revision, datasetRevision]) { filter.mask() }
    }
    /// how many samples are in use (the count every screen prints)
    func selectedCount() -> Int {
        countCache.get([filter.revision, datasetRevision]) { currentMask().reduce(0) { $0 + ($1 ? 1 : 0) } }
    }

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

    // MARK: not-detected values

    /// How the cells of a tested sample with no stored value are served ("na" = missing, as always;
    /// "zero" or "floor" where the service offers it). Per plot: back to "na" on a data source switch.
    var fill = "na"
    /// The fills the values answer for the plotted variables lists. The control is shown only when
    /// there is more than "na"; the app does not look at types to decide.
    var fillOptions: [String] = ["na"]
    /// per probe, the samples the service filled in (missing in the plain column, a value in the filled one)
    private var fillMasks: [String: [Bool]] = [:]
    private var fillOptionsMemo: [String: [String]] = [:]
    /// the filled cells of the plotted probes, for the caption and the statistics
    var fillNote: FillNote {
        guard fill != "na" else { return FillNote() }
        let words = meta?.typeWords ?? [:]
        return FillNote(fill: fill, probes: fillMasks.keys.sorted().map { name in
            FillNote.Probe(name: name, word: words[filter.columns[name]?.type ?? ""] ?? "", filledMask: fillMasks[name] ?? [])
        })
    }

    /// what is going on, for the user: "Loading CD8A...", or the last problem
    var status = ""
    /// the error of the last failed operation (for the explanation when nothing could be loaded)
    var lastError: Error?
    /// what to tell the user when the service could not be reached: their phone, or our server
    var outageText: String {
        if let e = lastError as? ServiceTooOld { return e.errorDescription ?? "" }
        // (APIClient keeps the URLError's code in `.transport`: it is the offline codes that say "your phone")
        if (lastError as? APIClient.APIError)?.isOffline == true || (lastError as? URLError).map({ APIClient.APIError.offlineCodes.contains($0.code) }) == true {
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
        datasets.filter { !$0.isHidden }.flatMap { d -> [DataSource] in
            [DataSource(dataset: d.name, preset: nil, label: d.label)] +
            d.parts.map { DataSource(dataset: d.name, preset: $0.label, label: "\(d.label): \($0.label)") }
        }
    }
    /// the open dataset's presets: the service's parts of it (each a preset that is always
    /// on while it is the data source) and its own (default_filters)
    var allPresets: [Preset] { meta.map(Self.presets(of:)) ?? [] }
    private static func presets(of m: DatasetMeta) -> [Preset] {
        let parts = (m.sources ?? []).filter { !$0.isWhole }.map(\.asPreset)
        let partLabels = Set(parts.map(\.label))
        return parts + m.presets.filter { !partLabels.contains($0.label) }
    }
    var sourceID: String { meta.map { m in fixedPreset.map { "\(m.dataset)|\($0)" } ?? m.dataset } ?? "" }

    func select(source id: String) async {
        guard id != sourceID, let src = sources.first(where: { $0.id == id }) else { return }
        await run("Opening \(src.label)") { try await self.open(src.dataset, preset: src.preset) }
    }

    /// the cohorts that have samples in the chosen data source (all of them for a whole dataset)
    var availableCohorts: [String] {
        guard let cohortCol = meta?.cohortColumn else { return [] }
        return cohortCache.get([filter.revision, datasetRevision]) {
            guard let col = filter.columns[cohortCol], let levels = col.levels else { return [] }
            return col.levelsPresent(in: filter.baseMask).map { levels[$0] }
        }
    }
    func column(_ name: String) -> Column? { name.isEmpty ? nil : filter.columns[name] }
    /// is this the name of one of the dataset's time-to-event variables?
    func isTTE(_ name: String) -> Bool { !name.isEmpty && (meta?.tte.contains { $0.name == name } ?? false) }
    /// a variable the dataset has: a column, or (as X) a time-to-event variable, which is
    /// read from its entry's own columns and need not be a column itself
    func isKnown(_ name: String) -> Bool { column(name) != nil || isTTE(name) }

    // MARK: loading

    /// the user changed the service address (or wants to try again)
    func reconnect() async {
        baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseURL.isEmpty { baseURL = t2DefaultService }
        UserDefaults.standard.set(baseURL, forKey: "baseURL")
        meta = nil
        datasetRevision += 1
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
            let offered = self.datasets.filter { !$0.isHidden }
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

    /// an operation that a newer one replaced: it stops without touching the state
    private struct Superseded: Error {}
    /// counts every run/open/setVariable/applyFill; an answer that arrives after a newer
    /// operation began is dropped (two taps, or a variable chosen twice, keep the last)
    private var generation = 0

    func open(_ name: String, launch: Bool = false, preset: String? = nil, retried: Bool = false) async throws {
        let g = generation
        // selections and filters are sticky across a switch: everything whose name the new
        // dataset has is kept (filter levels are kept where they exist too); the rest falls
        // back to the new dataset's defaults
        var carried: Carried? = nil
        if meta != nil, !launch {
            carried = Carried(x: x, y: y, color: color, size: size, facet: facet, xMore: xMore, yMore: yMore, condition: condition,
                              conditionOn: conditionOn, zscoreY: zscoreY, flip: flip, waterfall: waterfall, yIndividually: yIndividually, filters: filter.filters)
        }
        // Everything is fetched first; the state changes only when every answer is here, so a
        // failure (or a newer operation) leaves the previous dataset exactly as it was.
        var m = try await api.meta(name)
        guard g == generation else { throw Superseded() }
        // a service without the dataset contract: say so, derive nothing (the previous dataset stays open)
        if m.isOldService { throw ServiceTooOld() }
        var clin: Clinical
        do {
            clin = try await api.clinical(name, version: m.version)
        } catch APIClient.APIError.versionChanged {
            // the database was replaced between the two requests: ask once more
            guard g == generation else { throw Superseded() }
            m = try await api.meta(name)
            if m.isOldService { throw ServiceTooOld() }
            clin = try await api.clinical(name, version: m.version)
        }
        guard g == generation else { throw Superseded() }
        var cf = CrossFilter(sampleCount: clin.n)
        cf.load(clin.columns)
        func first(_ key: String, _ argument: String) -> String {
            (launch ? UserDefaults.standard.string(forKey: argument) : nil) ?? m.defaults[key] ?? ""
        }
        let x0 = first("x", "t2X"), y0 = first("y", "t2Y"), color0 = first("color", "t2Color"), size0 = first("size", "t2Size")
        let facet0 = (launch ? UserDefaults.standard.string(forKey: "t2Facet") : nil) ?? ""
        func needed(_ names: [String]) -> [String] {
            Set(names.filter { n in !n.isEmpty && cf.columns[n] == nil && !m.tte.contains { t in t.name == n } }).sorted()
        }
        var pendingMissing: String? = nil
        do {
            // one request for every carried name; the ones the dataset does not have come back
            // missing (a failure here only means nothing is carried over)
            if let c = carried {
                let want = needed(c.names)
                if !want.isEmpty, let r = try? await api.values(name, probes: want, version: m.version) { cf.load(r.columns) }
                guard g == generation else { throw Superseded() }
            }
            let want = needed([x0, y0, color0, size0, facet0])
            if !want.isEmpty {
                let r = try await api.values(name, probes: want, version: m.version)
                guard g == generation else { throw Superseded() }
                cf.load(r.columns)
                if !r.missing.isEmpty { pendingMissing = "Not in this dataset: \(r.missing.joined(separator: ", "))" }
            }
        } catch APIClient.APIError.versionChanged {
            // the database was replaced on the server meanwhile: start this dataset afresh (once)
            if retried { throw APIClient.APIError.versionChanged }
            try await open(name, launch: launch, preset: preset, retried: true)
            status = "The database on the server was updated. The dataset was reloaded: choose the variables again."
            return
        }
        guard g == generation else { throw Superseded() }

        // from here on nothing is awaited: the new dataset is put in place in one step
        meta = m
        datasetRevision += 1
        samples = clin.samples
        filter = cf
        fill = "na"; fillOptions = ["na"]; fillMasks = [:]      // a new data source starts with missing values as missing
        let presets = allPresets
        presetMasks = Dictionary(presets.map { ($0.label, $0.mask(columns: cf.columns, sampleCount: cf.sampleCount)) }, uniquingKeysWith: { a, _ in a })
        fixedPreset = preset.flatMap { label in presets.contains { $0.label == label } ? label : nil }
        datasetRevision += 1
        if let preset, fixedPreset == nil { status = "This dataset has no part called \u{201C}\(preset)\u{201D}; showing all of it." }
        if let note = pendingMissing { status = note; pendingMissing = nil }
        activePresets = Set(presets.filter(\.isDefault).map(\.label)).union(fixedPreset.map { [$0] } ?? [])
        x = x0
        y = y0
        color = color0
        size = size0
        facet = facet0
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
            let has = { (n: String) in !n.isEmpty && self.isKnown(n) }
            if has(c.x) { x = c.x }
            if has(c.y) { y = c.y }
            if has(c.color) || c.color.isEmpty { color = c.color }
            if has(c.size) || c.size.isEmpty { size = c.size }
            if has(c.facet) || c.facet.isEmpty { facet = c.facet }
            xMore = c.xMore.filter(has); yMore = c.yMore.filter(has); condition = c.condition.filter(has)
            conditionOn = c.conditionOn; zscoreY = c.zscoreY; flip = c.flip; waterfall = c.waterfall
            yIndividually = c.yIndividually && yMore.count >= 1
        }
        // a variable the dataset does not have is not kept as a selection
        if !isKnown(x) { x = "" }
        if column(y) == nil { y = "" }
        if column(color) == nil { color = "" }
        if column(size) == nil { size = "" }
        if column(facet) == nil { facet = "" }
        for v in [x, y, color, size] { filter.add(v) }     // plotted variables are filterable from the start
        // the dataset's opening cohorts (TCGA: nine of 33, a plot of all of them is too busy),
        // unless the user's own cohort choice comes along from the previous dataset
        if !(carried?.filters.contains { $0.column == m.cohortColumn } ?? false) { applyDefaultCohorts() }
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

    /// fetch any of these variables that are not on the device yet
    func ensureLoaded(_ names: [String]) async throws {
        guard let ds = datasetName else { return }
        let need = Set(names.filter { !$0.isEmpty && filter.columns[$0] == nil && !isTTE($0) }).sorted()
        guard !need.isEmpty else { return }
        let part = fixedPreset
        do {
            let r = try await loadValues(ds, need, fill: fill)
            if !r.missing.isEmpty { status = "Not in this dataset: \(r.missing.joined(separator: ", "))" }
        } catch APIClient.APIError.versionChanged {
            // the database was replaced on the server: what is on the device (the sample
            // order above all) belongs to the old one, so start this dataset afresh
            // (in the same data source)
            try await open(ds, preset: part)
            status = "The database on the server was updated. The dataset was reloaded: choose the variables again."
        }
    }

    /// Fetch `names` with `fill` and put them on the device. A fill that applies to none of the
    /// names is refused by the service (400): they are fetched plain instead. When the service did
    /// fill cells, the plain columns are fetched too (the device's URL cache usually has them) and the
    /// filled samples are worked out by comparing the two. Both answers are fetched BEFORE anything
    /// is applied, so a failure of the second leaves the device as it was. Returns the names the
    /// dataset lacks and the fill that was really applied.
    private func loadValues(_ ds: String, _ names: [String], fill wanted: String) async throws -> (missing: [String], applied: String) {
        let g = generation
        let version = meta?.version
        var r: (columns: [Column], missing: [String], info: ValuesInfo)
        var applied = wanted
        if wanted != "na" {
            do { r = try await api.values(ds, probes: names, version: version, fill: wanted) }
            catch APIClient.APIError.http(let code, _) where code == 400 {
                applied = "na"
                r = try await api.values(ds, probes: names, version: version)
            }
        } else {
            r = try await api.values(ds, probes: names, version: version)
        }
        var plain: [Column]? = nil
        if applied != "na", r.info.anyFilled {
            plain = try await api.values(ds, probes: r.columns.filter(\.isNumeric).map(\.name), version: version).columns
        }
        guard g == generation else { throw Superseded() }
        // both answers are in: apply them in one step
        filter.load(r.columns)
        for c in r.columns { fillMasks[c.name] = nil }
        if let plain {
            let before = Dictionary(plain.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            for c in r.columns {
                guard let after = c.numbers, let was = before[c.name]?.numbers, was.count == after.count else { continue }
                let mask = zip(was, after).map { $0.isNaN && !$1.isNaN }
                if mask.contains(true) { fillMasks[c.name] = mask }
            }
        }
        return (r.missing, applied)
    }

    /// the probes on the device (not the clinical columns): what a change of fill must fetch again
    private var loadedProbes: [String] {
        let clinical = Set(meta?.clinicalColumns ?? [])
        return filter.columns.keys.filter { !clinical.contains($0) && filter.columns[$0]?.type != "virtual" && filter.columns[$0]?.type != "clinical" }.sorted()
    }

    /// The Select screen's "Not detected" control: fetch the probes again with the fill and plot them.
    func setFill(_ f: String) async {
        guard f != fill, fillOptions.contains(f) else { return }
        await run("Loading") { try await self.applyFill(f) }
    }
    private func applyFill(_ f: String) async throws {
        guard let ds = datasetName else { return }
        let names = loadedProbes
        if names.isEmpty { fill = f; return }
        let part = fixedPreset
        do {
            let r = try await loadValues(ds, names, fill: f)
            fill = r.applied
            if f == "na" { fillMasks = [:] }
        } catch APIClient.APIError.versionChanged {
            try await open(ds, preset: part)      // (the chosen source part is kept)
        }
    }

    /// What the service says the plotted variables allow (the values answer's `fill_options`), kept
    /// per set of variables so that a repeated question costs nothing. If the fill in use is no longer
    /// offered (the variable that had it was replaced), the plot goes back to missing values.
    private func refreshFillOptions() async {
        guard let ds = datasetName, let version = meta?.version else { fillOptions = ["na"]; return }
        let clinical = Set(meta?.clinicalColumns ?? [])
        let plotted = ([x, y, color, size, facet] + xMore + yMore + condition).filter {
            !$0.isEmpty && !isTTE($0) && !clinical.contains($0) && filter.columns[$0] != nil
                && filter.columns[$0]?.type != "virtual" && filter.columns[$0]?.type != "clinical"
        }.uniqued().sorted()
        if plotted.isEmpty { fillOptions = ["na"] }
        else {
            let key = version + "|" + plotted.joined(separator: ",")
            if let known = fillOptionsMemo[key] { fillOptions = known }
            else if let r = try? await api.values(ds, probes: plotted, version: version) {
                fillOptionsMemo[key] = r.info.fillOptions
                fillOptions = r.info.fillOptions
            }
        }
        if fill != "na", !fillOptions.contains(fill) { try? await applyFill("na") }
    }

    enum Slot { case x, y, color, size, facet }

    func setVariable(_ slot: Slot, to name: String) async {
        await run(name.isEmpty ? "Updating" : "Loading \(name)") {
            try await self.ensureLoaded([name])
            guard name.isEmpty || self.filter.columns[name] != nil || (slot == .x && self.isTTE(name)) else { return }
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
    /// (`hits`: what the service says each name is: section, type, kind)
    func search(_ query: String) async -> (names: [String], total: Int, hits: [String: TypedHit])? {
        guard let ds = datasetName else { return ([], 0, [:]) }
        guard let r = try? await api.searchProbes(ds, query: query, limit: 200) else { return nil }
        return (r.probes, r.totalMatches, Dictionary((r.hitsTyped ?? []).map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    // MARK: samples

    // The dataset's presets are of two kinds, groups and exclusions (T2Kit's PresetChoices has
    // the rules and says what each is). They are worked out once per dataset and chosen
    // group, not on every redraw.

    /// the samples of the data source: the fixed preset's, or all of them
    private var sourceMask: Mask {
        sourceMaskCache.get(choicesKey) {
            fixedPreset.flatMap { presetMasks[$0] } ?? Mask(repeating: true, count: filter.sampleCount)
        }
    }
    /// how many samples the data source has (the "of" in "n of N samples in use")
    var sourceCount: Int { fixedPreset == nil ? filter.sampleCount : sourceMask.reduce(0) { $0 + ($1 ? 1 : 0) } }
    /// the groups a user can choose from within the data source
    var groupChoices: [Preset] {
        groupCache.get(choicesKey) {
            PresetChoices.groups(presets: allPresets, masks: presetMasks, fixed: fixedPreset, source: sourceMask)
        }
    }
    /// the group in use, if any
    var chosenGroup: String? {
        groupChoices.first { activePresets.contains($0.label) }?.label
    }
    /// the exclusions that would make a difference to the source and the chosen group
    var exclusionChoices: [Preset] {
        let group = chosenGroup
        return exclusionCache.get(ExclusionKey(choices: choicesKey, group: group)) {
            PresetChoices.exclusions(presets: allPresets, masks: presetMasks, fixed: fixedPreset, source: sourceMask, group: group)
        }
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
        // the follow-up limit is in days: a variable timed in other units is never capped by a stale choice
        let kmCap = tteEntry?.timeUnit == "days" ? kmMaxDays : 0
        let key = SceneKey(x: x, y: y, color: color, size: size, facet: facet, xMore: xMore, yMore: yMore, condition: condition,
                           conditionOn: conditionOn, kmGroups: kmGroups, kmMaxDays: kmCap, zscoreY: zscoreY, flip: flip,
                           waterfall: waterfall, yIndividually: yIndividually, fitLine: fitLine,
                           filterRevision: filter.revision, datasetRevision: datasetRevision, fill: fill)
        return sceneCache.get(key) {
            var request = PlotRequest(x: [x] + xMore, y: [y] + yMore, color: color, size: size, facet: facet)
            request.condition = condition
            request.conditionOn = condition.isEmpty ? .none : conditionOn
            request.kmGroups = kmGroups
            request.kmMaxDays = kmCap
            request.zscoreY = zscoreY
            request.yIndividually = yIndividually && !yMore.isEmpty
            request.flip = flip
            request.waterfall = waterfall
            request.fitLine = fitLine
            // (the website also asks for the cohort and the sample type of a sample when it keeps only complete ones)
            let required = [m.cohortColumn, m.sampleTypeColumn].compactMap { $0 }
            let context = PlotBuilder.Context(datasetLabel: PlotBuilder.sourceWord(dataset: m.label, part: fixedPreset),
                                              tte: m.tte, typeLabels: m.typeWords, handleColumns: required, filters: filterNote, fills: fillNote)
            return PlotBuilder.build(request, columns: filter.columns, keep: currentMask(), context: context)
        }
    }

    /// what is filtered, for the figure's "Filtered: ..." caption: the group and exclusions in
    /// use, the cohorts, and the Filter screen's other rules (the data source is named in the title)
    var filterNote: FilterNote {
        let exclusions = Set(allPresets.filter(PresetChoices.isExclusion).map(\.label))
        let used = activePresets.filter { $0 != fixedPreset }
        let cohortCol = meta?.cohortColumn
        return FilterNote(groups: used.filter { !exclusions.contains($0) }.sorted(),
                          exclusions: used.filter { exclusions.contains($0) }.sorted(),
                          cohorts: chosenCohorts.map { Array($0) },
                          cohortTotal: availableCohorts.count,
                          rules: filter.filters.filter { $0.column != cohortCol && $0.isActive })
    }

    /// is X a time-to-event variable of this dataset (so the plot is a Kaplan-Meier plot)?
    var isSurvival: Bool { isTTE(x) }
    /// the time-to-event entry X names, if it does
    var tteEntry: TTEVariable? { meta?.tte.first { $0.name == x } }

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
        return wanted.filter { !$0.isEmpty && filter.columns[$0] != nil }.uniqued()
    }

    /// how many of the table's columns are probes (not clinical columns)
    var tableProbeCount: Int {
        let clinical = Set(meta?.clinicalColumns ?? [])
        return tableColumns.filter { !clinical.contains($0) }.count
    }

    /// The export table (the website's "Download Table"): one row per sample in use, exactly
    /// as the presets and the filters leave them, with `tableColumns`, written to a new CSV
    /// file. Returns nil if there is nothing to write.
    func writeTable() async -> URL? {
        guard let m = meta else { return nil }
        let names = tableColumns
        // snapshots (value types) go to a background task: a big table is not built on the main actor
        let samples = self.samples, columns = names.compactMap { filter.columns[$0] }, mask = currentMask()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let file = "T2_table_\(m.dataset)_\(selectedCount())samples_\(names.count)columns_\(stamp.string(from: Date())).csv"
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(file)
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            let csv = TableExport.csv(samples: samples, columns: columns, keep: mask)
            do { try csv.write(to: url, atomically: true, encoding: .utf8) } catch { return nil }
            return url
        }.value
    }

    // MARK: cohorts (the website's Cohort box: a filter on the dataset's cohort column)

    /// the cohorts in use; nil = all
    var chosenCohorts: Set<String>? {
        if let col = meta?.cohortColumn, case .levels(let s)? = filter.filter(col)?.value { return s }
        return nil
    }
    /// the cohorts the dataset says to show first (`default_cohorts`, a list), where they
    /// exist; a dataset without that default (or whose named cohorts are not there) starts with all
    func applyDefaultCohorts() {
        guard let wanted = meta?.defaultCohorts, !wanted.isEmpty else { return }
        let present = Set(wanted).intersection(availableCohorts)
        guard !present.isEmpty else { return }
        setCohorts(present)
    }

    func setCohorts(_ chosen: Set<String>?) {
        guard let col = meta?.cohortColumn else { return }
        let all = availableCohorts
        guard !all.isEmpty else { return }
        filter.add(col)
        if let chosen, chosen.count < all.count { filter.set(col, value: .levels(chosen)) }
        else { filter.set(col, value: nil) }
    }

    private func run(_ what: String, _ work: @escaping () async throws -> Void) async {
        generation += 1
        let g = generation
        busy = true
        status = what + "\u{2026}"
        do {
            try await work()
            guard g == generation else { return }
            if meta != nil { await refreshFillOptions() }
            guard g == generation else { return }
            if status == what + "\u{2026}" { status = "" }
        } catch {
            // a newer operation replaced this one: it reports, and owns the busy flag
            guard g == generation else { return }
            if error is CancellationError {
                if status == what + "\u{2026}" { status = "" }
            } else {
                lastError = error
                status = "\(what) failed: \(error.localizedDescription)"
            }
        }
        busy = false
    }
}
