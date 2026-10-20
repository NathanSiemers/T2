import Foundation

// Which of a dataset's presets are worth offering, and the small cache the app keeps them in.
//
// A GROUP picks a set of samples ("GTEx normal tissues", "Primary tumors only": a rule with
// `in`); groups are alternatives, so one at most is in use. An EXCLUSION only removes samples
// ("Exclude cell lines": every rule a `not in`); any number can be on. A choice is offered
// only where it changes the samples in use: a group that is empty within the data source, or
// is the whole of it, is not offered, and nor is an exclusion that would remove nothing, or
// everything, from the source and the chosen group.

public enum PresetChoices {
    /// a preset that only removes samples
    public static func isExclusion(_ p: Preset) -> Bool { !p.rules.isEmpty && p.rules.allSatisfy { $0.op == "not in" } }

    /// does this preset keep some, but not all, of `base`?
    public static func narrows(_ label: String, within base: Mask, masks: [String: Mask]) -> Bool {
        guard let pm = masks[label], pm.count == base.count else { return false }
        var inBase = 0, kept = 0
        for i in base.indices where base[i] {
            inBase += 1
            if pm[i] { kept += 1 }
        }
        return kept > 0 && kept < inBase
    }

    /// the groups a user can choose from within the data source `source`. A group that comes
    /// to the same samples as an exclusion offered here (within GTEx, "GTEx normal tissues" is
    /// exactly "Exclude cell lines") is left to the exclusion, the clearer control.
    public static func groups(presets: [Preset], masks: [String: Mask], fixed: String?, source base: Mask) -> [Preset] {
        let exclusions = presets.filter { $0.label != fixed && isExclusion($0) && narrows($0.label, within: base, masks: masks) }
        return presets.filter { p in
            guard p.label != fixed, !isExclusion(p), narrows(p.label, within: base, masks: masks), let pm = masks[p.label] else { return false }
            return !exclusions.contains { e in
                guard let em = masks[e.label] else { return false }
                return base.indices.allSatisfy { !base[$0] || pm[$0] == em[$0] }
            }
        }
    }

    /// the exclusions that would make a difference to the source and the chosen group
    public static func exclusions(presets: [Preset], masks: [String: Mask], fixed: String?, source: Mask, group: String?) -> [Preset] {
        var base = source
        if let g = group, let gm = masks[g] { base = zip(base, gm).map { $0 && $1 } }
        return presets.filter { $0.label != fixed && isExclusion($0) && narrows($0.label, within: base, masks: masks) }
    }
}

/// Remembers one value and the key it was worked out for: asking again with the same key
/// returns it without working it out again; a different key works it out anew. The app keys
/// its plot scene and its choices by a revision counter that moves on every real change, so
/// a screen redrawn ten times for one change computes once.
public final class KeyedCache<Key: Equatable, Value> {
    private var key: Key?
    private var value: Value?
    /// how many times `make` has run (for tests and diagnostics)
    public private(set) var computations = 0
    public init() {}
    public func get(_ key: Key, make: () -> Value) -> Value {
        if let v = value, self.key == key { return v }
        let v = make()
        self.key = key; self.value = v; computations += 1
        return v
    }
    public func invalidate() { key = nil; value = nil }
}
