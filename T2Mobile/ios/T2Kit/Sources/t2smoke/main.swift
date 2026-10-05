// t2smoke: the Swift client against a RUNNING t2api, end to end, from the command line.
//   swift run t2smoke http://t2api:8080
// Walks what the app does on first launch: list datasets, read one dataset's meta and
// clinical table, fetch its default variables, apply each preset, cross-filter, fit a line.
import Foundation
import T2Kit

let base = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "http://127.0.0.1:3860"
let api = APIClient(baseURL: URL(string: base)!)
var failures = 0
func check(_ ok: Bool, _ msg: String) { print(ok ? "  PASS " : "  FAIL ", msg); if !ok { failures += 1 } }

let datasets = try await api.datasets()
check(!datasets.isEmpty, "datasets: \(datasets.map(\.name).joined(separator: ", "))")
for ds in datasets {
    print("\n== \(ds.name): \(ds.title) ==")
    let meta = try await api.meta(ds.name)
    let clin = try await api.clinical(ds.name)
    check(clin.samples.count == ds.nSamples && clin.columns.allSatisfy { $0.count == ds.nSamples },
          "clinical: \(clin.samples.count) samples x \(clin.columns.count) columns, every column full length")
    var cf = CrossFilter(sampleCount: clin.n)
    cf.load(clin.columns)
    // the dataset's default variables (some are clinical, some probes)
    let wanted = ["x", "y", "color"].compactMap { meta.defaults[$0] }.filter { !$0.isEmpty }
    let fetched = try await api.values(ds.name, probes: wanted + ["no_such_probe_zzz"])
    cf.load(fetched.columns)
    check(fetched.missing == ["no_such_probe_zzz"] && fetched.columns.count == Set(wanted).count,
          "values for the defaults (\(wanted.joined(separator: ", "))): \(fetched.columns.map { "\($0.name) [\($0.isNumeric ? "numeric" : "categorical"), \($0.missingCount) missing]" }.joined(separator: "; "))")
    for p in meta.presets {
        let n = p.mask(columns: cf.columns, sampleCount: clin.n).filter { $0 }.count
        check(n > 0 && n < clin.n, "preset \"\(p.label)\" (\(p.source)): \(n) of \(clin.n) samples")
    }
    let search = try await api.searchProbes(ds.name, query: "a", limit: 5)
    check(search.totalMatches > 0, "search \"a\": \(search.totalMatches) matches, first: \(search.probes.prefix(3).joined(separator: ", "))")
    // cross-filter on the first numeric default: keep its upper half
    if let y = fetched.columns.first(where: \.isNumeric), let v = y.numbers {
        cf.add(y.name)
        cf.set(y.name, value: .range(lo: Stats.median(v), hi: .infinity), includeMissing: false)
        let h = cf.histogram(y.name)!
        check(cf.selectedCount() > 0 && cf.selectedCount() < clin.n && h.selectedTotal == cf.selectedCount(),
              "filter \(y.name) >= median: \(cf.selectedCount()) of \(clin.n) samples; histogram agrees")
    }
}
// two probes, a regression: the plot the T2 site draws for CD8A vs FOXP3
if datasets.contains(where: { $0.name == "TCGA" }) {
    let r = try await api.values("TCGA", probes: ["CD8A", "FOXP3", "TP53.mut"])
    let byName = Dictionary(uniqueKeysWithValues: r.columns.map { ($0.name, $0) })
    if let x = byName["CD8A"]?.numbers, let y = byName["FOXP3"]?.numbers, let line = Stats.regression(x: x, y: y) {
        print(String(format: "\nTCGA  FOXP3 ~ CD8A: slope %.4f, intercept %.4f, r %.4f, n %d", line.slope, line.intercept, line.r, line.n))
        check(line.n > 10000 && line.r > 0.5, "regression over \(line.n) samples")
    }
    check(byName["TP53.mut"]?.levels == ["0", "1"], "TP53.mut arrives as a categorical 0/1")
}
print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
