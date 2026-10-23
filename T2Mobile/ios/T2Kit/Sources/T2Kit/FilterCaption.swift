import Foundation

// The "Filtered: ..." line under a figure: which samples the plot is drawn from, in plain
// words, so that a figure on its own says what was filtered out. Built from what the app
// holds (the chosen group, the exclusions, the cohorts, the Filter screen's rules); nothing
// is guessed. An unfiltered plot has no such line.

public struct FilterNote: Sendable, Equatable {
    /// the group preset in use (the data source itself is not a filter: the title names it)
    public var groups: [String]
    /// the exclusions in use ("Exclude cell lines", ...), by their labels
    public var exclusions: [String]
    /// the cohorts chosen, and how many the data source has; nil = all of them
    public var cohorts: [String]?
    public var cohortTotal: Int
    /// the Filter screen's rules on columns other than the cohort column
    public var rules: [ColumnFilter]

    public init(groups: [String] = [], exclusions: [String] = [], cohorts: [String]? = nil, cohortTotal: Int = 0, rules: [ColumnFilter] = []) {
        self.groups = groups; self.exclusions = exclusions; self.cohorts = cohorts; self.cohortTotal = cohortTotal; self.rules = rules
    }

    /// does anything restrict the samples?
    public var isFiltered: Bool { !groups.isEmpty || !exclusions.isEmpty || cohorts != nil || rules.contains(where: \.isActive) }

    /// "Filtered: Primary tumors only; Exclude cell lines; cohorts: 2 of 33 (BRCA, LUAD); age from 40 to 60."
    /// Empty when nothing is filtered.
    public var text: String {
        guard isFiltered else { return "" }
        var parts: [String] = []
        if !groups.isEmpty { parts.append(groups.joined(separator: ", ")) }
        if !exclusions.isEmpty { parts.append(exclusions.joined(separator: ", ")) }
        if let c = cohorts {
            if c.count <= 3, !c.isEmpty { parts.append("cohorts: \(c.sorted().joined(separator: ", "))") }
            else { parts.append("cohorts: \(c.count) of \(cohortTotal)") }
        } else if cohortTotal > 0 {
            parts.append("all cohorts")
        }
        for r in rules where r.isActive { parts.append(Self.describe(r)) }
        return "Filtered: " + parts.joined(separator: "; ") + "."
    }

    /// one rule of the Filter screen in plain words: "age from 40 to 60", "sex is F", "grade has a value"
    static func describe(_ r: ColumnFilter) -> String {
        var s: String
        switch r.value {
        case .range(let lo, let hi)?:
            switch (lo.isFinite, hi.isFinite) {
            case (true, true): s = "\(r.column) from \(PlotFormat.tickLabel(lo)) to \(PlotFormat.tickLabel(hi))"
            case (true, false): s = "\(r.column) at least \(PlotFormat.tickLabel(lo))"
            case (false, true): s = "\(r.column) at most \(PlotFormat.tickLabel(hi))"
            default: s = ""
            }
        case .levels(let set)?:
            let names = set.sorted()
            s = names.count <= 3 ? "\(r.column) is \(names.joined(separator: " or "))" : "\(r.column) is one of \(names.count) values"
        case nil:
            s = ""
        }
        if !r.includeMissing {
            s = s.isEmpty ? "\(r.column) has a value" : s + ", with a value"
        }
        return s
    }
}

// MARK: not-detected values

/// Which cells of the plotted probes the service filled in (the "Not detected" option): for
/// each such probe the samples that were missing in the plain (na) column and have a value in
/// the filled one, and the word its data type gives it ("protein"). The app works the masks out
/// by comparing the two columns; nothing here knows what a type is.
public struct FillNote: Sendable, Equatable {
    public struct Probe: Sendable, Equatable {
        public var name: String
        /// the type's title word ("protein"); empty when the dataset gives none
        public var word: String
        /// per sample: filled
        public var filledMask: [Bool]
        public init(name: String, word: String, filledMask: [Bool]) { self.name = name; self.word = word; self.filledMask = filledMask }
    }
    /// "zero" or "floor"
    public var fill: String
    public var probes: [Probe]
    public init(fill: String = "na", probes: [Probe] = []) { self.fill = fill; self.probes = probes }
    public var isEmpty: Bool { fill == "na" || probes.isEmpty }

    /// what the cells were set to, in words
    var valueText: String { fill == "floor" ? "the detection floor, per cohort" : "0" }

    /// The caption line and the statistics lines for the samples shown: the filtered samples that
    /// have a value for every plotted variable. Only probes with at least one filled cell among
    /// them are named; nothing at all when there are none.
    func describe(shown rows: [Int], plotted: Set<String>) -> (caption: String, stats: [StatLine]) {
        guard !isEmpty else { return ("", []) }
        let counts = probes.filter { plotted.contains($0.name) }.compactMap { p -> (Probe, Int)? in
            let k = rows.reduce(0) { $0 + ($1 < p.filledMask.count && p.filledMask[$1] ? 1 : 0) }
            return k > 0 ? (p, k) : nil
        }
        guard !counts.isEmpty else { return ("", []) }
        let n = rows.count
        let words = counts.map { $0.0.word }.filter { !$0.isEmpty }.uniqued()
        let kind = words.isEmpty ? "Not-detected values" : "Not-detected \(words.joined(separator: "/")) values"
        let caption: String
        if counts.count == 1 {
            caption = "\(kind) set to \(valueText) (\(counts[0].1.formatted()) of \(n.formatted()) samples shown)"
        } else if counts.count == 2 {
            caption = "\(kind) set to \(valueText): " + counts.map { "\($0.0.name) (\($0.1.formatted()) of \(n.formatted()))" }.joined(separator: ", ")
        } else {
            let cells = counts.reduce(0) { $0 + $1.1 }
            caption = "\(cells.formatted()) not-detected values set to \(valueText) (\(counts.count) variables)"
        }
        let stats = counts.map { StatLine("Not detected, \($0.0.name)", "set to \(fill == "floor" ? "the floor" : "0") in \($0.1.formatted()) of \(n.formatted())") }
        return (caption, stats)
    }
}
