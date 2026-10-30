import SwiftUI

/// What the onboarding screens need from outside: the plan service and the 24-hour draft.
struct PreviewDependencies {
    var generator: PlanGenerating
    var store: PreviewDraftStoring
    var now: () -> Date = Date.init
    var today: () -> String = PreviewViewModel.localToday

    static var live: PreviewDependencies {
        PreviewDependencies(generator: APIConfiguration.liveGenerator(), store: PreviewDraftStore())
    }
}

/// Interview, then preview, with no account. A draft saved less than 24 hours ago opens straight on the preview.
@MainActor
struct OnboardingFlow: View {
    private enum Stage {
        case interview(InterviewFlow)
        case preview(PreviewViewModel)
    }

    let dependencies: PreviewDependencies
    let onClose: () -> Void
    /// Decided once, when the screen appears, so a parent re-render never re-reads (and expires) the saved draft.
    @State private var stage: Stage?
    @State private var stageID = 0

    init(dependencies: PreviewDependencies, onClose: @escaping () -> Void) {
        self.dependencies = dependencies
        self.onClose = onClose
    }

    var body: some View {
        Group {
            switch stage {
            case nil:
                Palette.bg.color.ignoresSafeArea()
            case .interview(let flow)?:
                InterviewView(flow: flow, onFinish: finish, onClose: onClose)
            case .preview(let model)?:
                PreviewView(model: model, onChangeAnswer: { change(model.answers) }, onSave: nil) // saving arrives with task 3.4
                    .task { await model.load() }
            }
        }
        .id(stageID)
        .onAppear {
            guard stage == nil else { return }
            if let saved = dependencies.store.load(now: dependencies.now()) {
                stage = .preview(Self.model(for: saved.answers, dependencies))
            } else {
                stage = .interview(InterviewFlow())
            }
        }
    }

    private static func model(for answers: InterviewAnswers, _ d: PreviewDependencies) -> PreviewViewModel {
        PreviewViewModel(answers: answers, generator: d.generator, store: d.store, now: d.now, today: d.today)
    }

    private func finish(_ answers: InterviewAnswers, blankPlan: Bool) {
        if blankPlan { return onClose() } // building a blank plan arrives with the plan editor
        stage = .preview(Self.model(for: answers, dependencies))
        stageID += 1
    }

    private func change(_ answers: InterviewAnswers) {
        stage = .interview(InterviewFlow(prefilledWith: answers))
        stageID += 1
    }
}
