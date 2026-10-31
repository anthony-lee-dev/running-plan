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
        .padding(3)
        .background(Palette.segmentTrack.color, in: RoundedRectangle(cornerRadius: 12))
    }

    private func segment(_ title: String, _ mode: PlanMode) -> some View {
        Button { onSelect(mode) } label: {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected == mode ? Palette.ink.color : Palette.muted.color)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(selected == mode ? Palette.segmentSelected.color : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected == mode ? .isSelected : [])
    }
}

/// DK-Whole's week list: one row per week; tapping a week opens it. The goal card and the weekly distance chart
/// arrive in the next part of task 3.5.
struct WholeView: View {
    let model: WholeModel
    let onMode: (PlanMode) -> Void
    let onWeek: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PlanTitle()
                PlanModePicker(selected: .whole, onSelect: onMode)
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
