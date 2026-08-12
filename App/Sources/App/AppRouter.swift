//
//  AppRouter.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Навигация и оркестрация: создание партии, применение результата,
//  восстановление после перезапуска. Правил Sudoku здесь нет.
//

import Foundation
import Observation
import SwiftUI
import NamiDomain
import NamiData
import NamiExperience

@Observable
@MainActor
final class AppRouter {

    enum Screen: Equatable {
        case home
        case game
        case result(ResultPayload)
        case onboarding
    }

    struct ResultPayload: Equatable {
        let puzzle: Puzzle
        let rating: RatingResult
        let activeSeconds: Int
        let isDaily: Bool
        let dailyScore: Int?
        let promoted: Bool
        let event: PendingProgressEvent?
        /// Исходы, для которых девяти reason codes из ТЗ не хватает:
        /// повтор задачи и провал Perfect. Подменяется только текст,
        /// сам код причины остаётся нетронутым.
        let overrideReasonKey: String?
        /// Новый personal best для тира, если попытка была сопоставимой.
        let personalBestSeconds: Int?
        /// Доска действительно решена. Провал Perfect сюда не попадает.
        let wasSolved: Bool
        /// Очки за партию. `nil` в «Релаксе» — там счёт не ведётся.
        let score: SessionScoreState?
        /// Сколько рейтинговых результатов уже засчитано в калибровку.
        let calibrationProgress: Int?
    }

    private(set) var screen: Screen = .home
    private(set) var session: GameSessionStore?
    private(set) var snapshot: RatingSnapshot
    private(set) var rhythm: WeeklyRhythm
    private(set) var startupWarning: String?

    /// Последние выданные задачи. Нужны, чтобы «Новая игра» подряд не
    /// возвращалась к тому же варианту: завершёнными они ещё не считаются.
    private var recentlyOffered: [String] = []

    let puzzles: PuzzleRepository
    let progress: ProgressRepository
    let savedGames: SavedGameStore
    let applier: RatingResultApplier
    let preferences: PreferencesRepository
    let feedback: FeedbackCoordinator
    let theme: ThemeProvider

    init(
        puzzles: PuzzleRepository,
        progress: ProgressRepository,
        savedGames: SavedGameStore,
        applier: RatingResultApplier,
        preferences: PreferencesRepository,
        feedback: FeedbackCoordinator,
        theme: ThemeProvider
    ) {
        self.puzzles = puzzles
        self.progress = progress
        self.savedGames = savedGames
        self.applier = applier
        self.preferences = preferences
        self.feedback = feedback
        self.theme = theme
        self.snapshot = progress.snapshot()
        self.rhythm = WeeklyRhythm.compute(completionDates: progress.completionDates())
        theme.apply(id: preferences.themeID)
        if !progress.profile().onboardingCompleted { screen = .onboarding }
        // Первое чтение профиля — самое важное: именно здесь повреждённый
        // snapshot раньше молча превращался в игрока без рейтинга.
        surfaceProgressIssue()
    }

    // MARK: - Целостность прогресса

    /// Сообщение о сбое, обнаруженном до создания роутера (хранилище не
    /// открылось). Показывается тем же предупреждением, что и остальные.
    func reportStartupIssue(_ message: String) {
        startupWarning = message
    }

    /// `ProgressRepository` не `@Observable`, поэтому накопленный сбой
    /// забирается явно — в тех же точках, где обновляется snapshot.
    private func surfaceProgressIssue() {
        guard let issue = progress.takeIntegrityIssue() else { return }
        startupWarning = Self.message(for: issue)
    }

    /// Технический повод превращается в понятную фразу здесь: репозиторий
    /// не знает интерфейса, а игроку нужно понимать, что произошло с его
    /// прогрессом и что данные не стёрты.
    private static func message(for issue: ProgressIntegrityIssue) -> String {
        switch issue {
        case .snapshotUnreadable:
            "Сохранённый прогресс не читается. Рейтинг и ранг временно не обновляются — записи оставлены на месте, чтобы их можно было восстановить."
        case .profileUnreadable:
            "Профиль не открылся. Рейтинг и ранг временно не обновляются — сохранённые записи не тронуты."
        case .snapshotRecovered:
            "Сохранённый прогресс не читался и восстановлен из последнего засчитанного результата. Мог потеряться только он один; рейтинг снова обновляется."
        case .snapshotNotEncodable:
            "Прогресс не удалось подготовить к записи. Последний результат не сохранён."
        case .writeFailed:
            "Прогресс не записался на диск. Последний результат может не сохраниться."
        }
    }

    // MARK: - Состояние главного экрана

    var hasSavedGame: Bool { savedGames.hasSavedGame }

    var recommendedTier: DifficultyTier {
        puzzles.recommendedTier(forRating: snapshot.rating)
    }

    func refreshSnapshot() {
        snapshot = progress.snapshot()
        rhythm = WeeklyRhythm.compute(completionDates: progress.completionDates())
        surfaceProgressIssue()
    }

    // MARK: - Запуск партии

    func startNewGame(tier: DifficultyTier, mode: GameMode = .ranked,
                      modifiers: [ChallengeModifier] = [],
                      paceMode: RatingPaceMode = .disabled) {
        guard let puzzle = puzzles.nextPuzzle(
            in: tier,
            excluding: progress.completedPuzzleIDs(),
            recentlyOffered: recentlyOffered,
            unlike: session?.puzzle
        ) else {
            startupWarning = "В каталоге нет задач уровня \(L.t(tier.titleKey))"
            return
        }
        rememberOffered(puzzle.id)
        applyTheme(for: mode)
        makeSession(puzzle: puzzle, restored: nil, mode: mode,
                    modifiers: modifiers, paceMode: paceMode,
                    dailyVersion: nil)
        screen = .game
    }

    func startDaily() {
        guard let puzzle = puzzles.dailyPuzzle(for: Date()) else {
            startupWarning = "Задача дня недоступна"
            return
        }
        let version = DailySchedule.competitionVersion(puzzleID: puzzle.id)
        makeSession(puzzle: puzzle, restored: nil, modifiers: [], paceMode: .disabled,
                    dailyVersion: version)
        screen = .game
    }

    /// «Новая игра» из паузы: тот же уровень и те же испытания,
    /// но другая задача. Текущая партия просто бросается — по разделу 9.9
    /// незавершённая партия нейтральна и рейтинг не трогает.
    func startAnotherGame(like store: GameSessionStore) {
        let tier = store.puzzle.tier
        let modifiers = store.activeModifiers
        let paceMode = store.activePaceMode
        savedGames.clear()
        session = nil
        startNewGame(tier: tier, modifiers: modifiers, paceMode: paceMode)
    }

    /// Восстановление партии после перезапуска (критерий приёмки 4).
    func continueSavedGame() {
        switch savedGames.load(catalogVersion: puzzles.catalogVersion) {
        case .none:
            startupWarning = nil
        case .incompatible(let reason):
            // Повреждённый файл НЕ перезаписывает профиль.
            startupWarning = "Сохранение несовместимо (\(reason)). Можно начать задачу заново."
            savedGames.clear()
        case .restored(let persisted):
            guard let puzzle = puzzles.puzzle(id: persisted.puzzleID) else {
                startupWarning = "Задача сохранения отсутствует в каталоге"
                savedGames.clear()
                return
            }
            // Режим берётся из сохранения. Раньше здесь работало умолчание
            // `.ranked`, и продолженная партия «Релакса» начинала менять
            // рейтинг — ровно то, чего режим обещал не делать.
            makeSession(puzzle: puzzle, restored: persisted, mode: persisted.mode,
                        modifiers: persisted.modifiers,
                        paceMode: persisted.paceMode,
                        dailyVersion: persisted.dailyCompetitionVersion)
            screen = .game
        }
    }

    /// Помним восемь последних: достаточно, чтобы не повторяться в пределах
    /// одного вечера, и мало, чтобы не исчерпать небольшой тир.
    private func rememberOffered(_ id: String) {
        recentlyOffered.removeAll { $0 == id }
        recentlyOffered.append(id)
        if recentlyOffered.count > 8 { recentlyOffered.removeFirst() }
    }

    /// Режим предлагает тему, но не навязывает: если игрок выбирал оформление
    /// для этого режима явно, побеждает его выбор.
    private func applyTheme(for mode: GameMode) {
        let id = preferences.themeID(for: mode) ?? mode.suggestedThemeID
        guard id != theme.current.id else { return }
        theme.apply(id: id)
        preferences.themeID = id
    }

    private func makeSession(
        puzzle: Puzzle,
        restored: PersistedSession?,
        mode: GameMode = .ranked,
        modifiers: [ChallengeModifier],
        paceMode: RatingPaceMode,
        dailyVersion: String?
    ) {
        let profile = progress.assistanceProfile()
        let store = GameSessionStore(
            puzzle: puzzle,
            catalogVersion: puzzles.catalogVersion,
            board: restored?.board,
            history: restored?.history ?? MoveHistory(),
            mode: mode,
            initialProfile: restored?.initialProfileID ?? profile,
            sessionPolicy: restored?.sessionPolicy ?? progress.sessionPolicy(),
            ledger: restored?.ledger ?? AssistanceUsageLedger(),
            timing: restored?.timing ?? TimingSnapshot(),
            modifiers: modifiers,
            paceMode: paceMode,
            dailyCompetitionVersion: dailyVersion,
            allowsTapToClear: preferences.tapToClear,
            // Журнал и восстановленный из него счёт передаются вместе: счёт
            // не пересчитывается по доске, потому что по доске его вычислить
            // нельзя — он зависит от истории, а не от результата.
            journal: restored?.journal,
            restoredScore: restored?.restoredScore,
            integrityWarning: restored?.integrityWarning,
            feedback: feedback,
            autosave: { [weak self] snapshot, immediate in
                guard let self else { return }
                if immediate { savedGames.saveNow(snapshot) }
                else { savedGames.scheduleSave(snapshot) }
            }
        )
        session = store
    }

    // MARK: - Завершение партии

    func finish(session store: GameSessionStore) {
        let puzzle = store.puzzle
        let isDaily = puzzle.dailyEligible && screenIsDaily(store)

        // Прогресс не читается: считать рейтинг не от чего. `snapshot` в этом
        // случае — подставной стартовый (1000, калибровка 0), и посчитанный от
        // него ΔR был бы выдумкой: и на экране, и в поле `ratingAfter`, которое
        // статистика читает как факт. Партия объявляется нерейтинговой.
        let progressFrozen = progress.isWriteFrozen

        // Повторное решение того же puzzle ID не меняет рейтинг (раздел 9.9).
        let alreadyRanked = progress.hasRankedResult(forPuzzle: puzzle.id)
        var input = store.ratingInput(currentRating: snapshot.rating,
                                      appliedRatedCount: snapshot.calibrationRatedCount)
        // Два повода закончить партию нерейтингово: задача уже решалась и
        // прогресс не читается. Формулировка на экране у них разная, а расчёт
        // одинаковый — ΔR = 0 без отрицательного вклада.
        if alreadyRanked || progressFrozen {
            var ledger = store.currentLedger
            ledger.record(hintLayer: .reveal)   // «нерейтингово», но без отрицательного ΔR
            input = RatingInput(
                currentRating: snapshot.rating,
                puzzleDifficulty: puzzle.difficultyD,
                appliedRatedCount: snapshot.calibrationRatedCount,
                ledger: ledger,
                paceMode: .disabled,
                speedEligible: false,
                activeSeconds: store.activeSeconds,
                expectedActiveSecondsP50: puzzle.expectedActiveSecondsP50
            )
        }
        let rating = RatingEngine.evaluate(input)

        // Daily показывает тот же SessionScore, что и обычная партия:
        // две разные формулы за одну игру объяснить невозможно.
        let dailyScore = isDaily ? DailyScore.current(from: store.sessionScore) : nil

        let persisted = store.persistedSession()
        let ratedResultID = "\(puzzle.id)|\(persisted.timing.timingStartedAt?.timeIntervalSince1970 ?? 0)"
        let ledgerData = DomainCoding.encode(store.currentLedger)

        // В соревновательную запись Daily-счёт попадает только с правом на неё
        // (раздел 9.10): Reveal, третий strike, откат системных часов между
        // запусками и смена версии расписания исключают результат из
        // leaderboard. День при этом остаётся пройденным, и на экране
        // результата игрок видит свой счёт — сравнивать его с чужими нельзя,
        // а обнулять его игроку не за что.
        let leaderboardScore: Int? = {
            guard let dailyScore, let savedVersion = persisted.dailyCompetitionVersion,
                  DailyScore.isLeaderboardEligible(
                    ledger: store.currentLedger,
                    timing: persisted.timing,
                    savedCompetitionVersion: savedVersion,
                    activeCompetitionVersion: DailySchedule.competitionVersion(puzzleID: puzzle.id))
            else { return nil }
            return dailyScore
        }()

        // Счёт годится в рекорды, только если партия имела на это право.
        // В «Релаксе» счёта нет вовсе; в рейтинговой его снимают Reveal,
        // третья подтверждённая ошибка и расхождение журнала со снимком.
        let recordableScore: SessionScoreState? =
            (store.mode.appliesRating && store.sessionScore.isRecordable)
                ? store.sessionScore : nil

        let application = applier.apply(
            ratedResultID: ratedResultID,
            result: rating,
            resultRecord: GameResult(
                id: ratedResultID,
                puzzleID: puzzle.id,
                catalogVersion: puzzles.catalogVersion,
                tierRaw: puzzle.tier.rawValue,
                completedAt: .now,
                activeSeconds: store.activeSeconds,
                challengeElapsedSeconds: store.challengeElapsedSeconds,
                deltaR: rating.deltaR,
                ratingAfter: rating.newRating,
                isRanked: rating.isRanked,
                isPractice: store.currentLedger.isPractice,
                reasonCodeRaw: rating.reason.rawValue,
                ledgerData: ledgerData,
                initialProfileID: store.initialProfile.rawValue,
                ratingAlgorithmVersion: rating.algorithmVersion,
                isDaily: isDaily,
                dailyScore: leaderboardScore,
                wasComparable: store.isComparableAttempt && store.isSolved,
                challengeModifiers: store.activeModifiers.map(\.rawValue),
                ratingPaceModeRaw: store.activePaceMode.rawValue,
                techniques: puzzle.techniques,
                // Счёт пишем только у партий, где он вообще вёлся: в «Релаксе»
                // его нет, и ноль в рекордах означал бы «сыграл на ноль»,
                // а не «не играл на счёт».
                // `isRecordable` — не украшение экрана результата. Reveal,
                // третья ошибка и расхождение журнала со снимком снимают
                // право на запись; без этой проверки такой счёт попадал в
                // рекорды наравне с честным.
                sessionScore: recordableScore?.displayScore,
                maxMultiplierPermille: recordableScore?.maxMultiplierPermille
            )
        )

        // Сбой репозитория забираем всегда, иначе он всплывёт позже как
        // предупреждение о постороннем действии.
        let repositoryIssue = progress.takeIntegrityIssue()
        if let issue = application.persistenceFailure ?? repositoryIssue {
            startupWarning = Self.message(for: issue)
        }
        // Результат, не дошедший до диска, не двигает рейтинг на экране:
        // показать новое число и потерять его при перезапуске хуже, чем
        // честно сказать о сбое. Экран результата при этом остаётся —
        // партию игрок действительно решил.
        if application.persistenceFailure == nil {
            snapshot = application.snapshot
        }
        rhythm = WeeklyRhythm.compute(completionDates: progress.completionDates())
        savedGames.clear()

        if let event = application.event {
            feedback.handle(FeedbackTransaction(events: [.rankPromoted(division: event.toDivision)]))
        }

        screen = .result(ResultPayload(
            puzzle: puzzle,
            rating: rating,
            activeSeconds: store.activeSeconds,
            isDaily: isDaily,
            dailyScore: dailyScore,
            promoted: application.event != nil,
            event: application.event,
            // Заморозка объясняется первой: остальные причины при ней
            // второстепенны, а игрок должен понимать, почему партия не
            // засчитана, не сверяясь с предупреждением.
            overrideReasonKey: progressFrozen ? "result.progressFrozen"
                             : store.currentLedger.perfectFailed ? "result.perfectFailed"
                             : store.currentLedger.restartedWithoutRating ? "result.restarted"
                             : (alreadyRanked ? "result.repeat" : nil),
            personalBestSeconds: progress.personalBest(for: puzzle.tier),
            wasSolved: store.isSolved,
            score: store.mode.appliesRating ? store.sessionScore : nil,
            calibrationProgress: snapshot.isCalibrating ? snapshot.calibrationRatedCount : nil
        ))
    }

    private func screenIsDaily(_ store: GameSessionStore) -> Bool {
        store.persistedSession().dailyCompetitionVersion != nil
    }

    // MARK: - Навигация

    func goHome() {
        session = nil
        refreshSnapshot()
        screen = .home
    }

    func repeatSimilar() {
        guard case .result(let payload) = screen else { return goHome() }
        startNewGame(tier: payload.puzzle.tier)
    }

    func completeOnboarding() {
        progress.setOnboardingCompleted()
        screen = .home
    }

    func dismissWarning() { startupWarning = nil }
}
