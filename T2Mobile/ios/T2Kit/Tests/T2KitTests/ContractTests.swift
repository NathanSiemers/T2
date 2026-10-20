import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import T2Kit

// The dataset contract in the app layer (docs/DATASET-CONTRACT.md): survival read from a
// declared time-to-event entry, parallel value fetches, and the caches.

final class ContractSurvivalTests: XCTestCase {
    // the 6-MP trial of PlotBuilderMoreTests, its columns under names that follow no pair rule
    let time: [Double] = [6,6,6,6,7,9,10,10,11,13,16,17,19,20,22,23,25,32,32,34,35, 1,1,2,2,3,4,4,5,5,8,8,8,8,11,11,12,12,15,17,22,23]
    let event: [Double] = [1,1,1,0,1,0,1,0,0,1,1,0,0,0,1,1,0,0,0,0,0] + [Double](repeating: 1, count: 21)
    let z: [Double] = [0.3,-1.2,0.8,1.5,-0.4,0.1,2.0,-0.7,0.9,-1.5,0.2,1.1,-0.3,0.6,-0.9,1.8,-0.1,0.4,-1.1,0.7,1.3,
                       -0.5,1.0,-1.4,0.5,-0.2,1.6,-0.8,0.0,1.2,-1.0,0.35,-0.6,1.4,-1.3,0.75,-0.15,1.7,-0.45,0.95,-1.6,0.25]
    let all = Mask(repeating: true, count: 42)

    var columns: [String: Column] {
        // "OS" and "OS.time" exist but are decoys (not the declared columns): any code that
        // assumed the X / X.time pair would read them and get different numbers
        ["death": Column(name: "death", type: "clinical", data: .numeric(event)),
         "days_to_death": Column(name: "days_to_death", type: "clinical", data: .numeric(time)),
         "OS": Column(name: "OS", type: "clinical", data: .numeric([Double](repeating: 1, count: 42))),
         "OS.time": Column(name: "OS.time", type: "clinical", data: .numeric((0..<42).map { Double($0 + 1) })),
         "M": Column(name: "M", type: "rna", data: .numeric(z)),
         "arm": Column(name: "arm", type: "clinical", data: .categorical(levels: ["6-MP", "control"], codes: (0..<42).map { $0 < 21 ? 0 : 1 }))]
    }

    func testSurvivalReadsTheDeclaredColumnsNotThePairRule() {
        let entry = TTEVariable(name: "OS", label: "Overall Survival", eventCol: "death", timeCol: "days_to_death", timeUnit: "days")
        let context = PlotBuilder.Context(datasetLabel: "Trial", tte: [entry])
        var r = PlotRequest(x: ["OS"], y: ["arm"]); r.kmMaxDays = 0
        let s = PlotBuilder.build(r, columns: columns, keep: all, context: context)
        XCTAssertEqual(s.kind, .survival)
        XCTAssertEqual(s.title, "Overall Survival by arm groups")
        // the numbers of the 6-MP trial (survfit medians 23 and 8; survdiff p 4.2e-05), not of the decoys
        XCTAssertEqual(s.legend.entries.map(\.label), ["6-MP (med 23d)", "control (med 8d)"])
        XCTAssertEqual(s.stats.first { $0.label == "Log-rank p" }?.value, "4.2e-05")
        XCTAssertEqual(s.panels[0].yAxis.title, "OS probability")
        XCTAssertEqual(s.panels[0].xAxis.title, "Time (days)")
        // the same entry through names that DO follow the pair rule gives the same plot
        var paired = columns; paired["OS"] = columns["death"]; paired["OS.time"] = columns["days_to_death"]
        let p = PlotBuilder.build(r, columns: paired, keep: all,
                                  context: PlotBuilder.Context(datasetLabel: "Trial", tte: [TTEVariable(name: "OS", label: "Overall Survival", eventCol: "OS", timeCol: "OS.time")]))
        XCTAssertEqual(p.legend.entries.map(\.label), s.legend.entries.map(\.label))
        XCTAssertEqual(p.panels[0].lines.map(\.ys), s.panels[0].lines.map(\.ys))
    }

    func testSurvivalNeedsADeclaredEntryAndItsColumns() {
        // no entry for the name: OS is an ordinary numeric variable, whatever columns exist
        let none = PlotBuilder.build(PlotRequest(x: ["OS"], y: ["M"]), columns: columns, keep: all, context: PlotBuilder.Context(tte: []))
        XCTAssertEqual(none.kind, .scatter)
        // an entry whose columns the dataset lacks says which
        let bad = TTEVariable(name: "OS", label: "Overall Survival", eventCol: "gone", timeCol: "days_to_death")
        let s = PlotBuilder.build(PlotRequest(x: ["OS"], y: ["M"]), columns: columns, keep: all, context: PlotBuilder.Context(tte: [bad]))
        XCTAssertEqual(s.kind, .empty); XCTAssertTrue(s.message.contains("gone")); XCTAssertTrue(s.message.contains("Overall Survival"))
    }

    func testSurvivalUnitLabelsAndTicks() {
        let entry = TTEVariable(name: "RFS", label: "Relapse-free survival", eventCol: "death", timeCol: "days_to_death", timeUnit: "weeks")
        var r = PlotRequest(x: ["RFS"], y: ["arm"]); r.kmMaxDays = 30
        let s = PlotBuilder.build(r, columns: columns, keep: all, context: PlotBuilder.Context(tte: [entry]))
        XCTAssertEqual(s.kind, .survival, s.message)
        guard s.kind == .survival else { return }
        XCTAssertEqual(s.title, "Relapse-free survival by arm groups")
        XCTAssertEqual(s.panels[0].xAxis.title, "Time (weeks)")
        XCTAssertTrue(s.legend.entries[0].label.hasSuffix(" weeks)"), s.legend.entries[0].label)
        XCTAssertTrue(s.subtitle.contains("median RFS:")); XCTAssertTrue(s.subtitle.contains("follow-up \u{2264} 30 weeks"))
        // 365-unit ticks are for days only: here the axis ticks are round numbers up to the limit
        XCTAssertNotEqual(s.panels[0].xAxis.ticks, [0, 365])
        XCTAssertTrue(s.panels[0].xAxis.ticks.allSatisfy { $0 <= 30.6 })
    }

    func testHandleColumnsComeFromTheContextForIncompleteSamples() {
        // two handles, the sample type missing in one sample: dropped only when the context names it
        let n = 30
        let x = (0..<n).map { Double($0) }, y = (0..<n).map { Double($0 % 7) }
        var st = [Int](repeating: 0, count: n); st[3] = -1
        let cols: [String: Column] = ["a": Column(name: "a", type: "rna", data: .numeric(x)), "b": Column(name: "b", type: "rna", data: .numeric(y)),
                                      "stype": Column(name: "stype", type: "clinical", data: .categorical(levels: ["T"], codes: st))]
        var r = PlotRequest(x: ["a"], y: ["b"]); r.completeOnly = true
        let keep = Mask(repeating: true, count: n)
        XCTAssertEqual(PlotBuilder.build(r, columns: cols, keep: keep, context: PlotBuilder.Context()).n, n)
        XCTAssertEqual(PlotBuilder.build(r, columns: cols, keep: keep, context: PlotBuilder.Context(handleColumns: ["stype"])).n, n - 1)
    }

    func testNumericOnlyWarnsOnceAndDrops() {
        let cols: [String: Column] = ["a": Column(name: "a", type: "rna", data: .numeric([1])), "c": Column(name: "c", type: "clinical", data: .categorical(levels: ["x"], codes: [0]))]
        var w: [String] = []
        let kept = PlotBuilder.numericOnly(["a", "c", "zz"], columns: cols, warnings: &w) { "not numeric: \($0)" }
        XCTAssertEqual(kept, ["a"]); XCTAssertEqual(w, ["not numeric: c, zz"])
        w = []
        XCTAssertEqual(PlotBuilder.numericOnly(["a"], columns: cols, warnings: &w) { $0 }, ["a"]); XCTAssertEqual(w, [])
    }

    func testLevelsPresentAndGroupsOnAColumn() {
        let c = Column(name: "g", type: "clinical", data: .categorical(levels: ["a", "b", "c"], codes: [0, 2, 2, -1, 0]))
        XCTAssertEqual(c.levelsPresent(rows: [1, 2, 3]), [2])
        XCTAssertEqual(c.levelsPresent(rows: [0, 1, 3]), [0, 2])
        XCTAssertEqual(c.levelsPresent(in: nil), [0, 2])
        XCTAssertEqual(c.levelsPresent(in: [true, false, false, true, false]), [0])
        XCTAssertEqual(c.groups(rows: [0, 1, 2, 3, 4]), [0: [0, 4], 2: [1, 2]])      // the missing sample is in no group
        XCTAssertEqual(Column(name: "n", type: "rna", data: .numeric([1, 2])).levelsPresent(rows: [0]), [])
    }
}

/// Answers /values requests itself, the first chunk slowest, so that chunks finish in the
/// reverse of the order they were asked in.
final class ValuesStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var version = "v1"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let probes = (comps?.queryItems?.first { $0.name == "probes" }?.value ?? "").split(separator: ",").map(String.init)
        let first = Int(probes.first?.dropFirst(1) ?? "0") ?? 0           // names are p0, p1, ...
        let delay = max(0.0, 0.30 - Double(first / APIClient.maxProbesPerRequest) * 0.12)
        let cols = probes.map { #"{"name":"\#($0)","kind":"num","type":"rna","values":[1,2]}"# }.joined(separator: ",")
        let missing = probes.filter { $0.hasSuffix("7") }.map { "\"\($0)\"" }.joined(separator: ",")
        let body = #"{"dataset":"d","version":"\#(Self.version)","n":2,"columns":[\#(cols)],"missing":[\#(missing)]}"#
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            let resp = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

final class ParallelValuesTests: XCTestCase {
    private func client() -> APIClient {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ValuesStub.self]
        return APIClient(baseURL: URL(string: "http://stub.invalid")!, session: URLSession(configuration: cfg))
    }

    func testChunksAreFetchedTogetherAndKeepTheirOrder() async throws {
        ValuesStub.version = "v1"
        let names = (0..<250).map { "p\($0)" }                  // three requests of at most 100
        let started = Date()
        let r = try await client().values("d", probes: names, version: "v1")
        XCTAssertEqual(r.columns.map(\.name), names)            // the order asked, though the last chunk answers first
        XCTAssertEqual(r.missing, names.filter { $0.hasSuffix("7") })
        // sequentially the delays add up (0.30 + 0.18 + 0.06); together it is the longest one
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.50)
        // one request, and none
        let two = try await client().values("d", probes: ["p0", "p1"], version: "v1")
        XCTAssertEqual(two.columns.map(\.name), ["p0", "p1"])
        let none = try await client().values("d", probes: [], version: "v1")
        XCTAssertEqual(none.columns, []); XCTAssertEqual(none.missing, [])
    }

    func testAChangedVersionInAnyChunkFails() async {
        ValuesStub.version = "v2"
        do {
            _ = try await client().values("d", probes: (0..<150).map { "p\($0)" }, version: "v1")
            XCTFail("expected versionChanged")
        } catch APIClient.APIError.versionChanged {
        } catch { XCTFail("wrong error \(error)") }
    }
}

final class CacheTests: XCTestCase {
    func testKeyedCacheComputesOncePerKey() {
        let c = KeyedCache<Int, [Int]>()
        var made = 0
        func get(_ k: Int) -> [Int] { c.get(k) { made += 1; return [k] } }
        XCTAssertEqual(get(1), [1]); XCTAssertEqual(get(1), [1]); XCTAssertEqual(get(1), [1])
        XCTAssertEqual(made, 1)                                  // three redraws, one computation
        XCTAssertEqual(get(2), [2]); XCTAssertEqual(made, 2)     // a real change (the revision moved): worked out again
        XCTAssertEqual(get(1), [1]); XCTAssertEqual(made, 3)     // the old key does not come back stale
        c.invalidate(); _ = get(1); XCTAssertEqual(made, 4)
        XCTAssertEqual(c.computations, 4)
    }

    /// the choices a dataset offers, and that the cache serves a changed dataset afresh
    func testPresetChoicesAndTheirCacheFollowTheRevision() {
        let tumor = Preset(label: "Primary only", rules: [.init(column: "type", op: "in", values: ["P"])])
        let noCL = Preset(label: "Exclude cell lines", rules: [.init(column: "cl", op: "not in", values: ["y"])])
        let useless = Preset(label: "Everything", rules: [.init(column: "type", op: "in", values: ["P", "N"])])
        let presets = [tumor, noCL, useless]
        let cols: [String: Column] = [
            "type": Column(name: "type", type: "clinical", data: .categorical(levels: ["P", "N"], codes: [0, 0, 1, 1])),
            "cl": Column(name: "cl", type: "clinical", data: .categorical(levels: ["y", "n"], codes: [1, 1, 1, 0]))]
        let masks = Dictionary(uniqueKeysWithValues: presets.map { ($0.label, $0.mask(columns: cols, sampleCount: 4)) })
        let all = Mask(repeating: true, count: 4)
        XCTAssertTrue(PresetChoices.isExclusion(noCL)); XCTAssertFalse(PresetChoices.isExclusion(tumor))
        XCTAssertEqual(PresetChoices.groups(presets: presets, masks: masks, fixed: nil, source: all).map(\.label), ["Primary only"])
        XCTAssertEqual(PresetChoices.exclusions(presets: presets, masks: masks, fixed: nil, source: all, group: nil).map(\.label), ["Exclude cell lines"])
        // within the chosen group (samples 0,1) the exclusion removes nothing: not offered
        XCTAssertEqual(PresetChoices.exclusions(presets: presets, masks: masks, fixed: nil, source: all, group: "Primary only"), [])
        // a source that is the first two samples makes the group the whole of it: not offered
        XCTAssertEqual(PresetChoices.groups(presets: presets, masks: masks, fixed: nil, source: [true, true, false, false]), [])

        // the cache in front of it: keyed by (dataset revision), recomputed when the dataset changes
        let cache = KeyedCache<Int, [Preset]>()
        var revision = 1
        var source = all
        func groups() -> [Preset] { cache.get(revision) { PresetChoices.groups(presets: presets, masks: masks, fixed: nil, source: source) } }
        XCTAssertEqual(groups().count, 1); XCTAssertEqual(groups().count, 1)
        XCTAssertEqual(cache.computations, 1)
        source = [true, true, false, false]                      // the data source changed but nobody said so: still the old answer
        XCTAssertEqual(groups().count, 1)
        revision += 1                                            // a real change bumps the revision
        XCTAssertEqual(groups().count, 0); XCTAssertEqual(cache.computations, 2)
    }
}

final class CrossFilterCacheTests: XCTestCase {
    /// the leave-one-out masks from the failure counts are the brute-force ones, and a change
    /// of any kind is seen at once (the memo of the old state is never served)
    func testLeaveOneOutAndCachesFollowEveryChange() {
        let n = 60
        let a = (0..<n).map { Double($0) }
        let b = (0..<n).map { Double(($0 * 7) % 11) }
        let g = (0..<n).map { $0 % 4 == 0 ? -1 : $0 % 3 }
        var cf = CrossFilter(sampleCount: n)
        cf.load([Column(name: "a", type: "rna", data: .numeric(a)), Column(name: "b", type: "rna", data: .numeric(b)),
                 Column(name: "g", type: "clinical", data: .categorical(levels: ["x", "y", "z"], codes: g))])
        for c in ["a", "b", "g"] { cf.add(c) }
        func brute(excluding name: String?) -> Mask {
            var keep = cf.baseMask ?? Mask(repeating: true, count: n)
            for f in cf.filters where f.column != name && f.isActive {
                let m = f.mask(for: cf.columns[f.column]!)
                for i in 0..<n where !m[i] { keep[i] = false }
            }
            return keep
        }
        func check() {
            for name in [nil, "a", "b", "g"] as [String?] { XCTAssertEqual(cf.mask(excluding: name), brute(excluding: name), "excluding \(name ?? "none")") }
        }
        check()
        // the revision moves on every real change and on nothing else (the app's caches are keyed by it)
        var rev = cf.revision
        _ = cf.mask(); _ = cf.histogram("a"); _ = cf.levelsPresent("g"); XCTAssertEqual(cf.revision, rev)
        cf.set("a", value: .range(lo: 1, hi: 50)); XCTAssertGreaterThan(cf.revision, rev); rev = cf.revision
        cf.baseMask = Mask(repeating: true, count: n); XCTAssertGreaterThan(cf.revision, rev); rev = cf.revision
        cf.remove("a"); XCTAssertGreaterThan(cf.revision, rev); cf.add("a"); cf.set("a", value: nil)
        let before = cf.selectedCount()
        cf.set("a", value: .range(lo: 10, hi: 40)); check()
        cf.set("b", value: .range(lo: 2, hi: 8), includeMissing: false); check()
        cf.set("g", value: .levels(["x", "z"])); check()
        XCTAssertLessThan(cf.selectedCount(), before)
        cf.baseMask = (0..<n).map { $0 % 2 == 0 }; check()
        XCTAssertEqual(cf.levelsPresent("g"), [0, 1, 2].filter { l in (0..<n).contains { $0 % 2 == 0 && g[$0] == l } })
        cf.remove("a"); check()
        cf.add("a", first: true); check()
        // histogram bins do not move with the filters; counts do
        let h1 = cf.histogram("a", bins: 10)!
        cf.set("a", value: .range(lo: 0, hi: 5))
        let h2 = cf.histogram("a", bins: 10)!
        XCTAssertEqual(h1.edges, h2.edges); XCTAssertNotEqual(h1.selected, h2.selected); XCTAssertEqual(h1.shown, h2.shown)
        // a column loaded again with other numbers: range and masks are worked out afresh
        cf.load([Column(name: "a", type: "rna", data: .numeric(a.map { $0 * 2 }))])
        XCTAssertEqual(cf.histogram("a", bins: 10)!.edges.last!, h1.edges.last! * 2, accuracy: 1e-9)
    }
}
