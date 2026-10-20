import Foundation

// Choosing which samples are used: presets (ready-made subsets from the server) and the
// cross-filter (Thanos, in the T2T website): any number of columns, each with a range or a
// set of levels, and for each column a histogram of the samples that pass all the OTHER
// filters, so the effect of one filter on every other variable is visible at once.
//
// Semantics are those of Thanos (make_mask in thanos_plot.R):
//   - a range keeps lo <= x <= hi; an infinite bound means "no limit on that side"
//   - a level set keeps the samples whose level is in it
//   - a missing value passes if and only if `includeMissing` is on (the default)
//   - no value set = no restriction (apart from includeMissing)

/// Which samples a mask keeps: `mask[i]` is true if sample `i` is in.
public typealias Mask = [Bool]

public extension Preset {
    /// The samples in this preset. A rule over a column that is absent or not categorical
    /// excludes nothing (the server only sends rules that fit the dataset).
    func mask(columns: [String: Column], sampleCount: Int) -> Mask {
        var keep = Mask(repeating: true, count: sampleCount)
        for rule in rules {
            guard let col = columns[rule.column], case .categorical(let levels, let codes) = col.data else { continue }
            let wanted = Set(rule.values)
            let hit = levels.map { wanted.contains($0) }
            let isIn = rule.op == "in"
            for i in 0..<min(sampleCount, codes.count) {
                let inSet = codes[i] >= 0 && hit[codes[i]]
                if inSet != isIn { keep[i] = false }
            }
        }
        return keep
    }
}

/// One column's filter.
public struct ColumnFilter: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case range(lo: Double, hi: Double)
        case levels(Set<String>)
    }
    public var column: String
    public var value: Value?
    public var includeMissing: Bool
    public init(column: String, value: Value? = nil, includeMissing: Bool = true) {
        self.column = column; self.value = value; self.includeMissing = includeMissing
    }
    /// does this filter restrict anything?
    public var isActive: Bool {
        if !includeMissing { return true }
        switch value {
        case nil: return false
        case .range(let lo, let hi): return lo.isFinite || hi.isFinite
        case .levels: return true
        }
    }

    public func mask(for col: Column) -> Mask {
        switch col.data {
        case .numeric(let x):
            guard case .range(let lo, let hi)? = value else {
                return x.map { includeMissing || !$0.isNaN }
            }
            return x.map { $0.isNaN ? includeMissing : ($0 >= lo && $0 <= hi) }
        case .categorical(let levels, let codes):
            guard case .levels(let wanted)? = value else {
                return codes.map { includeMissing || $0 >= 0 }
            }
            let hit = levels.map { wanted.contains($0) }
            return codes.map { $0 < 0 ? includeMissing : hit[$0] }
        }
    }
}

/// Counts for one column's histogram.
public struct Histogram: Sendable, Equatable {
    /// bin labels: level names, or the centre of each numeric bin
    public var labels: [String]
    /// numeric bins only: lower edge of each bin, and the common width
    public var edges: [Double]
    public var width: Double
    /// samples passing all OTHER filters, per bin
    public var shown: [Int]
    /// of those, the ones also passing this column's own filter
    public var selected: [Int]
    /// totals including samples with no value for this column (they have no bin)
    public var shownTotal: Int
    public var selectedTotal: Int
}

/// What a cross-filter works out once and reuses until it changes: each filter's own mask,
/// how many active filters each sample fails (so every leave-one-out mask costs O(n), not
/// O(filters x n)), the levels present in the universe. A class so that the value-type
/// CrossFilter can fill it from non-mutating methods; every mutation gives the filter a fresh one.
final class FilterMemo: @unchecked Sendable {
    private let lock = NSRecursiveLock()      // failCounts() fills itself from ownMask()
    private var own: [String: Mask] = [:]
    private var fails: [Int32]?
    private var present: [String: [Int]] = [:]
    func with<T>(_ body: (FilterMemo) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }
    func ownMask(_ name: String, make: () -> Mask) -> Mask {
        with { m in
            if let hit = m.own[name] { return hit }
            let made = make(); m.own[name] = made; return made
        }
    }
    func failCounts(make: () -> [Int32]) -> [Int32] {
        with { m in
            if let hit = m.fails { return hit }
            let made = make(); m.fails = made; return made
        }
    }
    func levels(_ name: String, make: () -> [Int]) -> [Int] {
        with { m in
            if let hit = m.present[name] { return hit }
            let made = make(); m.present[name] = made; return made
        }
    }
}

/// Facts about a loaded column that do not depend on the filters (the range the histogram
/// bins are cut from): worked out once per column, kept until columns are loaded again.
final class ColumnMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var ranges: [String: (lo: Double, hi: Double)?] = [:]
    func range(_ name: String, make: () -> (lo: Double, hi: Double)?) -> (lo: Double, hi: Double)? {
        lock.lock(); defer { lock.unlock() }
        if let hit = ranges[name] { return hit }
        let made = make(); ranges[name] = .some(made); return made
    }
}

/// The cross-filter over a set of loaded columns.
public struct CrossFilter: Sendable {
    public let sampleCount: Int
    public private(set) var columns: [String: Column] = [:] { didSet { columnMemo = ColumnMemo(); changed() } }
    /// the filter columns, in display order
    public private(set) var filters: [ColumnFilter] = [] { didSet { changed() } }
    /// the universe: samples outside it do not exist as far as the filter is concerned
    /// (the combination of the active presets); nil = all samples
    public var baseMask: Mask? { didSet { changed() } }
    /// moves on every change of the columns, the filters or the universe: the key under which
    /// anything computed from this filter (the mask, the plot) can be kept until it moves
    public private(set) var revision = 0
    private var memo = FilterMemo()
    private mutating func changed() { memo = FilterMemo(); revision &+= 1 }
    private var columnMemo = ColumnMemo()

    public init(sampleCount: Int) { self.sampleCount = sampleCount }

    /// make columns available (needed before they can be filtered on)
    public mutating func load(_ cols: [Column]) {
        for c in cols where c.count == sampleCount { columns[c.name] = c }
    }
    /// add a column to the filter set (no restriction yet); no-op if already there or unknown.
    /// `first`: put it at the top of the list (a column the user just asked for), else at the end
    public mutating func add(_ name: String, first: Bool = false) {
        guard columns[name] != nil, !filters.contains(where: { $0.column == name }) else { return }
        if first { filters.insert(ColumnFilter(column: name), at: 0) } else { filters.append(ColumnFilter(column: name)) }
    }
    /// removing a column removes its filter completely
    public mutating func remove(_ name: String) { filters.removeAll { $0.column == name } }
    public mutating func set(_ name: String, value: ColumnFilter.Value?, includeMissing: Bool? = nil) {
        guard let i = filters.firstIndex(where: { $0.column == name }) else { return }
        filters[i].value = value
        if let includeMissing { filters[i].includeMissing = includeMissing }
    }
    public func filter(_ name: String) -> ColumnFilter? { filters.first { $0.column == name } }

    /// the indices of the levels of a categorical column that have at least one sample in
    /// the universe (base mask): a level of another part of a split dataset ("TCGA" in the
    /// GTEx part) is not offered as a filter choice, it would be a no-op
    public func levelsPresent(_ name: String) -> [Int] {
        guard let col = columns[name], col.levels != nil else { return [] }
        return memo.levels(name) { col.levelsPresent(in: baseMask) }
    }

    private func base() -> Mask { baseMask ?? Mask(repeating: true, count: sampleCount) }

    /// one filter's own mask (not including the universe), kept until something changes
    private func ownMask(_ f: ColumnFilter, _ col: Column) -> Mask {
        memo.ownMask(f.column) { f.mask(for: col) }
    }
    /// per sample, how many of the active filters it fails
    private func failCounts() -> [Int32] {
        memo.failCounts {
            var fails = [Int32](repeating: 0, count: sampleCount)
            for f in filters where f.isActive {
                guard let col = columns[f.column] else { continue }
                let m = ownMask(f, col)
                for i in 0..<sampleCount where !m[i] { fails[i] += 1 }
            }
            return fails
        }
    }

    /// samples passing the universe and every filter
    public func mask() -> Mask { mask(excluding: nil) }
    /// samples passing the universe and every filter EXCEPT `name`'s (leave-one-out): the
    /// failure counts are made once, so each leave-one-out mask is one pass over the samples
    public func mask(excluding name: String?) -> Mask {
        var keep = base()
        let fails = failCounts()
        // an active filter on `name` that a sample fails counts once in `fails`: take it back
        var own: Mask? = nil
        if let name, let f = filters.first(where: { $0.column == name && $0.isActive }), let col = columns[name] { own = ownMask(f, col) }
        for i in 0..<sampleCount where keep[i] {
            let f = fails[i] - (own.map { $0[i] ? 0 : 1 } ?? 0)
            if f > 0 { keep[i] = false }
        }
        return keep
    }
    public func selectedCount() -> Int { mask().reduce(0) { $0 + ($1 ? 1 : 0) } }
    public func universeCount() -> Int { base().reduce(0) { $0 + ($1 ? 1 : 0) } }

    /// the histogram of one column: samples passing all other filters, split by its own
    public func histogram(_ name: String, bins: Int = 40) -> Histogram? {
        guard let col = columns[name] else { return nil }
        let loo = mask(excluding: name)
        let own = ownMask(filter(name) ?? ColumnFilter(column: name), col)
        var shownTotal = 0, selectedTotal = 0
        for i in 0..<sampleCount where loo[i] { shownTotal += 1; if own[i] { selectedTotal += 1 } }
        switch col.data {
        case .categorical(let levels, let codes):
            var shown = [Int](repeating: 0, count: levels.count), sel = shown
            for i in 0..<sampleCount where loo[i] && codes[i] >= 0 {
                shown[codes[i]] += 1
                if own[i] { sel[codes[i]] += 1 }
            }
            return Histogram(labels: levels, edges: [], width: 0, shown: shown, selected: sel,
                             shownTotal: shownTotal, selectedTotal: selectedTotal)
        case .numeric(let x):
            // bin edges come from the WHOLE column, so bars do not move as filters change
            let range = columnMemo.range(name) {
                let present = x.filter { !$0.isNaN }
                guard let lo = present.min(), let hi = present.max() else { return nil }
                return (lo, hi)
            }
            guard let (lo, hi) = range else {
                return Histogram(labels: [], edges: [], width: 0, shown: [], selected: [], shownTotal: shownTotal, selectedTotal: selectedTotal)
            }
            let n = max(1, bins)
            let width = hi > lo ? (hi - lo) / Double(n) : 1
            var shown = [Int](repeating: 0, count: n), sel = shown
            for i in 0..<sampleCount where loo[i] && !x[i].isNaN {
                let b = min(n - 1, max(0, Int((x[i] - lo) / width)))
                shown[b] += 1
                if own[i] { sel[b] += 1 }
            }
            let edges = (0..<n).map { lo + Double($0) * width }
            return Histogram(labels: edges.map { String(format: "%.3g", $0 + width / 2) }, edges: edges, width: width,
                             shown: shown, selected: sel, shownTotal: shownTotal, selectedTotal: selectedTotal)
        }
    }
}
