import SwiftUI

/// DK-Progress: the goal countdown, the three tallies, running volume per week and a win worth noticing. Only draws
/// `ProgressModel`. System fonts until the font task.
struct ProgressOverview: View {
    let model: ProgressModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppTab.progress.title)
                        .font(.system(size: 30, weight: .bold))
                        .tracking(-0.6)
                        .foregroundStyle(Palette.ink.color)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier(AppTab.progress.screenIdentifier)
                    Text(model.headline)
                        .font(.system(size: 16))
                        .lineSpacing(3)
                        .foregroundStyle(Palette.muted.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                goalCard
                HStack(alignment: .top, spacing: 10) {
                    tile(model.sessions, colour: Palette.ink, id: "progress.sessions")
                    tile(model.keyRuns, colour: Palette.ink, id: "progress.keyRuns")
                    tile(model.strength, colour: Palette.strengthText, id: "progress.strength")
                }
                .fixedSize(horizontal: false, vertical: true)
                chart
                if let win = model.win {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("A win worth noticing").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                        Text(win).font(.system(size: 14)).lineSpacing(3).foregroundStyle(Palette.muted.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Palette.bg.color.ignoresSafeArea())
    }

    private var goalCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.goal.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.greenSoftText.color)
                    Text(model.goal.countdown)
                        .font(.system(size: 44, weight: .bold))
                        .tracking(-0.9)
                        .foregroundStyle(Palette.countdown.color)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text(model.goal.detail).font(.system(size: 14)).foregroundStyle(Palette.greenSoftText.color)
                }
                Spacer(minLength: 8)
                if let badge = model.goal.badge {
                    Text(badge.title)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(badge == .onTrack ? Palette.greenInk.color : Palette.amberTitle.color)
                        .background(badge == .onTrack ? Palette.green.color : Palette.amberSoft.color, in: Capsule())
                        .accessibilityIdentifier("progress.badge")
                }
            }
            Text(model.goal.note)
                .font(.system(size: 14))
                .lineSpacing(3)
                .foregroundStyle(Palette.greenSoftBody.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.greenSoft.color, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("progress.goal")
    }

    private func tile(_ tile: ProgressModel.Tile, colour: RGB, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tile.value)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(colour.color)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(tile.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.ink.color)
            Text(tile.detail).font(.system(size: 12)).foregroundStyle(Palette.muted.color)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    private var chart: some View {
        let top = max(model.bars.map { max($0.plannedKm, $0.ranKm ?? 0) }.max() ?? 0, 0.1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Running volume").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                Spacer()
                Text("km per week").font(.system(size: 13)).foregroundStyle(Palette.muted.color)
            }
            VStack(spacing: 12) {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(model.bars, id: \.week) { bar in
                        HStack(alignment: .bottom, spacing: 4) {
                            column(bar.plannedKm / top, colour: Palette.goalTrack)
                            if let ran = bar.ranKm { column(ran / top, colour: Palette.green) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 112, alignment: .bottom)
                HStack(spacing: 0) {
                    ForEach(model.bars, id: \.week) { bar in
                        Text(bar.label)
                            .font(.system(size: 12, weight: bar.isCurrent ? .bold : .regular))
                            .foregroundStyle(bar.isCurrent ? Palette.ink.color : Palette.muted.color)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.chartSpoken)
            HStack(spacing: 16) {
                legend("Planned", colour: Palette.goalTrack)
                if model.firstWeekNote == nil { legend("Ran", colour: Palette.green) }
            }
            .accessibilityHidden(true)
            if let note = model.firstWeekNote {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("progress.firstWeek")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("progress.chart")
    }

    private func column(_ share: Double, colour: RGB) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 2, bottomTrailingRadius: 2, topTrailingRadius: 5)
            .fill(colour.color)
            .frame(maxWidth: 20)
            .frame(height: max(2, 100 * min(share, 1)))
    }

    private func legend(_ title: String, colour: RGB) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(colour.color).frame(width: 12, height: 12)
            Text(title).font(.system(size: 12)).foregroundStyle(Palette.muted.color)
        }
    }
}
