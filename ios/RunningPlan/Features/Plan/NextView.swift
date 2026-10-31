import SwiftUI

/// DK-Next: today's session (or the next one), this week day by day, and what comes after. The review card, the inbox
/// card, Open workout, Make it easier and Move or skip arrive with their own tasks. System fonts until the font task.
struct NextView: View {
    let model: NextModel
    let onSetGoal: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.eyebrow)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.muted.color)
                        .accessibilityIdentifier("next.plan")
                    Text("Ready when you are")
                        .font(.system(size: 30, weight: .bold))
                        .tracking(-0.6)
                        .foregroundStyle(Palette.ink.color)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier(AppTab.next.screenIdentifier)
                }
                if let focus = model.focus {
                    FocusCard(focus: focus)
                } else if let nothing = model.nothingToDo {
                    nothingCard(nothing)
                }
                if !model.week.isEmpty {
                    weekCard
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Palette.bg.color.ignoresSafeArea())
    }

    private func nothingCard(_ nothing: NextModel.NothingToDo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(nothing == .finished ? "Your plan is finished. Well done." : "No more sessions in this plan.")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.ink.color)
            if nothing == .finished {
                Button(action: onSetGoal) {
                    // The frame inside the label, so the whole bar is tappable.
                    Text("Set a new goal")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(Palette.accent.color, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
    }

    private var weekCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("This week").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                Spacer()
                if let header = model.weekHeader {
                    Text(header).font(.system(size: 13)).monospacedDigit().foregroundStyle(Palette.muted.color)
                }
            }
            HStack(spacing: 4) {
                ForEach(Array(model.week.enumerated()), id: \.offset) { _, day in
                    DayDot(day: day).frame(maxWidth: .infinity)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.weekSpoken)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.line.color)
                    Capsule().fill(Palette.green.color).frame(width: proxy.size.width * model.weekProgress)
                }
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            if let nextUp = model.nextUp {
                Text(nextUp).font(.system(size: 13)).foregroundStyle(Palette.muted.color)
            }
        }
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 18, trailing: 16))
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct FocusCard: View {
    let focus: NextModel.Focus

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(focus.label).font(.system(size: 12, weight: .semibold)).tracking(0.96).foregroundStyle(Palette.accentText.color)
                Spacer()
                Text(focus.effort)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.chipText.color)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 10)
                    .background(Palette.accentSoft.color, in: Capsule())
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(focus.title).font(.system(size: 28, weight: .bold)).tracking(-0.56).foregroundStyle(Palette.ink.color)
                Text(focus.detail).font(.system(size: 15)).monospacedDigit().foregroundStyle(Palette.muted.color)
            }
            if !focus.shape.isEmpty {
                WorkoutShape(segments: focus.shape).frame(height: 60)
            }
            Text(focus.why).font(.system(size: 14)).lineSpacing(3).foregroundStyle(Palette.muted.color)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }
}

/// The workout as bars: as wide as each step's time, as tall as its effort (a share of the height it is given, so
/// the 60 pt shape on Next and the 28 pt one on Week keep the boards' proportions).
struct WorkoutShape: View {
    let segments: [SessionSummary.Segment]

    static func heightShare(_ intensity: SessionSummary.Intensity) -> CGFloat {
        switch intensity {
        case .hard: 56.0 / 60
        case .steady: 40.0 / 60
        case .easy: 22.0 / 60
        case .recovery: 14.0 / 60
        }
    }

    static func color(_ intensity: SessionSummary.Intensity) -> Color {
        switch intensity {
        case .hard: Palette.accentBorder.color
        case .steady: Palette.phaseBuild.color
        case .easy, .recovery: Palette.phaseBase.color
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let total = max(segments.reduce(0) { $0 + $1.seconds }, 1)
            let gaps = CGFloat(max(segments.count - 1, 0))
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Self.color(segment.intensity))
                        .frame(width: max(2, (proxy.size.width - gaps) * segment.seconds / total), height: proxy.size.height * Self.heightShare(segment.intensity))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityHidden(true)
    }
}

private struct DayDot: View {
    let day: NextModel.Day

    var body: some View {
        VStack(spacing: 6) {
            Text(day.letter)
                .font(.system(size: 12, weight: day.isToday ? .semibold : .regular))
                .foregroundStyle(day.isToday ? Palette.ink.color : Palette.muted.color)
            dot.frame(width: 36, height: 36)
        }
    }

    @ViewBuilder private var dot: some View {
        switch day.state {
        case .done:
            Circle().fill(Palette.green.color)
                .overlay(Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Palette.greenInk.color))
                .overlay(day.isToday ? Circle().strokeBorder(Palette.accentBorder.color, lineWidth: 3) : nil)
        case .planned(let number):
            Circle().strokeBorder(day.isToday ? Palette.accentBorder.color : Palette.line.color, lineWidth: day.isToday ? 3 : 2)
                .overlay(
                    Text(number)
                        .font(.system(size: 13, weight: day.isToday ? .semibold : .regular))
                        .foregroundStyle(day.isToday ? Palette.ink.color : Palette.muted.color)
                )
        case .rest:
            Circle().strokeBorder(day.isToday ? Palette.accentBorder.color : Palette.restRing.color, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                .overlay(Text("rest").font(.system(size: 11)).foregroundStyle(day.isToday ? Palette.ink.color : Palette.muted.color))
        case .skipped:
            Circle().strokeBorder(day.isToday ? Palette.accentBorder.color : Palette.line.color, lineWidth: 2)
                .overlay(Image(systemName: "minus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Palette.muted.color))
        }
    }
}
