import Foundation

// The shapes of the t2api responses (docs/API.md). Every column has one entry per sample,
// in the dataset's sample order.

/// One variable: a probe, a clinical column, or the virtual `cohort` / `subtype`.
public struct Column: Sendable, Equatable {
    public enum Data: Sendable, Equatable {
        /// `Double.nan` = missing
        case numeric([Double])
        /// `codes[i]` indexes `levels`; -1 = missing
        case categorical(levels: [String], codes: [Int])
    }
    public let name: String
    /// data type: "rna", "mut", ..., "clinical", "virtual"
    public let type: String
    public let data: Data

    public init(name: String, type: String, data: Data) {
        self.name = name; self.type = type; self.data = data
    }

    public var count: Int {
        switch data {
        case .numeric(let v): return v.count
        case .categorical(_, let c): return c.count
        }
    }
    public var isNumeric: Bool { if case .numeric = data { return true } else { return false } }
    public var numbers: [Double]? { if case .numeric(let v) = data { return v } else { return nil } }
    public var levels: [String]? { if case .categorical(let l, _) = data { return l } else { return nil } }
    public var codes: [Int]? { if case .categorical(_, let c) = data { return c } else { return nil } }
    /// is sample `i` missing a value?
    public func isMissing(_ i: Int) -> Bool {
        // (an index outside the column is missing, never a trap)
        switch data {
        case .numeric(let v): return !v.indices.contains(i) || v[i].isNaN
        case .categorical(_, let c): return !c.indices.contains(i) || c[i] < 0
        }
    }
    /// the level of sample `i`, or nil (numeric column or missing)
    public func level(_ i: Int) -> String? {
        if case .categorical(let l, let c) = data, c.indices.contains(i), c[i] >= 0, l.indices.contains(c[i]) { return l[c[i]] }
        return nil
    }
    public var missingCount: Int { (0..<count).reduce(0) { $0 + (isMissing($1) ? 1 : 0) } }

    // MARK: levels in use

    /// the indices of the levels (`0..<levelCount`) that have at least one of `rows`, in level order
    public static func levelsPresent(codes: [Int], levelCount: Int, rows: [Int]) -> [Int] {
        var seen = [Bool](repeating: false, count: levelCount)
        for r in rows where codes[r] >= 0 { seen[codes[r]] = true }
        return (0..<levelCount).filter { seen[$0] }
    }
    /// the indices of the levels that have at least one sample where `mask` is true (nil = everywhere)
    public static func levelsPresent(codes: [Int], levelCount: Int, in mask: Mask?) -> [Int] {
        var seen = [Bool](repeating: false, count: levelCount)
        for i in codes.indices where codes[i] >= 0 && (mask.map { i < $0.count && $0[i] } ?? true) { seen[codes[i]] = true }
        return (0..<levelCount).filter { seen[$0] }
    }
    /// `rows` grouped by level code (missing values left out)
    public static func groups(codes: [Int], rows: [Int]) -> [Int: [Int]] {
        var g: [Int: [Int]] = [:]
        for r in rows where codes[r] >= 0 { g[codes[r], default: []].append(r) }
        return g
    }
    /// the levels of a categorical column that occur among `rows` (droplevels); [] for a numeric column
    public func levelsPresent(rows: [Int]) -> [Int] {
        guard case .categorical(let l, let c) = data else { return [] }
        return Self.levelsPresent(codes: c, levelCount: l.count, rows: rows)
    }
    /// the levels that occur in the samples where `mask` is true (nil = all); [] for a numeric column
    public func levelsPresent(in mask: Mask?) -> [Int] {
        guard case .categorical(let l, let c) = data else { return [] }
        return Self.levelsPresent(codes: c, levelCount: l.count, in: mask)
    }
    /// `rows` grouped by level code; [:] for a numeric column
    public func groups(rows: [Int]) -> [Int: [Int]] {
        guard case .categorical(_, let c) = data else { return [:] }
        return Self.groups(codes: c, rows: rows)
    }
}

extension Column: Decodable {
    private enum Keys: String, CodingKey { case name, kind, type, values, levels, codes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        switch try c.decode(String.self, forKey: .kind) {
        case "num":
            let v = try c.decode([Double?].self, forKey: .values)
            data = .numeric(v.map { $0 ?? .nan })
        case "cat":
            data = .categorical(levels: try c.decode([String].self, forKey: .levels),
                                codes: try c.decode([Int].self, forKey: .codes))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown column kind \(other)")
        }
    }
}

/// Which clinical columns play which part in a dataset.
public struct Roles: Decodable, Sendable, Equatable {
    public let cohortCol: String
    public let subtypeCol: String
    public let sampletypeCol: String
    public let normalLabel: [String]
    public let hemeValues: [String]
    public let sampletypeLevels: [String]
}

/// A ready-made subset of samples, offered as a one-tap choice.
public struct Preset: Decodable, Sendable, Equatable, Identifiable {
    public struct Rule: Decodable, Sendable, Equatable {
        public let column: String
        /// "in" or "not in"
        public let op: String
        public let values: [String]
        public init(column: String, op: String, values: [String]) {
            self.column = column; self.op = op; self.values = values
        }
    }
    public let label: String
    public let description: String
    /// switched on when the dataset is first opened
    public let isDefault: Bool
    /// "database" (the dataset's own default_filters table) or "derived" (from its roles)
    public let source: String
    public let rules: [Rule]
    public var id: String { label }
    private enum CodingKeys: String, CodingKey { case label, description, isDefault = "default", source, rules }
    public init(label: String, description: String = "", isDefault: Bool = false, source: String = "", rules: [Rule]) {
        self.label = label; self.description = description; self.isDefault = isDefault; self.source = source; self.rules = rules
    }
}

/// A data source: the whole collection, or one of the parts a dataset declares ("GTEx",
/// "TARGET" within TCGA-TARGET-GTEx), with what the service worked out for it: the cohorts
/// present, the presets that change its samples (as groups and as exclusions), the
/// categorical clinical columns with a single value there. Computed by the service
/// (sources.go), so the app never has to know anything about a dataset.
public struct DataSource: Decodable, Sendable, Equatable, Identifiable {
    public let label: String
    public let description: String
    /// empty for the whole collection
    public let rules: [Preset.Rule]
    public let nSamples: Int
    public let cohorts: [String]
    public let groups: [String]
    public let exclusions: [String]
    public let singleLevelColumns: [String]
    public var id: String { label }
    public var isWhole: Bool { rules.isEmpty }
    /// the part as a preset of the app's model (the data source is a preset that is always on)
    public var asPreset: Preset { Preset(label: label, description: description, source: "service", rules: rules) }
    public init(label: String, description: String = "", rules: [Preset.Rule], nSamples: Int = 0, cohorts: [String] = [],
                groups: [String] = [], exclusions: [String] = [], singleLevelColumns: [String] = []) {
        self.label = label; self.description = description; self.rules = rules; self.nSamples = nSamples
        self.cohorts = cohorts; self.groups = groups; self.exclusions = exclusions; self.singleLevelColumns = singleLevelColumns
    }
}

public struct DatasetSummary: Decodable, Sendable, Equatable, Identifiable {
    public let name: String
    public let title: String
    public let label: String
    public let nSamples: Int
    public let nProbes: Int
    /// changes when the database file is replaced: the key for anything cached on the device
    public let version: String
    public let roles: Roles
    /// the variables to show first: keys x, y, color, size, condition
    public let defaults: [String: String]
    /// the whole collection first, then its parts (absent from services before 2026-10-10)
    public let sources: [DataSource]?
    /// the dataset contract's handles (absent from services before it)
    public let handles: [Handle]?
    /// the dataset's own metadata says it is not to be offered in the apps (the service's
    /// `"hidden": true`, e.g. the synthetic test dataset); absent = not hidden, and absent
    /// from services before 2026-10-20
    public let hidden: Bool?
    public var id: String { name }
    /// the parts offered as data sources of their own
    public var parts: [DataSource] { (sources ?? []).filter { !$0.isWhole } }
    /// the synthetic test dataset (not real data): built for tests, not offered to users
    public var isDemo: Bool { name == "DEMO" || title.localizedCaseInsensitiveContains("not real data") }
    /// is the dataset left out of the menus? The service's `hidden` flag, or (for a service
    /// that does not send it yet) the older rule above.
    public var isHidden: Bool { hidden == true || isDemo }
}

/// One data type of a dataset ("rna", "mut", "sig", ...) as the database describes it.
public struct DataTypeInfo: Decodable, Sendable, Identifiable, Equatable {
    public let type: String
    public let description: String?
    public let example: String?
    public let reference: String?
    /// the word a plot title uses for the type (absent from services before the dataset contract)
    public let label: String?
    /// where the data of the type come from (a web page; absent from older services)
    public let sourceUrl: String?
    /// the full reference of the type, joined by the service to the data set's bibliography
    /// (all absent from services before the citations round)
    public let referenceTitle: String?
    public let referenceAuthors: String?
    public let referenceJournal: String?
    public let referenceYear: Int?
    public let referenceUrl: String?
    public var id: String { type }
}

/// What a clinical column means (the service's `clinical_descriptions`).
public struct ClinicalDescription: Decodable, Sendable, Identifiable, Equatable {
    public let column: String
    public let description: String
    public let source: String?
    public var id: String { column }
}

/// A column that plays a part in every dataset (docs/DATASET-CONTRACT.md: `handles`). The
/// `name` is the real column; the role says which part it plays.
public struct Handle: Decodable, Sendable, Equatable {
    public static let cohort = "cohort"
    public static let subcohort = "subcohort"
    public static let sampleType = "sample_type"
    public let name: String
    /// "cohort", "subcohort" or "sample_type"
    public let role: String
    public init(name: String, role: String) { self.name = name; self.role = role }
}

/// A time-to-event variable the dataset declares: `name` is what the user picks as X; the
/// event column (1 = event, 0 = censored) and the time column are read from the clinical
/// columns, in `timeUnit`. Nothing about them is guessed from the name.
public struct TTEVariable: Decodable, Sendable, Equatable, Identifiable {
    public let name: String
    public let label: String
    public let eventCol: String
    public let timeCol: String
    public let timeUnit: String
    public let description: String
    public var id: String { name }
    public init(name: String, label: String = "", eventCol: String, timeCol: String, timeUnit: String = "days", description: String = "") {
        self.name = name; self.label = label.isEmpty ? name : label; self.eventCol = eventCol; self.timeCol = timeCol
        self.timeUnit = timeUnit; self.description = description
    }
    private enum Keys: String, CodingKey { case name, label, eventCol, timeCol, timeUnit, description }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(name: try c.decode(String.self, forKey: .name),
                  label: try c.decodeIfPresent(String.self, forKey: .label) ?? "",
                  eventCol: try c.decode(String.self, forKey: .eventCol),
                  timeCol: try c.decode(String.self, forKey: .timeCol),
                  timeUnit: try c.decodeIfPresent(String.self, forKey: .timeUnit) ?? "days",
                  description: try c.decodeIfPresent(String.self, forKey: .description) ?? "")
    }
    /// how a time reads on an axis and in a median: "d" for days, else the unit's own word
    public var unitSuffix: String { timeUnit == "days" ? "d" : " " + timeUnit }
}

/// One paper in a bibliography: the data set's (`about.references`) or the statistical
/// methods' (`MethodReferences`). Shown with its full title, never abbreviated.
public struct Reference: Decodable, Sendable, Equatable, Identifiable {
    public let group: String
    public let title: String
    public let authors: String
    public let journal: String
    public let year: Int?
    public let pmid: String
    public let doi: String
    /// the link (the service fills it: PubMed, else doi.org, else the project page)
    public let url: String
    /// one plain sentence on what the reference is for
    public let note: String
    public var id: String { title + url }
    public init(group: String = "", title: String, authors: String = "", journal: String = "", year: Int? = nil,
                pmid: String = "", doi: String = "", url: String = "", note: String = "") {
        self.group = group; self.title = title; self.authors = authors; self.journal = journal; self.year = year
        self.pmid = pmid; self.doi = doi; self.note = note
        self.url = url.isEmpty ? Reference.link(pmid: pmid, doi: doi) : url
    }
    /// PubMed for a PMID, else doi.org, else empty (as the service derives it)
    public static func link(pmid: String, doi: String) -> String {
        if !pmid.isEmpty { return "https://pubmed.ncbi.nlm.nih.gov/\(pmid)/" }
        if !doi.isEmpty { return "https://doi.org/\(doi)" }
        return ""
    }
    /// "Journal, 2018" (either part may be missing)
    public var journalYear: String {
        [journal, year.map { String($0) } ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
    }
    private enum Keys: String, CodingKey { case group, title, authors, journal, year, pmid, doi, url, note }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        // a PMID may arrive as text or as a number
        var pmid = try? c.decodeIfPresent(String.self, forKey: .pmid)
        if pmid == nil, let n = try? c.decodeIfPresent(Int.self, forKey: .pmid) { pmid = String(n) }
        self.init(group: try c.decodeIfPresent(String.self, forKey: .group) ?? "",
                  title: try c.decode(String.self, forKey: .title),
                  authors: try c.decodeIfPresent(String.self, forKey: .authors) ?? "",
                  journal: try c.decodeIfPresent(String.self, forKey: .journal) ?? "",
                  year: try? c.decodeIfPresent(Int.self, forKey: .year),
                  pmid: pmid ?? "",
                  doi: try c.decodeIfPresent(String.self, forKey: .doi) ?? "",
                  url: try c.decodeIfPresent(String.self, forKey: .url) ?? "",
                  note: try c.decodeIfPresent(String.self, forKey: .note) ?? "")
    }
}

/// The dataset's own About text (any part may be empty).
public struct About: Decodable, Sendable, Equatable {
    public let description: String
    public let citation: String
    public let attribution: String
    public let url: String
    /// the data set's bibliography, in display order (empty when it has none)
    public let references: [Reference]
    public init(description: String = "", citation: String = "", attribution: String = "", url: String = "", references: [Reference] = []) {
        self.description = description; self.citation = citation; self.attribution = attribution; self.url = url
        self.references = references
    }
    private enum Keys: String, CodingKey { case description, citation, attribution, url, references }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(description: try c.decodeIfPresent(String.self, forKey: .description) ?? "",
                  citation: try c.decodeIfPresent(String.self, forKey: .citation) ?? "",
                  attribution: try c.decodeIfPresent(String.self, forKey: .attribution) ?? "",
                  url: try c.decodeIfPresent(String.self, forKey: .url) ?? "",
                  references: try c.decodeIfPresent([Reference].self, forKey: .references) ?? [])
    }
    public var isEmpty: Bool { description.isEmpty && citation.isEmpty && attribution.isEmpty && url.isEmpty && references.isEmpty }
}

public struct DatasetMeta: Decodable, Sendable {
    public let dataset: String
    public let title: String
    public let label: String
    public let version: String
    public let nSamples: Int
    public let nProbes: Int
    public let roles: Roles
    public let defaults: [String: String]
    public let presets: [Preset]
    /// the whole collection first, then its parts (absent from services before 2026-10-10)
    public let sources: [DataSource]?
    public let clinicalColumns: [String]
    public let survivalEndpoints: [String]
    /// display names of the cohorts (absent from older services)
    public let cohorts: [CohortName]?
    /// the data types of the dataset with their descriptions (the `types` table; absent from older services)
    public let types: [DataTypeInfo]?
    /// what the clinical columns mean, in the order of `clinicalColumns` (absent from older services)
    public let clinicalDescriptions: [ClinicalDescription]?
    // The dataset contract (docs/DATASET-CONTRACT.md); absent from services before it. The
    // app does not guess what is missing: see `isOldService`.
    /// the dataset's name as the service knows it
    public let name: String?
    /// the cohort / sub-cohort / sample-type columns, by role
    public let handles: [Handle]?
    /// the time-to-event variables the dataset declares (`survivalEndpoints` is their names)
    public let tteVariables: [TTEVariable]?
    public let about: About?
    /// the cohorts to show first, as a list (`defaults["cohorts"]` is the same, comma-joined, for app 1.0)
    public let defaultCohorts: [String]?

    /// does the service lack what the app relies on? (Clients derive nothing: no literal
    /// "cohort" column, no `X` / `X.time` pairs.)
    public var isOldService: Bool { handles == nil || tteVariables == nil }

    /// the column that holds the cohort (the handle with that role)
    public var cohortColumn: String? { handleName(Handle.cohort) }
    /// the sub-cohort column, if the dataset has one
    public var subcohortColumn: String? { handleName(Handle.subcohort) }
    /// the column that says tumor / normal ...
    public var sampleTypeColumn: String? { handleName(Handle.sampleType) }
    private func handleName(_ role: String) -> String? { handles?.first { $0.role == role }?.name }
    /// every handle column, in the service's order
    public var handleColumns: [String] { (handles ?? []).map(\.name) }
    /// the time-to-event variables, [] when the service declares none
    public var tte: [TTEVariable] { tteVariables ?? [] }
    /// "OS, PFI, DSS or DFI": the dataset's time-to-event names, from the data, never a fixed list
    public var tteNames: String {
        let n = tte.map(\.name)
        return n.count <= 1 ? (n.first ?? "") : n.dropLast().joined(separator: ", ") + " or " + n[n.count - 1]
    }
    /// the one-line survival hint of the About screen; empty when the dataset has no time-to-event variables
    public var survivalHint: String {
        tte.isEmpty ? "" : "Survival curves: choose \(tteNames) as X to draw Kaplan-Meier curves by groups of Y."
    }
    /// the short form, under the X picker of the Select screen
    public var survivalHintShort: String {
        tte.isEmpty ? "" : "Survival: choose \(tteNames) as X for Kaplan-Meier curves."
    }
    /// the word a plot title uses for a data type ("mutation" for `mut`); nil = no word (a bare RNA name).
    /// Read from the `types` rows (`type` is a value there): the `type_labels` dictionary is not
    /// decoded, because the snake-case key strategy would mangle type names such as `immune_score`.
    public func typeLabel(for type: String) -> String? {
        guard let w = types?.first(where: { $0.type == type })?.label, !w.isEmpty else { return nil }
        return w
    }
    /// the type -> word pairs that have a word
    public var typeWords: [String: String] {
        var m: [String: String] = [:]
        for t in types ?? [] { if let w = t.label, !w.isEmpty { m[t.type] = w } }
        return m
    }

    /// the bibliography grouped by its `group`, groups and items in order of first appearance
    public var referenceGroups: [(group: String, items: [Reference])] {
        var out: [(group: String, items: [Reference])] = []
        for r in about?.references ?? [] {
            if let i = out.firstIndex(where: { $0.group == r.group }) { out[i].items.append(r) }
            else { out.append((group: r.group, items: [r])) }
        }
        return out
    }

    /// the description of a clinical column, if the service has one
    public func describe(_ column: String) -> ClinicalDescription? { clinicalDescriptions?.first { $0.column == column } }

    /// what to call a cohort value on screen: its `cohortstring` ("breast invasive carcinoma ( BRCA )"),
    /// or the value itself when the dataset has no name for it
    public func cohortTitle(_ value: String) -> String {
        guard let hit = cohorts?.first(where: { $0.cohort == value }), !hit.cohortstring.isEmpty else { return value }
        return hit.cohortstring
    }
}

/// One cohort's names: the value in the data, a long name, and the two combined.
public struct CohortName: Decodable, Sendable, Equatable {
    public let cohort: String
    public let cohortstring: String
    public let lcohort: String

    public init(cohort: String, cohortstring: String = "", lcohort: String = "") {
        self.cohort = cohort; self.cohortstring = cohortstring; self.lcohort = lcohort
    }
    private enum Keys: String, CodingKey { case cohort, cohortstring, lcohort }
    /// A name that is missing or null becomes "": one unnamed cohort must not make the
    /// whole dataset unreadable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        cohort = try c.decodeIfPresent(String.self, forKey: .cohort) ?? ""
        cohortstring = try c.decodeIfPresent(String.self, forKey: .cohortstring) ?? ""
        lcohort = try c.decodeIfPresent(String.self, forKey: .lcohort) ?? ""
    }
}

public struct Clinical: Decodable, Sendable {
    public let dataset: String
    public let n: Int
    /// sample ids, in THE order of every column
    public let samples: [String]
    public let columns: [Column]
}

public struct Values: Decodable, Sendable {
    public let dataset: String
    /// the database version these values come from (absent in answers of older servers)
    public let version: String?
    public let n: Int
    public let columns: [Column]
    /// requested names the dataset does not have
    public let missing: [String]
    /// the fills the answer's variables allow (`["na"]` = none; the control is shown only when more),
    /// and, when a fill was applied, which one, the cells changed per probe and the samples tested
    /// (all absent from services before the not-detected option). NOTE the decoder's snake-case
    /// strategy also rewrites the dictionary keys ("A_B" -> "AB"): the keys are not relied on.
    public let fillOptions: [String]?
    public let fill: String?
    public let filled: [String: Int]?
    public let testedN: [String: Int]?
}

/// What the answers to one values request (possibly several chunks) say about not-detected fills.
public struct ValuesInfo: Sendable, Equatable {
    /// the union of the chunks' options, in the order na, zero, floor; ["na"] when the service says nothing
    public var fillOptions: [String] = ["na"]
    /// the fill the service applied ("na" = none)
    public var fill: String = "na"
    /// did the service change any cell?
    public var anyFilled = false
    public init(fillOptions: [String] = ["na"], fill: String = "na", anyFilled: Bool = false) {
        self.fillOptions = fillOptions; self.fill = fill; self.anyFilled = anyFilled
    }
    /// merge the answers of the chunks of one request
    public static func merge(_ answers: [Values]) -> ValuesInfo {
        var offered = Set<String>(["na"]), applied = "na", any = false
        for a in answers {
            offered.formUnion(a.fillOptions ?? [])
            if let f = a.fill, f != "na" { applied = f }
            if let c = a.filled, c.values.contains(where: { $0 > 0 }) { any = true }
        }
        return ValuesInfo(fillOptions: ["na", "zero", "floor"].filter { offered.contains($0) }
                              + offered.subtracting(["na", "zero", "floor"]).sorted(),
                          fill: applied, anyFilled: any)
    }
}

/// One search hit with what the service knows about it (`hits_typed`): where the menu puts
/// it and what it holds.
public struct TypedHit: Decodable, Sendable, Equatable {
    public let name: String
    /// "handle", "probe" or "clinical"
    public let section: String
    /// a `types` name, or "clinical" / "virtual"
    public let type: String
    /// "num" or "cat"
    public let kind: String
    public init(name: String, section: String, type: String, kind: String) {
        self.name = name; self.section = section; self.type = type; self.kind = kind
    }
    public var isNumeric: Bool { kind == "num" }
}

public struct ProbeSearch: Decodable, Sendable {
    public let probes: [String]
    public let totalMatches: Int
    /// the same hits with section, type and kind (absent from services before the dataset contract)
    public let hitsTyped: [TypedHit]?
    /// the hit for a name, if the service typed it
    public func hit(_ name: String) -> TypedHit? { hitsTyped?.first { $0.name == name } }
}

struct DatasetList: Decodable { let datasets: [DatasetSummary] }
