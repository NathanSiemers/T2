import SwiftUI
import T2Kit

/// The Thanos screen: one card per filter column. A numeric column shows a histogram of
/// the samples that pass all the OTHER filters, with this column's own selection
/// highlighted, and a range; a categorical column shows its levels as bars that are also
/// the checkboxes. All counting is T2Kit's (CrossFilter); nothing is asked of the server.
struct FilterView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.meta == nil {
                    NoDatasetView()
                } else {
                    list
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var list: some View {
        List {
            Section {
                let selected = model.filter.selectedCount(), universe = model.filter.universeCount()
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(selected.formatted()) of \(universe.formatted()) samples selected")
                        .font(.headline)
                        .accessibilityIdentifier("filter-count")
                    if universe < model.filter.sampleCount {
                        Text("\(model.filter.sampleCount.formatted()) in the dataset; the subsets switched on under Select leave \(universe.formatted()).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if selected == 0 {
                        Text("No sample passes every filter: nothing will be plotted.")
                            .font(.footnote).foregroundStyle(.orange)
                            .accessibilityIdentifier("filter-none")
                    }
                }
                VariablePicker(title: "Add a filter column", current: "", allowNone: false) { name in
                    Task { await model.addFilterColumn(name) }
                }
                if model.filter.filters.contains(where: \.isActive) {
                    Button("Remove all restrictions", role: .destructive) { model.resetFilters() }
                        .accessibilityIdentifier("filter-reset")
                }
            } footer: {
                Text("Each bar shows the samples that pass all the other filters; the coloured part also passes this one.")
            }
            ForEach(model.filter.filters, id: \.column) { f in
                Section {
                    FilterCard(name: f.column)
                } header: {
                    HStack {
                        Text(f.column).textCase(nil).font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Remove") { model.filter.remove(f.column) }
                            .font(.footnote).textCase(nil)
                            .accessibilityIdentifier("filter-remove-\(f.column)")
                    }
                }
            }
        }
    }
}

struct FilterCard: View {
    let name: String
    @Environment(AppModel.self) private var model
    @State private var showAllLevels = false

    var body: some View {
        if let col = model.filter.columns[name], let h = model.filter.histogram(name, bins: 36) {
            let f = model.filter.filter(name) ?? ColumnFilter(column: name)
            switch col.data {
            case .numeric(let v):
                numeric(v, h, f)
            case .categorical(let levels, _):
                categorical(levels, h, f)
            }
            if col.missingCount > 0 {
                Toggle("Include samples with no value (\(col.missingCount.formatted()))",
                       isOn: Binding(get: { f.includeMissing }, set: { model.filter.set(name, value: f.value, includeMissing: $0) }))
                    .font(.subheadline)
            }
            Text("\(h.selectedTotal.formatted()) of \(h.shownTotal.formatted()) pass this filter")
                .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
        } else {
            Text("Not loaded").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func numeric(_ v: [Double], _ h: Histogram, _ f: ColumnFilter) -> some View {
        let present = v.filter { !$0.isNaN }
        if let lo = present.min(), let hi = present.max(), hi > lo {
            VStack(spacing: 2) {
                HistogramBars(shown: h.shown, selected: h.selected)
                    .frame(height: 90)
                    .accessibilityElement()
                    .accessibilityLabel("Histogram of \(name)")
                HStack {
                    Text(PlotFormat.number(lo))
                    Spacer()
                    Text(PlotFormat.number((lo + hi) / 2))
                    Spacer()
                    Text(PlotFormat.number(hi))
                }
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            RangeControl(lo: lo, hi: hi, current: f.value) { model.filter.set(name, value: $0) }
        } else {
            Text("Every sample has the same value: nothing to filter on.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func categorical(_ levels: [String], _ h: Histogram, _ f: ColumnFilter) -> some View {
        let chosen: Set<String> = Self.chosen(f, levels)
        let top = max(1, h.shown.max() ?? 1)
        let limit = 8
        let visible = showAllLevels || levels.count <= limit + 2 ? Array(levels.indices) : Array(levels.indices.prefix(limit))
        HStack {
            Button("All") { model.filter.set(name, value: nil) }
            Text("\u{00B7}").foregroundStyle(.secondary)
            Button("None") { model.filter.set(name, value: .levels([])) }
            Spacer()
            Text("\(chosen.count) of \(levels.count) chosen").font(.footnote).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .font(.subheadline)
        ForEach(visible, id: \.self) { i in
            LevelRow(level: levels[i], shown: i < h.shown.count ? h.shown[i] : 0, selected: i < h.selected.count ? h.selected[i] : 0,
                     top: top, isOn: chosen.contains(levels[i])) {
                var s = chosen
                if s.contains(levels[i]) { s.remove(levels[i]) } else { s.insert(levels[i]) }
                model.filter.set(name, value: s.count == levels.count ? nil : .levels(s))
            }
        }
        if visible.count < levels.count {
            Button("Show all \(levels.count) values") { showAllLevels = true }.font(.subheadline)
        } else if showAllLevels, levels.count > limit + 2 {
            Button("Show fewer") { showAllLevels = false }.font(.subheadline)
        }
    }

    private static func chosen(_ f: ColumnFilter, _ levels: [String]) -> Set<String> {
        if case .levels(let s)? = f.value { return s }
        return Set(levels)
    }
}

/// One level of a categorical filter: its checkbox, its name, and its count as a bar.
struct LevelRow: View {
    let level: String
    let shown: Int
    let selected: Int
    let top: Int
    let isOn: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                Text(level).foregroundStyle(shown > 0 ? Color.primary : Color.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.25)).frame(width: barWidth(shown), height: 8)
                    Capsule().fill(Color.accentColor).frame(width: barWidth(selected), height: 8)
                }
                .frame(width: 80, alignment: .leading)
                Text(shown.formatted()).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
        }
        .accessibilityLabel("\(level), \(shown) samples, \(isOn ? "included" : "excluded")")
        .accessibilityIdentifier("level-\(level)")
    }
    private func barWidth(_ n: Int) -> CGFloat { n <= 0 ? 0 : max(2, 80 * CGFloat(n) / CGFloat(max(1, top))) }
}

/// The bars of a numeric histogram: grey = passes the other filters, coloured = also this one.
struct HistogramBars: View {
    let shown: [Int]
    let selected: [Int]

    var body: some View {
        Canvas { ctx, size in
            let n = shown.count
            guard n > 0, let top = shown.max(), top > 0 else { return }
            let w = size.width / CGFloat(n)
            for i in 0..<n {
                let x = CGFloat(i) * w + 0.5
                let all = size.height * CGFloat(shown[i]) / CGFloat(top)
                ctx.fill(Path(CGRect(x: x, y: size.height - all, width: max(1, w - 1), height: all)), with: .color(Color.secondary.opacity(0.3)))
                let own = i < selected.count ? size.height * CGFloat(selected[i]) / CGFloat(top) : 0
                ctx.fill(Path(CGRect(x: x, y: size.height - own, width: max(1, w - 1), height: own)), with: .color(Color.accentColor))
            }
        }
    }
}

/// Two sliders for a range; a handle at its end means "no limit on that side".
struct RangeControl: View {
    let lo: Double
    let hi: Double
    let current: ColumnFilter.Value?
    let change: (ColumnFilter.Value?) -> Void

    var body: some View {
        let cur = bounds
        VStack(spacing: 4) {
            HStack {
                Text("from \(PlotFormat.number(cur.0))").font(.footnote.monospacedDigit()).frame(width: 96, alignment: .leading)
                Slider(value: Binding(get: { cur.0 }, set: { update($0, cur.1) }), in: lo...hi)
                    .accessibilityIdentifier("range-from")
            }
            HStack {
                Text("to \(PlotFormat.number(cur.1))").font(.footnote.monospacedDigit()).frame(width: 96, alignment: .leading)
                Slider(value: Binding(get: { cur.1 }, set: { update(cur.0, $0) }), in: lo...hi)
                    .accessibilityIdentifier("range-to")
            }
        }
    }
    /// the range in force, with an open side shown at the column's own end
    private var bounds: (Double, Double) {
        if case .range(let a, let b)? = current { return (max(a, lo), min(b, hi)) }
        return (lo, hi)
    }
    private func update(_ a: Double, _ b: Double) {
        let l = a <= lo ? -Double.infinity : a
        let h = b >= hi ? Double.infinity : b
        change(l.isInfinite && h.isInfinite ? nil : .range(lo: l, hi: max(h, l)))
    }
}
