import SwiftUI

/// DK-Review: the week at a glance, what is suggested for the weeks ahead, and the inbox card. Draws a `ReviewModel`;
/// the proposals are passed in so a snapshot test can show one without a store. System fonts until the font task.
struct ReviewView<Proposals: View>: View {
    let model: ReviewModel
    var onBack: () -> Void = {}
    var onInbox: () -> Void = {}
    var onSettings: () -> Void = {}
    /// Set when the review could not be refreshed.
    var error: String?
    @ViewBuilder var proposals: () -> Proposals

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                        Text("Next").font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(Palette.ink.color)
                    .frame(minHeight: Metrics.minTouchTarget)
                    .contentShape(Rectangle())
                }
                .padding(.leading, -6)
                .accessibilityLabel("Back to Next")
                .accessibilityIdentifier("review.back")
                header
                glance
                suggestions
                if let title = model.inboxTitle { inboxCard(title) }
                if let error {
                    Text(error).font(.system(size: 14)).foregroundStyle(Palette.accentText.color).accessibilityIdentifier("review.error")
                }
                footer
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Palette.bg.color.ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.eyebrow).font(.system(size: 12, weight: .semibold)).tracking(1).foregroundStyle(Palette.muted.color)
            Text(model.headline)
                .font(.system(size: 32, weight: .bold)).tracking(-0.6)
                .foregroundStyle(Palette.ink.color)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("screen.review")
            Text(model.summary).font(.system(size: 15)).foregroundStyle(Palette.muted.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var glance: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The week at a glance").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .top, spacing: 10) {
                ForEach(model.tiles, id: \.label) { tile in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tile.value).font(.system(size: 26, weight: .bold)).monospacedDigit().foregroundStyle(Palette.ink.color)
                            .minimumScaleFactor(0.7).lineLimit(1)
                        Text(tile.label).font(.system(size: 12)).foregroundStyle(Palette.muted.color)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("review.tile")
                }
            }
            if !model.keyRuns.isEmpty {
                VStack(spacing: 0) {
                    ForEach(model.keyRuns) { run in keyRunRow(run) }
                }
                .overlay(alignment: .top) { Rectangle().fill(Palette.line.color).frame(height: 1) }
            }
            if let line = model.checkInLine {
                Text(line).font(.system(size: 13)).foregroundStyle(Palette.muted.color).accessibilityIdentifier("review.checkins")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
    }

    private func keyRunRow(_ run: ReviewModel.KeyRun) -> some View {
        HStack(spacing: 10) {
            switch run.outcome {
            case .hit: Image(systemName: "checkmark").font(.system(size: 14, weight: .heavy)).foregroundStyle(Palette.green.color)
            case .missed, .skipped: Image(systemName: "minus").font(.system(size: 14, weight: .bold)).foregroundStyle(Palette.muted.color)
            case .upcoming: Image(systemName: "circle").font(.system(size: 12)).foregroundStyle(Palette.muted.color)
            }
            Text(run.title).font(.system(size: 15)).foregroundStyle(Palette.ink.color)
            Spacer()
            Text(run.note).font(.system(size: 13)).foregroundStyle(Palette.muted.color)
        }
        .frame(minHeight: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line.color).frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(run.title): \(run.note)")
        .accessibilityIdentifier("review.keyrun")
    }

    @ViewBuilder private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SUGGESTED FOR THE WEEKS AHEAD").font(.system(size: 13, weight: .semibold)).tracking(1).foregroundStyle(Palette.muted.color)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
            proposals()
        }
    }

    private func inboxCard(_ title: String) -> some View {
        Button(action: onInbox) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.blueText.color)
                    Text(model.inboxDetail).font(.system(size: 13)).foregroundStyle(Palette.blueText.color.opacity(0.85))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Palette.blueText.color)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(Palette.blueSoft.color, in: RoundedRectangle(cornerRadius: 20))
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("review.inbox")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Suggestions never change your plan on their own.").font(.system(size: 13)).foregroundStyle(Palette.muted.color)
            Button(action: onSettings) {
                Text("Choose how often reviews appear").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.accentText.color)
                    .frame(minHeight: Metrics.minTouchTarget, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("review.settings")
        }
    }
}
