import SwiftUI

/// DK-CheckIn after a confirmed match: sends the after-session check-in through `PlanStore`. The check-in's id is made
/// once per visit, so a retry after a lost reply is not stored twice.
struct CheckInScreen: View {
    let plans: PlanStore
    let target: InboxStore.CheckInTarget
    let onClose: () -> Void
    @State private var feeling: AfterFeeling?
    @State private var pain = false
    @State private var saving = false
    @State private var error: String?
    @State private var id = UUID().uuidString.lowercased()

    var body: some View {
        CheckInView(
            model: CheckInModel(session: target.session.value2, activity: target.activity),
            feeling: $feeling, pain: $pain, saving: saving, error: error,
            onSave: save, onSkip: onClose
        )
    }

    private func save() {
        guard let feeling else { return }
        saving = true
        Task {
            let failed = await plans.checkIn(sessionId: target.id, after: AfterCheckIn(feeling: feeling, pain: pain), id: id)
            saving = false
            if let failed { error = failed } else { onClose() }
        }
    }
}

/// Draws a `CheckInModel`; the answers are bindings so the snapshot test can set them. System fonts until the font task.
struct CheckInView: View {
    let model: CheckInModel
    @Binding var feeling: AfterFeeling?
    @Binding var pain: Bool
    var saving = false
    var error: String?
    var onSave: () -> Void = {}
    var onSkip: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Button(action: onSkip) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 18, weight: .semibold))
                        Text("Inbox").font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(Palette.ink.color)
                    .frame(minHeight: Metrics.minTouchTarget)
                    .contentShape(Rectangle())
                }
                .padding(.leading, -6)
                .accessibilityLabel("Back to Inbox")
                header
                planVsActual
                checkIn
                if let error {
                    Text(error).font(.system(size: 14)).foregroundStyle(Palette.accentText.color).accessibilityIdentifier("checkin.error")
                }
                actions
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Palette.bg.color.ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.eyebrow).font(.system(size: 12, weight: .semibold)).tracking(1).foregroundStyle(Palette.green.color)
            Text(model.headline)
                .font(.system(size: 32, weight: .bold)).tracking(-0.6)
                .foregroundStyle(Palette.ink.color)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("screen.checkin")
            Text(model.summary).font(.system(size: 15)).foregroundStyle(Palette.muted.color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var planVsActual: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Plan vs actual").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                .accessibilityAddTraits(.isHeader)
            if let distance = model.distance { bar(distance, id: "checkin.distance") }
            bar(model.time, id: "checkin.time")
            if let pace = model.pace { paceRow(pace) }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
    }

    private func valueLine(_ label: String, planned: String?, actual: String) -> some View {
        HStack {
            Text(label).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.ink.color)
            Spacer()
            (Text(planned.map { "\($0) · " } ?? "").foregroundStyle(Palette.muted.color)
                + Text(actual).fontWeight(.bold).foregroundStyle(Palette.ink.color))
                .font(.system(size: 14)).monospacedDigit()
        }
    }

    private func bar(_ bar: CheckInModel.Bar, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            valueLine(bar.label, planned: bar.planned, actual: bar.actual)
            if let fill = bar.fill {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.goalTrack.color)
                        Capsule().fill(Palette.green.color).frame(width: geo.size.width * fill)
                    }
                }
                .frame(height: 10)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bar.spoken)
        .accessibilityIdentifier(id)
    }

    private func paceRow(_ pace: CheckInModel.Pace) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            valueLine("Pace", planned: pace.planned, actual: pace.actual)
            if let band = pace.band, let marker = pace.marker {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.goalTrack.color).frame(height: 10)
                        Capsule().fill(Palette.greenSoft.color)
                            .overlay(Capsule().strokeBorder(Palette.green.color, lineWidth: 1))
                            .frame(width: w * (band.upperBound - band.lowerBound), height: 10)
                            .offset(x: w * band.lowerBound)
                        RoundedRectangle(cornerRadius: 2).fill(Palette.ink.color)
                            .frame(width: 4, height: 16)
                            .offset(x: min(w - 4, max(0, w * marker - 2)))
                    }
                    .frame(height: 16)
                }
                .frame(height: 16)
            }
            if let verdict = pace.verdict {
                Text(verdict).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(pace.inRange ? Palette.greenSoftText.color : Palette.amberText.color)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pace.spoken)
        .accessibilityIdentifier("checkin.pace")
    }

    private var checkIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("How did it feel?").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.ink.color)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 8) {
                ForEach(AfterFeeling.allCases, id: \.self) { option in
                    feelingRow(option)
                }
            }
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Any pain or niggle?").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.ink.color)
                    Text("Just yes or no").font(.system(size: 13)).foregroundStyle(Palette.muted.color)
                }
                Spacer()
                painSwitch
            }
            .padding(.top, 6)
            guidance
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 24))
    }

    private func feelingRow(_ option: AfterFeeling) -> some View {
        let selected = feeling == option
        return Button { feeling = option } label: {
            HStack {
                Text(option.title).font(.system(size: 15, weight: selected ? .bold : .semibold)).foregroundStyle(Palette.ink.color)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(Palette.accentText.color)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(selected ? Palette.accentSoft.color : .clear, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? Palette.accentBorder.color : Palette.goalTrack.color, lineWidth: selected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("checkin.feel")
    }

    /// Yes / No, the whole 46 pt track the hit area (docs/design-notes.md, touch targets).
    private var painSwitch: some View {
        HStack(spacing: 0) {
            segment("Yes", selected: pain) { pain = true }
            segment("No", selected: !pain) { pain = false }
        }
        .padding(.horizontal, 3)
        .background(Palette.segmentTrack.color, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Any pain or niggle?")
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? Palette.ink.color : Palette.muted.color)
                .frame(minWidth: 56, minHeight: 40)
                .background(selected ? Palette.segmentSelected.color : .clear, in: RoundedRectangle(cornerRadius: 10))
                // The track's own padding belongs to the button, so the whole 46 pt track is the hit area.
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("checkin.pain.\(title.lowercased())")
    }

    /// Never dismissible, whatever the review setting; a notice card once pain is flagged.
    @ViewBuilder private var guidance: some View {
        let g = CheckInModel.painGuidance(pain: pain)
        if g.isNotice {
            VStack(alignment: .leading, spacing: 4) {
                Text("Look after it").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.amberTitle.color)
                Text(g.text).font(.system(size: 13)).foregroundStyle(Palette.amberText.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.amberSoft.color, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("checkin.guidance")
        } else {
            Text(g.text).font(.system(size: 13)).foregroundStyle(Palette.muted.color)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("checkin.guidance")
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: onSave) {
                ZStack {
                    if saving { ProgressView().tint(.white) } else { Text("Save").font(.system(size: 17, weight: .semibold)) }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Palette.accent.color, in: RoundedRectangle(cornerRadius: 18))
                .contentShape(Rectangle())
            }
            .disabled(saving || feeling == nil)
            .opacity(feeling == nil ? 0.4 : 1)
            .accessibilityLabel("Save")
            .accessibilityIdentifier("checkin.save")
            Button(action: onSkip) {
                Text("Skip for now").font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.muted.color)
                    .frame(maxWidth: .infinity, minHeight: Metrics.minTouchTarget).contentShape(Rectangle())
            }
            .accessibilityIdentifier("checkin.skip")
        }
        .padding(.top, 8)
    }
}
