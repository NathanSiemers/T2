// NOT YET COMPILED: written on a machine without Xcode. Expect small fixes on first build.
import SwiftUI
import Charts
import T2Kit

/// The Thanos screen: one card per filter column, with a histogram of the samples that pass
/// all the OTHER filters (this column's own selection highlighted) and its control.
struct FilterView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(model.filter.selectedCount()) of \(model.filter.universeCount()) samples selected").font(.headline)
                    VariablePicker(title: "Add a filter column", current: "") { name in Task { await model.addFilterColumn(name) } }
                }
                ForEach(model.filter.filters, id: \.column) { f in
                    Section(f.column) { FilterCard(name: f.column) }
                        .swipeActions { Button("Remove", role: .destructive) { model.filter.remove(f.column) } }
                }
            }
            .navigationTitle("Filter")
        }
    }
}

struct FilterCard: View {
    let name: String
    @Environment(AppModel.self) private var model

    var body: some View {
        if let col = model.filter.columns[name], let h = model.filter.histogram(name, bins: 30) {
            let f = model.filter.filter(name) ?? ColumnFilter(column: name)
            Chart {
                ForEach(Array(h.labels.enumerated()), id: \.offset) { i, label in
                    BarMark(x: .value("bin", label), y: .value("n", h.selected[i])).foregroundStyle(Color(red: 0.05, green: 0.03, blue: 0.53))
                    BarMark(x: .value("bin", label), y: .value("n", h.shown[i] - h.selected[i])).foregroundStyle(Color(red: 0.61, green: 0.09, blue: 0.62))
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) }
            .frame(height: 110)
            Text("\(h.selectedTotal) / \(h.shownTotal)").font(.footnote.monospaced())
            switch col.data {
            case .numeric(let v):
                let present = v.filter { !$0.isNaN }
                if let lo = present.min(), let hi = present.max(), hi > lo {
                    RangeControl(lo: lo, hi: hi, current: f.value) { model.filter.set(name, value: $0) }
                }
            case .categorical(let levels, _):
                let chosen: Set<String> = { if case .levels(let s)? = f.value { return s } else { return Set(levels) } }()
                ForEach(levels.prefix(40), id: \.self) { level in
                    Toggle(level, isOn: Binding(get: { chosen.contains(level) }, set: { on in
                        var s = chosen; if on { s.insert(level) } else { s.remove(level) }
                        model.filter.set(name, value: s.count == levels.count ? nil : .levels(s))
                    }))
                }
            }
            if col.missingCount > 0 {
                Toggle("Include missing (\(col.missingCount))", isOn: Binding(get: { f.includeMissing },
                                                                                set: { model.filter.set(name, value: f.value, includeMissing: $0) }))
            }
        }
    }
}

/// Two sliders for a range; a handle at its end means "no limit on that side".
struct RangeControl: View {
    let lo: Double, hi: Double
    let current: ColumnFilter.Value?
    let change: (ColumnFilter.Value?) -> Void
    var body: some View {
        let cur: (Double, Double) = { if case .range(let a, let b)? = current { return (max(a, lo), min(b, hi)) } else { return (lo, hi) } }()
        VStack {
            LabeledContent(String(format: "from %.3g", cur.0)) {
                Slider(value: Binding(get: { cur.0 }, set: { update($0, cur.1) }), in: lo...hi)
            }
            LabeledContent(String(format: "to %.3g", cur.1)) {
                Slider(value: Binding(get: { cur.1 }, set: { update(cur.0, $0) }), in: lo...hi)
            }
        }
    }
    private func update(_ a: Double, _ b: Double) {
        let l = a <= lo ? -Double.infinity : a, h = b >= hi ? Double.infinity : b
        change(l.isInfinite && h.isInfinite ? nil : .range(lo: l, hi: max(h, l)))
    }
}
