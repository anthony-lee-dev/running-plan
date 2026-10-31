import SwiftUI

/// DK-Week: one week of the plan, day by day, with arrows to the weeks either side. "Add a session" and opening a
/// session arrive with the session editor (task 4.1).
struct WeekView: View {
    let model: WeekModel
    var onMode: (PlanMode) -> Void = { _ in }
    let onWeek: (Int) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PlanTitle()
                PlanModePicker(selected: .week, onSelect: onMode)
                navigator
                summary
                VStack(spacing: 10) {
                    ForEach(Array(model.days.enumerated()), id: \.offset) { _, day in
                        DayRow(day: day)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Palette.bg.color.ignoresSafeArea())
    }

    private var navigator: some View {
        HStack(spacing: 8) {
            arrow("chevron.left", label: "Previous week", enabled: model.canGoBack) { onWeek(model.week - 1) }
                .padding(.leading, -10)
            VStack(spacing: 0) {
                Text(model.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink.color)
                    .accessibilityIdentifier("week.title")
                Text(model.range).font(.system(size: 13)).foregroundStyle(Palette.muted.color)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            arrow("chevron.right", label: "Next week", enabled: model.canGoForward) { onWeek(model.week + 1) }
                .padding(.trailing, -10)
        }
    }

    private func arrow(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: Metrics.minTouchTarget, height: Metrics.minTouchTarget)
                .contentShape(Rectangle())
        }
        .foregroundStyle(enabled ? Palette.ink.color : Palette.line.color)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.planned).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink.color)
                Spacer(minLength: 0)
                Text(model.summary).font(.system(size: 14)).monospacedDigit().multilineTextAlignment(.trailing).foregroundStyle(Palette.muted.color)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.line.color)
                    Capsule().fill(Palette.green.color).frame(width: proxy.size.width * model.progress)
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}

private struct DayRow: View {
    let day: WeekModel.Day

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Text(day.weekday)
                    .font(.system(size: 12, weight: day.isToday ? .bold : .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(day.isToday ? Palette.accentText.color : Palette.muted.color)
                Text(day.number)
                    .font(.system(size: 18, weight: day.isToday ? .bold : .semibold))
                    .foregroundStyle(day.isToday ? Palette.accentText.color : Palette.ink.color)
            }
            .frame(width: 40)
            .padding(.top, 14)
            VStack(spacing: 8) {
                if day.isRest {
                    rest
                } else {
                    ForEach(Array(day.items.enumerated()), id: \.offset) { _, item in
                        ItemCard(item: item)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.spoken)
    }

    private var rest: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Rest day").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
            Text("Protected. Recovery is part of the plan.").font(.system(size: 13)).foregroundStyle(Palette.muted.color)
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.restBorder.color, style: StrokeStyle(lineWidth: 2, dash: [5, 4])))
    }
}

private struct ItemCard: View {
    let item: WeekModel.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                    Text(item.detail).font(.system(size: 13)).monospacedDigit().foregroundStyle(Palette.muted.color)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            if !item.shape.isEmpty {
                WorkoutShape(segments: item.shape).frame(height: 28)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 16))
        .overlay(item.trailing == .today ? RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.accentBorder.color, lineWidth: 2) : nil)
    }

    @ViewBuilder private var trailing: some View {
        switch item.trailing {
        case .done:
            Circle().fill(Palette.green.color).frame(width: 28, height: 28)
                .overlay(Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Palette.greenInk.color))
        case .skipped:
            Text("Skipped").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted.color)
        case .today:
            Image(systemName: "chevron.right").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
        case .badge(let badge):
            Text(Self.text(badge))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.colors(badge).text)
                .padding(.vertical, 3)
                .padding(.horizontal, 9)
                .background(Self.colors(badge).fill, in: Capsule())
        case .none:
            EmptyView()
        }
    }

    private static func text(_ badge: WeekModel.Badge) -> String {
        switch badge {
        case .easy: "Easy"
        case .long: "Long"
        case .yours: "Yours"
        }
    }

    private static func colors(_ badge: WeekModel.Badge) -> (fill: Color, text: Color) {
        switch badge {
        case .easy: (Palette.greenSoft.color, Palette.greenSoftText.color)
        case .long: (Palette.blueSoft.color, Palette.blueText.color)
        case .yours: (Palette.line.color, Palette.yoursText.color)
        }
    }
}
