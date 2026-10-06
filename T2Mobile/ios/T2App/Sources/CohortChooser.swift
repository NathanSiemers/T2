import SwiftUI
import T2Kit

/// Which cohorts are used (the website's Cohort box). It is a filter on the dataset's
/// cohort column, so the Filter tab shows the same choice.
struct CohortChooser: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let levels = model.availableCohorts        // those with samples in the chosen data source
        let chosen = model.chosenCohorts ?? Set(levels)
        List {
            Section {
                Button("All cohorts") { model.setCohorts(nil) }.accessibilityIdentifier("cohorts-all")
                Button("None") { model.setCohorts([]) }.accessibilityIdentifier("cohorts-none")
            } footer: {
                Text("\(chosen.count) of \(levels.count) cohorts chosen; \(model.filter.selectedCount().formatted()) samples in use.")
            }
            Section {
                ForEach(levels, id: \.self) { level in
                    Button {
                        var s = chosen
                        if s.contains(level) { s.remove(level) } else { s.insert(level) }
                        model.setCohorts(s)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: chosen.contains(level) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(chosen.contains(level) ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(level).foregroundStyle(Color.primary)
                                if let title = model.meta?.cohortTitle(level), title != level {
                                    Text(title).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("cohort-\(level)")
                }
            }
        }
        .navigationTitle("Cohorts")
        .navigationBarTitleDisplayMode(.inline)
    }
}
