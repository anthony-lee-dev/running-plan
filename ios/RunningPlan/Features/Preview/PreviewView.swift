import SwiftUI

/// DK-Preview: the suggested plan before there is an account. System fonts until the font task.
struct PreviewView: View {
    let model: PreviewViewModel
    let onChangeAnswer: () -> Void
    /// Nil shows the button disabled.
    let onSave: (() -> Void)?
    /// Leaves the preview; the draft stays on the device for 24 hours.
    var onClose: () -> Void = {}
    /// Save shows a spinner in place of its label and cannot be tapped again.
    var saving = false
    /// A save failure, shown under the button.
    var saveError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                switch model.state {
                case .loading:
                    header(subtitle: "Making your plan…")
                    startCard
                    ProgressView().tint(Palette.accentText.color).frame(maxWidth: .infinity).padding(.top, 40).accessibilityLabel("Making your plan")
                case .failed(let message):
                    header(subtitle: nil)
                    failure(message)
                case .loaded(let preview):
                    header(subtitle: preview.headline + ". It starts gently, and you can change anything.")
                    chart(preview)
                    weekOne(preview)
                    startCard
                    notices(preview)
                    footer
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 34)
        }
        .background(Palette.bg.color.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("screen.preview")
    }

    // MARK: Pieces

    private func header(subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PREVIEW · NOT SAVED YET")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.96)
                .foregroundStyle(Palette.accentText.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                // An overlay, so the board's layout (which has no close control) keeps its spacing.
                .overlay(alignment: .trailing) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: Metrics.minTouchTarget, height: Metrics.minTouchTarget)
                            .contentShape(Rectangle())
                    }
                    .foregroundStyle(Palette.ink.color)
                    .accessibilityLabel("Close")
                    // Closing mid-save would lose the "saved" hand-off for a plan the server already has.
                    .disabled(saving)
                    .padding(.trailing, -12)
                }
            Text("Your suggested plan")
                .font(.system(size: 34, weight: .bold))
                .tracking(-0.7)
                .foregroundStyle(Palette.ink.color)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).font(.system(size: 16)).foregroundStyle(Palette.muted.color)
            }
        }
        .padding(.top, 8)
    }

    /// The start-date picker: today by default, or any earlier day (a back-dated plan shows its past sessions as missed,
    /// so a run already done can be matched to one).
    private var startCard: some View {
        let zone = TimeZone.current
        let chosen = model.effectiveStart
        let latest = model.latestStart
        let aligned = model.current?.draft.startDate
        return card(spacing: 8) {
            HStack {
                Text("Starts on").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                Spacer()
                DatePicker(
                    "Starts on",
                    selection: Binding(
                        get: { LocalDay.noon(of: chosen, in: zone) },
                        set: { newValue in
                            let day = LocalDay.string(from: newValue, in: zone)
                            Task { await model.setStartDate(day) }
                        }
                    ),
                    in: ...LocalDay.noon(of: latest, in: zone),
                    displayedComponents: .date
                )
                .labelsHidden()
                .colorScheme(.dark)
                .accessibilityIdentifier("preview.startDate")
            }
            Text("Today, or an earlier day if you've already started. Sessions before today show as missed.")
                .font(.system(size: 13)).foregroundStyle(Palette.muted.color)
            if let aligned, aligned != chosen {
                Text("Your goal date moves the start to \(LocalDay.heading(aligned)), so the plan ends on it.")
                    .font(.system(size: 13)).foregroundStyle(Palette.amberText.color)
                    .accessibilityIdentifier("preview.startAligned")
            }
        }
    }

    private func failure(_ message: String) -> some View {
        card {
            Text(message).font(.system(size: 16)).foregroundStyle(Palette.ink.color).accessibilityIdentifier("preview.error")
            Button("Try again") { Task { await model.retry() } }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.accentText.color)
                .frame(minHeight: Metrics.minTouchTarget)
            Button("Change an answer", action: onChangeAnswer)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.muted.color)
                .frame(minHeight: Metrics.minTouchTarget)
        }
    }

    private func chart(_ preview: PlanPreview) -> some View {
        card(spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Weekly distance").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                Spacer()
                Text("km per week").font(.system(size: 13)).foregroundStyle(Palette.muted.color)
            }
            WeeklyBars(bars: preview.bars)
                .frame(height: 130)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(preview.chartDescription)
            HStack(spacing: 14) {
                ForEach([PlanPreview.Phase.base, .build, .peak, .taper], id: \.self) { phase in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(WeeklyBars.color(phase)).frame(width: 12, height: 12)
                        Text(phase.title).font(.system(size: 12)).foregroundStyle(Palette.muted.color)
                    }
                }
            }
            .accessibilityHidden(true)
            if !preview.chartNote.isEmpty {
                Text(preview.chartNote).font(.system(size: 14)).foregroundStyle(Palette.muted.color)
            }
        }
    }

    private func weekOne(_ preview: PlanPreview) -> some View {
        card(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(preview.weekTitle).font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                Spacer()
                Text(preview.weekPhase).font(.system(size: 13)).foregroundStyle(Palette.muted.color)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                ForEach(preview.days) { day in
                    GridRow {
                        Text(day.weekday).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.muted.color).frame(minWidth: 44, alignment: .leading)
                        Text(day.text).font(.system(size: 15)).foregroundStyle(day.isRest ? Palette.muted.color : Palette.ink.color)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let sample = preview.sample {
                Divider().overlay(Palette.line.color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(sample.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink.color)
                    Text(sample.detail).font(.system(size: 14)).monospacedDigit().foregroundStyle(Palette.muted.color)
                    Text(sample.why).font(.system(size: 14)).foregroundStyle(Palette.muted.color)
                }
            }
        }
    }

    @ViewBuilder private func notices(_ preview: PlanPreview) -> some View {
        if !preview.warnings.isEmpty {
            notice(title: "Heads up", lines: preview.warnings.map(\.message), showChange: false)
        }
        notice(title: "What we assumed", lines: preview.assumptions, showChange: true)
    }

    private func notice(title: String, lines: [String], showChange: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.amberTitle.color).accessibilityAddTraits(.isHeader)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 14)).foregroundStyle(Palette.amberText.color)
            }
            if showChange {
                Button("Change an answer", action: onChangeAnswer)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.amberLink.color)
                    .frame(minHeight: Metrics.minTouchTarget, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.amberSoft.color, in: RoundedRectangle(cornerRadius: 20))
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button(action: { onSave?() }) {
                ZStack {
                    Text("Save your plan").opacity(saving ? 0 : 1)
                    if saving { ProgressView().tint(.white).accessibilityLabel("Saving your plan") }
                }
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Palette.accent.color, in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.white)
            }
            .disabled(onSave == nil || saving)
            .opacity(onSave == nil ? 0.4 : 1)
            .accessibilityIdentifier("preview.save")
            if let saveError {
                Text(saveError).font(.system(size: 15)).foregroundStyle(Palette.amberText.color).accessibilityIdentifier("preview.saveError")
            }
            Text("Sign in with your email to keep it. Unsaved previews are deleted after 24 hours.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.muted.color)
        }
        .padding(.top, 6)
    }

    private func card<Content: View>(spacing: CGFloat = 10, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: spacing, content: content)
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
    }
}

/// One bar per week, in the colour of its phase, as tall as its distance.
struct WeeklyBars: View {
    let bars: [PlanPreview.WeekBar]

    static func color(_ phase: PlanPreview.Phase) -> Color {
        switch phase {
        case .base: Palette.phaseBase.color
        case .build: Palette.phaseBuild.color
        case .peak: Palette.phasePeak.color
        case .taper: Palette.phaseTaper.color
        }
    }

    var body: some View {
        let tallest = max(bars.map(\.kilometres).max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(bars) { bar in
                UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 2, bottomTrailingRadius: 2, topTrailingRadius: 6)
                    .fill(Self.color(bar.phase))
                    .frame(height: max(4, 119 * bar.kilometres / tallest))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
