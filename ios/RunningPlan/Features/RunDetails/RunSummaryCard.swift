import SwiftUI

/// The written summary under the hero stats (issue #132). The "what to do next" line is the server's; with a pain flag it is the
/// fixed guidance and shows as a notice, like the check-in screen.
struct RunSummaryCard: View {
    let result: RunSummaryResult

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Summary").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink.color)
                .accessibilityAddTraits(.isHeader)
            Text(result.text)
                .font(.system(size: 15)).foregroundStyle(Palette.ink.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("rundetails.summary.text")
            if let next = result.nextStep {
                if result.pain {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Look after it").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.amberTitle.color)
                        Text(next).font(.system(size: 13)).foregroundStyle(Palette.amberText.color).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.amberSoft.color, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("rundetails.summary.next")
                } else {
                    Text(next).font(.system(size: 14)).foregroundStyle(Palette.muted.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("rundetails.summary.next")
                }
            }
            if result.isAI {
                Text("Generated summary").font(.system(size: 12)).foregroundStyle(Palette.muted.color)
                    .accessibilityIdentifier("rundetails.summary.generated")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rundetails.summary")
    }
}
