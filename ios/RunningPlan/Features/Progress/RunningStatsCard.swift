import SwiftUI

/// "Your running" on Progress (issue #137): the week's or month's totals from the imported runs, how they compare with
/// the period before, a bar per period, and for a week how it stands against the plan. Only draws `RunningStatsModel`.
struct RunningStatsCard: View {
    let totals: RunTotals
    /// Nil without a plan under way (or before the progress reply is in).
    let planWeek: RunningStatsModel.PlanWeek?
    @State private var period: RunTotals.Period = .week

    var body: some View {
        let model = RunningStatsModel(totals: totals, period: period, planWeek: planWeek)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Your running").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Picker("Period", selection: $period) {
                    ForEach(RunTotals.Period.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 170)
                .accessibilityIdentifier("progress.running.period")
            }
            Text(model.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted.color)
            HStack(alignment: .top, spacing: 10) {
                ForEach(model.tiles, id: \.label) { tile in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tile.value).font(.system(size: 20, weight: .bold)).monospacedDigit()
                            .foregroundStyle(Palette.ink.color).minimumScaleFactor(0.6).lineLimit(1)
                        Text(tile.label).font(.system(size: 12)).foregroundStyle(Palette.muted.color)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityIdentifier("progress.running.tiles")
            if let note = model.emptyNote ?? model.comparison {
                Text(note).font(.system(size: 14)).foregroundStyle(Palette.muted.color)
                    .accessibilityIdentifier("progress.running.note")
            }
            bars(model)
            if let plan = model.planWeek {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.greenSoftText.color)
                    ForEach(plan.lines, id: \.self) { line in
                        Text(line).font(.system(size: 14)).monospacedDigit().foregroundStyle(Palette.ink.color)
                    }
                    Text("Counts the runs matched to your sessions, so it can differ from this week's total.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted.color).fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.greenSoft.color, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("progress.running.plan")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("progress.running")
    }

    private func bars(_ model: RunningStatsModel) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(model.bars.enumerated()), id: \.offset) { _, bar in
                    UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 2, bottomTrailingRadius: 2, topTrailingRadius: 5)
                        .fill(bar.isCurrent ? Palette.green.color : Palette.goalTrack.color)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(2, 80 * bar.share))
                }
            }
            .frame(height: 80, alignment: .bottom)
            HStack(spacing: 4) {
                ForEach(Array(model.bars.enumerated()), id: \.offset) { _, bar in
                    Text(bar.label).font(.system(size: 10, weight: bar.isCurrent ? .bold : .regular))
                        .foregroundStyle(bar.isCurrent ? Palette.ink.color : Palette.muted.color)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.chartSpoken)
    }
}
