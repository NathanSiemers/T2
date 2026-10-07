import SwiftUI
import T2Kit

/// What T2 is, who made it, how to cite it, and the data types of the open dataset as the
/// database itself describes them. Reached from the "?" on the Select screen.
struct AboutView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var advanced = false
    @State private var clinical = false
    @State private var contact = false

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
                Section {
                    Text("Companies and institutions that would like an internal or privately hosted deployment of the T2 database, the web site or this app are welcome to get in touch.")
                        .font(.callout)
                    Button { contact = true } label: { Label("Contact the author", systemImage: "envelope") }
                        .accessibilityIdentifier("contact-button")
                } header: {
                    Text("Private deployments")
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
                    if let described = m.clinicalDescriptions, !described.isEmpty {
                        Section {
                            DisclosureGroup(isExpanded: $clinical) {
                                ForEach(described) { c in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.column).font(.callout.monospaced())
                                        Text(c.description).font(.footnote)
                                        if let s = c.source, !s.isEmpty { Text(s).font(.caption2).foregroundStyle(.secondary) }
                                    }
                                    .accessibilityIdentifier("clinical-\(c.column)")
                                }
                            } label: {
                                Text("\(described.count) clinical variables")
                            }
                            .accessibilityIdentifier("clinical-variables")
                        } header: {
                            Text("Clinical variables in \(m.label)")
                        } footer: {
                            Text("The sample annotations that can be plotted and filtered on, with what each one means and where it comes from. The survival endpoints (OS, DSS, DFI, PFI) follow the TCGA Pan-Cancer Clinical Data Resource.")
                        }
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
            .sheet(isPresented: $contact) { ContactView() }
        }
    }
}

/// The message goes to the server, which keeps it and forwards it to the author; no
/// address is in the app. Name, a valid email address and a message are required.
struct ContactView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var affiliation = ""
    @State private var email = ""
    @State private var message = ""
    @State private var sending = false
    @State private var sent = false
    @State private var problem = ""
    @State private var appeared = Date()

    private var emailLooksValid: Bool {
        let t = email.trimmingCharacters(in: .whitespaces)
        return t.range(of: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }
    private var canSend: Bool {
        !sending && !name.trimmingCharacters(in: .whitespaces).isEmpty && emailLooksValid && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                if sent {
                    Section {
                        Label("Thank you. Your message has been delivered to the author.", systemImage: "checkmark.circle.fill")
                            .accessibilityIdentifier("contact-sent")
                    }
                } else {
                    Section {
                        TextField("Your name", text: $name).textContentType(.name).accessibilityIdentifier("contact-name")
                        TextField("Company or institution (optional)", text: $affiliation).textContentType(.organizationName).accessibilityIdentifier("contact-affiliation")
                        TextField("Your email address", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("contact-email")
                    } footer: {
                        if !email.isEmpty, !emailLooksValid { Text("That does not look like an email address.") }
                    }
                    Section {
                        TextEditor(text: $message).frame(minHeight: 140).accessibilityIdentifier("contact-message")
                    } header: {
                        Text("Message")
                    } footer: {
                        Text("Up to 4,000 characters. Your message and address go to the author and nowhere else.")
                    }
                    if !problem.isEmpty {
                        Section { Text(problem).foregroundStyle(.red).font(.footnote).accessibilityIdentifier("contact-problem") }
                    }
                }
            }
            .navigationTitle("Contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(sent ? "Done" : "Cancel") { dismiss() } }
                if !sent {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { Task { await send() } } label: {
                            if sending { ProgressView() } else { Text("Send") }
                        }
                        .disabled(!canSend)
                        .accessibilityIdentifier("contact-send")
                        // (XCUITest's isEnabled is not reliable for a toolbar button on every iOS: the tests read this)
                        .accessibilityValue(canSend ? "ready" : "incomplete")
                    }
                }
            }
            .onAppear { appeared = Date() }
        }
    }

    private func send() async {
        sending = true; problem = ""
        let m = APIClient.ContactMessage(
            name: String(name.trimmingCharacters(in: .whitespaces).prefix(200)),
            affiliation: String(affiliation.trimmingCharacters(in: .whitespaces).prefix(200)),
            email: email.trimmingCharacters(in: .whitespaces),
            message: String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4000)),
            started: Date().timeIntervalSince(appeared),
            app: "T2 iOS \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
        do {
            try await model.sendContactMessage(m)
            sent = true
        } catch {
            problem = "The message could not be sent: \(error). Please try again later."
        }
        sending = false
    }
}
