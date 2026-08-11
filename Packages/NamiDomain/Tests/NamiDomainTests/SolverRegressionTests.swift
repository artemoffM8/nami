//
//  SolverRegressionTests.swift
//  NamiDomainTests
//
//  Created by artemoffM8.
//
//  Swift-солвер обязан совпадать с эталонным Python-rater-ом
//  (ContentTools/python/nami_sudoku.py, версия `nami-human-1`), которым
//  размечен бандлированный каталог. Эти значения взяты прямо из classic.json.
//
//  Если тест упал — разошлись две реализации ОДНОГО алгоритма.
//  Чинить нужно ту, что отклонилась, а не подгонять ожидание.
//

import XCTest
@testable import NamiDomain

final class SolverRegressionTests: XCTestCase {

    struct Case {
        let puzzle: String
        let seRating: Double
        let workScore: Int
        let dependencyDepth: Int

        init(_ puzzle: String, _ seRating: Double, _ workScore: Int, _ dependencyDepth: Int) {
            self.puzzle = puzzle
            self.seRating = seRating
            self.workScore = workScore
            self.dependencyDepth = dependencyDepth
        }
    }

    /// По три задачи из каждого тира.
    /// По три задачи из каждого тира. Значения пересняты после появления
    /// «прямых» техник: часть задач решается дешевле, чем раньше.
    static let cases: [Case] = [
        Case("020065009006900001918000000007004085000803000890600300000000953200006400500340020", 1.5, 529, 28),
        Case("050600381001020750000003000060980005487050000500004008000200000900001536010007040", 1.2, 504, 36),
        Case("408000903000020700000400012900000400003594200002000008260008000007050000109000307", 1.5, 547, 35),
        Case("001000000800002307050081900070050000009000283000000000283700400000000050400100009", 2.0, 629, 33),
        Case("050140098000500600700283004006000500000305000004000300100728003003009000690031070", 2.0, 515, 34),
        Case("000000000028040030150032400005700610009080300074003200001370052030050190000000000", 2.0, 552, 30),
        Case("000400200140005708000000049400209060806000903020608001380000000704100082001007000", 2.0, 568, 32),
        Case("000000200200869005080027000002605009007080600800701300000910030500374008009000000", 2.0, 559, 31),
        Case("005000002000291040000000800406080000300010006950040000060309020230005000001800030", 2.5, 596, 37),
        Case("308600100090002003000000000500208600003104900006907004000000000100700060005009308", 4.2, 981, 35),
        Case("200000730070020690000470200420950000003000500000063019007031000062080040038000005", 4.2, 676, 40),
        Case("070820000005001002010005000630009200501000906002500014000300080800900100000068030", 4.2, 933, 34),
        Case("370020105090000000005007008009000000010506300050700080430160000900080710501003602", 6.6, 828, 33),
        Case("400000200000620109000009438000097000360000072000260000273800000609031000004000006", 6.6, 743, 29),
        Case("000000032000903000000060409002008300014000000573400000060701000000540026400000000", 6.6, 846, 32)
    ]

    func testHumanSolverMatchesReferenceRater() {
        for item in Self.cases {
            let trace = HumanSolver.solve(givens: item.puzzle)
            XCTAssertEqual(trace.status, .solved, "не решено: \(item.puzzle)")
            XCTAssertEqual(trace.seRating, item.seRating, accuracy: 0.001,
                           "seRating разошёлся: \(item.puzzle)")
            XCTAssertEqual(trace.workScore, item.workScore,
                           "workScore разошёлся: \(item.puzzle)")
            XCTAssertEqual(trace.dependencyDepth, item.dependencyDepth,
                           "dependencyDepth разошёлся: \(item.puzzle)")
        }
    }

    func testCatalogPuzzlesHaveUniqueSolution() {
        for item in Self.cases {
            let outcome = ExactSolver.solve(item.puzzle, limit: 2)
            XCTAssertEqual(outcome.solutionCount, 1, "не единственное решение: \(item.puzzle)")
        }
    }

    func testTierBoundariesMatchProductSpec() {
        XCTAssertEqual(DifficultyTier.forSERating(1.2), .easy)
        XCTAssertEqual(DifficultyTier.forSERating(2.3), .medium)
        XCTAssertEqual(DifficultyTier.forSERating(3.0), .hard)
        XCTAssertEqual(DifficultyTier.forSERating(4.2), .expert)
        XCTAssertEqual(DifficultyTier.forSERating(6.6), .master)
    }

    /// Каталог не содержит задач, требующих перебора (раздел 8.2).
    func testNoGuessingRequired() {
        for item in Self.cases {
            XCTAssertNotEqual(HumanSolver.solve(givens: item.puzzle).status, .unsolvable)
        }
    }
}
