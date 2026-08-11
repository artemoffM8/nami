//
//  GameView.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Игровой экран (раздел 5.4). Логотип и глобальная навигация скрыты,
//  поле почти edge-to-edge, таймер скрыт по умолчанию, во время партии
//  фон полностью статичен и приглушён.
//

import SwiftUI
import NamiDomain
import NamiData
import NamiExperience

struct GameView: View {

    @Environment(GameSessionStore.self) private var session
    @Environment(ThemeProvider.self) private var theme
    @Environment(PreferencesRepository.self) private var preferences
    @Environment(AppRouter.self) private var router
    @Environment(FeedbackCoordinator.self) private var feedback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @State private var showPause = false
    @State private var showHint = false
    @State private var showStatistics = false
    @State private var showRestartConfirm = false
    @State private var showSettings = false
    @State private var showNewGameConfirm = false
    @State private var coachTarget: CoachCard.Target?

    private var palette: CellPalette { CellPalette(theme: theme) }

    /// Во время калибровки перезапуск заблокирован: он делает партию
    /// тренировочной, а значит три нужных результата не наберутся.
    private var restartBlocked: Bool {
        session.mode.appliesRating && router.snapshot.isCalibrating
    }

    var body: some View {
        ZStack {
            ClaritySpaceView(
                tier: router.snapshot.bestTier,
                detailLevel: router.snapshot.bestDivision?.detailLevel ?? 0,
                state: showPause ? .dimmedStill : .still,
                theme: theme.current,
                reduceMotion: reduceMotion || preferences.reduceMotionBoost
            )
            .ignoresSafeArea()

            VStack(spacing: 10) {
                topBar
                // Отдельная полоса: счёт не должен двигать сетку при каждом
                // изменении и не должен отъедать площадь касания у клеток.
                if session.mode.appliesRating {
                    ScoreHUD(
                        score: session.sessionScore,
                        pendingCount: session.pendingScoreCount,
                        delta: session.scoreDelta,
                        palette: palette,
                        accent: theme.color(.accent),
                        primary: theme.color(.primaryText),
                        secondary: theme.color(.secondaryText),
                        reduceMotion: effectsReduceMotion
                    )
                }
                board
                statusLine
                actionRow
                keypad
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            session.startTiming()
            session.struggleNudgesEnabled = preferences.struggleNudges
            startCoachIfNeeded()
            // Детектор затыка опрашивается редко: он почти всегда молчит,
            // а дорогой поиск хода делает только когда всё остальное совпало.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                session.evaluateStruggle()
            }
            // Экран закрыт (выход, новая партия): фоновый поиск хода больше
            // некому показать, и его ответ не должен догнать следующий экран.
            session.cancelStruggleProbe()
        }
        .onChange(of: scenePhase) { _, phase in
            // Уход в фон — то же событие, что и пауза (раздел 13.8).
            // А вот возврат снимает его только тогда, когда паузу поставила
            // сцена: игрок, нажавший «Пауза», обязан вернуться в паузу.
            // Иначе шторка паузы остаётся на экране, а часы под ней идут.
            guard phase == .active else {
                session.suspend()
                return
            }
            guard !showPause else { return }
            session.resume()
        }
        .onChange(of: session.isSolved) { _, solved in
            guard solved else { return }
            // Даём победной волне доиграть: иначе экран результата подменяет
            // игровой мгновенно и эффект не виден вообще.
            let delay: Duration = effectsReduceMotion ? .milliseconds(260) : .milliseconds(900)
            Task { @MainActor in
                try? await Task.sleep(for: delay)
                router.finish(session: session)
            }
        }
        .onChange(of: session.attemptEnded) { _, ended in
            guard ended else { return }
            // Провал Perfect: даём прочитать строку состояния перед результатом.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                router.finish(session: session)
            }
        }
        .sheet(isPresented: $showHint) {
            HintSheet(
                state: session.hint,
                onAdvance: { session.advanceHint() },
                onReveal: { session.confirmReveal(); showHint = false },
                onClose: { session.closeHint(); showHint = false }
            )
            .themedSurface()
        }
        .sheet(isPresented: $showPause) { pauseSheet.themedSurface() }
        // Оба действия теряют прогресс, поэтому спрашиваем подтверждение
        // и честно называем последствие для рейтинга.
        .confirmationDialog(L.t("pause.restart.title"),
                            isPresented: $showRestartConfirm, titleVisibility: .visible) {
            Button(L.t("pause.restart.confirm"), role: .destructive) {
                showPause = false
                session.restart()
                session.resume()
            }
            Button(L.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(L.t("pause.restart.message"))
        }
        .confirmationDialog(L.t("pause.newGame.title"),
                            isPresented: $showNewGameConfirm, titleVisibility: .visible) {
            Button(L.t("pause.newGame.confirm"), role: .destructive) {
                showPause = false
                router.startAnotherGame(like: session)
            }
            Button(L.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(L.t("pause.newGame.message"))
        }
        .background { keyboardShortcuts }
    }

    /// В паузе метка строится из ФАКТИЧЕСКОГО ledger, а не из настроек.
    private var ratingLabelText: String {
        switch session.ledgerLabel {
        case .full: L.t("game.ratingLabel.full")
        case .adjusted: L.t("game.ratingLabel.adjusted")
        case .unranked: L.t("game.ratingLabel.unranked")
        }
    }

    // MARK: - Верх

    private var topBar: some View {
        HStack {
            Button {
                session.suspend()
                router.goHome()
            } label: {
                Image(systemName: "chevron.left").font(.title3)
            }
            .accessibilityLabel(L.t("common.back"))

            Spacer()

            VStack(spacing: 2) {
                Text(L.t(session.puzzle.tier.titleKey))
                    .font(.subheadline.weight(.medium))
                    // Долгое нажатие на уровень заполняет доску — только в Debug.
                    #if DEBUG
                    .onLongPressGesture { session.debugFillAlmostSolved() }
                    #endif
                // Таймер скрыт по умолчанию, но в скоростном испытании
                // показывается компактно — иначе бонус темпа вслепую.
                if preferences.showTimer || session.activePaceMode.allowsSpeedBonus {
                    // Время живёт в GameTimer и считается от часов, а не от
                    // состояния: без собственного тика SwiftUI перерисовывал бы
                    // строку только когда игрок что-то нажал.
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(timeText)
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(theme.color(.secondaryText))
                    }
                }
                if !modeBadge.isEmpty {
                    Text(modeBadge)
                        .font(.caption2)
                        .foregroundStyle(theme.color(.accent))
                }
            }

            Spacer()

            Button {
                session.suspend()
                showPause = true
            } label: {
                Image(systemName: "pause.circle").font(.title3)
            }
            .accessibilityLabel(L.t("game.pause"))
        }
        .foregroundStyle(theme.color(.primaryText))
        .padding(.top, 4)
    }

    /// Активные модификаторы объявлены на экране, а не только до старта.
    private var modeBadge: String {
        // Режим объявляется постоянно: игрок должен видеть, на кону рейтинг
        // или нет, не открывая меню.
        var parts = [L.t(session.mode.badgeKey)]
        parts += session.activeModifiers.map { L.t($0.titleKey) }
        if session.activePaceMode == .againstPersonalBest {
            parts.append(L.t("challenge.againstPB"))
        }
        return parts.joined(separator: " · ")
    }

    private var timeText: String {
        let seconds = session.activeSeconds
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Поле

    private var effectsReduceMotion: Bool {
        reduceMotion || preferences.reduceMotionBoost
    }

    private var board: some View {
        BoardView(
            states: session.renderStates,
            palette: palette,
            thinLine: theme.current.thinLineWidth,
            thickLine: theme.current.thickLineWidth,
            largeDigits: preferences.largeDigits,
            effect: feedback.lastCommand,
            reduceMotion: effectsReduceMotion,
            personality: EffectPersonality(themeID: theme.current.id),
            onEffectFinished: { feedback.clearVisual(id: $0) },
            onSelect: { session.select($0) }
        )
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var statusLine: some View {
        if let signal = session.struggleSignal {
            StruggleNudgeCard(
                signal: signal,
                palette: palette,
                onAccept: { session.acceptStruggleNudge(); showHint = true },
                onLater: { session.dismissStruggleNudge(mute: true) }
            )
        } else if let target = coachTarget {
            CoachCard(target: target, palette: palette) { dismissCoach(target) }
        } else if let message = session.statusMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(theme.color(.secondaryText))
                .transition(.opacity)
                .accessibilityAddTraits(.updatesFrequently)
        } else if session.showGuessGuard {
            // Guess Guard не блокирует игру.
            Button {
                session.dismissGuessGuard()
                openHint()
            } label: {
                Text(L.t("game.guessGuard")).font(.footnote)
            }
        }
    }

    // MARK: - Действия

    private var actionRow: some View {
        HStack(spacing: 8) {
            action("arrow.uturn.backward", L.t("game.undo"), enabled: session.canUndo) {
                session.undo()
            }
            action("eraser", L.t("game.erase")) { session.erase() }
            action(session.notesMode ? "pencil.circle.fill" : "pencil",
                   L.t("game.notes"), active: session.notesMode) {
                if coachTarget == .notes { dismissCoach(.notes) }
                session.toggleNotesMode()
            }
            if session.allowsManualCheck {
                action("checkmark.circle", L.t("game.check")) { session.check() }
            }
            action("lightbulb", L.t("game.hint")) { openHint() }
            if session.sessionPolicy.fieldCandidates == .lensOnDemand {
                action("circle.grid.3x3", L.t("game.lens")) { session.toggleLens() }
            }
        }
    }

    private func action(
        _ systemImage: String,
        _ title: String,
        enabled: Bool = true,
        active: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            VStack(spacing: 3) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? palette.selected : .clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .foregroundStyle(theme.color(.primaryText))
        .accessibilityLabel(title)
    }

    private var keypad: some View {
        KeypadView(
            illegalDigits: session.keypadIllegalDigits,
            completedDigits: session.completedDigits,
            hideCompleted: session.completedDigitTreatment == .hide,
            lockedDigit: session.lockedDigit,
            layout: preferences.keypadLayout,
            palette: palette,
            onTap: { session.input($0) },
            onLongPress: { session.lock(digit: $0) }
        )
    }

    private func openHint() {
        // Первое самостоятельное нажатие Hint делает карточку бессмысленной.
        if coachTarget == .hint { dismissCoach(.hint) }
        session.openHint()
        showHint = true
    }

    // MARK: - Одноразовые карточки интерфейса (раздел 5.1)

    private func startCoachIfNeeded() {
        guard preferences.showInterfaceTips else { return }
        let profile = router.progress.profile()
        if !profile.interfaceCoachNotesShown { coachTarget = .notes }
        else if !profile.interfaceCoachHintShown { coachTarget = .hint }
    }

    private func dismissCoach(_ target: CoachCard.Target) {
        router.progress.markCoachCardShown(notes: target == .notes,
                                           hint: target == .hint)
        let profile = router.progress.profile()
        if target == .notes, !profile.interfaceCoachHintShown {
            coachTarget = .hint
        } else {
            coachTarget = nil
        }
        // После обеих карточек настройка выключается сама.
        if router.progress.coachCardsComplete { preferences.showInterfaceTips = false }
    }

    // MARK: - Пауза

    private var pauseSheet: some View {
        VStack(spacing: 14) {
            Text(L.t("game.paused")).font(.title2.weight(.semibold))
            // В паузе метка строится из ФАКТИЧЕСКОГО ledger, а не из настроек.
            Text(ratingLabelText).font(.footnote).foregroundStyle(.secondary)

            Button(L.t("game.resume")) {
                showPause = false
                session.resume()
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.color(.accent))

            // Перезапуск делает партию тренировочной, поэтому во время
            // калибровки он превращается в ловушку: игрок жмёт его раз за разом
            // и три нужных результата не набираются никогда.
            Button(L.t("pause.restart")) {
                showPause = false
                showRestartConfirm = true
            }
            .buttonStyle(.bordered)
            .disabled(restartBlocked)

            if restartBlocked {
                Text(L.t("pause.restart.calibration",
                         RatingEngine.calibrationCount - router.snapshot.calibrationRatedCount))
                    .font(.caption2)
                    .foregroundStyle(theme.color(.secondaryText))
                    .multilineTextAlignment(.center)
            }

            Button(L.t("pause.newGame")) {
                showPause = false
                showNewGameConfirm = true
            }
            .buttonStyle(.bordered)
            Button(L.t("stats.title")) { showStatistics = true }
                .buttonStyle(.bordered)
            Button(L.t("common.settings")) { showSettings = true }
                .buttonStyle(.bordered)
            Button(L.t("game.exit")) {
                showPause = false
                router.goHome()
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.color(.secondaryText))
            .padding(.top, 2)
        }
        .padding(24)
        .presentationDetents([.height(restartBlocked ? 540 : 500)])
        .sheet(isPresented: $showStatistics) { StatisticsView().themedSurface() }
        .sheet(isPresented: $showSettings) { SettingsView().themedSurface() }
    }

    // MARK: - Внешняя клавиатура iPad (раздел 15)

    private var keyboardShortcuts: some View {
        Group {
            ForEach(1...9, id: \.self) { digit in
                Button("") { session.input(digit) }
                    .keyboardShortcut(KeyEquivalent(Character(String(digit))), modifiers: [])
            }
            Button("") { session.erase() }.keyboardShortcut(.delete, modifiers: [])
            Button("") { session.toggleNotesMode() }.keyboardShortcut("n", modifiers: [])
            Button("") { openHint() }.keyboardShortcut("h", modifiers: [])
            // Сокращение живёт ровно там же, где кнопка: в профиле, который
            // сверяет ход с решением сам, «Проверить» с экрана убрано, и
            // клавиша не имеет права брать за него цену проверки.
            if session.allowsManualCheck {
                Button("") { session.check() }.keyboardShortcut("c", modifiers: [])
            }
            Button("") { session.undo() }.keyboardShortcut("z", modifiers: .command)
            Button("") { session.selectNextEmpty() }.keyboardShortcut(.space, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
