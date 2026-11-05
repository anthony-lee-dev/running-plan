import SwiftUI

/// "Sync conflict" (docs/design-notes.md): a sheet naming the session with "Keep mine" (primary) and "Use the other
/// version" (secondary), both showing the differing fields.
struct ConflictSheet: View {
    let model: ConflictModel
    let onKeepMine: () -> Void
    let onUseOther: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("This session changed on another device")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Palette.ink.color)
                Text("\(model.title) was edited here and somewhere else. Which version do you want?")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.muted.color)
                ForEach(model.rows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.field).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted.color)
                        HStack(alignment: .top, spacing: 12) {
                            column("Mine", row.mine)
                            column("The other", row.theirs)
                        }
                    }
                    .padding(14)
                    .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityElement(children: .combine)
                }
                Button(action: onKeepMine) {
                    Text("Keep mine")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .background(Palette.accent.color, in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("conflict.keepMine")
                Button(action: onUseOther) {
                    Text("Use the other version")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: Metrics.minTouchTarget)
                        .foregroundStyle(Palette.accentText.color)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("conflict.useOther")
            }
            .padding(20)
        }
        .background(Palette.bg.color)
        .presentationDetents([.large])
        .interactiveDismissDisabled()
        .accessibilityIdentifier("screen.conflict")
    }

    private func column(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(Palette.muted.color)
            Text(value).font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.ink.color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Offline. Changes are saved and will sync." under the title while edits wait.
struct OfflineBanner: View {
    var body: some View {
        Text("Offline. Changes are saved and will sync.")
            .font(.system(size: 13))
            .foregroundStyle(Palette.muted.color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Palette.bg.color)
            .accessibilityIdentifier("offline.banner")
    }
}
