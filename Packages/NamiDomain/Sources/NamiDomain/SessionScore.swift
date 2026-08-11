//
//  SessionScore.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  Счёт партии по спецификации `novemi-session-score-v1`.
//
//  Три правила, из которых следует всё остальное:
//
//  1. Только целые числа. Ни одного Double в пути к итогу: на разных
//     устройствах и версиях Swift дробная арифметика может разойтись в
//     последнем разряде, а leaderboard обязан совпадать бит в бит.
//     Единственное округление — `roundHalfUp`.
//
//  2. Нормализованный бюджет. Задачи различаются числом пустых клеток, поэтому
//     фиксированная цена за цифру делает их несопоставимыми. Каждой задаче
//     выделяется общий бюджет `B`, а он уже делится между клетками. Остаток
//     раздаётся по ПОРЯДКУ награждения, а не по номеру клетки — иначе игрок
//     мог бы приберечь заранее известные «дорогие» клетки под высокий множитель.
//
//  3. Журнал, а не снимок доски. Счёт — это история подтверждённых достижений.
//     Поэтому Undo и повторный ввод не фармят очки: клетка, группа и пара
//     «клетка+цифра» учитываются ровно один раз за сессию.
//

import Foundation

// MARK: - Целочисленная арифметика

public enum ScoreMath {
    /// Единственное округление во всей системе.
    public static func roundHalfUp(_ numerator: Int, _ denominator: Int) -> Int {
        precondition(denominator > 0, "делитель обязан быть положительным")
        return (numerator + denominator / 2) / denominator
    }

    /// Деление вверх без `a + b - 1`: то выражение может переполниться.
    public static func ceilDiv(_ numerator: Int, _ denominator: Int) -> Int {
        precondition(denominator > 0, "делитель обязан быть положительным")
        let (quotient, remainder) = numerator.quotientAndRemainder(dividingBy: denominator)
        return remainder > 0 ? quotient + 1 : quotient
    }
}

// MARK: - Константы правил

/// Версионированный набор констант. Активная сессия навсегда фиксирует свою
/// версию: формула не может измениться посреди партии.
public struct SessionScoreRuleSet: Equatable, Sendable {

    public let id: String
    public let basePlacementBudget: Int
    public let factorDenominator: Int
    public let baseFactorNumerator: Int
    public let ratingNumeratorPerPoint: Int
    public let minimumPuzzleRating: Int
    public let maximumPuzzleRating: Int

    public let multiplierBasePermille: Int
    public let multiplierStepPermille: Int
    public let multiplierMaximumTier: Int
    public let tierNumerator: Int
    public let tierDenominator: Int

    public let completedGroupBase: Int
    public let completedPuzzleBase: Int

    public let confirmedErrorMinimumBps: Int
    public let confirmedErrorMeanCellPermille: Int
    public let manualCheckBps: Int

    public let maximumDisplayScore: Int

    public static let v1 = SessionScoreRuleSet(
        id: "novemi-session-score-v1",
        basePlacementBudget: 4000,
        factorDenominator: 1_800_000,
        baseFactorNumerator: 1_800_000,
        ratingNumeratorPerPoint: 350,
        minimumPuzzleRating: 600,
        maximumPuzzleRating: 2400,
        multiplierBasePermille: 1000,
        multiplierStepPermille: 100,
        multiplierMaximumTier: 10,
        tierNumerator: 50,
        tierDenominator: 3,
        completedGroupBase: 30,
        completedPuzzleBase: 400,
        confirmedErrorMinimumBps: 300,
        confirmedErrorMeanCellPermille: 2500,
        manualCheckBps: 300,
        maximumDisplayScore: 999_999
    )

    /// Цена подсказки в basis points от `B`.
    public func hintBps(_ layer: HintLayer) -> Int {
        switch layer {
        case .none: 0
        case .region: 100
        case .techniqueName: 300
        case .candidatesAndLogic: 600
        // Reveal делает результат тренировочным; отдельной цены у него нет.
        case .reveal: 600
        }
    }

    /// Цена помощи кандидатами в basis points от `B`.
    public func candidateAidBps(_ aid: CandidateAid) -> Int {
        switch aid {
        case .none: 0
        case .keypadDimming: 50
        case .lens: 100
        case .selectedCellPersistent: 200
        case .wholeBoard: 500
        }
    }

    /// Бонус темпа в basis points от счёта до бонуса.
    public func paceBps(timeRatioPermille: Int) -> Int {
        if timeRatioPermille <= 700 { return 1500 }
        if timeRatioPermille <= 850 { return 1000 }
        if timeRatioPermille <= 1000 { return 500 }
        return 0
    }
}

// MARK: - Бюджет задачи

/// Всё, что зависит только от задачи и не меняется по ходу партии.
public struct SessionScoreBudget: Equatable, Sendable {

    public let rules: SessionScoreRuleSet
    public let emptyCellCount: Int
    /// Общий бюджет за цифры, `B`.
    public let placementBudget: Int
    public let groupBonus: Int
    public let completionBonus: Int
    public let errorPenalty: Int
    public let checkPenalty: Int

    public init(puzzleRating: Int, emptyCellCount: Int,
                rules: SessionScoreRuleSet = .v1) {
        self.rules = rules
        let cells = max(1, emptyCellCount)
        self.emptyCellCount = cells

        let delta = min(max(puzzleRating - rules.minimumPuzzleRating, 0),
                        rules.maximumPuzzleRating - rules.minimumPuzzleRating)
        let numerator = rules.baseFactorNumerator + rules.ratingNumeratorPerPoint * delta

        func scaled(_ value: Int) -> Int {
            ScoreMath.roundHalfUp(value * numerator, rules.factorDenominator)
        }

        let budget = scaled(rules.basePlacementBudget)
        self.placementBudget = budget
        self.groupBonus = scaled(rules.completedGroupBase)
        self.completionBonus = scaled(rules.completedPuzzleBase)

        // Штраф обязан быть больше максимальной награды одного угаданного хода,
        // иначе перебор цифр имел бы положительное ожидание.
        self.errorPenalty = max(
            ScoreMath.roundHalfUp(budget * rules.confirmedErrorMinimumBps, 10_000),
            ScoreMath.roundHalfUp(budget * rules.confirmedErrorMeanCellPermille,
                                  1000 * cells)
        )
        self.checkPenalty = ScoreMath.roundHalfUp(budget * rules.manualCheckBps, 10_000)
    }

    /// Доля бюджета за клетку с данным порядковым номером награждения.
    /// Сумма всех долей всегда ровно `B`.
    public func cellBase(awardOrdinal: Int) -> Int {
        let quotient = placementBudget / emptyCellCount
        let remainder = placementBudget % emptyCellCount
        return awardOrdinal < remainder ? quotient + 1 : quotient
    }
}

// MARK: - Состояние

public struct SessionScoreState: Equatable, Sendable {

    public let budget: SessionScoreBudget

    /// Знаковый баланс. Штраф не исчезает, если очков пока нет: иначе первые
    /// переборы в начале партии были бы бесплатными.
    public private(set) var scoreBalance = 0
    public private(set) var positiveTotal = 0
    public private(set) var penaltyLedger = 0

    public private(set) var streak = 0
    public private(set) var maxStreak = 0
    public private(set) var multiplierPermille: Int
    public private(set) var maxMultiplierPermille: Int

    public private(set) var placementTotal = 0
    public private(set) var structureTotal = 0
    public private(set) var paceBonus = 0

    public private(set) var confirmedErrorStrikes = 0
    public private(set) var revealUsed = false
    public private(set) var sealed = false

    /// Бонус темпа необратимо теряется от любой помощи и любой ошибки.
    /// Флаг только гаснет: вернуть право нельзя ничем.
    public private(set) var paceEligible = true

    /// Сколько платных проверок было в партии. Нужен только для аналитики:
    /// журнал помощи монотонен и хранит уровень, а не количество.
    public private(set) var manualCheckCount = 0

    // Ключи идемпотентности.
    private var awardedCells: Set<Int> = []
    private var nonScoringCells: Set<Int> = []
    private var awardOrdinalByCell: [Int: Int] = [:]
    private var nextAwardOrdinal = 0
    private var awardedGroups: Set<Int> = []
    private var penalizedAttempts: Set<AttemptKey> = []
    // Храним УПЛАЧЕННУЮ СУММУ, а не уровень в базисных пунктах. Иначе
    // округление на каждой ступени накапливается, и игрок, поднимавшийся
    // постепенно, платит больше того, кто сразу взял верхний уровень.
    private var paidHintAmount: [HintKey: Int] = [:]
    private var paidCheckKeys: Set<CheckKey> = []
    private var paidCandidateAidAmount = 0
    /// Задача решается один раз за сессию, значит и бонус за неё выдаётся один
    /// раз. Ключ идемпотентности здесь вырожденный — булев, — но он такой же
    /// обязательный, как `awardedCells` или `paidCheckKeys`.
    private var completionAwarded = false

    public struct AttemptKey: Hashable, Sendable {
        public let cell: Int
        public let digit: Int
        public init(cell: Int, digit: Int) { self.cell = cell; self.digit = digit }
    }

    public struct HintKey: Hashable, Sendable {
        public let revision: UInt64
        public let stepHash: UInt64
        public init(revision: UInt64, stepHash: UInt64) {
            self.revision = revision
            self.stepHash = stepHash
        }
    }

    public struct CheckKey: Hashable, Sendable {
        public let revision: UInt64
        public let isRuleOfMode: Bool
        public init(revision: UInt64, isRuleOfMode: Bool) {
            self.revision = revision
            self.isRuleOfMode = isRuleOfMode
        }
    }

    public init(budget: SessionScoreBudget) {
        self.budget = budget
        self.multiplierPermille = budget.rules.multiplierBasePermille
        self.maxMultiplierPermille = budget.rules.multiplierBasePermille
    }

    /// HUD никогда не показывает отрицательное число, но долг не исчезает.
    public var displayScore: Int {
        min(budget.rules.maximumDisplayScore, max(0, scoreBalance))
    }

    /// Штраф, который реально уместился в набранные очки.
    public var effectivePenalty: Int { min(penaltyLedger, positiveTotal) }
    /// Непогашенный остаток — отдельная несуммируемая подпись в разборе.
    public var penaltyRemainder: Int { penaltyLedger - effectivePenalty }

    /// Третий подтверждённый strike переводит результат в тренировочный.
    /// Восстановление разошлось с журналом. Доска при этом остаётся играбельной
    /// — терять партию из-за нашей же ошибки хранения несоразмерно, — но счёт
    /// перестаёт претендовать на таблицу лидеров.
    public private(set) var integrityBroken = false

    public mutating func markIntegrityBroken() { integrityBroken = true }

    public var isRecordable: Bool {
        !revealUsed && !integrityBroken && confirmedErrorStrikes < 3
    }

    /// Текущая ступень множителя, 0...10.
    public var multiplierTier: Int {
        (multiplierPermille - budget.rules.multiplierBasePermille)
            / budget.rules.multiplierStepPermille
    }

    /// Сколько верных ходов до следующей ступени. `nil` на максимуме.
    ///
    /// Порог ступени `t` — наименьшая серия, при которой
    /// `50 * streak / (3N) >= t`, то есть `ceil(3 * N * t / 50)`.
    public var movesToNextTier: Int? {
        let rules = budget.rules
        let next = multiplierTier + 1
        guard next <= rules.multiplierMaximumTier else { return nil }
        let threshold = ScoreMath.ceilDiv(rules.tierDenominator * budget.emptyCellCount * next,
                                          rules.tierNumerator)
        return max(0, threshold - streak)
    }

    /// Доля пути до следующей ступени, 0...1. Это НЕ таймер: полоса
    /// заполняется только верными ходами и никогда не убывает сама.
    public var tierProgress: Double {
        let rules = budget.rules
        let next = multiplierTier + 1
        guard next <= rules.multiplierMaximumTier else { return 1 }
        let upper = ScoreMath.ceilDiv(rules.tierDenominator * budget.emptyCellCount * next,
                                      rules.tierNumerator)
        let lower = ScoreMath.ceilDiv(rules.tierDenominator * budget.emptyCellCount
                                      * multiplierTier, rules.tierNumerator)
        let span = upper - lower
        guard span > 0 else { return 1 }
        return min(1, max(0, Double(streak - lower) / Double(span)))
    }

    // MARK: Внутренние переходы

    fileprivate mutating func add(points: Int) {
        positiveTotal += points
        scoreBalance += points
    }

    fileprivate mutating func charge(_ amount: Int) {
        guard amount > 0 else { return }
        penaltyLedger += amount
        scoreBalance -= amount
    }

    fileprivate mutating func setStreak(_ value: Int) {
        streak = max(0, value)
        maxStreak = max(maxStreak, streak)
        let rules = budget.rules
        // Порог зависит от размера задачи: множитель достигает максимума
        // примерно после 60% чисто заполненного поля независимо от длины.
        let tier = min(rules.multiplierMaximumTier,
                       rules.tierNumerator * streak
                       / (rules.tierDenominator * budget.emptyCellCount))
        multiplierPermille = rules.multiplierBasePermille + rules.multiplierStepPermille * tier
        maxMultiplierPermille = max(maxMultiplierPermille, multiplierPermille)
    }

    fileprivate mutating func consumeOrdinal(for cell: Int) -> Int {
        if let existing = awardOrdinalByCell[cell] { return existing }
        let ordinal = nextAwardOrdinal
        awardOrdinalByCell[cell] = ordinal
        nextAwardOrdinal += 1
        return ordinal
    }

    /// Сколько клеток уже оплачено. Нужно снаружи, чтобы сверять счёт с
    /// доской после восстановления из журнала: расхождение здесь означает,
    /// что две проекции одной истории разошлись.
    public var awardedCellCount: Int { awardedCells.count }
    /// Клетки, «истратившие» порядковый номер: оплаченные плюс заполненные
    /// системой или Reveal.
    public var reachedCellCount: Int { reachedCells.count }

    fileprivate var reachedCells: Set<Int> { awardedCells.union(nonScoringCells) }
    fileprivate func hasAwarded(group: Int) -> Bool { awardedGroups.contains(group) }
    fileprivate func hasPenalized(_ key: AttemptKey) -> Bool { penalizedAttempts.contains(key) }
    fileprivate func paidHint(_ key: HintKey) -> Int { paidHintAmount[key] ?? 0 }
    fileprivate func hasPaid(check: CheckKey) -> Bool { paidCheckKeys.contains(check) }
    fileprivate var hasAwardedCompletion: Bool { completionAwarded }
    fileprivate var candidateAidPaid: Int { paidCandidateAidAmount }

    fileprivate mutating func markAwarded(cell: Int) { awardedCells.insert(cell) }
    fileprivate mutating func markNonScoring(cell: Int) { nonScoringCells.insert(cell) }
    fileprivate mutating func markAwarded(group: Int) { awardedGroups.insert(group) }
    fileprivate mutating func markPenalized(_ key: AttemptKey) { penalizedAttempts.insert(key) }
    fileprivate mutating func markHint(_ key: HintKey, amount: Int) {
        paidHintAmount[key] = amount
    }
    fileprivate mutating func markCheck(_ key: CheckKey) { paidCheckKeys.insert(key) }
    fileprivate mutating func markCompletionAwarded() { completionAwarded = true }
    fileprivate mutating func markCandidateAid(amount: Int) {
        paidCandidateAidAmount = amount
    }
    fileprivate mutating func markReveal() { revealUsed = true }
    fileprivate mutating func dropPaceEligibility() { paceEligible = false }
    fileprivate mutating func countCheck() { manualCheckCount += 1 }
    fileprivate mutating func addStrike() { confirmedErrorStrikes += 1 }
    fileprivate mutating func seal() { sealed = true }
    fileprivate mutating func addPlacement(_ points: Int) { placementTotal += points }
    fileprivate mutating func addStructure(_ points: Int) { structureTotal += points }
    fileprivate mutating func setPace(_ points: Int) { paceBonus = points }
}

/// Когда счёт узнаёт о правильности хода.
///
/// Если счётчик реагирует на верную цифру немедленно, он выполняет
/// автопроверку в обход профиля помощи: игрок смотрит на прирост очков и
/// понимает, угадал он или нет. В «Бумаге» это недопустимо — там приложение
/// обещало ничего не сверять.
public enum ScoreValidationPolicy: String, Codable, Sendable {
    /// Профиль сверяет ввод с решением, значит счёт может делать то же.
    case immediateValidated
    /// Правильность становится известна только после Check или финиша,
    /// и очки начисляются одним пакетом.
    case deferredValidation

    public init(validation: SessionPolicy.Validation) {
        self = validation == .againstSolution ? .immediateValidated : .deferredValidation
    }
}

// MARK: - Входы и эффекты

public enum SessionScoreInput: Sendable {
    /// Подтверждённое размещение. `correct` известен только после валидации:
    /// в «Бумаге» это происходит пакетом после Check, а не сразу.
    case placementConfirmed(cell: Int, digit: Int, correct: Bool)
    /// Клетка заполнена системой или Reveal: ordinal тратится, очки не идут.
    case placementNonScoring(cell: Int)
    case groupsConfirmed([Int])
    case puzzleCompleted
    case manualCheck(revision: UInt64, isRuleOfMode: Bool)
    case hintOpened(layer: HintLayer, revision: UInt64, stepHash: UInt64)
    case candidateAidEscalated(CandidateAid)
    case paceResolved(elapsedMs: Int, expectedMs: Int, eligible: Bool)
}

public enum ScorePenaltyReason: Equatable, Sendable {
    case confirmedError, manualCheck, hint, candidateAid
}

public enum ScoreEffect: Equatable, Sendable {
    case pointsAdded(delta: Int, total: Int)
    case multiplierChanged(from: Int, to: Int, streak: Int)
    case penaltyApplied(reason: ScorePenaltyReason, delta: Int, total: Int)
    case becamePractice
    case sealed(total: Int)
}

// MARK: - Reducer

public enum SessionScoreReducer {

    /// Чистая функция: одно и то же состояние плюс тот же вход всегда дают
    /// один результат. Повторная доставка входа не меняет состояние.
    @discardableResult
    public static func apply(_ input: SessionScoreInput,
                             to state: inout SessionScoreState) -> [ScoreEffect] {
        guard !state.sealed else { return [] }
        var effects: [ScoreEffect] = []
        let multiplierBefore = state.multiplierPermille

        switch input {
        case let .placementConfirmed(cell, digit, correct):
            if correct {
                // Клетка награждается максимум один раз за сессию.
                guard !state.reachedCells.contains(cell) else { break }
                let ordinal = state.consumeOrdinal(for: cell)
                state.markAwarded(cell: cell)
                state.setStreak(state.streak + 1)
                let points = ScoreMath.roundHalfUp(
                    state.budget.cellBase(awardOrdinal: ordinal) * state.multiplierPermille,
                    1000
                )
                state.add(points: points)
                state.addPlacement(points)
                effects.append(.pointsAdded(delta: points, total: state.displayScore))
            } else {
                // Штраф идёт за каждую новую уникальную пару «клетка+цифра»,
                // но повтор той же пары бесплатен: игрок уже её видел.
                let key = SessionScoreState.AttemptKey(cell: cell, digit: digit)
                guard !state.hasPenalized(key) else { break }
                state.markPenalized(key)
                state.dropPaceEligibility()
                state.charge(state.budget.errorPenalty)
                state.setStreak(0)
                effects.append(.penaltyApplied(reason: .confirmedError,
                                               delta: state.budget.errorPenalty,
                                               total: state.displayScore))
            }

        case let .placementNonScoring(cell):
            guard !state.reachedCells.contains(cell) else { break }
            _ = state.consumeOrdinal(for: cell)
            state.markNonScoring(cell: cell)

        case let .groupsConfirmed(units):
            var gained = 0
            for unit in units where !state.hasAwarded(group: unit) {
                state.markAwarded(group: unit)
                gained += state.budget.groupBonus
            }
            guard gained > 0 else { break }
            // Бонус группы НЕ умножается на серию: иначе порядок заполнения
            // превращается в способ фарма.
            state.add(points: gained)
            state.addStructure(gained)
            effects.append(.pointsAdded(delta: gained, total: state.displayScore))

        case .puzzleCompleted:
            // Бонус завершения идемпотентен САМ ПО СЕБЕ, как и цена проверки
            // ниже. До этого повтор был безвреден только потому, что журнал
            // запечатывается после `puzzleCompleted`, — инвариант держался в
            // другом типе. Стоит записи прийти повторно (воспроизведение,
            // повторная доставка, будущий вызов не из журнала) — и в таблицу
            // лидеров уходят выдуманные очки.
            guard !state.hasAwardedCompletion else { break }
            state.markCompletionAwarded()
            state.add(points: state.budget.completionBonus)
            state.addStructure(state.budget.completionBonus)
            effects.append(.pointsAdded(delta: state.budget.completionBonus,
                                        total: state.displayScore))

        case let .manualCheck(revision, isRuleOfMode):
            // Обязательная проверка режима Perfect — правило, а не помощь.
            guard !isRuleOfMode else { break }
            let key = SessionScoreState.CheckKey(revision: revision, isRuleOfMode: false)
            // Повторная проверка неизменившейся позиции бесплатна.
            guard !state.hasPaid(check: key) else { break }
            state.markCheck(key)
            state.countCheck()
            state.dropPaceEligibility()
            state.charge(state.budget.checkPenalty)
            state.setStreak(0)
            effects.append(.penaltyApplied(reason: .manualCheck,
                                           delta: state.budget.checkPenalty,
                                           total: state.displayScore))

        case let .hintOpened(layer, revision, stepHash):
            let key = SessionScoreState.HintKey(revision: revision, stepHash: stepHash)
            // Полная цена уровня считается один раз от бюджета, списывается
            // только недоплаченная часть. Итог не зависит от пути.
            let target = ScoreMath.roundHalfUp(
                state.budget.placementBudget * state.budget.rules.hintBps(layer), 10_000)
            let difference = max(0, target - state.paidHint(key))
            if difference > 0 {
                state.markHint(key, amount: target)
                let cost = difference
                state.charge(cost)
                effects.append(.penaltyApplied(reason: .hint, delta: cost,
                                               total: state.displayScore))
            }
            if layer != .none { state.dropPaceEligibility() }
            switch layer {
            case .none: break
            case .region: state.setStreak(state.streak / 2)
            case .techniqueName, .candidatesAndLogic: state.setStreak(0)
            case .reveal:
                state.setStreak(0)
                state.markReveal()
                effects.append(.becamePractice)
            }

        case let .candidateAidEscalated(aid):
            let target = ScoreMath.roundHalfUp(
                state.budget.placementBudget * state.budget.rules.candidateAidBps(aid), 10_000)
            let difference = max(0, target - state.candidateAidPaid)
            guard difference > 0 else { break }
            state.markCandidateAid(amount: target)
            // Любая помощь кандидатами выше нейтральной снимает бонус темпа.
            if aid != .none { state.dropPaceEligibility() }
            let cost = difference
            state.charge(cost)
            if aid == .wholeBoard { state.setStreak(0) }
            effects.append(.penaltyApplied(reason: .candidateAid, delta: cost,
                                           total: state.displayScore))

        case let .paceResolved(elapsedMs, expectedMs, eligible):
            defer {
                state.seal()
                effects.append(.sealed(total: state.displayScore))
            }
            guard eligible, state.paceEligible, state.isRecordable,
                  expectedMs > 0, elapsedMs > 0 else { break }
            let ratio = ScoreMath.ceilDiv(elapsedMs * 1000, expectedMs)
            let bps = state.budget.rules.paceBps(timeRatioPermille: ratio)
            guard bps > 0 else { break }
            // Бонус считается от счёта ПОСЛЕ штрафов и не может быть
            // отрицательным: медленное прохождение получает ноль.
            let base = max(0, state.scoreBalance)
            let bonus = ScoreMath.roundHalfUp(base * bps, 10_000)
            state.add(points: bonus)
            state.setPace(bonus)
            effects.append(.pointsAdded(delta: bonus, total: state.displayScore))
        }

        if state.multiplierPermille != multiplierBefore {
            effects.append(.multiplierChanged(from: multiplierBefore,
                                              to: state.multiplierPermille,
                                              streak: state.streak))
        }
        if state.confirmedErrorStrikes >= 3 && !state.revealUsed {
            effects.append(.becamePractice)
        }
        return effects
    }

    /// Отдельный вход для strike: один Check со многими ошибками создаёт
    /// ровно один strike, но отдельный штраф за каждую новую пару.
    public static func registerStrike(in state: inout SessionScoreState) {
        guard !state.sealed, state.confirmedErrorStrikes < 3 else { return }
        state.addStrike()
    }
}
