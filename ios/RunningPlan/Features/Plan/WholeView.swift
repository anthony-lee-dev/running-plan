import SwiftUI

/// The two views of the Plan tab.
enum PlanMode: Equatable {
    case week, whole
}

/// The Week / Whole plan switch under the Plan title (DK-Week, DK-Whole).
struct PlanModePicker: View {
    let selected: PlanMode
    let onSelect: (PlanMode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment("Week", .week)
            segment("Whole plan", .whole)
        }
        .padding(.horizontal, 3)
        .background(Palette.segmentTrack.color, in: RoundedRectangle(cornerRadius: 12))
    }

    private func segment(_ title: String, _ mode: PlanMode) -> some View {
        Button { onSelect(mode) } label: {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected == mode ? Palette.ink.color : Palette.muted.color)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(selected == mode ? Palette.segmentSelected.color : .clear, in: RoundedRectangle(cornerRadius: 10))
                // Inside the label, so the whole 46 pt track is the tap area (docs/design-notes.md).
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected == mode ? .isSelected : [])
    }
}

/// DK-Whole: the goal card, weekly distance by phase, and one row per week; tapping a week (bar or row) opens it.
/// "On track" and distance done wait for the progress endpoint (backlog 2.15).
struct WholeView: View {
    let model: WholeModel
    let onMode: (PlanMode) -> Void
    let onWeek: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PlanTitle()
                PlanModePicker(selected: .whole, onSelect: onMode)
                goalCard
                chart
                VStack(spacing: 0) {
                    ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                        if index > 0, row.state != .current, model.rows[index - 1].state != .current {
                            Divider().overlay(Palette.line.color).padding(.horizontal, 14)
                        }
                        WeekRow(row: row) { onWeek(row.week) }
                    }
                }
                .padding(.vertical, 6)
                .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
                .clipShape(RoundedRectangle(cornerRadius: 24))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Palette.bg.color.ignoresSafeArea())
    }
}

extension WholeView {
    private var goalCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("GOAL").font(.system(size: 12, weight: .semibold)).tracking(0.96).foregroundStyle(Palette.accentText.color)
                Text(model.goal.title).font(.system(size: 28, weight: .bold)).tracking(-0.56).foregroundStyle(Palette.ink.color)
                Text(model.goal.subtitle).font(.system(size: 14)).foregroundStyle(Palette.goalText.color)
            }
            VStack(spacing: 6) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.goalTrack.color)
                        Capsule().fill(Palette.accentText.color).frame(width: proxy.size.width * model.goal.progress)
                    }
                }
                .frame(height: 8)
                HStack {
                    Text(model.goal.weekLabel)
                    Spacer()
                    Text(model.goal.doneLabel)
                }
                .font(.system(size: 13))
                .foregroundStyle(Palette.goalText.color)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.goalCard.color, in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Palette.goalBorder.color, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Weekly distance").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                Spacer()
                Text("tap a week to open it").font(.system(size: 13)).foregroundStyle(Palette.muted.color)
            }
            let tallest = max(model.bars.map(\.kilometres).max() ?? 1, 1)
            VStack(spacing: 8) {
                HStack(alignment: .bottom, spacing: 5) {
                    ForEach(model.bars, id: \.week) { bar in
                        UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 2, bottomTrailingRadius: 2, topTrailingRadius: 6)
                            .fill(bar.phase.map(WeeklyBars.color) ?? Palette.line.color)
                            .opacity(bar.isAhead ? 0.4 : 1)
                            .frame(height: max(4, 119 * bar.kilometres / tallest))
                            .overlay(
                                bar.isCurrent
                                    ? RoundedRectangle(cornerRadius: 8).stroke(Palette.ink.color, lineWidth: 3).padding(-4)
                                    : nil
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { onWeek(bar.week) }
                    }
                }
                .frame(height: 140, alignment: .bottom)
                HStack(spacing: 5) {
                    ForEach(model.bars, id: \.week) { bar in
                        Text("\(bar.week + 1)")
                            .font(.system(size: 11, weight: bar.isCurrent ? .bold : .regular))
                            .foregroundStyle(bar.isCurrent ? Palette.ink.color : Palette.muted.color)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            // One element with a summary; the week rows below open each week for VoiceOver.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.chartSpoken)
            HStack(spacing: 14) {
                ForEach([PlanPreview.Phase.base, .build, .peak, .taper], id: \.self) { phase in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(WeeklyBars.color(phase)).frame(width: 12, height: 12)
                        Text(phase.title).font(.system(size: 12)).foregroundStyle(Palette.muted.color)
                    }
                }
            }
            .accessibilityHidden(true)
        }
        .padding(18)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
    }
}

/// "Plan", the tab's title.
struct PlanTitle: View {
    var body: some View {
        Text("Plan")
            .font(.system(size: 30, weight: .bold))
            .tracking(-0.6)
            .foregroundStyle(Palette.ink.color)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(AppTab.plan.screenIdentifier)
    }
}

private struct WeekRow: View {
    let row: WholeModel.Row
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(row.label).font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.ink.color).frame(width: 34, alignment: .leading)
                Text(row.detail)
                    .font(.system(size: 15, weight: row.state == .current ? .semibold : .regular))
                    .foregroundStyle(row.state == .current ? Palette.ink.color : Palette.muted.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text(row.distance).font(.system(size: 15, weight: .semibold)).monospacedDigit().foregroundStyle(Palette.ink.color)
                Group {
                    if row.state == .done {
                        Image(systemName: "checkmark").foregroundStyle(Palette.green.color)
                    } else {
                        Image(systemName: "chevron.right").foregroundStyle(Palette.ink.color)
                    }
                }
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 20)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 52)
            .background(row.state == .current ? Palette.accentSoft.color : .clear)
            .contentShape(Rectangle())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spoken)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("whole.week.\(row.week + 1)")
    }
}
