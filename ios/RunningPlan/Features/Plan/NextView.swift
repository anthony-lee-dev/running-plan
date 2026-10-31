import SwiftUI

/// DK-Next: today's session (or the next one) with Open workout, Make it easier and Move or skip, this week day by day,
/// and what comes after. The review card and the inbox card arrive with their own tasks. System fonts until the font task.
struct NextView: View {
    let model: NextModel
    let onSetGoal: () -> Void
    var onOpen: (String) -> Void = { _ in }
    var onEasier: (String) -> Void = { _ in }
    var onMove: (String) -> Void = { _ in }
    /// Workouts waiting in the import inbox, and the way into it (also how a run is added by hand).
    var inboxCount = 0
    var onInbox: () -> Void = {}
    /// A quick adjustment is on its way to the server.
    var busy = false
    var error: String?

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
                    FocusCard(focus: focus, busy: busy, error: error, onOpen: onOpen, onEasier: onEasier, onMove: onMove)
                } else if let nothing = model.nothingToDo {
                    nothingCard(nothing)
                }
                if !model.week.isEmpty {
                    weekCard
                }
                inboxCard
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Palette.bg.color.ignoresSafeArea())
    }

    private var inboxCard: some View {
        Button(action: onInbox) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import inbox").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                    Text(inboxCount == 0 ? "Check Health for new runs" : "\(inboxCount) waiting to be matched")
                        .font(.system(size: 13)).foregroundStyle(Palette.muted.color)
                }
                Spacer()
                if inboxCount > 0 {
                    Text("\(inboxCount)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 3).background(Palette.accent.color, in: Capsule())
                }
                Image(systemName: "chevron.right").foregroundStyle(Palette.muted.color)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: Metrics.minTouchTarget, alignment: .leading)
            .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 20))
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("next.inbox")
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
    let busy: Bool
    let error: String?
    let onOpen: (String) -> Void
    let onEasier: (String) -> Void
    let onMove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            summary
            Button { onOpen(focus.sessionId) } label: {
                Text("Open workout")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Palette.accent.color, in: RoundedRectangle(cornerRadius: 16))
                    .foregroundStyle(.white)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("next.open")
            if focus.canAdjust {
                HStack(spacing: 10) {
                    SecondaryButton(title: "Make it easier") { onEasier(focus.sessionId) }
                    SecondaryButton(title: "Move or skip") { onMove(focus.sessionId) }
                }
                .disabled(busy)
                .opacity(busy ? 0.4 : 1)
            }
            if let error {
                Text(error).font(.system(size: 13)).foregroundStyle(Palette.accentText.color)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
    }

    private var summary: some View {
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(focus.label.capitalized): \(focus.title), \(focus.effort). \(PaceFormat.spoken(focus.detail)). \(focus.why)")
    }
}

/// A bordered button (design notes: secondary button), full width of its share of the row.
struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(Palette.ink.color)
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.goalTrack.color, lineWidth: 1))
                .contentShape(Rectangle())
        }
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
