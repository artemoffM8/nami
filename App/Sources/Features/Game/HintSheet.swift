//
//  HintSheet.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Подсказка раскрывается слоями (раздел 4.2). Sheet не закрывает поле,
//  на каждом шаге ровно одна основная кнопка «Ещё шаг», а Reveal требует
//  отдельного подтверждения и явно предупреждает о потере рейтинга.
//
//  Максимальный открытый слой уже записан в ledger и не отменяется закрытием
//  sheet, Undo или сменой профиля.
//

import SwiftUI
import NamiDomain

struct HintSheet: View {

    let state: HintDisplayState
    let onAdvance: () -> Void
    let onReveal: () -> Void
    let onClose: () -> Void

    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L.t("hint.title"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)

            content

            HStack {
                Button(L.t("common.close"), action: onClose)
                    .buttonStyle(.bordered)
                Spacer()
                primaryAction
            }
        }
        .padding(20)
        .presentationDetents([.height(280), .medium])
        .presentationBackgroundInteraction(.enabled(upThrough: .height(280)))
        .onAppear { titleFocused = true }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .closed:
            EmptyView()

        case .conflicts:
            // Критерий приёмки 37: только conflict guidance, без trace и Reveal.
            Text(L.t("hint.conflictFirst"))
                .font(.body)

        case .unsolvable:
            Text(L.t("hint.unsolvablePosition")).font(.body)

        case .noStep:
            Text(L.t("hint.noLogicalStep")).font(.body)

        case .step(let step, let layer):
            VStack(alignment: .leading, spacing: 10) {
                Label(L.t(layer.titleKey), systemImage: "lightbulb")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if layer >= .techniqueName {
                    Text(L.t(step.technique.nameKey)).font(.title3.weight(.semibold))
                }
                if layer >= .candidatesAndLogic {
                    Text(L.t(step.technique.explanationKey)).font(.body)
                }
                if layer == .region {
                    Text(L.t("hint.regionBody")).font(.body)
                }
                if layer >= .candidatesAndLogic {
                    Text(L.t("hint.revealWarning"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch state {
        case .step(let step, let layer):
            if layer < .candidatesAndLogic {
                Button(L.t("hint.nextStep"), action: onAdvance)
                    .buttonStyle(.borderedProminent)
            } else if step.placement != nil {
                Button(L.t("hint.layer.4.title"), action: onReveal)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            } else {
                Button(L.t("common.done"), action: onClose)
                    .buttonStyle(.borderedProminent)
            }
        default:
            Button(L.t("common.done"), action: onClose)
                .buttonStyle(.borderedProminent)
        }
    }
}
