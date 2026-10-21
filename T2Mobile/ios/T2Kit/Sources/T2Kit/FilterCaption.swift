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
