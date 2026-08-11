//
//  SessionScoreTests.swift
//  NamiDomainTests
//
//  Created by artemoffM8.
//
//  Проверяется не «примерно похоже», а ровно то, что делает счёт честным:
//  суммы сходятся, повторы ничего не дают, угадывание невыгодно.
//

import XCTest
@testable import NamiDomain

final class SessionScoreTests: XCTestCase {

    // Пример из спецификации: D = 1200, N = 50.
    private let budget = SessionScoreBudget(puzzleRating: 1200, emptyCellCount: 50)

    private func fresh() -> SessionScoreState { SessionScoreState(budget: budget) }

    // MARK: - Арифметика

    func testRoundHalfUp() {
        XCTAssertEqual(ScoreMath.roundHalfUp(1, 2), 1)
        XCTAssertEqual(ScoreMath.roundHalfUp(3, 2), 2)
        XCTAssertEqual(ScoreMath.roundHalfUp(0, 7), 0)
        XCTAssertEqual(ScoreMath.roundHalfUp(90 * 1300, 1000), 117)
    }

    func testCeilDivDoesNotOverflowOnLargeValues() {
        XCTAssertEqual(ScoreMath.ceilDiv(10, 4), 3)
        XCTAssertEqual(ScoreMath.ceilDiv(8, 4), 2)
        XCTAssertEqual(ScoreMath.ceilDiv(Int.max - 1, Int.max), 1)
    }

    // MARK: - Golden-векторы спецификации

    func testBudgetMatchesSpecification() {
        XCTAssertEqual(budget.placementBudget, 4467)
        XCTAssertEqual(budget.groupBonus, 34)
        XCTAssertEqual(budget.completionBonus, 447)
        XCTAssertEqual(budget.checkPenalty, 134)
        XCTAssertEqual(budget.errorPenalty, 223)
    }

    /// Сумма долей обязана быть ровно `B` при любом числе клеток —
    /// иначе бюджет «протекает» и задачи снова несопоставимы.
    func testCellBaseSumsToBudgetForEveryBoardSize() {
        for cells in [17, 30, 45, 50, 64, 81] {
            let local = SessionScoreBudget(puzzleRating: 1750, emptyCellCount: cells)
            let total = (0..<cells).reduce(0) { $0 + local.cellBase(awardOrdinal: $1) }
            XCTAssertEqual(total, local.placementBudget, "разошлось при N = \(cells)")
        }
    }

    func testPlacementOnTenthStreakMatchesSpecification() {
        var state = fresh()
        for cell in 0..<10 {
            SessionScoreReducer.apply(
                .placementConfirmed(cell: cell, digit: 1, correct: true), to: &state)
        }
        // 50 * 10 / (3 * 50) = 3 -> ×1.30
        XCTAssertEqual(state.multiplierPermille, 1300)
        XCTAssertEqual(state.streak, 10)
    }

    // MARK: - Множитель

    func testMultiplierNeverExceedsDouble() {
        var state = fresh()
        for cell in 0..<50 {
            SessionScoreReducer.apply(
                .placementConfirmed(cell: cell, digit: 1, correct: true), to: &state)
        }
        XCTAssertEqual(state.multiplierPermille, 2000)
        XCTAssertLessThanOrEqual(state.multiplierPermille, 2000)
    }

    func testErrorResetsStreakAndMultiplier() {
        var state = fresh()
        for cell in 0..<12 {
            SessionScoreReducer.apply(
                .placementConfirmed(cell: cell, digit: 1, correct: true), to: &state)
        }
        XCTAssertGreaterThan(state.multiplierPermille, 1000)
        SessionScoreReducer.apply(
            .placementConfirmed(cell: 70, digit: 9, correct: false), to: &state)
        XCTAssertEqual(state.streak, 0)
        XCTAssertEqual(state.multiplierPermille, 1000)
    }

    // MARK: - Защита от фарма

    func testSameCellNeverAwardedTwice() {
        var state = fresh()
        SessionScoreReducer.apply(
            .placementConfirmed(cell: 4, digit: 7, correct: true), to: &state)
        let after = state.displayScore
        SessionScoreReducer.apply(
            .placementConfirmed(cell: 4, digit: 7, correct: true), to: &state)
        XCTAssertEqual(state.displayScore, after)
        XCTAssertEqual(state.streak, 1, "повтор не должен наращивать серию")
    }

    func testSameGroupNeverAwardedTwice() {
        var state = fresh()
        SessionScoreReducer.apply(.groupsConfirmed([3]), to: &state)
        let after = state.displayScore
        SessionScoreReducer.apply(.groupsConfirmed([3]), to: &state)
        XCTAssertEqual(state.displayScore, after)
    }

    func testRepeatedWrongPairIsFreeButNewPairIsNot() {
        var state = fresh()
        SessionScoreReducer.apply(
            .placementConfirmed(cell: 5, digit: 3, correct: false), to: &state)
        let afterFirst = state.penaltyLedger
        SessionScoreReducer.apply(
            .placementConfirmed(cell: 5, digit: 3, correct: false), to: &state)
        XCTAssertEqual(state.penaltyLedger, afterFirst, "та же пара — уже показана")
        SessionScoreReducer.apply(
            .placementConfirmed(cell: 5, digit: 4, correct: false), to: &state)
        XCTAssertEqual(state.penaltyLedger, afterFirst + budget.errorPenalty)
    }

    /// Ключевое свойство: перебор цифр обязан иметь отрицательное ожидание.
    func testGuessingIsMathematicallyUnprofitable() {
        let bestReward = ScoreMath.roundHalfUp(
            budget.cellBase(awardOrdinal: 0) * 2000, 1000)
        XCTAssertGreaterThan(budget.errorPenalty, bestReward,
                             "штраф должен превышать лучшую награду за один ход")
    }

    /// Задача решается один раз, значит и бонус за неё выдаётся один раз.
    ///
    /// Раньше это держалось не на самом редьюсере, а на том, что журнал
    /// запечатывается после `puzzleCompleted`. Инвариант, живущий в другом
    /// типе, однажды перестаёт выполняться — и в таблицу лидеров уходят
    /// очки, которых игрок не набирал.
    func testCompletionBonusIsAwardedOnlyOnce() {
        var state = fresh()
        SessionScoreReducer.apply(
            .placementConfirmed(cell: 0, digit: 1, correct: true), to: &state)
        let beforeFinish = state.displayScore

        let first = SessionScoreReducer.apply(.puzzleCompleted, to: &state)
        XCTAssertEqual(state.displayScore, beforeFinish + budget.completionBonus)
        XCTAssertEqual(state.structureTotal, budget.completionBonus)
        XCTAssertEqual(first, [.pointsAdded(delta: budget.completionBonus,
                                            total: state.displayScore)])

        let afterFirst = state
        let second = SessionScoreReducer.apply(.puzzleCompleted, to: &state)
        XCTAssertTrue(second.isEmpty, "повтор не порождает эффектов")
        XCTAssertEqual(state.displayScore, afterFirst.displayScore,
                       "второй бонус — это выдуманные очки")
        XCTAssertEqual(state.structureTotal, afterFirst.structureTotal)
        XCTAssertEqual(state, afterFirst, "повтор не меняет состояние вообще ничем")
    }

    func testRepeatedCheckOnSameRevisionIsFree() {
        var state = fresh()
        SessionScoreReducer.apply(.manualCheck(revision: 7, isRuleOfMode: false), to: &state)
        let after = state.penaltyLedger
        SessionScoreReducer.apply(.manualCheck(revision: 7, isRuleOfMode: false), to: &state)
        XCTAssertEqual(state.penaltyLedger, after)
        SessionScoreReducer.apply(.manualCheck(revision: 8, isRuleOfMode: false), to: &state)
        XCTAssertEqual(state.penaltyLedger, after + budget.checkPenalty)
    }

    func testPerfectModeCheckIsFree() {
        var state = fresh()
        SessionScoreReducer.apply(.manualCheck(revision: 1, isRuleOfMode: true), to: &state)
        XCTAssertEqual(state.penaltyLedger, 0)
    }

    func testHintUpgradeChargesOnlyDifference() {
        var state = fresh()
        SessionScoreReducer.apply(
            .hintOpened(layer: .region, revision: 1, stepHash: 42), to: &state)
        let afterArea = state.penaltyLedger
        XCTAssertEqual(afterArea,
                       ScoreMath.roundHalfUp(budget.placementBudget * 100, 10_000))

        SessionScoreReducer.apply(
            .hintOpened(layer: .techniqueName, revision: 1, stepHash: 42), to: &state)
        let expected = ScoreMath.roundHalfUp(budget.placementBudget * 300, 10_000)
        XCTAssertEqual(state.penaltyLedger, expected, "должна списаться только разница")

        // Повторное открытие оплаченного слоя бесплатно.
        SessionScoreReducer.apply(
            .hintOpened(layer: .region, revision: 1, stepHash: 42), to: &state)
        XCTAssertEqual(state.penaltyLedger, expected)
    }

    func testCandidateAidChargesOnlyEscalation() {
        var state = fresh()
        SessionScoreReducer.apply(.candidateAidEscalated(.lens), to: &state)
        let afterLens = state.penaltyLedger
        SessionScoreReducer.apply(.candidateAidEscalated(.keypadDimming), to: &state)
        XCTAssertEqual(state.penaltyLedger, afterLens, "понижение не возвращает и не берёт")
        SessionScoreReducer.apply(.candidateAidEscalated(.wholeBoard), to: &state)
        XCTAssertEqual(state.penaltyLedger,
                       ScoreMath.roundHalfUp(budget.placementBudget * 500, 10_000))
        XCTAssertEqual(state.streak, 0, "всё поле сбрасывает серию")
    }

    func testNonScoringCellConsumesOrdinalButPaysNothing() {
        var state = fresh()
        SessionScoreReducer.apply(.placementNonScoring(cell: 0), to: &state)
        XCTAssertEqual(state.displayScore, 0)
        SessionScoreReducer.apply(
            .placementConfirmed(cell: 1, digit: 5, correct: true), to: &state)
        // Первая клетка съела ordinal 0, вторая получает ordinal 1.
        XCTAssertEqual(state.displayScore,
                       ScoreMath.roundHalfUp(budget.cellBase(awardOrdinal: 1) * 1000, 1000))
    }

    // MARK: - Баланс и штрафной остаток

    func testPenaltyDebtSurvivesAtZeroScore() {
        var state = fresh()
        SessionScoreReducer.apply(
            .placementConfirmed(cell: 0, digit: 1, correct: false), to: &state)
        XCTAssertEqual(state.displayScore, 0, "HUD не показывает минус")
        XCTAssertGreaterThan(state.penaltyRemainder, 0, "долг не исчезает")
        XCTAssertEqual(state.effectivePenalty, 0)
    }

    func testBreakdownAlwaysSums() {
        var state = fresh()
        for cell in 0..<20 {
            SessionScoreReducer.apply(
                .placementConfirmed(cell: cell, digit: 1, correct: true), to: &state)
        }
        SessionScoreReducer.apply(.groupsConfirmed([0, 1, 2]), to: &state)
        SessionScoreReducer.apply(.manualCheck(revision: 3, isRuleOfMode: false), to: &state)
        SessionScoreReducer.apply(
            .placementConfirmed(cell: 60, digit: 8, correct: false), to: &state)
        SessionScoreReducer.apply(.puzzleCompleted, to: &state)

        let sum = state.placementTotal + state.structureTotal
            - state.effectivePenalty + state.paceBonus
        XCTAssertEqual(sum, state.displayScore, "четыре строки обязаны сойтись с итогом")
    }

    // MARK: - Бонус темпа

    func testPaceBonusTiers() {
        for (ratioMs, expectedBps) in [(700, 1500), (850, 1000), (1000, 500), (1200, 0)] {
            var state = fresh()
            SessionScoreReducer.apply(
                .placementConfirmed(cell: 0, digit: 1, correct: true), to: &state)
            let before = state.scoreBalance
            SessionScoreReducer.apply(
                .paceResolved(elapsedMs: ratioMs, expectedMs: 1000, eligible: true),
                to: &state)
            XCTAssertEqual(state.paceBonus,
                           ScoreMath.roundHalfUp(before * expectedBps, 10_000),
                           "бакет \(ratioMs)")
        }
    }

    func testSlowCompletionNeverLosesPoints() {
        var state = fresh()
        for cell in 0..<10 {
            SessionScoreReducer.apply(
                .placementConfirmed(cell: cell, digit: 1, correct: true), to: &state)
        }
        let before = state.displayScore
        SessionScoreReducer.apply(
            .paceResolved(elapsedMs: 999_999, expectedMs: 1000, eligible: true), to: &state)
        XCTAssertEqual(state.displayScore, before, "время не может отнимать очки")
        XCTAssertEqual(state.paceBonus, 0)
    }

    /// Любая помощь и любая ошибка необратимо снимают право на бонус темпа.
    func testAnyAssistanceRemovesPaceEligibility() {
        let cases: [(String, SessionScoreInput)] = [
            ("проверка", .manualCheck(revision: 1, isRuleOfMode: false)),
            ("подсказка", .hintOpened(layer: .region, revision: 1, stepHash: 1)),
            ("кандидаты", .candidateAidEscalated(.lens)),
            ("ошибка", .placementConfirmed(cell: 9, digit: 9, correct: false))
        ]
        for (name, input) in cases {
            var state = fresh()
            SessionScoreReducer.apply(
                .placementConfirmed(cell: 0, digit: 1, correct: true), to: &state)
            SessionScoreReducer.apply(input, to: &state)
            XCTAssertFalse(state.paceEligible, name)
            SessionScoreReducer.apply(
                .paceResolved(elapsedMs: 100, expectedMs: 1000, eligible: true), to: &state)
            XCTAssertEqual(state.paceBonus, 0, "бонус после «\(name)» должен быть нулевым")
        }
    }

    func testIneligiblePaceGivesNothingButStillSeals() {
        var state = fresh()
        SessionScoreReducer.apply(
            .paceResolved(elapsedMs: 100, expectedMs: 1000, eligible: false), to: &state)
        XCTAssertEqual(state.paceBonus, 0)
        XCTAssertTrue(state.sealed)
    }

    // MARK: - Запечатывание и тренировочный результат

    func testSealedStateIgnoresFurtherInput() {
        var state = fresh()
        SessionScoreReducer.apply(
            .paceResolved(elapsedMs: 100, expectedMs: 1000, eligible: false), to: &state)
        let after = state.displayScore
        SessionScoreReducer.apply(
            .placementConfirmed(cell: 3, digit: 3, correct: true), to: &state)
        XCTAssertEqual(state.displayScore, after)
    }

    func testRevealMakesResultUnrecordable() {
        var state = fresh()
        XCTAssertTrue(state.isRecordable)
        SessionScoreReducer.apply(
            .hintOpened(layer: .reveal, revision: 1, stepHash: 9), to: &state)
        XCTAssertFalse(state.isRecordable)
    }

    func testThirdStrikeMakesResultUnrecordable() {
        var state = fresh()
        for _ in 0..<3 { SessionScoreReducer.registerStrike(in: &state) }
        XCTAssertFalse(state.isRecordable)
        XCTAssertEqual(state.confirmedErrorStrikes, 3)
    }

    // MARK: - Свойства на случайных сценариях

    /// Более глубокая помощь при прочих равных не может увеличить итог.
    func testDeeperHelpNeverIncreasesScore() {
        func run(with aid: CandidateAid) -> Int {
            var state = fresh()
            SessionScoreReducer.apply(.candidateAidEscalated(aid), to: &state)
            for cell in 0..<30 {
                SessionScoreReducer.apply(
                    .placementConfirmed(cell: cell, digit: 1, correct: true), to: &state)
            }
            return state.displayScore
        }
        let ladder: [CandidateAid] = [.none, .keypadDimming, .lens,
                                      .selectedCellPersistent, .wholeBoard]
        let scores = ladder.map(run)
        XCTAssertEqual(scores, scores.sorted(by: >), "помощь глубже — очков не больше")
    }

    /// Дополнительная подтверждённая ошибка не может поднять итог.
    func testMoreErrorsNeverIncreaseScore() {
        func run(errors: Int) -> Int {
            var state = fresh()
            for index in 0..<errors {
                SessionScoreReducer.apply(
                    .placementConfirmed(cell: 70 + index, digit: 9, correct: false),
                    to: &state)
            }
            for cell in 0..<30 {
                SessionScoreReducer.apply(
                    .placementConfirmed(cell: cell, digit: 1, correct: true), to: &state)
            }
            return state.displayScore
        }
        let scores = (0...4).map(run)
        XCTAssertEqual(scores, scores.sorted(by: >))
    }

    /// Дублирование любого подмножества входов не меняет результат.
    func testDuplicatedInputsAreIdempotent() {
        let inputs: [SessionScoreInput] = [
            .placementConfirmed(cell: 0, digit: 1, correct: true),
            .placementConfirmed(cell: 1, digit: 2, correct: true),
            .groupsConfirmed([0]),
            .manualCheck(revision: 1, isRuleOfMode: false),
            .placementConfirmed(cell: 2, digit: 3, correct: false),
            .hintOpened(layer: .region, revision: 1, stepHash: 5),
            .puzzleCompleted
        ]
        var once = fresh()
        for input in inputs { SessionScoreReducer.apply(input, to: &once) }

        var twice = fresh()
        for input in inputs {
            SessionScoreReducer.apply(input, to: &twice)
            SessionScoreReducer.apply(input, to: &twice)
        }
        XCTAssertEqual(once.displayScore, twice.displayScore)
        XCTAssertEqual(once.penaltyLedger, twice.penaltyLedger)
        XCTAssertEqual(once.streak, twice.streak)
    }
}
