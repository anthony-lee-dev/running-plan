import SwiftUI

/// "I'd rather build my own plan": choose how many weeks, then create an empty plan (signing in first when needed).
/// Sessions are added from the Plan tab with "Add a session".
struct BlankPlanView: View {
    let goal: InterviewAnswers.Goal?
    let today: String
    let save: SaveFlowModel
    let onClose: () -> Void

    @State private var weeks: Int
    /// Made once, so a retried create replays instead of making a second plan.
    @State private var planID = UUID().uuidString.lowercased()

    init(goal: InterviewAnswers.Goal?, today: String, save: SaveFlowModel, onClose: @escaping () -> Void) {
        self.goal = goal
        self.today = today
        self.save = save
        self.onClose = onClose
        _weeks = State(initialValue: BlankPlan.suggestedWeeks(goal: goal, today: today))
    }

    var body: some View {
        let saving = save.step == .saving
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(Palette.ink.color)
                        .frame(width: Metrics.minTouchTarget, height: Metrics.minTouchTarget)
                }
                .accessibilityLabel("Close")
            }
            Text("Build your own plan")
                .font(.system(size: 30, weight: .bold)).tracking(-0.6).foregroundStyle(Palette.ink.color)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("screen.blankPlan")
            Text("Start with an empty plan and add your own sessions, week by week, from the Plan tab. We won't suggest changes to it.")
                .font(.system(size: 16)).foregroundStyle(Palette.muted.color)
            VStack(alignment: .leading, spacing: 6) {
                Stepper("\(weeks) weeks", value: $weeks, in: 1...52)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.ink.color)
                Text("Starts \(NextModel.weekday(BlankPlan.startDate(today: today))), \(PlanPreview.shortDate(BlankPlan.startDate(today: today)))")
                    .font(.system(size: 14)).foregroundStyle(Palette.muted.color)
            }
            .padding(16)
            .background(Palette.card.color, in: RoundedRectangle(cornerRadius: 18))
            Spacer()
            if let error = save.error {
                Text(error).font(.system(size: 14)).foregroundStyle(Palette.accentText.color)
            }
            Button {
                Task { await save.saveBlank(BlankPlan.body(goal: goal, today: today, weeks: weeks, id: planID)) }
            } label: {
                Group {
                    if saving { ProgressView().tint(.white) } else { Text("Create my plan") }
                }
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Palette.accent.color, in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(.white)
                .contentShape(Rectangle())
            }
            .disabled(saving)
            .accessibilityIdentifier("blank.create")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .background(Palette.bg.color.ignoresSafeArea())
        .tint(Palette.accentText.color)
    }
}
