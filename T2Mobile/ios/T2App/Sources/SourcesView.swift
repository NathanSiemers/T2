import SwiftUI
import T2Kit

/// A web link, only for http(s) addresses.
func webURL(_ s: String?) -> URL? {
    guard let s, !s.isEmpty, let u = URL(string: s), u.scheme == "https" || u.scheme == "http" else { return nil }
    return u
}

/// One reference as a row: the full title in bold, the authors, "journal, year", a note in
/// plain words. The whole row opens the link when there is one.
struct ReferenceRow: View {
    let title: String
    var authors = ""
    var journalYear = ""
    var note = ""
    var url = ""

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.bold()).foregroundStyle(.primary)
            if !authors.isEmpty { Text(authors).font(.footnote).foregroundStyle(.primary) }
            if !journalYear.isEmpty { Text(journalYear).font(.caption).foregroundStyle(.secondary) }
            if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(.primary) }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        if let link = webURL(url) {
            Link(destination: link) {
                HStack(alignment: .top, spacing: 8) {
                    content
                    Image(systemName: "arrow.up.right.square").font(.footnote).foregroundStyle(.secondary)
                }
            }
        } else {
            content
        }
    }
}

extension ReferenceRow {
    init(_ r: Reference) {
        self.init(title: r.title, authors: r.authors, journalYear: r.journalYear, note: r.note, url: r.url)
    }
}

/// The sources behind what the app shows: the open data set's bibliography, its data types
/// with their references, the statistical methods, and T2 itself.
struct SourcesView: View {
    @Environment(AppModel.self) private var model
    /// an id to scroll to when the screen opens ("methods")
    var scrollTo: String?

    init(scrollTo: String? = nil) { self.scrollTo = scrollTo }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                if let m = model.meta {
                    let groups = m.referenceGroups
                    ForEach(Array(groups.enumerated()), id: \.offset) { index, g in
                        Section {
                            ForEach(g.items) { r in ReferenceRow(r) }
                        } header: {
                            Text(g.group.isEmpty ? "References" : g.group)
                        } footer: {
                            if index == groups.count - 1, let a = m.about?.attribution, !a.isEmpty { Text(a) }
                        }
                    }
                    if groups.isEmpty, let a = m.about?.attribution, !a.isEmpty {
                        Section {
                            Text(a).font(.footnote)
                        } header: {
                            Text("This data set: \(m.label)")
                        }
                    }
                    dataTypes(m)
                }
                methods
                Section {
                    Text(t2Citation).font(.footnote)
                    Link(destination: URL(string: "https://www.fiveprime.org")!) {
                        Label("The T2 website (fiveprime.org)", systemImage: "safari")
                    }
                } header: {
                    Text("T2")
                }
            }
            .task {
                guard let target = scrollTo else { return }
                try? await Task.sleep(for: .milliseconds(400))
                proxy.scrollTo(target, anchor: .top)
            }
        }
        .navigationTitle("Sources and citations")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func dataTypes(_ m: DatasetMeta) -> some View {
        Section {
            if let types = m.types, !types.isEmpty {
                ForEach(types) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.type).font(.callout.monospaced())
                        if let l = t.label, !l.isEmpty { Text(l).font(.footnote) }
                        if let d = t.description, !d.isEmpty { Text(d).font(.footnote) }
                        if let e = t.example, !e.isEmpty { Text("e.g. \(e)").font(.footnote).foregroundStyle(.secondary) }
                    }
                    if let title = t.referenceTitle, !title.isEmpty {
                        ReferenceRow(title: title, authors: t.referenceAuthors ?? "",
                                     journalYear: [t.referenceJournal ?? "", t.referenceYear.map { String($0) } ?? ""]
                                        .filter { !$0.isEmpty }.joined(separator: ", "),
                                     url: t.referenceUrl ?? "")
                    } else if let ref = t.reference, !ref.isEmpty {
                        ReferenceRow(title: ref, url: t.referenceUrl ?? "")
                    }
                    if let src = webURL(t.sourceUrl) {
                        Link(destination: src) {
                            HStack(spacing: 6) {
                                Text("Data: \(src.host ?? t.sourceUrl ?? "")").font(.footnote)
                                Spacer(minLength: 8)
                                Image(systemName: "arrow.up.right.square").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text("This dataset does not describe its data types.").font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Data types in \(m.label)")
        } footer: {
            Text("A variable's suffix names its type (TP53.mut, CDKN2A.cnv, NK.sig); a bare gene name is RNA expression. Values are exactly those of the T2 database.")
        }
    }

    private var methods: some View {
        Section {
            ForEach(Array(MethodReferences.all.enumerated()), id: \.offset) { index, r in
                if index == 0 {
                    ReferenceRow(r).id("methods").accessibilityIdentifier("sources-methods")
                } else {
                    ReferenceRow(r)
                }
            }
        } header: {
            Text("Methods")
        } footer: {
            Text("The statistics T2 computes on the device, and the papers that define them.")
        }
    }
}

/// SourcesView in a sheet of its own (from the plot's "Methods and sources" link).
struct SourcesSheet: View {
    @Environment(\.dismiss) private var dismiss
    var scrollTo: String?

    var body: some View {
        NavigationStack {
            SourcesView(scrollTo: scrollTo)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
