import Foundation

/// The Select tab's quantize chip (spec 2c, token roles x / color / graph-for-each): a numeric
/// variable cut into 2-4 quantile groups, shown to the plot as a derived categorical column.
/// Same rule as the website's quant_resolve (lib.R): the cut points come from the plotted
/// complete rows only (current mask AND a value for the source X AND a value for Y), are global,
/// and are `t2_quantile_groups(m, k, min_n = 5)` == `Stats.quantileGroupsUnique` + `groupLabels`.
public enum SelectCut {
    public struct Result: Sendable, Equatable {
        /// the derived column's name: "<name> (halves|tertiles|quartiles)"
        public var label: String
        public var levels: [String]
        /// group of every sample (-1 = outside the universe, or missing)
        public var codes: [Int]
        /// the samples in each group
        public var sizes: [Int]
        /// the plain-language notice when the cut was refused (the plot then uses the source column)
        public var notice: String?
    }

    public static func label(name: String, k: Int) -> String {
        "\(name) (\(k == 2 ? "halves" : k == 3 ? "tertiles" : k == 4 ? "quartiles" : "\(k) groups"))"
    }

    /// The universe: the mask AND, for each given column, a value. `required` are the source
    /// columns of X and Y (nil entries = not a served column, e.g. a survival endpoint: no rule).
    public static func universe(keep: Mask, required: [Column?]) -> Mask {
        var u = keep
        for case let c? in required {
            for i in u.indices where u[i] {
                if c.isMissing(i) { u[i] = false }
                else if let v = c.numbers, !v[i].isFinite { u[i] = false }
            }
        }
        return u
    }

    /// Cut `values` (the source column, full length) into `k` groups over `universe`.
    public static func resolve(name: String, k: Int, values: [Double], universe: Mask) -> Result {
        let n = values.count
        let lab = label(name: name, k: k)
        func refuse(_ why: String) -> Result {
            Result(label: lab, levels: [], codes: [Int](repeating: -1, count: n), sizes: [],
                   notice: "\(name) cannot be split into \(k) groups: \(why); the plot uses the continuous values.")
        }
        let m = (0..<n).map { universe.indices.contains($0) && universe[$0] && values[$0].isFinite ? values[$0] : Double.nan }
        let cut = Stats.quantileGroupsUnique(m, groups: k)
        guard cut.count >= 2 else { return refuse("it has fewer than 2 distinct values among the plotted samples") }
        var sizes = [Int](repeating: 0, count: cut.count)
        for g in cut.group where g >= 0 { sizes[g] += 1 }
        if sizes.contains(where: { $0 < groupMinN }) {
            return refuse("the groups would hold only \(sizes.map(String.init).joined(separator: "/")) samples (at least \(groupMinN) are needed in each; many samples share one marker value). Try fewer groups")
        }
        return Result(label: lab, levels: Stats.groupLabels(made: cut.count), codes: cut.group, sizes: sizes, notice: nil)
    }
}
