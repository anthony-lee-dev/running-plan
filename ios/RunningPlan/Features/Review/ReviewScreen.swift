import SwiftUI

/// The weekly review over the tabs (DK-Review): the summary and, one by one, the proposals. An accepted proposal changes
/// the plan on the server and the reply replaces ours, so Next and Plan show it at once; the review then reloads (the
/// plan revision moved, so the engine looks again and the other cards are rebuilt).
struct ReviewScreen: View {
    let plans: PlanStore
    let review: ReviewStore
    let inbox: InboxStore
    let settings: ReviewSettingsModel
    let onClose: () -> Void
    @State private var showInbox = false
    @State private var showSettings = false

    var body: some View {
        Group {
            if let model = review.model {
                ReviewView(
                    model: model, onBack: onClose, onInbox: { showInbox = true }, onSettings: { showSettings = true }, error: review.error
                ) {
                    if review.proposals.proposals.isEmpty, review.proposals.applied.isEmpty {
                        Text("Nothing to change. Your plan stays as it is.")
                            .font(.system(size: 15)).foregroundStyle(Palette.muted.color)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("review.none")
                    } else {
                        ProposalList(store: review.proposals, today: PreviewViewModel.localToday(), onChanged: reload)
                    }
                }
            } else {
                gone
            }
        }
        .fullScreenCover(isPresented: $showInbox, onDismiss: { Task { await reload() } }) {
            InboxScreen(store: inbox, plans: plans, onClose: { showInbox = false })
        }
        .sheet(isPresented: $showSettings, onDismiss: { Task { await reload() } }) {
            ReviewSettingsSheet(model: settings, onClose: { showSettings = false })
        }
    }

    /// No review to show any more (a setting turned reviews off, or the plan changed under us).
    private var gone: some View {
        ZStack {
            Palette.bg.color.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("No review right now")
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(Palette.ink.color)
                    .accessibilityIdentifier("screen.review.none")
                Button(action: onClose) {
                    Text("Back to Next").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.accentText.color)
                        .frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("review.back")
            }
        }
    }

    private func reload() async {
        guard let plan = plans.plan else { return }
        await review.load(plan: plan, today: PreviewViewModel.localToday(), keepingOpen: true)
    }
}
