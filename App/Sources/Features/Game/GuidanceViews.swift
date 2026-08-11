//
//  GuidanceViews.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Всё, что приложение говорит игроку по своей инициативе.
//  Общее правило: карточка не блокирует поле, всегда закрывается одним
//  касанием и никогда не появляется дважды без запроса.
//

import SwiftUI
import NamiDomain
import NamiExperience

/// Предложение помощи при затыке. Не подсказывает само —
/// только предлагает открыть первый слой подсказки и честно называет цену.
struct StruggleNudgeCard: View {

    let signal: StruggleSignal
    let palette: CellPalette
    let onAccept: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t(signal.titleKey))
                .font(.subheadline.weight(.medium))
            Text(L.t(signal.bodyKey))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(L.t("nudge.accept"), action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(palette.focusRing)
                Button(L.t("common.notNow"), action: onLater)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
            }
            Text(L.t("nudge.cost"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.focusRing.opacity(0.35), lineWidth: 1)
        )
        .transition(.opacity)
        .accessibilityElement(children: .contain)
    }
}

/// Одноразовая карточка InterfaceCoach (раздел 5.1).
/// Показывается ДО первого самостоятельного использования функции
/// и после просмотра обеих карточек выключается навсегда.
struct CoachCard: View {

    enum Target: String, Identifiable {
        case notes, hint
        var id: String { rawValue }

        var textKey: String { "coach.\(rawValue)" }
        var symbol: String { self == .notes ? "pencil" : "lightbulb" }
    }

    let target: Target
    let palette: CellPalette
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            HStack(spacing: 10) {
                Image(systemName: target.symbol)
                    .foregroundStyle(palette.focusRing)
                Text(L.t(target.textKey))
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.thinMaterial)
            )
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    }
}

/// «Как играть»: обзор основных функций. Всегда пропускается одной кнопкой
/// и доступен потом из выбора сложности — поэтому его не страшно закрыть.
struct HowToPlayView: View {

    @Environment(ThemeProvider.self) private var theme
    @Environment(\.dismiss) private var dismiss

    private struct Topic: Identifiable {
        let id = UUID()
        let symbol: String
        let titleKey: String
        let bodyKey: String
    }

    private let topics: [Topic] = [
        Topic(symbol: "square.grid.3x3", titleKey: "howto.input.title",
              bodyKey: "howto.input.body"),
        Topic(symbol: "pencil", titleKey: "howto.notes.title",
              bodyKey: "howto.notes.body"),
        Topic(symbol: "lightbulb", titleKey: "howto.hint.title",
              bodyKey: "howto.hint.body"),
        Topic(symbol: "slider.horizontal.3", titleKey: "howto.profiles.title",
              bodyKey: "howto.profiles.body"),
        Topic(symbol: "chart.line.uptrend.xyaxis", titleKey: "howto.rating.title",
              bodyKey: "howto.rating.body"),
        Topic(symbol: "flag", titleKey: "howto.challenges.title",
              bodyKey: "howto.challenges.body"),
        Topic(symbol: "gearshape", titleKey: "howto.settings.title",
              bodyKey: "howto.settings.body")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L.t("howto.intro"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(topics) { topic in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: topic.symbol)
                            .foregroundStyle(theme.color(.accent))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L.t(topic.titleKey)).font(.subheadline.weight(.medium))
                            Text(L.t(topic.bodyKey))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }
            .navigationTitle(L.t("home.howToPlay"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.t("common.done")) { dismiss() }
                }
            }
        }
    }
}
