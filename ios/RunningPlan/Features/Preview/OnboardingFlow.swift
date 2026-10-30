import SwiftUI

/// What the onboarding screens need from outside: the plan service, the 24-hour draft, sign-in and saving.
struct PreviewDependencies {
    var generator: PlanGenerating
    var store: PreviewDraftStoring
    var signIn: SignInService
    var saver: PlanSaving
    var now: () -> Date = Date.init
    var today: () -> String = PreviewViewModel.localToday

    static var live: PreviewDependencies {
        PreviewDependencies(
            generator: APIConfiguration.liveGenerator(),
            store: PreviewDraftStore(),
            signIn: APIConfiguration.liveSession,
            saver: APIPlanSaver(client: APIConfiguration.liveSignedInClient())
        )
    }
}

/// Interview, then preview, with no account. A draft saved less than 24 hours ago opens straight on the preview.
@MainActor
struct OnboardingFlow: View {
    private enum Stage {
        case interview(InterviewFlow)
        case preview(PreviewViewModel, SaveFlowModel)
    }

    let dependencies: PreviewDependencies
    let onClose: () -> Void
    /// Called with the new plan's id once it is saved.
    let onSaved: (String) -> Void
    /// Decided once, when the screen appears, so a parent re-render never re-reads (and expires) the saved draft.
    @State private var stage: Stage?
    @State private var stageID = 0

    init(dependencies: PreviewDependencies, onClose: @escaping () -> Void, onSaved: @escaping (String) -> Void = { _ in }) {
        self.dependencies = dependencies
        self.onClose = onClose
        self.onSaved = onSaved
    }

    var body: some View {
        Group {
            switch stage {
            case nil:
                Palette.bg.color.ignoresSafeArea()
            case .interview(let flow)?:
                InterviewView(flow: flow, onFinish: finish, onClose: onClose)
            case .preview(let model, let save)?:
                // Read here, in the body, so a change of step redraws the screen and shows or hides the sheet.
                let signingIn = save.showsSignIn
                PreviewView(
                    model: model,
                    onChangeAnswer: { change(model.answers) },
                    onSave: model.current.map { preview in { Task { await save.save(preview) } } },
                    onClose: onClose,
                    saving: save.step == .saving,
                    saveError: save.error
                )
                .task { await model.load() }
                .sheet(isPresented: Binding(get: { signingIn }, set: { if !$0 && save.showsSignIn { save.cancelSignIn() } })) {
                    SignInView(model: save)
                }
                .onChange(of: save.step) {
                    if case .saved(let id) = save.step { onSaved(id) }
                }
            }
        }
        .id(stageID)
        .onAppear {
            guard stage == nil else { return }
            if let saved = dependencies.store.load(now: dependencies.now()) {
                stage = Self.preview(for: saved.answers, dependencies)
            } else {
                stage = .interview(InterviewFlow())
            }
        }
    }

    private static func preview(for answers: InterviewAnswers, _ d: PreviewDependencies) -> Stage {
        .preview(
            PreviewViewModel(answers: answers, generator: d.generator, store: d.store, now: d.now, today: d.today),
            SaveFlowModel(signIn: d.signIn, saver: d.saver, store: d.store, now: d.now)
        )
    }

    private func finish(_ answers: InterviewAnswers, blankPlan: Bool) {
        if blankPlan { return onClose() } // building a blank plan arrives with the plan editor
        stage = Self.preview(for: answers, dependencies)
        stageID += 1
    }

    private func change(_ answers: InterviewAnswers) {
        stage = .interview(InterviewFlow(prefilledWith: answers))
        stageID += 1
    }
}
