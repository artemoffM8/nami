//
//  GameSessionStore.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Один источник истины игрового экрана (раздел 13.4): выбор, режим Notes,
//  история, подсказка и состояние партии. Правила Sudoku живут в NamiDomain —
//  здесь только presentation state и оркестрация.
//
//  Производные флаги считаются РОВНО ОДИН РАЗ после действия игрока и
//  раскладываются в 81 компактный `CellRenderState`, чтобы Observation
//  обновляла только реально изменившиеся клетки (раздел 13.5).
//

import Foundation
import Observation
import NamiDomain
import NamiData
import NamiExperience

/// Компактное состояние одной клетки для отрисовки.
struct CellRenderState: Equatable, Sendable {
    var value: UInt8 = 0
    var isGiven = false
    var manualNotes: DigitMask = 0
    /// Только `legalCandidates & ~manualNotes` — ручная заметка визуально побеждает.
    var assistedCandidates: DigitMask = 0
    var isSelected = false
    var isRelated = false
    var isSameDigit = false
    var isConflict = false
    var isHintFocus = false
    var isVerifiedWrong = false
}

enum HintDisplayState: Equatable {
    case closed
    case conflicts([Int])
    case unsolvable
    case noStep
    case step(SolveStep, HintLayer)
}

@Observable
@MainActor
final class GameSessionStore {

    // MARK: - Состояние партии

    /// Задача партии неизменна, и это не стилистика: `solutionDigits` —
    /// её кэш, снятый ровно один раз в `init`. Переприсваивание тихо
    /// рассогласовало бы кэш с решением и начало бы врать о каждом ходе
    /// игрока, поэтому запрет обязан быть ошибкой компиляции, а не
    /// обещанием на ревью.
    let puzzle: Puzzle
    private(set) var board: BoardState
    private(set) var derived: BoardDerivedState
    private(set) var history = MoveHistory()
    private(set) var renderStates: [CellRenderState]

    var selectedIndex: Int?
    private(set) var notesMode = false
    private(set) var lockedDigit: Int?

    private(set) var initialProfile: AssistanceProfile
    var sessionPolicy: SessionPolicy { didSet { refreshRenderStates() } }
    private(set) var ledger = AssistanceUsageLedger()
    private(set) var modifiers: [ChallengeModifier]
    private(set) var paceMode: RatingPaceMode

    /// Объявленный до старта режим. Журнал помощи может только подтвердить
    /// его, но не сделать партию рейтинговой, если игрок выбрал «Релакс».
    let mode: GameMode

    /// Счёт партии. Считается только в рейтинговом режиме: в «Релаксе» счёт
    /// был бы фоновым давлением там, где его обещали убрать.
    private(set) var sessionScore: SessionScoreState
    /// Когда счёт узнаёт о правильности хода. В «Бумаге» и «Фокусе» —
    /// только после Check или финиша, иначе HUD выдаёт скрытую автопроверку.
    let scoreValidationPolicy: ScoreValidationPolicy

    /// Ходы, ждущие подтверждения. Порядок = порядок ввода: пакет применяется
    /// хронологически, чтобы серия строилась так же, как при мгновенной сверке.
    private var pendingPlacements: [(cell: Int, digit: Int)] = []
    private var pendingGroups: [Int] = []
    /// Растёт при любом изменении доски: по нему различаются оплаченные Check.
    private var valueRevision: UInt64 = 0

    var pendingScoreCount: Int { pendingPlacements.count }

    // MARK: - Журнал

    /// Канонический журнал партии. Доска и счёт — его проекции, а не два
    /// независимых снимка, которые могут разъехаться при падении.
    private(set) var journal: SessionJournal
    /// События текущей команды игрока. Копятся до конца действия и уходят в
    /// журнал одной транзакцией: внутри команды доска и счёт заведомо не
    /// согласованы, и такого промежуточного состояния на диске быть не должно.
    private var commandBuffer: [GameJournalEvent] = []
    /// Журнал разошёлся со снимком при восстановлении. Играть можно,
    /// записывать результат — нет.
    private(set) var integrityWarning: String?

    /// Копит события команды. Вызывать до изменения доски незачем — важно лишь,
    /// чтобы `commitCommand()` случился один раз в конце действия.
    private func record(_ event: GameJournalEvent) {
        commandBuffer.append(event)
    }

    /// Закрывает команду. Ошибка записи не должна ронять партию: игрок сильнее
    /// пострадает от падения, чем от потери журнала. Но и молчать нельзя —
    /// без журнала счёт больше не подтверждён, поэтому партия теряет право
    /// на запись, как при повреждении.
    private func commitCommand() {
        guard !commandBuffer.isEmpty else { return }
        let events = commandBuffer
        commandBuffer.removeAll()
        do {
            try journal.appendTransaction(events)
        } catch {
            guard integrityWarning == nil else { return }
            integrityWarning = "журнал: \(error)"
            sessionScore.markIntegrityBroken()
        }
    }

    /// Одна занятая позиция под изменение счёта. Второго центра уведомлений
    /// над клавиатурой нет: два бегущих числа читаются как шум.
    struct ScoreDelta: Equatable, Identifiable {
        let id = UUID()
        var value: Int
        /// Ключ причины для штрафа; у прироста причины нет.
        var reasonKey: String?
    }

    private(set) var scoreDelta: ScoreDelta?
    private var deltaShownAt: Double = 0
    private var deltaTask: Task<Void, Never>?

    /// Ключ логического шага. Стабилен при повторном открытии шторки:
    /// иначе каждый показ создавал бы новую платную подсказку.
    ///
    /// Считается устойчивым хешем, а НЕ стандартным `Hasher`. Тот засеивается
    /// случайно при каждом запуске процесса, поэтому после перезапуска
    /// приложения тот же шаг получил бы другой ключ — и игрок заплатил бы за
    /// уже оплаченную подсказку второй раз. Пока состояние жило только в
    /// памяти, это было незаметно; с журналом стало бы регрессией.
    private var hintStepHash: UInt64 {
        guard case let .step(step, _) = hint else { return 0 }
        // Массив, а не строка: одиночное значение не кодируется в JSON как
        // корневой элемент, и отпечаток вышел бы нулевым.
        return StableDigest.of([
            step.technique.rawValue,
            step.placement?.cell ?? -1,
            step.placement?.digit ?? -1,
            step.eliminations.first?.cell ?? -1
        ])
    }

    private(set) var timer: GameTimer
    private(set) var isSolved = false
    /// Попытка завершена не победой (сейчас — только провал Perfect).
    private(set) var attemptEnded = false
    private(set) var statusMessage: String?
    private(set) var showGuessGuard = false

    /// Какие цифры уже побывали в клетке. Единственный признак угадывания,
    /// который работает и в «Бумаге»: там приложение не сверяет ввод с
    /// решением и о неверной цифре просто не знает.
    private var digitsTried: [Int: Set<UInt8>] = [:]

    /// Клетки, которые проверка уже показала как неверные.
    private(set) var verifiedWrongCells: Set<Int> = []
    /// Временная «Линза кандидатов» для выбранной клетки.
    private(set) var lensCell: Int?

    private(set) var hint: HintDisplayState = .closed

    /// Ненавязчивое предложение помощи, когда игрок застрял.
    private(set) var struggleSignal: StruggleSignal?
    private var struggle = StruggleDetector()
    private let clock: any MonotonicClock = SystemMonotonicClock()
    /// Пользовательская настройка: можно выключить совсем.
    var struggleNudgesEnabled = true

    private let dailyCompetitionVersion: String?
    /// Настройка «повторное нажатие очищает клетку» (раздел 5.4).
    private let allowsTapToClear: Bool

    /// Приёмник телеметрии. По умолчанию — no-op: приложение не отправляет
    /// ничего, пока внешний SDK не выбран явно.
    private let analytics: any AnalyticsService

    private let builder = MoveBuilder()
    private let feedback: FeedbackCoordinator
    private let catalogVersion: String
    /// Решение задачи, разобранное в цифры один раз. `matchesSolution`
    /// вызывается пакетами (в «Бумаге» — по всей отложенной пачке за Check),
    /// и разбор строки на каждый ход давал лишнюю аллокацию массива из 81
    /// элемента прямо в горячем пути ввода. Значение задачи не меняется.
    ///
    /// Сам разбор лежит в домене (`PuzzleSolution`), а не здесь: расхождение
    /// кэша с решением тихо ломает проверку ходов, и такое правило обязано
    /// быть покрыто тестом, а приватное поле экрана тесту недоступно.
    private let solutionDigits: PuzzleSolution
    /// `(snapshot, immediate)` — immediate обходит debounce при уходе в фон.
    private let autosave: (PersistedSession, Bool) -> Void

    // MARK: - Инициализация

    init(
        puzzle: Puzzle,
        catalogVersion: String,
        board: BoardState? = nil,
        history: MoveHistory = MoveHistory(),
        mode: GameMode = .ranked,
        initialProfile: AssistanceProfile,
        sessionPolicy: SessionPolicy,
        ledger: AssistanceUsageLedger = AssistanceUsageLedger(),
        timing: TimingSnapshot = TimingSnapshot(),
        modifiers: [ChallengeModifier] = [],
        paceMode: RatingPaceMode = .disabled,
        dailyCompetitionVersion: String? = nil,
        allowsTapToClear: Bool = true,
        journal: SessionJournal? = nil,
        restoredScore: SessionScoreState? = nil,
        integrityWarning: String? = nil,
        analytics: any AnalyticsService = NoopAnalyticsService(),
        feedback: FeedbackCoordinator,
        autosave: @escaping (PersistedSession, Bool) -> Void
    ) {
        self.puzzle = puzzle
        self.solutionDigits = PuzzleSolution(puzzle.solution)
        self.mode = mode
        self.catalogVersion = catalogVersion
        self.dailyCompetitionVersion = dailyCompetitionVersion
        self.allowsTapToClear = allowsTapToClear
        self.analytics = analytics
        let startingBoard = board ?? BoardState(givens: puzzle.puzzle) ?? BoardState()
        self.board = startingBoard
        self.derived = SudokuValidator.derive(startingBoard)
        self.history = history
        self.initialProfile = initialProfile
        self.modifiers = modifiers
        self.paceMode = paceMode
        self.feedback = feedback
        self.autosave = autosave
        self.renderStates = [CellRenderState](repeating: CellRenderState(), count: 81)

        var policy = sessionPolicy
        if modifiers.contains(.noNotes) { policy = policy.applyingNoNotes() }
        if modifiers.contains(.perfect) { policy = policy.applyingPerfect() }
        self.sessionPolicy = policy

        var startingLedger = ledger
        startingLedger.validationIsRuleOfMode = modifiers.contains(.perfect)
        // Режим объявлен до старта и дальше не меняется — он же решает,
        // может ли партия вообще стать рейтинговой.
        startingLedger.mode = mode
        self.ledger = startingLedger
        self.timer = GameTimer(snapshot: timing)
        self.scoreValidationPolicy = ScoreValidationPolicy(validation: policy.validation)
        // Восстановленный счёт приходит из журнала, который писался одной
        // транзакцией с доской. Пересчитывать его здесь нельзя: мы не знаем
        // истории, а доска её не хранит.
        self.sessionScore = restoredScore ?? SessionScoreState(budget: SessionScoreBudget(
            puzzleRating: puzzle.difficultyD,
            emptyCellCount: 81 - puzzle.givensCount
        ))
        self.integrityWarning = integrityWarning
        self.journal = journal ?? SessionJournal()
        let isFreshJournal = journal == nil
        // Нечитаемый журнал возвращает предупреждение, но не счёт: тогда
        // создаётся свежий, и он «чистый». Партия при этом восстановлена
        // из непроверенного источника — право на запись она потеряла.
        //
        // Строка стоит ПОСЛЕ инициализации `journal`: до неё `self` ещё не
        // собран целиком, а мутирующий вызов по своему же свойству требует
        // готового `self` — иначе компилятор не пропустит.
        if integrityWarning != nil { self.sessionScore.markIntegrityBroken() }

        // Восстановление времени после перезапуска процесса. Строка обязана
        // стоять ЗДЕСЬ — до первого `startTiming()`, то есть до `resume()`:
        //  • интервал, пока приложения не было, засчитывается в
        //    соревновательное время Daily (иначе выход и перезапуск
        //    останавливали бы соревновательные часы — это эксплойт);
        //  • партия, сохранённая посреди хода, теряет право на бонус темпа;
        //  • откат системных часов помечается аномалией и снимает право
        //    на leaderboard (`DailyScore.isLeaderboardEligible`).
        // Свежая партия сюда приходит с пустым снимком, для неё вызов —
        // no-op, и бонус темпа она не теряет.
        timer.restore(wallClockNow: clock.wallClock)

        recordPassiveAssistance()
        if isFreshJournal {
            // Старт — первая команда журнала. Стартовой позицией берётся
            // ТЕКУЩАЯ доска, а не исходная задача: сюда попадают и партии,
            // сохранённые до появления журнала, где доска уже наполовину
            // заполнена. С `givens` воспроизведение разошлось бы со снимком
            // и объявило такую партию повреждённой.
            record(.sessionStarted(SessionDescriptor(
                puzzleID: puzzle.id,
                givens: puzzle.puzzle,
                solution: puzzle.solution,
                catalogVersion: catalogVersion,
                difficultyD: puzzle.difficultyD,
                mode: mode,
                policy: self.scoreValidationPolicy,
                startingBoard: startingBoard.serialized(),
                autoReduceNotes: policy.autoReduceNotes)))
            // Постоянная помощь по кандидатам оплачивается один раз на старте.
            record(.candidateAidEscalated(self.ledger.candidateAid))
            applyScore(.candidateAidEscalated(self.ledger.candidateAid))
            commitCommand()
        } else {
            // Счётчик ревизий обязан продолжиться с восстановленного значения.
            // Начав с нуля, он выдал бы уже оплаченные номера проверок — и
            // первые Check после перезапуска оказались бы бесплатными,
            // сохраняя серию. В «Бумаге», где Check единственный источник
            // правды, это было бы прямым способом фармить множитель.
            self.valueRevision = journal?.replay()?.valueRevision ?? 0
        }
        refreshRenderStates()

        if mode.appliesRating {
            analytics.record(.sessionScoreStarted(SessionScoreContext(
                ruleSet: SessionScoreRuleSet.v1.id,
                tier: puzzle.tier,
                difficultyD: puzzle.difficultyD,
                policy: scoreValidationPolicy,
                mode: mode
            )))
        }
    }

    // MARK: - Счёт партии

    /// Единственная точка входа в reducer. В «Релаксе» счёт не ведётся вообще.
    private func applyScore(_ input: SessionScoreInput) {
        guard mode.appliesRating else { return }
        let effects = SessionScoreReducer.apply(input, to: &sessionScore)
        for effect in effects {
            switch effect {
            case let .pointsAdded(delta, _):
                showDelta(delta, reasonKey: nil)
            case let .penaltyApplied(reason, delta, _):
                showDelta(-delta, reasonKey: reasonKey(for: reason))
                analytics.record(.penaltyApplied(reason: reason,
                                                 ruleSet: SessionScoreRuleSet.v1.id))
            case let .multiplierChanged(from, to, _):
                if to > from {
                    analytics.record(.multiplierTierReached(
                        tier: sessionScore.multiplierTier,
                        ruleSet: SessionScoreRuleSet.v1.id))
                }
            case .becamePractice, .sealed:
                break
            }
        }
    }

    private func reasonKey(for reason: ScorePenaltyReason) -> String {
        switch reason {
        case .confirmedError: "score.reason.error"
        case .manualCheck: "score.reason.check"
        case .hint: "score.reason.hint"
        case .candidateAid: "score.reason.candidates"
        }
    }

    /// События ближе 100 мс сливаются в одну видимую дельту: быстрый ввод не
    /// должен выстраивать очередь всплывающих чисел.
    private func showDelta(_ value: Int, reasonKey: String?) {
        let now = clock.now
        if var existing = scoreDelta, now - deltaShownAt < 0.1 {
            existing.value += value
            existing.reasonKey = reasonKey ?? existing.reasonKey
            scoreDelta = existing
        } else {
            scoreDelta = ScoreDelta(value: value, reasonKey: reasonKey)
            deltaShownAt = now
        }
        let shownID = scoreDelta?.id
        deltaTask?.cancel()
        deltaTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(520))
            guard let self, self.scoreDelta?.id == shownID else { return }
            self.scoreDelta = nil
        }
    }

    /// Применяет накопленный пакет: сначала цена проверки и сброс серии,
    /// затем исходы в порядке ввода, затем группы. Порядок важен —
    /// правильные ходы после ошибки должны успеть построить новую серию.
    private func flushPendingScore(chargingCheck revision: UInt64?) {
        // Журнал ведётся всегда, даже в «Релаксе»: без него восстановленная
        // партия теряет историю ходов, а счёт тут ни при чём.
        recordValidationBatch(chargingCheck: revision)
        guard mode.appliesRating else { return }
        if let revision {
            applyScore(.manualCheck(revision: revision,
                                    isRuleOfMode: modifiers.contains(.perfect)))
        }
        let batchSize = pendingPlacements.count
        var sawError = false
        for placement in pendingPlacements {
            let correct = matchesSolution(cell: placement.cell, digit: placement.digit)
            if !correct { sawError = true }
            applyScore(.placementConfirmed(cell: placement.cell,
                                           digit: placement.digit,
                                           correct: correct))
        }
        // Весь пакет создаёт не более одного strike, сколько бы неверных
        // клеток он ни нашёл: игрок совершил одно действие.
        if sawError { SessionScoreReducer.registerStrike(in: &sessionScore) }
        if revision != nil, batchSize > 0 {
            analytics.record(.paperBatchResolved(moves: batchSize,
                                                 ruleSet: SessionScoreRuleSet.v1.id))
        }
        pendingPlacements.removeAll()

        if !pendingGroups.isEmpty {
            applyScore(.groupsConfirmed(pendingGroups))
            pendingGroups.removeAll()
        }
    }

    /// Пакет отложенной сверки в журнал. Записывается ДО применения к счёту,
    /// чтобы порядок в журнале совпадал с порядком в reducer: восстановление
    /// проходит тем же путём и обязано получить то же число.
    private func recordValidationBatch(chargingCheck revision: UInt64?) {
        guard revision != nil || !pendingPlacements.isEmpty || !pendingGroups.isEmpty else {
            return
        }
        var sequence = UInt64(0)
        let outcomes = pendingPlacements.map { placement -> PlacementOutcome in
            sequence += 1
            return PlacementOutcome(
                cell: placement.cell, digit: placement.digit,
                correct: matchesSolution(cell: placement.cell, digit: placement.digit),
                commitSequence: sequence)
        }
        record(.validationApplied(ValidationBatch(
            validationID: UUID(),
            isManualCheck: revision != nil,
            isRuleOfMode: modifiers.contains(.perfect),
            valueRevision: revision ?? valueRevision,
            outcomes: outcomes,
            completedGroups: pendingGroups)))
    }

    // MARK: - Жизненный цикл

    /// Атомарно устанавливается при первом показе сетки. Для восстановленной
    /// партии `start()` — no-op, а `resume()` продолжает уже начатый отсчёт:
    /// `timer.restore(wallClockNow:)` отработал в `init`, и повторять его
    /// здесь нельзя — экран может появиться повторно, а восстановление
    /// на идущем таймере потеряло бы накопленное активное время.
    func startTiming() {
        timer.start()
        timer.resume()
    }

    /// Pause, Back/Home и scenePhase .inactive/.background — одно событие.
    func suspend() {
        timer.suspend()
        persist(immediate: true)
    }

    func resume() {
        timer.resume()
    }

    // MARK: - Ввод

    // MARK: - Помощь при затыке

    /// Вход детектора, снятый ДО ухода в фон. Дорогая проверка обязана увидеть
    /// ровно ту же позицию, что и дешёвая: иначе два прохода детектора
    /// рассуждали бы о разных моментах времени, и результат перестал бы
    /// совпадать с синхронным.
    private struct StruggleProbeInput {
        let now: Double
        let gameSeconds: Double
        let expectedSeconds: Double
        let filledRatio: Double
        /// Ревизия значений на момент снимка — по ней отбрасывается устаревший ответ.
        let revision: UInt64
        /// Сигнал дешёвого прохода: с ним сверяется вывод дорогого.
        let candidate: StruggleSignal
    }

    /// Незавершённый фоновый поиск логического хода. Ровно один за раз: опрос
    /// приходит каждые 5 секунд, а полный каскад техник на трудной доске
    /// в этот интервал не обязан укладываться.
    private var struggleProbe: Task<Void, Never>?
    /// Поколение проверки. Отменённая задача не должна освободить слот,
    /// который к моменту её пробуждения занят уже следующей.
    private var struggleProbeGeneration: UInt64 = 0

    /// Вызывается периодически из игрового экрана. Сам вызов ничего не меняет,
    /// пока детектор не решит, что пора предложить помощь.
    func evaluateStruggle() {
        guard struggleNudgesEnabled, !isSolved, !attemptEnded, struggleSignal == nil else { return }
        // Пока считается предыдущий каскад, следующий опрос не запускает свой:
        // очередь одинаковых поисков не ускорила бы ответ, а нагрузку удвоила.
        guard struggleProbe == nil else { return }
        let now = clock.now
        // Логический ход ищем только когда всё остальное уже совпало —
        // это единственная дорогая проверка.
        let filled = Double(board.filledCount) / 81.0
        let cheapSignal = struggle.evaluate(
            now: now, gameSeconds: timer.activeSeconds,
            expectedSeconds: Double(puzzle.expectedActiveSecondsP50),
            filledRatio: filled, hasLogicalStep: true
        )
        guard let candidate = cheapSignal else { return }

        // Каскад техник уезжает с главного актора. Он срабатывает редко, но
        // на трудной доске занимает заметное время, а считался он на том же
        // потоке, которым игрок в этот момент нажимает клетки.
        //
        // Уехать ему безопасно: `BoardState` — Sendable-значение, а `HumanSolver`
        // не хранит состояния и работает с копией доски. Ничего общего
        // изменяемого между актором и фоном не остаётся.
        let input = StruggleProbeInput(
            now: now,
            gameSeconds: timer.activeSeconds,
            expectedSeconds: Double(puzzle.expectedActiveSecondsP50),
            filledRatio: filled,
            revision: valueRevision,
            candidate: candidate
        )
        let snapshot = board
        struggleProbeGeneration &+= 1
        let generation = struggleProbeGeneration
        struggleProbe = Task { @MainActor [weak self] in
            let hasStep = await Task.detached(priority: .utility) {
                HumanSolver.nextStep(board: snapshot) != nil
            }.value
            guard let self else { return }
            self.releaseStruggleProbe(generation: generation)
            guard !Task.isCancelled else { return }
            self.applyStruggleProbe(input, hasStep: hasStep)
        }
    }

    /// Возврат с фона. Пока считался каскад, доска могла уехать вперёд —
    /// подсказка по устаревшей позиции хуже любой задержки, поэтому результат
    /// применяется только к той же ревизии значений.
    ///
    /// Ревизии достаточно: заметки её не двигают, но солвер их и не читает
    /// (см. `HumanSolver`), а на `filledRatio` они не влияют.
    private func applyStruggleProbe(_ input: StruggleProbeInput, hasStep: Bool) {
        guard struggleNudgesEnabled, !isSolved, !attemptEnded, struggleSignal == nil else { return }
        guard valueRevision == input.revision else { return }
        // Детектор перечитывается живым, а не снимком: если игрок за это время
        // что-то сделал, его активность обязана погасить сигнал ровно так же,
        // как гасила бы при синхронном вычислении.
        guard let signal = struggle.evaluate(
            now: input.now, gameSeconds: input.gameSeconds,
            expectedSeconds: input.expectedSeconds,
            filledRatio: input.filledRatio, hasLogicalStep: hasStep
        ), signal == input.candidate || hasStep else { return }

        struggle.markShown(signal, at: input.now)
        struggleSignal = signal
    }

    /// Освобождает слот, если он всё ещё принадлежит именно этой проверке.
    private func releaseStruggleProbe(generation: UInt64) {
        guard struggleProbeGeneration == generation else { return }
        struggleProbe = nil
    }

    /// Экран уходит, партия начинается заново — незавершённая проверка
    /// больше ни к чему не относится.
    func cancelStruggleProbe() {
        struggleProbe?.cancel()
        struggleProbe = nil
        struggleProbeGeneration &+= 1
    }

    /// «Не сейчас» — до конца партии больше не предлагаем.
    func dismissStruggleNudge(mute: Bool) {
        struggleSignal = nil
        if mute { struggle.mute() }
    }

    /// Игрок принял предложение: открываем первый слой подсказки.
    func acceptStruggleNudge() {
        struggleSignal = nil
        openHint()
    }

    func select(_ index: Int) {
        guard index != selectedIndex else { return }
        struggle.recordActivity(at: clock.now)
        selectedIndex = index
        if lensCell != index { lensCell = nil }
        feedback.handle(FeedbackTransaction(events: [.cellSelected(index)]))
        refreshRenderStates()
    }

    func selectNextEmpty() {
        let start = (selectedIndex ?? -1) + 1
        for offset in 0..<81 {
            let index = (start + offset) % 81
            if board[index].value == 0 { select(index); return }
        }
    }

    func input(_ digit: Int) {
        guard let index = selectedIndex, !board[index].isGiven else { return }

        if notesMode {
            guard board[index].value == 0 else { return }
            record(.noteToggled(cell: index, digit: digit))
            commit(builder.toggleNote(digit, at: index, board: board),
                   events: [.notesChanged(cell: index)])
            return
        }

        // Повторное нажатие очищает клетку, если настройка включена.
        if board[index].value == UInt8(digit), allowsTapToClear {
            erase()
            return
        }

        let transaction = builder.placeDigit(digit, at: index, board: board,
                                             autoReduceNotes: sessionPolicy.autoReduceNotes)
        commitPlacement(transaction, cell: index, digit: digit)
    }

    func erase() {
        guard let index = selectedIndex, !board[index].isGiven else { return }
        verifiedWrongCells.remove(index)
        // Стирание цифры и стирание заметок ощущаются по-разному, поэтому
        // и звучат по-разному: у пустой клетки убирать нечего, кроме пометок.
        let event: GameEvent = board[index].value > 0
            ? .digitErased(cell: index)
            : .notesChanged(cell: index)
        valueRevision += 1
        // Стёртая цифра не должна дождаться Check и получить очки за клетку,
        // которой на доске уже нет.
        pendingPlacements.removeAll { $0.cell == index }
        record(.digitRemoved(cell: index))
        commit(builder.erase(at: index, board: board), events: [event])
    }

    func toggleNotesMode() {
        notesMode.toggle()
    }

    func lock(digit: Int?) {
        lockedDigit = (lockedDigit == digit) ? nil : digit
    }

    func undo() {
        var next = board
        guard let undone = history.undo(on: &next) else { return }
        board = next
        valueRevision += 1
        // Отменённые клетки убираются из очереди на сверку: иначе Check
        // начислил бы за них очки уже после того, как игрок их вернул назад.
        // Undo по-прежнему НЕ возвращает уже начисленное — только снимает
        // неподтверждённое.
        let touched = Set(undone.deltas.map(\.index))
        pendingPlacements.removeAll { touched.contains($0.cell) }
        record(.moveUndone)
        struggle.recordUndo(at: clock.now)
        feedback.noteUndo()
        // Undo НЕ уменьшает ledger: зафиксированная помощь остаётся зафиксированной.
        recompute(events: [])
    }

    var canUndo: Bool { history.canUndo }

    // MARK: - Применение хода

    private func commitPlacement(_ transaction: MoveTransaction, cell: Int, digit: Int) {
        struggle.recordActivity(at: clock.now)
        let beforeDerived = derived
        var next = board
        MoveApplier.apply(transaction, to: &next)
        board = next
        history.record(transaction)
        verifiedWrongCells.remove(cell)

        valueRevision += 1
        record(.digitCommitted(cell: cell, digit: digit,
                               source: transaction.isReveal ? .reveal : .user))

        let newDerived = SudokuValidator.derive(board)
        var events: [GameEvent] = [.digitPlaced(cell: cell, digit: digit)]

        // Каждый ход начинается с чистой строки состояния.
        statusMessage = nil

        // Конфликт правил — это accuracyError, но НЕ угадывание (раздел 9.4).
        if newDerived.conflicts.contains(cell) {
            ledger.recordAccuracyError()
            events.append(.conflictDetected(cells: newDerived.conflicts.indices))
            struggle.recordConflict(at: clock.now)
            // Предупреждение показываем только там, где конфликт и так подсвечен.
            // В «Бумаге» приложение молчит: оно не знает того, чего у него
            // не просили проверить (раздел 9.4).
            if sessionPolicy.validation != .manualOnly {
                statusMessage = L.t("game.conflictHint")
            }
        }

        // Автоматическая сверка «Ассистента»: единственный источник strike,
        // потому что ошибка становится ЯВНО показанной игроку.
        if sessionPolicy.validation == .againstSolution {
            ledger.record(validationAid: .automaticSolutionCheck)
            if !matchesSolution(cell: cell, digit: digit) {
                verifiedWrongCells.insert(cell)
                let isNew = ledger.registerSolutionMismatch(cell: cell, digit: digit)
                if isNew { evaluateGuessGuard() }
                statusMessage = L.t("game.mismatchHint")
                if modifiers.contains(.perfect) {
                    // Первая неверная цифра завершает попытку (раздел 11).
                    ledger.registerPerfectFailure()
                    statusMessage = L.t("challenge.perfect.failed")
                    timer.suspend()
                    attemptEnded = true
                }
            }
        }

        let completed = SudokuValidator.newlyCompletedUnits(before: beforeDerived, after: newDerived)
        for unit in completed {
            events.append(.groupCompleted(kind: unit.kind, unitIndex: unit.unitIndex))
        }

        // Клетку открыло приложение, а не игрок: порядковый номер тратится,
        // очки не идут, серия не растёт. Ровно это делает воспроизведение
        // журнала — и если не сделать то же здесь, две проекции одной
        // истории дадут разный счёт.
        if transaction.isReveal {
            applyScore(.placementNonScoring(cell: cell))
            if !completed.isEmpty {
                applyScore(.groupsConfirmed(completed.map(\.unitIndex)))
                record(.validationApplied(ValidationBatch(
                    validationID: UUID(), isManualCheck: false,
                    isRuleOfMode: modifiers.contains(.perfect),
                    valueRevision: valueRevision, outcomes: [],
                    completedGroups: completed.map(\.unitIndex))))
            }
        } else {
        switch scoreValidationPolicy {
        case .immediateValidated:
            // Профиль и так сверяет ввод с решением — счёт не добавляет
            // никакой новой информации.
            let correct = matchesSolution(cell: cell, digit: digit)
            record(.validationApplied(ValidationBatch(
                validationID: UUID(), isManualCheck: false,
                isRuleOfMode: modifiers.contains(.perfect),
                valueRevision: valueRevision,
                outcomes: [PlacementOutcome(cell: cell, digit: digit, correct: correct,
                                            commitSequence: valueRevision)],
                completedGroups: completed.map(\.unitIndex))))
            applyScore(.placementConfirmed(cell: cell, digit: digit, correct: correct))
            if !completed.isEmpty {
                applyScore(.groupsConfirmed(completed.map(\.unitIndex)))
            }
        case .deferredValidation:
            // Здесь приложение обещало ничего не сверять. Ход и группы ждут
            // Check или финиша; HUD показывает только счётчик ожидания.
            pendingPlacements.removeAll { $0.cell == cell }
            pendingPlacements.append((cell: cell, digit: digit))
            pendingGroups.append(contentsOf: completed.map(\.unitIndex))
        }
        }

        if newDerived.isSolvedByRules && !isSolved {
            isSolved = true
            // Решённая доска канонична: правильность больше не тайна,
            // поэтому пакет применяется без цены проверки.
            flushPendingScore(chargingCheck: nil)
            applyScore(.puzzleCompleted)
            let elapsedMs = Int(timer.activeSeconds * 1000)
            let expectedMs = puzzle.expectedActiveSecondsP50 * 1000
            let paceEligible = timer.snapshot.speedEligible && paceMode.allowsSpeedBonus
            record(.puzzleCompleted(elapsedMs: elapsedMs, expectedMs: expectedMs,
                                    paceEligible: paceEligible))
            applyScore(.paceResolved(
                elapsedMs: elapsedMs,
                expectedMs: expectedMs,
                eligible: paceEligible))
            if mode.appliesRating {
                analytics.record(.sessionScoreCompleted(SessionScoreSummary(
                    ruleSet: SessionScoreRuleSet.v1.id,
                    tier: puzzle.tier,
                    difficultyD: puzzle.difficultyD,
                    score: sessionScore.displayScore,
                    elapsedMs: elapsedMs,
                    expectedMs: expectedMs,
                    maxStreak: sessionScore.maxStreak,
                    maxMultiplierPermille: sessionScore.maxMultiplierPermille,
                    confirmedErrors: sessionScore.confirmedErrorStrikes,
                    checkCount: sessionScore.manualCheckCount,
                    deepestHint: ledger.hintLayer,
                    candidateAid: ledger.candidateAid,
                    isRecordable: sessionScore.isRecordable
                )))
            }
            events.append(.puzzleSolved)
            timer.suspend()
        }

        derived = newDerived
        // Команда закрывается до сохранения: на диск обязан уйти журнал,
        // в котором ход записан целиком, вместе со своим исходом.
        commitCommand()
        feedback.handle(FeedbackTransaction(events: events))
        refreshRenderStates()
        persist(immediate: isSolved)
    }

    private func commit(_ transaction: MoveTransaction, events: [GameEvent]) {
        var next = board
        MoveApplier.apply(transaction, to: &next)
        board = next
        history.record(transaction)
        recompute(events: events)
    }

    private func recompute(events: [GameEvent]) {
        commitCommand()
        derived = SudokuValidator.derive(board)
        if !events.isEmpty { feedback.handle(FeedbackTransaction(events: events)) }
        refreshRenderStates()
        persist(immediate: false)
    }

    private func matchesSolution(cell: Int, digit: Int) -> Bool {
        guard cell < solutionDigits.count else { return true }
        return solutionDigits.matches(cell: cell, digit: digit)
    }

    // MARK: - Проверка

    /// Доступна ли ручная проверка. Тот же признак решает и показ кнопки
    /// «Проверить», и живость сокращения внешней клавиатуры: там, где
    /// приложение сверяет каждый ход с решением само, платить за проверку
    /// не за что.
    var allowsManualCheck: Bool { sessionPolicy.validation != .againstSolution }

    /// Ручное «Проверить». Записывает `validationAid = 0.04` даже без ошибок:
    /// подтверждение корректности поля само по себе является помощью.
    ///
    /// В профиле, который и так сверяет ввод с решением, проверка не делает
    /// ничего нового, а цену берёт. Запрет стоит здесь, а не только в UI:
    /// кнопки на экране нет, но вызвать `check()` может и сокращение
    /// клавиатуры, и любая будущая точка входа.
    func check() {
        guard allowsManualCheck else { return }
        var mismatches: [(cell: Int, digit: Int)] = []
        for index in 0..<81 {
            let value = board[index].value
            guard value != 0, !board[index].isGiven else { continue }
            if !matchesSolution(cell: index, digit: Int(value)) {
                mismatches.append((index, Int(value)))
                verifiedWrongCells.insert(index)
            }
        }
        let created = ledger.registerManualCheck(mismatches: mismatches)
        flushPendingScore(chargingCheck: valueRevision)
        statusMessage = mismatches.isEmpty
            ? L.t("game.checkNoErrors")
            : L.t("game.checkErrors", mismatches.count)
        if created { evaluateGuessGuard() }
        commitCommand()
        refreshRenderStates()
        persist(immediate: false)
    }

    private func evaluateGuessGuard() {
        showGuessGuard = ledger.confirmedGuessStrikes >= 1 && !ledger.isPractice
    }

    func dismissGuessGuard() { showGuessGuard = false }

    // MARK: - Линза и кандидаты

    /// Использование линзы записывается один раз за сессию и влияет
    /// на самостоятельность (раздел 5.4).
    func toggleLens() {
        guard let index = selectedIndex, board[index].value == 0 else { return }
        if lensCell == index {
            lensCell = nil
        } else {
            lensCell = index
            ledger.record(candidateAid: .lens)
            record(.candidateAidEscalated(.lens))
            applyScore(.candidateAidEscalated(.lens))
            commitCommand()
        }
        refreshRenderStates()
        persist(immediate: false)
    }

    /// Пассивная помощь, доступная сразу по политике, фиксируется на старте:
    /// она реально видна игроку всё время партии.
    private func recordPassiveAssistance() {
        switch sessionPolicy.fieldCandidates {
        case .off: break
        case .lensOnDemand: break                       // пишется по факту использования
        case .selectedCellPersistent: ledger.record(candidateAid: .selectedCellPersistent)
        case .wholeBoard: ledger.record(candidateAid: .wholeBoard)
        }
        if sessionPolicy.keypadHints == .dimIllegal {
            ledger.record(candidateAid: .keypadDimming)
        }
        if sessionPolicy.singleCandidateHighlight {
            ledger.record(validationAid: .singleCandidateHighlight)
        }
        if sessionPolicy.impossibleNoteWarning {
            ledger.record(validationAid: .impossibleNoteWarning)
        }
    }

    // MARK: - Подсказка

    func openHint() {
        struggle.recordHintOpened(at: clock.now)
        struggleSignal = nil
        switch HintPlanner.plan(board: board, derived: derived) {
        case .solved:
            hint = .closed
        case .resolveConflicts(let cells):
            // Противоречие: только conflict guidance, без trace и Reveal.
            hint = .conflicts(cells)
        case .unsolvablePosition:
            hint = .unsolvable
        case .noLogicalStep:
            hint = .noStep
        case .step(let step):
            hint = .step(step, .region)
            ledger.record(hintLayer: .region)
            record(.hintLayerOpened(layer: .region, revision: valueRevision,
                                    stepDigest: hintStepHash))
            applyScore(.hintOpened(layer: .region, revision: valueRevision,
                                   stepHash: hintStepHash))
        }
        commitCommand()
        // Подсветка области живёт в renderStates, поэтому их надо пересобрать.
        refreshRenderStates()
        persist(immediate: false)
    }

    func advanceHint() {
        guard case .step(let step, let layer) = hint else { return }
        guard let next = layer.next else { return }
        // Reveal подтверждается отдельно — см. `confirmReveal()`.
        guard next != .reveal else { return }
        hint = .step(step, next)
        ledger.record(hintLayer: next)
        record(.hintLayerOpened(layer: next, revision: valueRevision,
                                stepDigest: hintStepHash))
        applyScore(.hintOpened(layer: next, revision: valueRevision,
                               stepHash: hintStepHash))
        commitCommand()
        refreshRenderStates()
        persist(immediate: false)
    }

    /// Прямое открытие цифры делает партию нерейтинговой,
    /// но не отменяет прогресс дня.
    func confirmReveal() {
        guard case .step(let step, _) = hint, let placement = step.placement else { return }
        ledger.record(hintLayer: .reveal)
        record(.hintLayerOpened(layer: .reveal, revision: valueRevision,
                                stepDigest: hintStepHash))
        applyScore(.hintOpened(layer: .reveal, revision: valueRevision,
                               stepHash: hintStepHash))
        hint = .closed
        selectedIndex = placement.cell
        let transaction = builder.placeDigit(placement.digit, at: placement.cell, board: board,
                                             autoReduceNotes: sessionPolicy.autoReduceNotes,
                                             isReveal: true)
        commitPlacement(transaction, cell: placement.cell, digit: placement.digit)
    }

    func closeHint() {
        hint = .closed
        refreshRenderStates()
    }

    // MARK: - Render states

    private func refreshRenderStates() {
        let selected = selectedIndex
        let selectedValue = selected.map { board[$0].value } ?? 0
        let hintCells: Set<Int> = {
            if case .step(let step, let layer) = hint, layer >= .region {
                return Set(HintPlanner.presentation(for: step, layer: layer).regionCells)
            }
            if case .conflicts(let cells) = hint { return Set(cells) }
            return []
        }()

        var next = renderStates
        for index in 0..<81 {
            let cell = board[index]
            var state = CellRenderState()
            state.value = cell.value
            state.isGiven = cell.isGiven
            state.manualNotes = cell.manualNotesMask
            state.assistedCandidates = assistedCandidates(for: index, selected: selected)
            state.isSelected = (index == selected)
            state.isRelated = selected.map {
                $0 != index && BoardTopology.sees($0, index)
            } ?? false
            state.isSameDigit = sessionPolicy.highlightSameDigit
                && selectedValue != 0 && cell.value == selectedValue && index != selected
            state.isConflict = sessionPolicy.validation != .manualOnly
                && derived.conflicts.contains(index)
            state.isHintFocus = hintCells.contains(index)
            state.isVerifiedWrong = verifiedWrongCells.contains(index)
            next[index] = state
        }
        renderStates = next
    }

    private func assistedCandidates(for index: Int, selected: Int?) -> DigitMask {
        guard board[index].value == 0 else { return 0 }
        let legal = derived.legalCandidates[index] & ~board[index].manualNotesMask
        switch sessionPolicy.fieldCandidates {
        case .off:
            return 0
        case .lensOnDemand:
            return lensCell == index ? legal : 0
        case .selectedCellPersistent:
            return index == selected ? legal : 0
        case .wholeBoard:
            return legal
        }
    }

    /// Допустимые цифры для панели: приглушение недопустимых.
    var keypadIllegalDigits: DigitMask {
        guard sessionPolicy.keypadHints == .dimIllegal,
              let index = selectedIndex, board[index].value == 0 else { return 0 }
        return Digits.all & ~derived.legalCandidates[index]
    }

    /// Что делать с цифрой, расставленной все девять раз.
    enum CompletedDigitTreatment { case keep, dim, hide }

    /// Полностью расставленная цифра убирается с панели — но НЕ на «Мастере»
    /// и НЕ в профиле «Бумага»: там приложение принципиально ничего
    /// не подсказывает, а исчезнувшая кнопка — это подсказка.
    var completedDigitTreatment: CompletedDigitTreatment {
        guard sessionPolicy.dimCompletedDigits else { return .keep }
        guard puzzle.tier != .master else { return .keep }
        return .hide
    }

    var completedDigits: DigitMask {
        completedDigitTreatment == .keep ? 0 : derived.completedDigits
    }

    // MARK: - Перезапуск

    /// «Начать заново»: доска возвращается к исходной, история очищается,
    /// журнал помощи СОХРАНЯЕТСЯ и результат становится нерейтинговым.
    func restart() {
        board = BoardState(givens: puzzle.puzzle) ?? board
        history = MoveHistory()
        derived = SudokuValidator.derive(board)
        selectedIndex = nil
        lensCell = nil
        verifiedWrongCells.removeAll()
        hint = .closed
        isSolved = false
        attemptEnded = false
        showGuessGuard = false
        statusMessage = L.t("pause.restarted")
        struggle = StruggleDetector(startedAt: clock.now)
        struggleSignal = nil
        // Проверка, начатая на прежней доске, к новой партии отношения не имеет.
        cancelStruggleProbe()
        // Счёт начинается заново вместе с доской, но множитель НЕ
        // восстанавливается: использованная помощь уже засчитана в журнале.
        // Счёт партии продолжается: журнал помощи монотонен, и уже уплаченные
        // цены не возвращаются. Ожидающие подтверждения ходы пропадают вместе
        // с доской — они больше ничего не подтверждают.
        pendingPlacements.removeAll()
        pendingGroups.removeAll()
        valueRevision += 1
        digitsTried.removeAll()
        timer.restartAttempt()
        ledger.registerRestart()
        startFreshJournal()
        refreshRenderStates()
        persist(immediate: true)
    }

    /// Перезапуск начинает НОВЫЙ журнал, а не дописывает старый.
    ///
    /// Иначе на диск ушла бы пустая доска вместе с полной историей: при
    /// следующей загрузке проекция журнала разошлась бы со снимком, и партия
    /// оказалась бы помечена повреждённой за совершенно законное действие
    /// игрока. Дописать «событие перезапуска» в старую историю тоже нельзя —
    /// счёт восстановился бы вместе со всеми начислениями до сброса.
    ///
    /// Счёт при этом сознательно НЕ обнуляется: уплаченные цены помощи
    /// монотонны, и перезапуск не должен быть способом от них избавиться.
    private func startFreshJournal() {
        commandBuffer.removeAll()
        journal = SessionJournal()
        record(.sessionStarted(descriptor(startingBoard: board.serialized())))
        record(.candidateAidEscalated(ledger.candidateAid))
        commitCommand()
    }

    private func descriptor(startingBoard: String) -> SessionDescriptor {
        SessionDescriptor(
            puzzleID: puzzle.id,
            givens: puzzle.puzzle,
            solution: puzzle.solution,
            catalogVersion: catalogVersion,
            difficultyD: puzzle.difficultyD,
            mode: mode,
            policy: scoreValidationPolicy,
            startingBoard: startingBoard,
            autoReduceNotes: sessionPolicy.autoReduceNotes)
    }

    // MARK: - Сохранение

    func persistedSession() -> PersistedSession {
        PersistedSession(
            puzzleID: puzzle.id,
            catalogVersion: catalogVersion,
            board: board,
            givens: puzzle.puzzle,
            history: history,
            initialProfileID: initialProfile,
            sessionPolicy: sessionPolicy,
            ledger: ledger,
            timing: timer.snapshot,
            modifiers: modifiers,
            paceMode: paceMode,
            dailyCompetitionVersion: dailyCompetitionVersion,
            journal: journal,
            integrityWarning: integrityWarning
        )
    }

    private func persist(immediate: Bool) {
        autosave(persistedSession(), immediate)
    }

    // MARK: - Завершение

    /// Сопоставима ли попытка с personal best (раздел 11): без паузы,
    /// без подсказок глубже «Области», без Reveal и без подтверждённых ошибок.
    var isComparableAttempt: Bool {
        timer.snapshot.speedEligible
            && !ledger.revealUsed
            && ledger.hintLayer <= .region
            && ledger.confirmedGuessStrikes == 0
            && !ledger.perfectFailed
    }

    var activeModifiers: [ChallengeModifier] { modifiers }
    var activePaceMode: RatingPaceMode { paceMode }

    /// Метка рейтинга по фактическому использованию помощи.
    var ledgerLabel: AssistanceUsageLedger.RatingLabel { ledger.ratingLabel }
    var currentLedger: AssistanceUsageLedger { ledger }

    var activeSeconds: Int { Int(timer.activeSeconds.rounded()) }
    var challengeElapsedSeconds: Int { Int(timer.challengeElapsedSeconds.rounded()) }

    #if DEBUG
    /// Отладка: заполняет доску решением, оставляя одну пустую клетку,
    /// чтобы можно было за один ход проверить экран результата и рейтинг.
    /// В релизную сборку не попадает.
    func debugFillAlmostSolved() {
        var next = board
        var remaining: Int?
        for index in 0..<81 where next[index].value == 0 {
            if remaining == nil { remaining = index; continue }
            // Читаем из того же кэша, что и проверка ходов: второй разбор
            // решения рядом с ним — приглашение скопировать не тот идиом.
            // Неизвестная клетка остаётся пустой: писать в неё литеральный
            // ноль значило бы выдать повреждённое решение за заполненное.
            guard let digit = solutionDigits.digit(at: index), digit > 0 else { continue }
            next[index].value = UInt8(digit)
            next[index].manualNotesMask = 0
        }
        board = next
        history = MoveHistory()
        derived = SudokuValidator.derive(board)
        selectedIndex = remaining
        if let remaining, let digit = solutionDigits.digit(at: remaining), digit > 0 {
            statusMessage = "DEBUG · клетка \(remaining), цифра \(digit)"
        }
        refreshRenderStates()
    }
    #endif

    func ratingInput(currentRating: Int, appliedRatedCount: Int) -> RatingInput {
        RatingInput(
            currentRating: currentRating,
            puzzleDifficulty: puzzle.difficultyD,
            appliedRatedCount: appliedRatedCount,
            ledger: ledger,
            paceMode: paceMode,
            speedEligible: timer.snapshot.speedEligible,
            activeSeconds: activeSeconds,
            expectedActiveSecondsP50: puzzle.expectedActiveSecondsP50
        )
    }
}
