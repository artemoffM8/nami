//
//  RatingEngineTests.swift
//  NamiDomainTests
//
//  Created by artemoffM8.
//
//  Критерии приёмки 18, 24, 26, 32 и раздел 9.
//

import XCTest
@testable import NamiDomain

final class RatingEngineTests: XCTestCase {

    private func input(
        rating: Int = 1000,
        difficulty: Int = 1200,
        applied: Int = 20,
        ledger: AssistanceUsageLedger = AssistanceUsageLedger(),
        pace: RatingPaceMode = .disabled,
        speedEligible: Bool = true,
        activeSeconds: Int = 300,
        expected: Int = 600
    ) -> RatingInput {
        RatingInput(currentRating: rating, puzzleDifficulty: difficulty,
                    appliedRatedCount: applied, ledger: ledger, paceMode: pace,
                    speedEligible: speedEligible, activeSeconds: activeSeconds,
                    expectedActiveSecondsP50: expected)
    }

    // Критерий 24: сумма видимых слагаемых равна итоговому ΔR.
    func testBreakdownAlwaysSumsToDelta() {
        let ratings = [600, 700, 1000, 1500, 2400]
        let difficulties = [600, 900, 1200, 2000, 2400]
        let appliedCounts = [0, 6, 30]

        for rating in ratings {
            for difficulty in difficulties {
                for applied in appliedCounts {
                    for strikes in 0...2 {
                        var ledger = AssistanceUsageLedger()
                        ledger.record(candidateAid: .wholeBoard)
                        ledger.record(hintLayer: .candidatesAndLogic)
                        ledger.record(validationAid: .automaticSolutionCheck)
                        for index in 0..<strikes {
                            ledger.registerSolutionMismatch(cell: index, digit: 1)
                        }
                        let result = RatingEngine.evaluate(input(
                            rating: rating, difficulty: difficulty,
                            applied: applied, ledger: ledger
                        ))
                        XCTAssertEqual(result.breakdown.total, result.deltaR,
                                       "R=\(rating) D=\(difficulty) strikes=\(strikes)")
                        XCTAssertGreaterThanOrEqual(result.newRating, 600)
                    }
                }
            }
        }
    }

    // Критерий 18: Classic всегда получает бонус темпа 0, даже при очень быстром решении.
    func testClassicNeverGetsSpeedBonus() {
        let result = RatingEngine.evaluate(input(pace: .disabled, activeSeconds: 60, expected: 600))
        XCTAssertEqual(result.speedCandidate, 0)
        XCTAssertEqual(result.breakdown.speedBonus, 0)
    }

    func testAgainstPersonalBestGivesPositiveBonusOnly() {
        let fast = RatingEngine.evaluate(input(pace: .againstPersonalBest,
                                               activeSeconds: 300, expected: 600))
        XCTAssertEqual(fast.speedCandidate, 3)
        XCTAssertGreaterThan(fast.breakdown.speedBonus, 0)

        let slow = RatingEngine.evaluate(input(pace: .againstPersonalBest,
                                               activeSeconds: 1200, expected: 600))
        XCTAssertEqual(slow.speedCandidate, 0)
        XCTAssertEqual(slow.breakdown.speedBonus, 0)   // не отрицательный, а нулевой
    }

    // Критерий 27: любое gameSuspended снимает право на бонус.
    func testSuspendedAttemptLosesSpeedBonus() {
        let result = RatingEngine.evaluate(input(pace: .timedLimit, speedEligible: false,
                                                 activeSeconds: 200, expected: 600))
        XCTAssertEqual(result.speedCandidate, 0)
    }

    func testStrikeDisablesSpeedBonus() {
        var ledger = AssistanceUsageLedger()
        ledger.registerSolutionMismatch(cell: 0, digit: 5)
        let result = RatingEngine.evaluate(input(ledger: ledger, pace: .againstPersonalBest,
                                                 activeSeconds: 200, expected: 600))
        XCTAssertEqual(result.speedCandidate, 0)
    }

    // Критерий 26: третья подтверждённая ошибка -> practice, но не отрицательный ΔR.
    func testThirdStrikeMakesPracticeWithoutNegativeDelta() {
        var ledger = AssistanceUsageLedger()
        for index in 0..<3 { ledger.registerSolutionMismatch(cell: index, digit: 1) }
        XCTAssertTrue(ledger.isPractice)

        let result = RatingEngine.evaluate(input(ledger: ledger))
        XCTAssertFalse(result.isRanked)
        XCTAssertEqual(result.deltaR, 0)
        XCTAssertEqual(result.reason, .practiceThirdStrike)
    }

    func testRevealMakesUnranked() {
        var ledger = AssistanceUsageLedger()
        ledger.record(hintLayer: .reveal)
        let result = RatingEngine.evaluate(input(ledger: ledger))
        XCTAssertFalse(result.isRanked)
        XCTAssertEqual(result.deltaR, 0)
        XCTAssertEqual(result.reason, .unrankedReveal)
    }

    func testHarderPuzzleGivesPositiveDelta() {
        let result = RatingEngine.evaluate(input(rating: 1000, difficulty: 1400))
        XCTAssertGreaterThan(result.deltaR, 0)
        XCTAssertEqual(result.reason, .harderThanRating)
    }

    /// Самостоятельное решение никогда не уходит в минус: S = 1, а E < 1.
    /// Лёгкая задача просто перестаёт добавлять рейтинг.
    func testEasierPuzzleGivesZeroDeltaAndEasierReason() {
        let result = RatingEngine.evaluate(input(rating: 1600, difficulty: 800))
        XCTAssertEqual(result.deltaR, 0)
        XCTAssertEqual(result.reason, .easierThanRating)
    }

    /// Минус создают только помощь и подтверждённые ошибки.
    func testAssistanceCanProduceNegativeDelta() {
        var ledger = AssistanceUsageLedger()
        ledger.record(candidateAid: .wholeBoard)
        ledger.record(hintLayer: .candidatesAndLogic)
        ledger.registerSolutionMismatch(cell: 0, digit: 3)
        let result = RatingEngine.evaluate(input(rating: 1600, difficulty: 800, ledger: ledger))
        XCTAssertLessThan(result.deltaR, 0)
        XCTAssertTrue([.assistanceReducedResult, .verifiedErrorsReducedResult]
            .contains(result.reason))
    }

    func testDeltaIsAlwaysInsideCaps() {
        for difficulty in stride(from: 600, through: 2400, by: 50) {
            let result = RatingEngine.evaluate(input(rating: 1000, difficulty: difficulty))
            XCTAssertGreaterThanOrEqual(result.deltaR, -12)
            XCTAssertLessThanOrEqual(result.deltaR, 28)
        }
    }

    func testKFactorSchedule() {
        XCTAssertEqual(RatingEngine.kFactor(appliedRatedCount: 0), 48)
        XCTAssertEqual(RatingEngine.kFactor(appliedRatedCount: 4), 48)
        XCTAssertEqual(RatingEngine.kFactor(appliedRatedCount: 5), 32)
        XCTAssertEqual(RatingEngine.kFactor(appliedRatedCount: 14), 32)
        XCTAssertEqual(RatingEngine.kFactor(appliedRatedCount: 15), 20)
    }

    func testAssistCapIsRespected() {
        var ledger = AssistanceUsageLedger()
        ledger.record(candidateAid: .wholeBoard)             // 0.12
        ledger.record(hintLayer: .candidatesAndLogic)        // 0.14
        ledger.record(validationAid: .automaticSolutionCheck) // 0.06
        XCTAssertEqual(ledger.assistPenalty, 0.24, accuracy: 0.0001)
    }

    // Критерий 32: у каждого reason code есть локализуемый ключ.
    func testEveryReasonCodeHasKey() {
        for code in ResultReasonCode.allCases {
            XCTAssertTrue(code.localizationKey.hasPrefix("result.reason."))
        }
    }
}
