import Foundation

/// The publication export of an Analysis result (docs/ANALYSIS-SPEC.md section 9a): the figure
/// caption's sentences and the stats .txt. Pure (no UI), so the Linux suite pins the strings.
/// The citation line is NOT here: the renderer adds the source line.
public enum AnalysisExport {
    /// the statistic's name in the sentence; nil = no statistic clause (Fisher exact)
    static func statName(_ method: String) -> String? {
        switch method {
        case "Wilcoxon rank-sum": return "W"
        case "Kruskal-Wallis", "Pearson chi-squared", "Log-rank": return "chi-squared"
        case "Welch t-test": return "t"
        case "Welch ANOVA": return "F"
        default: return nil
        }
    }

    /// group n's, in the grouping's level order; for a categorical variable the sum of the group's level counts
    static func groupSizes(kind: GroupVariableKind, result: GroupTestResult) -> [(String, Int)] {
        result.groups.map { g in
            if kind == .categorical {
                return (g.group, result.levels.filter { $0.group == g.group }.reduce(0) { $0 + $1.count })
            }
            return (g.group, g.n)
        }
    }

    /// sentences 1-5 (no citation), one per line
    public static func caption(grouping: String, kind: GroupVariableKind, result: GroupTestResult, nUniverse: Int,
                               maintained: [String], dataset: String, notes: [String]) -> String {
        var out: [String] = []
        let sizes = groupSizes(kind: kind, result: result)
        if !sizes.isEmpty {
            out.append("Groups (\(grouping)): " + sizes.map { "\($0.0) n=\($0.1)" }.joined(separator: ", ") + "; universe n=\(nUniverse).")
        }
        if let t = result.test.first {
            var clauses: [String] = []
            if let name = statName(t.method), let st = t.statistic, !st.isNaN { clauses.append("\(name) = " + String(format: "%.4g", st)) }
            if t.method != "Wilcoxon rank-sum", let df = t.df, !df.isNaN {
                clauses.append("df = " + (t.method.hasPrefix("Welch") ? String(format: "%.3g", df) : String(Int(df.rounded()))))
            }
            clauses.append("p = " + Stats.pValueString(t.p))
            out.append("\(t.method): " + clauses.joined(separator: ", ") + ".")
        }
        for n in notes where !n.isEmpty { out.append(n.hasSuffix(".") ? n : n + ".") }
        out.append("Maintained filters: " + (maintained.isEmpty ? "none" : maintained.joined(separator: "; ")) + ".")
        out.append("Data: \(dataset).")
        return out.joined(separator: "\n")
    }

    // MARK: the stats text

    static func num(_ v: Double?) -> String {
        guard let v, !v.isNaN else { return "NA" }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return "\(v)"
    }

    /// rows of cells, space-aligned (left-justified, two spaces between columns, no trailing blanks)
    static func align(_ rows: [[String]]) -> String {
        guard let cols = rows.map(\.count).max() else { return "" }
        let widths = (0..<cols).map { c in rows.map { c < $0.count ? $0[c].count : 0 }.max() ?? 0 }
        return rows.map { r in
            var line = ""
            for (c, cell) in r.enumerated() {
                line += cell
                if c < r.count - 1 { line += String(repeating: " ", count: widths[c] - cell.count + 2) }
            }
            return line
        }.joined(separator: "\n")
    }

    /// The stats .txt: `# T2 analysis: <dataset>, <date>.`, blank, the caption sentences, blank, the
    /// groups block and the test block (header words as the CSV's, plus a final `p_text`).
    /// `date` is "YYYY-MM-DD" (the caller's clock, so this stays pure).
    public static func text(grouping: String, kind: GroupVariableKind, result: GroupTestResult, nUniverse: Int,
                            maintained: [String], dataset: String, notes: [String], date: String) -> String {
        var out = "# T2 analysis: \(dataset), \(date).\n\n"
        out += caption(grouping: grouping, kind: kind, result: result, nUniverse: nUniverse, maintained: maintained, dataset: dataset, notes: notes)
        out += "\n\n"
        let g: [[String]]
        switch kind {
        case .numeric:
            g = [["group", "n", "median", "q1", "q3"]] + result.groups.map { [$0.group, String($0.n), num($0.median), num($0.q1), num($0.q3)] }
        case .categorical:
            g = [["group", "level", "count", "prop"]] + result.levels.map { [$0.group, $0.level, String($0.count), num($0.prop)] }
        case .survival:
            g = [["group", "n", "events", "median_survival"]] + result.groups.map { [$0.group, String($0.n), $0.events.map(String.init) ?? "NA", $0.medianSurvival ?? "NA"] }
        }
        out += align(g) + "\n\n"
        let t = [["term", "method", "statistic", "df", "p", "p_bh", "note", "p_text"]] + result.test.map {
            [$0.term, $0.method, num($0.statistic), num($0.df), num($0.p), num($0.pBH), $0.note ?? "", Stats.pValueString($0.p)]
        }
        out += align(t) + "\n"
        if let why = result.refused { out += "# Not compared: \(why)\n" }
        return out
    }
}
