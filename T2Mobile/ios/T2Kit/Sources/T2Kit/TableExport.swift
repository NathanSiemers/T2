import Foundation

/// The table behind a plot, as the website's "Download Table": one row per sample in use,
/// the sample id and the chosen variables, as CSV text.
///
/// Numbers are written with the shortest text that reads back as the same 64-bit value
/// (what the service sent); a missing value is `NA`, as R writes it.
public enum TableExport {
    public static func csv(samples: [String], columns: [Column], keep: Mask) -> String {
        var out = (["sample"] + columns.map(\.name)).map(quoted).joined(separator: ",") + "\n"
        for i in samples.indices where i < keep.count && keep[i] {
            var fields = [quoted(samples[i])]
            for c in columns {
                guard i < c.count else { fields.append("NA"); continue }
                switch c.data {
                case .numeric(let v): fields.append(number(v[i]))
                case .categorical(let levels, let codes): fields.append(codes[i] >= 0 ? quoted(levels[codes[i]]) : "NA")
                }
            }
            out += fields.joined(separator: ",") + "\n"
        }
        return out
    }

    /// shortest text that round-trips; whole numbers without ".0"
    static func number(_ v: Double) -> String {
        if v.isNaN { return "NA" }
        if v.isInfinite { return v > 0 ? "Inf" : "-Inf" }
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return "\(v)"
    }
    /// quoted only when it has to be (a comma, a quote, a line break, or text that would read as missing)
    static func quoted(_ s: String) -> String {
        if s.isEmpty || s == "NA" || s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
