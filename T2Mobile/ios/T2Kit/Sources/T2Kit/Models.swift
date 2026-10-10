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
        switch data {
        case .numeric(let v): return v[i].isNaN
        case .categorical(_, let c): return c[i] < 0
        }
    }
    /// the level of sample `i`, or nil (numeric column or missing)
    public func level(_ i: Int) -> String? {
        if case .categorical(let l, let c) = data, c[i] >= 0 { return l[c[i]] }
        return nil
    }
    public var missingCount: Int { (0..<count).reduce(0) { $0 + (isMissing($1) ? 1 : 0) } }
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
    public var id: String { name }
    /// the parts offered as data sources of their own
    public var parts: [DataSource] { (sources ?? []).filter { !$0.isWhole } }
    /// the synthetic test dataset (not real data): built for tests, not offered to users
    public var isDemo: Bool { name == "DEMO" || title.localizedCaseInsensitiveContains("not real data") }
}

/// One data type of a dataset ("rna", "mut", "sig", ...) as the database describes it.
public struct DataTypeInfo: Decodable, Sendable, Identifiable, Equatable {
    public let type: String
    public let description: String?
    public let example: String?
    public let reference: String?
    public var id: String { type }
}

/// What a clinical column means (the service's `clinical_descriptions`).
public struct ClinicalDescription: Decodable, Sendable, Identifiable, Equatable {
    public let column: String
    public let description: String
    public let source: String?
    public var id: String { column }
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

    /// the description of a clinical column, if the service has one
    public func describe(_ column: String) -> ClinicalDescription? { clinicalDescriptions?.first { $0.column == column } }

    /// what to call a cohort value on screen: its `cohortstring` ("breast invasive carcinoma ( BRCA )"),
    /// or the value itself when the dataset has no name for it
    public func cohortTitle(_ value: String) -> String {
        guard let hit = cohorts?.first(where: { $0.cohort == value }), !hit.cohortstring.isEmpty else { return value }
        return hit.cohortstring
    }
    /// the survival endpoints this dataset can really analyse: an endpoint needs its event
    /// column and its time column ("OS" and "OS.time") among the clinical columns.
    /// (The service lists the same four names for every dataset.)
    public var usableSurvivalEndpoints: [String] {
        let have = Set(clinicalColumns)
        return survivalEndpoints.filter { have.contains($0) && have.contains($0 + ".time") }
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
}

public struct ProbeSearch: Decodable, Sendable {
    public let probes: [String]
    public let totalMatches: Int
}

struct DatasetList: Decodable { let datasets: [DatasetSummary] }
