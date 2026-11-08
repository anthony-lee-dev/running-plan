import SwiftUI

/// The proposals of a plan, each accepted or dismissed one by one (design §6.6a): DK-Review's cards, "Applied" rows
/// for what was just accepted, and the out-of-date state with Refresh. Reusable: the weekly review shows it for the
/// review's proposals, and Goal and settings (#77) shows it for an interview re-run after `ProposalsStore.proposeInterviewRerun`.
struct ProposalList: View {
    let store: ProposalsStore
    /// The user's local day (`YYYY-MM-DD`), sent when Refresh asks the engine again.
    let today: String
    /// Called after an accept, a dismiss or a refresh, so the owner can reload what depends on the plan.
    var onChanged: () async -> Void = {}

    var body: some View {
        VStack(spacing: 10) {
            ForEach(store.applied) { row in
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green.color)
                    Text("Applied: \(row.title)").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink.color)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: Metrics.minTouchTarget, alignment: .leading)
                .background(Palette.greenSoft.color, in: RoundedRectangle(cornerRadius: 20))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("proposal.applied")
            }
            ForEach(store.cards()) { card in
                ProposalCardView(
                    model: card, working: store.isWorking(card.id), refreshing: store.refreshing, error: store.errors[card.id],
                    includeUserOwned: Binding(get: { store.includesUserOwned(card.id) }, set: { store.setIncluded($0, for: card.id) }),
                    onAccept: { Task { if await store.accept(card.id) { await onChanged() } } },
                    onDismiss: { Task { if await store.dismiss(card.id) { await onChanged() } } },
                    onRefresh: { Task { await store.refresh(today: today); await onChanged() } }
                )
            }
        }
    }
}

/// One proposal card (docs/design-notes.md "Proposal card"). Draws a `ProposalCardModel`; the buttons call back.
struct ProposalCardView: View {
    let model: ProposalCardModel
    var working = false
    var refreshing = false
    var error: String?
    @Binding var includeUserOwned: Bool
    var onAccept: () -> Void = {}
    var onDismiss: () -> Void = {}
    var onRefresh: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if model.urgent {
                    Text("Urgent").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.amberTitle.color)
                        .padding(.horizontal, 9).padding(.vertical, 3).background(Palette.amberSoft.color, in: Capsule())
                }
                Text(model.title).font(.system(size: 17, weight: .bold)).foregroundStyle(Palette.ink.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("proposal.title")
                Text(model.reason).font(.system(size: 14)).foregroundStyle(Palette.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = model.planNote {
                    Text(note).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink.color)
                }
            }
            ForEach(model.rows.filter { !$0.locked }) { row in changeRow(row) }
            if model.moreCount > 0 {
                Text(model.moreText).font(.system(size: 13)).foregroundStyle(Palette.muted.color)
            }
            ForEach(model.rows.filter(\.locked)) { row in lockedRow(row) }
            if model.lockedCount > 0 {
                Toggle("Include my own sessions", isOn: $includeUserOwned)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink.color)
                    .tint(Palette.accent.color)
                    .frame(minHeight: Metrics.minTouchTarget)
                    .disabled(model.stale || working)
                    .accessibilityIdentifier("proposal.include")
            }
            if let error {
                Text(error).font(.system(size: 14)).foregroundStyle(Palette.accentText.color).accessibilityIdentifier("proposal.error")
            }
            if model.stale { staleFooter } else { actions }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("proposal.card")
    }

    private func changeRow(_ row: ProposalCardModel.Row) -> some View {
        HStack(spacing: 10) {
            Text(row.day).font(.system(size: 13)).foregroundStyle(Palette.muted.color)
            Spacer(minLength: 8)
            if let before = row.before {
                Text(before).font(.system(size: 15)).strikethrough().foregroundStyle(Palette.muted.color)
            }
            if let after = row.after {
                Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink.color)
                Text(after).font(.system(size: 17, weight: .bold)).foregroundStyle(Palette.ink.color)
            } else if row.dropped {
                Text("Dropped").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink.color)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Palette.bg.color, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(row))
        .accessibilityIdentifier("proposal.row")
    }

    private static func spoken(_ row: ProposalCardModel.Row) -> String {
        if row.dropped { return "\(row.day): \(row.before ?? row.label) is dropped" }
        return "\(row.day): \(row.before.map { "from \($0) " } ?? "")to \(row.after ?? "")"
    }

    /// "Sunday cycling is yours": shown, and left alone unless the user includes their own sessions.
    private func lockedRow(_ row: ProposalCardModel.Row) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock").font(.system(size: 18)).foregroundStyle(Palette.ink.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.lockedText).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink.color)
                Text(includeUserOwned ? "Included in this change" : "Left alone unless you choose to include it")
                    .font(.system(size: 13)).foregroundStyle(Palette.muted.color)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.segmentTrack.color, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("proposal.locked")
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button(action: onAccept) {
                Group {
                    if working { ProgressView().tint(.white) } else { Text("Accept").font(.system(size: 16, weight: .semibold)) }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Palette.accent.color, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
            }
            .layoutPriority(2)
            .disabled(working || model.changesNothing(includeUserOwned: includeUserOwned))
            .opacity(model.changesNothing(includeUserOwned: includeUserOwned) ? 0.4 : 1)
            .accessibilityLabel("Accept")
            .accessibilityIdentifier("proposal.accept")
            Button(action: onDismiss) {
                Text("Dismiss").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink.color)
                    .frame(width: 120, height: 50)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.restBorder.color, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .disabled(working)
            .accessibilityIdentifier("proposal.dismiss")
        }
    }

    /// Plan revision moved: actions are off, with a plain sentence and Refresh.
    private var staleFooter: some View {
        HStack(spacing: 12) {
            Text("This suggestion is out of date").font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.amberText.color)
                .accessibilityIdentifier("proposal.stale")
            Spacer()
            Button(action: onRefresh) {
                Group {
                    if refreshing { ProgressView().tint(Palette.accentText.color) } else { Text("Refresh").font(.system(size: 15, weight: .semibold)) }
                }
                .foregroundStyle(Palette.accentText.color)
                .frame(minWidth: Metrics.minTouchTarget, minHeight: Metrics.minTouchTarget)
                .contentShape(Rectangle())
            }
            .disabled(refreshing)
            .accessibilityIdentifier("proposal.refresh")
        }
    }
}
