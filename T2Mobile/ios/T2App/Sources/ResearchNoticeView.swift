import SwiftUI

/// Whether the one-time research-use notice is still to be shown. The launch argument
/// `-t2ResetNotice YES` forgets that it was seen (the UI tests photograph it that way).
func researchNoticeNeeded() -> Bool {
    let d = UserDefaults.standard
    if d.bool(forKey: "t2ResetNotice") { d.removeObject(forKey: "t2ResearchNoticeSeen") }
    return !d.bool(forKey: "t2ResearchNoticeSeen")
}

/// Shown once, on the first launch: who the app is for, and where the sources are.
struct ResearchNoticeView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "testtube.2")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("For research use")
                .font(.title.bold())
                .accessibilityIdentifier("notice-title")
            Text("T2 Cancer Genomics is a research tool for scientists in biomedical research. It shows public research data and statistics computed from them. It gives no medical advice and must not be used for diagnosis or treatment decisions. The sources of every data set and of every statistical method are listed under About \u{203A} Sources and citations.")
                .font(.body)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("notice-text")
            Spacer()
            Button {
                UserDefaults.standard.set(true, forKey: "t2ResearchNoticeSeen")
                dismiss()
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("notice-continue")
        }
        .padding(24)
        .interactiveDismissDisabled()
    }
}
