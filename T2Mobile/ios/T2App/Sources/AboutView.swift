import SwiftUI
import T2Kit

/// What T2 is, who made it, how to cite it, and the data types of the open dataset as the
/// database itself describes them. Reached from the "?" on the Select screen.
struct AboutView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var advanced = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section("T2") {
                    Text("T2 is a database and search tool for the TCGA Pan-Cancer data and related collections (TCGA-TARGET-GTEx). Pick two variables (genes, mutations, copy number, signatures, clinical annotation) and T2 draws the relationship across thousands of tumour samples, with the statistics; narrow the samples with the presets and the Filter screen; export a publication figure from the Publish screen. The phone fetches only the values of the variables you choose; filtering, statistics and drawing happen on the device.")
                        .font(.callout)
                    Link(destination: URL(string: "https://www.fiveprime.org")!) {
                        Label("The T2 website (fiveprime.org)", systemImage: "safari")
                    }
                    Link(destination: URL(string: "https://www.fiveprime.org/T2T")!) {
                        Label("T2 in the browser", systemImage: "globe")
                    }
                }
                Section("Attribution") {
                    Text("Nathan O. Siemers, Ph.D.").font(.callout)
                    Text("Please cite: \(t2Citation)").font(.footnote)
                    Text("Data: TCGA Pan-Cancer Atlas (2018) via UCSC Xena; TCGA-TARGET-GTEx RNA-seq processed by the UCSC Toil pipeline.").font(.footnote).foregroundStyle(.secondary)
                }
                if let m = model.meta {
                    Section {
                        if let types = m.types, !types.isEmpty {
                            ForEach(types) { t in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.type).font(.callout.monospaced())
                                    if let d = t.description, !d.isEmpty { Text(d).font(.footnote) }
                                    if let e = t.example, !e.isEmpty { Text("e.g. \(e)").font(.footnote).foregroundStyle(.secondary) }
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
                Section {
                    DisclosureGroup("Advanced", isExpanded: $advanced) {
                        TextField("Service address", text: $model.baseURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .accessibilityIdentifier("service-address")
                        Button("Reconnect") { Task { await model.reconnect() } }
                    }
                } footer: {
                    Text("For a copy of the T2 data service run elsewhere. Leave it alone otherwise.")
                }
            }
            .navigationTitle("About T2")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
