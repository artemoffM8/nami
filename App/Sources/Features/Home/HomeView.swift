//
//  HomeView.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Раздел 5.2. Приоритет сверху вниз: одна большая кнопка, рекомендуемая
//  сложность, компактная карточка рейтинга, стадия пространства, вторичные
//  действия. Ни карусели, ни баннеров, ни отдельной кнопки магазина.
//

import SwiftUI
import NamiDomain
import NamiData
import NamiExperience

struct HomeView: View {

    @Environment(AppRouter.self) private var router
    @Environment(ThemeProvider.self) private var theme
    @Environment(PreferencesRepository.self) private var preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showDifficulty = false
    @State private var showSettings = false
    @State private var showProgress = false
    @State private var showHowToPlay = false
    @State private var showStatistics = false
    @State private var showDojo = false

    var body: some View {
        ZStack {
            ClaritySpaceView(
                tier: router.snapshot.bestTier,
                detailLevel: router.snapshot.bestDivision?.detailLevel ?? 0,
                state: .ambient,
                theme: theme.current,
                reduceMotion: reduceMotion || preferences.reduceMotionBoost
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer(minLength: 40)

                Text(L.t("app.name"))
                    .font(.system(size: 30, weight: .regular))
                    .tracking(6)
                    .foregroundStyle(theme.color(.primaryText))

                Spacer()

                primaryButton

                // Раньше единственным входом в выбор сложности была строка
                // «Рекомендуем: …», похожая на подпись, а не на кнопку.
                Button {
                    showDifficulty = true
                } label: {
                    VStack(spacing: 2) {
                        Text(L.t("home.newGame"))
                            .font(.body.weight(.medium))
                        Text(L.t("home.recommended", L.t(router.recommendedTier.titleKey)))
                            .font(.caption)
                            .foregroundStyle(theme.color(.secondaryText))
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.bordered)
                .tint(theme.color(.accent))

                Button { showProgress = true } label: { ratingCard }
                    .buttonStyle(.plain)

                Spacer()

                menuRow
                    .padding(.bottom, 16)
            }
            .padding(.horizontal, 24)
        }
        .sheet(isPresented: $showDifficulty) { DifficultySheet().themedSurface() }
        .sheet(isPresented: $showSettings) { SettingsView().themedSurface() }
        .sheet(isPresented: $showProgress) { ProgressSheet().themedSurface() }
        .sheet(isPresented: $showHowToPlay) { HowToPlayView().themedSurface() }
        .sheet(isPresented: $showStatistics) { StatisticsView().themedSurface() }
        .sheet(isPresented: $showDojo) { DojoView().themedSurface() }
        .alert(
            router.startupWarning ?? "",
            isPresented: Binding(
                get: { router.startupWarning != nil },
                set: { if !$0 { router.dismissWarning() } }
            )
        ) {
            Button(L.t("common.close")) { router.dismissWarning() }
        }
        .onAppear {
            router.refreshSnapshot()
            // Обзор показывается ОДИН раз после онбординга и потом всегда
            // доступен из выбора сложности — поэтому его не страшно закрыть.
            if !preferences.howToPlaySeen {
                preferences.howToPlaySeen = true
                showHowToPlay = true
            }
        }
    }

    /// Явное меню вместо двух неприметных ссылок внизу. Каждый пункт —
    /// иконка плюс подпись: без подписи иконки читаются как угодно.
    private var menuRow: some View {
        HStack(alignment: .top, spacing: 4) {
            menuItem("chart.line.uptrend.xyaxis", L.t("home.progress")) { showProgress = true }
            menuItem("rosette", L.t("stats.title")) { showStatistics = true }
            // Додзё стоит рядом с «Как играть», а не в настройках: это способ
            // научиться, а не параметр.
            menuItem("figure.mind.and.body", L.t("home.dojo")) { showDojo = true }
            menuItem("questionmark.circle", L.t("home.howToPlay")) { showHowToPlay = true }
            menuItem("gearshape", L.t("common.settings")) { showSettings = true }
        }
    }

    private func menuItem(_ icon: String, _ title: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.title3)
                Text(title)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.color(.secondaryText))
        .accessibilityLabel(title)
    }

    private var primaryButton: some View {
        Button {
            if router.hasSavedGame { router.continueSavedGame() } else { router.startDaily() }
        } label: {
            Text(router.hasSavedGame ? L.t("home.continueGame") : L.t("home.dailyRitual"))
                .font(.title3.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.borderedProminent)
        .tint(theme.color(.accent))
    }

    /// До пятого рейтингового результата — карточка «Калибровка N/5»
    /// с нейтральной линией горизонта, без ранга и расстояния.
    @ViewBuilder
    private var ratingCard: some View {
        let snapshot = router.snapshot
        VStack(spacing: 8) {
            if snapshot.isCalibrating {
                Text(L.t("home.calibration", snapshot.calibrationRatedCount,
                         RatingEngine.calibrationCount))
                    .font(.headline)
                Text(L.t("home.calibrationHint"))
                    .font(.caption)
                    .foregroundStyle(theme.color(.secondaryText))
            } else {
                Text("\(snapshot.rating)")
                    .font(.system(size: 40, weight: .regular))
                    .monospacedDigit()
                Text(L.t("home.rating"))
                    .font(.caption)
                    .foregroundStyle(theme.color(.secondaryText))

                if let display = snapshot.displayDivision {
                    Text("\(L.t(display.tier.titleKey)) \(display.romanKey)")
                        .font(.subheadline.weight(.medium))
                    if let progress = snapshot.promotionConfirmationProgress() {
                        Text(L.t("home.promotionConfirmation", progress))
                            .font(.caption)
                            .foregroundStyle(theme.color(.accent))
                    } else if display.index < 14,
                              let distance = display.pointsToNext(from: snapshot.rating),
                              // Ноль очков до порога означает, что порог уже
                              // пройден и ждать надо подтверждения, а не очков.
                              // Строка «до ранга — 0» при неподвижном ранге
                              // читается как поломка.
                              distance > 0 {
                        let next = RankDivision(index: display.index + 1)
                        Text(L.t("home.toNextRank",
                                 "\(L.t(next.tier.titleKey)) \(next.romanKey)", distance))
                            .font(.caption)
                            .foregroundStyle(theme.color(.secondaryText))
                    } else if display.index < 14,
                              display.pointsToNext(from: snapshot.rating) == 0 {
                        Text(L.t("home.promotionConfirmation", 0))
                            .font(.caption)
                            .foregroundStyle(theme.color(.secondaryText))
                    }
                }
            }

            Text(L.t("home.rhythm", router.rhythm.completedDays))
                .font(.caption)
                .foregroundStyle(theme.color(.secondaryText))
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(theme.color(.boardSurface).opacity(0.85))
        )
        .accessibilityElement(children: .combine)
    }
}

/// Раздел 5.3. «Как играть» — отдельное действие над списком, а не шестой уровень.
struct DifficultySheet: View {

    @Environment(AppRouter.self) private var router
    @Environment(ThemeProvider.self) private var theme
    @Environment(PreferencesRepository.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @State private var showHowToPlay = false
    @State private var mode: GameMode = .ranked

    // Модификаторы поверх одной игровой сессии, а не три отдельных движка.
    @State private var perfect = false
    @State private var noNotes = false
    @State private var againstPersonalBest = false

    private var modifiers: [ChallengeModifier] {
        var result: [ChallengeModifier] = []
        if perfect { result.append(.perfect) }
        if noNotes { result.append(.noNotes) }
        return result
    }

    private var paceMode: RatingPaceMode {
        againstPersonalBest ? .againstPersonalBest : .disabled
    }

    var body: some View {
        NavigationStack {
            List {
                Section(L.t("mode.choose")) {
                    Picker(L.t("mode.choose"), selection: $mode) {
                        ForEach(GameMode.allCases) { item in
                            Text(L.t(item.titleKey)).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(L.t(mode.subtitleKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // Текущий рейтинг показывается только там, где он на кону.
                    if mode.appliesRating {
                        let snapshot = router.snapshot
                        // Во время калибровки подтверждённой ступени ещё нет:
                        // показываем сырую, но приглушённой — она предварительна.
                        let division = snapshot.displayDivision ?? snapshot.ratingDivision
                        HStack(spacing: 12) {
                            RankBadgeView(division: division,
                                          size: 44,
                                          accent: theme.color(.accent),
                                          surface: theme.color(.boardSurface),
                                          isDimmed: snapshot.displayDivision == nil)
                            RankProgressBar(rating: snapshot.rating,
                                            division: division,
                                            accent: theme.color(.accent),
                                            track: theme.color(.secondaryText))
                        }
                        .padding(.vertical, 2)

                        if snapshot.isCalibrating {
                            Text(L.t("home.calibration",
                                     snapshot.calibrationRatedCount,
                                     RatingEngine.calibrationCount))
                                .font(.caption2)
                                .foregroundStyle(theme.color(.secondaryText))
                        }
                    }
                }

                Section {
                    ForEach(DifficultyTier.allCases, id: \.self) { tier in
                        Button {
                            preferences.gameMode = mode
                            dismiss()
                            router.startNewGame(tier: tier,
                                                mode: mode,
                                                modifiers: modifiers,
                                                paceMode: paceMode)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L.t(tier.titleKey)).font(.headline)
                                Text(L.t(tier.subtitleKey))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let sample = router.puzzles.puzzles(in: tier).first {
                                    Text(L.t("difficulty.expectedTime",
                                             max(3, sample.estimatedMinutes - 3),
                                             sample.estimatedMinutes + 5))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                if let best = router.progress.personalBest(for: tier) {
                                    Text(L.t("challenge.personalBest",
                                             best / 60, best % 60))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                } header: {
                    Text(L.t("home.chooseDifficulty"))
                }

                Section {
                    Button(L.t("home.howToPlay")) { showHowToPlay = true }
                }

                // Раздел 11: модификаторы, а не отдельные режимы.
                // Всё, что влияет на рейтинг, объявлено ДО старта.
                Section {
                    Toggle(L.t("challenge.perfect.title"), isOn: $perfect)
                    Toggle(L.t("challenge.noNotes.title"), isOn: $noNotes)
                    Toggle(L.t("challenge.againstPB"), isOn: $againstPersonalBest)
                } header: {
                    Text(L.t("challenge.section"))
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if perfect { Text(L.t("challenge.perfect.rule")) }
                        if noNotes { Text(L.t("challenge.noNotes.rule")) }
                        if againstPersonalBest { Text(L.t("challenge.speedRule")) }
                    }
                    .font(.caption2)
                }
            }
            .onAppear { mode = preferences.gameMode }
            .navigationTitle(L.t("home.chooseDifficulty"))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showHowToPlay) { HowToPlayView().themedSurface() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("common.close")) { dismiss() }
                }
            }
        }
    }
}

/// Раздел 5.6.
struct ProgressSheet: View {

    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(L.t("home.rating")) {
                    LabeledContent(L.t("home.rating"), value: "\(router.snapshot.rating)")
                    if let display = router.snapshot.displayDivision {
                        LabeledContent(
                            L.t("progress.title"),
                            value: "\(L.t(display.tier.titleKey)) \(display.romanKey)"
                        )
                    }
                    if let stability = router.snapshot.demotionRiskProgress() {
                        Text(L.t("progress.stability", stability))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section(L.t("progress.lastResults")) {
                    let results = router.progress.recentResults(limit: 10)
                    if results.isEmpty {
                        Text("—").foregroundStyle(.secondary)
                    } else {
                        ForEach(results, id: \.id) { result in
                            HStack {
                                Text(L.t("difficulty.\(result.tierRaw).title"))
                                Spacer()
                                Text(result.deltaR >= 0 ? "+\(result.deltaR)" : "\(result.deltaR)")
                                    .monospacedDigit()
                                    .foregroundStyle(result.isRanked ? .primary : .secondary)
                            }
                        }
                    }
                }
                Section {
                    Text(L.t("home.rhythm", router.rhythm.completedDays))
                }
            }
            .navigationTitle(L.t("progress.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("common.close")) { dismiss() }
                }
            }
        }
    }
}
