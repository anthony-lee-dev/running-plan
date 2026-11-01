import SwiftUI

/// Runs that could be matched to a session, chosen from the session page (issue #105). Each row is one imported run.
struct RunPicker: View {
    let runs: [RunMatchModel.RunRow]
    let onPick: (RunMatchModel.RunRow) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if runs.isEmpty {
                    Text("No unmatched run fits this session. Import runs from the inbox, or add one by hand.")
                        .foregroundStyle(Palette.muted.color)
                        .accessibilityIdentifier("runpicker.empty")
                }
                ForEach(runs) { run in
                    Button { onPick(run) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.headline).font(.system(size: 16, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.ink.color)
                            Text(run.heading).font(.system(size: 13)).foregroundStyle(Palette.muted.color)
                        }
                        .frame(minHeight: Metrics.minTouchTarget, alignment: .leading)
                    }
                    .accessibilityIdentifier("runpicker.pick")
                    .listRowBackground(Palette.card.color)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.bg.color)
            .navigationTitle("Match a run")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) } }
        }
        .preferredColorScheme(.dark)
    }
}

/// Every imported run, matched or not, so a run can be moved to another session (or taken off one) from the run's side.
struct RunsScreen: View {
    let store: InboxStore
    let onClose: () -> Void
    @State private var picking: String?

    var body: some View {
        let model = store.runs(today: PreviewViewModel.localToday())
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button(action: onClose) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                        Text("Import inbox").font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(Palette.ink.color)
                    .frame(minHeight: Metrics.minTouchTarget)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Back to Import inbox")
                Text("All imported runs")
                    .font(.system(size: 32, weight: .bold)).tracking(-0.6)
                    .foregroundStyle(Palette.ink.color)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("screen.runs")
                if model.rows.isEmpty {
                    Text(store.allRunsLoaded ? "No runs imported yet" : "Looking for runs")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink.color)
                        .accessibilityIdentifier("runs.empty")
                }
                if let error = store.error {
                    Text(error).font(.system(size: 14)).foregroundStyle(Palette.accentText.color).accessibilityIdentifier("runs.error")
                }
                ForEach(model.rows) { row in
                    RunCard(row: row, busy: store.busy, store: store, onPick: { picking = row.id })
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Palette.bg.color.ignoresSafeArea())
        .task { await store.loadAllRuns() }
        .refreshable { await store.loadAllRuns() }
        .sheet(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } })) {
            if let id = picking {
                let choices = model.choices(for: id)
                SessionPicker(
                    choices: choices,
                    emptyNote: choices.isEmpty ? "Your plan has no open session of this type left to match it to." : nil,
                    onPick: { choice in
                        picking = nil
                        Task { await store.rematch(activityId: id, sessionId: choice.id, label: choice.title) }
                    },
                    onClose: { picking = nil }
                )
            }
        }
    }
}

private struct RunCard: View {
    let row: RunsModel.Row
    let busy: Bool
    let store: InboxStore
    let onPick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(row.run.heading).font(.system(size: 13)).foregroundStyle(Palette.muted.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.run.headline).font(.system(size: 20, weight: .bold)).monospacedDigit().foregroundStyle(Palette.ink.color)
                if !row.run.detail.isEmpty {
                    Text(row.run.detail).font(.system(size: 14)).monospacedDigit().foregroundStyle(Palette.muted.color)
                }
            }
            Text(row.status.text).font(.system(size: 15, weight: .semibold)).foregroundStyle(statusColor)
                .accessibilityIdentifier("runs.status")
            HStack(spacing: 10) {
                switch row.status {
                case .matched(let sessionId, _):
                    SecondaryButton(title: "Change session", action: onPick).accessibilityIdentifier("runs.change")
                    SecondaryButton(title: "Unmatch") { Task { await store.unmatch(sessionId: sessionId) } }.accessibilityIdentifier("runs.unmatch")
                case .inbox:
                    SecondaryButton(title: "Match to a session", action: onPick).accessibilityIdentifier("runs.match")
                case .extra, .ignored:
                    SecondaryButton(title: "Match to a session", action: onPick).accessibilityIdentifier("runs.match")
                    SecondaryButton(title: "Back to inbox") { Task { await store.backToInbox(row.id) } }.accessibilityIdentifier("runs.inbox")
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
        .disabled(busy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runs.card")
    }

    private var statusColor: Color {
        if case .matched = row.status { return Palette.greenSoftText.color }
        return Palette.muted.color
    }
}
