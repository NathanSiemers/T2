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

    // MARK: a quantized Y (UI-REWORK step 6; spec 2c, role y)

    /// The notice when the groups are consumed as the plot's colour.
    public static func quantaNotice(_ name: String) -> String {
        "\(name): the plot keeps the continuous values; the groups color the plot (and are offered on the Analysis tab)."
    }
    /// The notice when the groups cannot be the colour (a colour of the user's own, several
    /// Y probes, a survival plot): the original "no meaning" wording.
    public static func demoteNotice(_ name: String, role: String = "y") -> String {
        "\(name): groups have no meaning as \(role); the plot uses the continuous values (the groups are offered on the Analysis tab)."
    }

    public struct YColoring: Sendable, Equatable {
        /// the derived column to colour by (nil = none); it is added to the plot's columns under `column.name`
        public var column: Column?
        public var notices: [String]
    }

    /// A quantized Y keeps the continuous values on Y; the groups become the colour unless the
    /// user chose a colour (that wins; the token demotes), several Y probes are plotted
    /// (probe_quanta is not offered on iOS: demoted), or the plot is a survival plot (which
    /// cuts its own Y). The cut universe is the same as the other cuts' (mask AND finite source X
    /// AND finite Y); a refused cut gives no colour and the refusal notice.
    public static func yColoring(name: String, k: Int, userColor: String, multiY: Bool, survival: Bool,
                                 columns: [String: Column], keep: Mask, x: String) -> YColoring {
        guard (2...4).contains(k), !name.isEmpty, let src = columns[name], let values = src.numbers else {
            return YColoring(column: nil, notices: [])
        }
        if survival || multiY || !userColor.isEmpty {
            return YColoring(column: nil, notices: [demoteNotice(name)])
        }
        let u = universe(keep: keep, required: [columns[x], src])
        let r = resolve(name: name, k: k, values: values, universe: u)
        if let why = r.notice { return YColoring(column: nil, notices: [why]) }
        return YColoring(column: Column(name: r.label, type: "virtual", data: .categorical(levels: r.levels, codes: r.codes)),
                         notices: [quantaNotice(name)])
    }
}
