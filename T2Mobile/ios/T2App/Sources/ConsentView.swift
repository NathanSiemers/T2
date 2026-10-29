import SwiftUI

/// Where the data in T2 come from, under what consent they were collected, and the
/// policies under which they are shared. Reached from About > Data sharing and informed
/// consent. The rows reuse ReferenceRow (SourcesView.swift): title, plain-words note, link.
struct ConsentView: View {
    var body: some View {
        List {
            Section {
                Text("Every data set in T2 comes from the open-access tier of a public research program: de-identified data, collected under informed consent and institutional review board oversight at the source, and released by the programs for public use under the policies below. T2 adds no data of its own and collects none from you.")
                    .font(.callout)
                    .accessibilityIdentifier("consent-intro")
            }
            Section {
                ReferenceRow(title: "TCGA Human Subjects Protection and Data Access Policies",
                             note: "The NCI and NHGRI policy defining the open-access tier of de-identified TCGA data that T2 uses (PDF).",
                             url: "https://www.cancer.gov/ccg/research/structural-genomics/tcga/history/policies/tcga-human-subjects-data-policies.pdf")
                ReferenceRow(title: "TCGA ethics and policies overview",
                             note: "Informed consent guidelines and data use for The Cancer Genome Atlas.",
                             url: "https://www.cancer.gov/ccg/research/genome-sequencing/tcga/history/ethics-policies")
                ReferenceRow(title: "NIH Genomic Data Sharing Policy (NOT-OD-14-124)",
                             note: "Governs the sharing of TCGA, TARGET and CPTAC data.",
                             url: "https://grants.nih.gov/grants/guide/notice-files/NOT-OD-14-124.html")
                ReferenceRow(title: "NCI Genomic Data Commons: data access policies",
                             note: "Open versus controlled access. T2 uses open-access data only.",
                             url: "https://gdc.cancer.gov/access-data/data-access-policies")
                ReferenceRow(title: "NCI Proteomic Data Commons: data use",
                             note: "All proteomic data in the PDC (the CPTAC program) are open access.",
                             url: "https://datacommons.cancer.gov/repository/proteomic-data-commons")
                ReferenceRow(title: "GTEx informed consent (NHGRI)",
                             note: "The consent under which GTEx donors' next of kin released the de-identified data for public use (PDF).",
                             url: "https://www.genome.gov/Pages/PolicyEthics/InformedConsent/5_GTEx_ENCODE_Sample_Consent.pdf")
                ReferenceRow(title: "TARGET: using the data",
                             note: "The TARGET program's data at the Genomic Data Commons, under the same policies.",
                             url: "https://www.cancer.gov/ccg/research/genome-sequencing/target/using-target-data")
            } header: {
                Text("The policies")
            } footer: {
                Text("The controlled-access tiers of these programs, which require case-by-case approval by an NIH data access committee, are not in T2.")
            }
        }
        .navigationTitle("Data sharing and consent")
        .navigationBarTitleDisplayMode(.inline)
    }
}
