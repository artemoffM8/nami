//
//  ExactSolver.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  Битмаск-перебор с MRV. Используется для проверки единственности решения
//  и подтверждения целостности каталога. На устройстве вызывается редко:
//  тяжёлый SERater на телефоне не запускается (раздел 13.4).
//

import Foundation

public enum ExactSolver {

    public struct Outcome: Equatable, Sendable {
        public let solutionCount: Int   // 0, 1 или 2 («2» = «два и более»)
        public let firstSolution: String?

        public var isUnique: Bool { solutionCount == 1 }
    }

    /// Считает решения до `limit` штук.
    public static func solve(_ givens: String, limit: Int = 2) -> Outcome {
        guard givens.count == BoardTopology.cellCount else {
            return Outcome(solutionCount: 0, firstSolution: nil)
        }
        var values = [UInt8](repeating: 0, count: 81)
        var candidates = [DigitMask](repeating: Digits.all, count: 81)

        for (index, ch) in givens.enumerated() {
            guard ch != "0", ch != "." else { continue }
            guard let d = ch.wholeNumberValue, (1...9).contains(d) else {
                return Outcome(solutionCount: 0, firstSolution: nil)
            }
            if !assign(&values, &candidates, index, d) {
                return Outcome(solutionCount: 0, firstSolution: nil)
            }
        }

        var solutions: [String] = []
        search(&values, &candidates, limit: limit, solutions: &solutions)
        return Outcome(solutionCount: solutions.count, firstSolution: solutions.first)
    }

    public static func solution(for givens: String) -> String? {
        let outcome = solve(givens, limit: 1)
        return outcome.firstSolution
    }

    // MARK: - Internals

    private static func assign(
        _ values: inout [UInt8],
        _ candidates: inout [DigitMask],
        _ index: Int,
        _ digit: Int
    ) -> Bool {
        guard candidates[index] & Digits.bit(digit) != 0 || values[index] == UInt8(digit) else {
            return false
        }
        values[index] = UInt8(digit)
        candidates[index] = 0
        let bit = Digits.bit(digit)
        for peer in BoardTopology.peers[index] {
            if candidates[peer] & bit != 0 {
                candidates[peer] &= ~bit
                if values[peer] == 0 && candidates[peer] == 0 { return false }
            } else if values[peer] == UInt8(digit) {
                return false
            }
        }
        return true
    }

    private static func search(
        _ values: inout [UInt8],
        _ candidates: inout [DigitMask],
        limit: Int,
        solutions: inout [String]
    ) {
        if solutions.count >= limit { return }

        var best = -1
        var bestCount = 10
        for index in 0..<81 where values[index] == 0 {
            let count = Digits.count(candidates[index])
            if count == 0 { return }
            if count < bestCount {
                best = index
                bestCount = count
                if count == 1 { break }
            }
        }
        if best < 0 {
            solutions.append(String(values.map { Character(String($0)) }))
            return
        }

        let options = candidates[best]
        var mask = options
        while mask != 0 {
            let digit = mask.trailingZeroBitCount
            mask &= mask - 1
            var nextValues = values
            var nextCandidates = candidates
            if assign(&nextValues, &nextCandidates, best, digit) {
                search(&nextValues, &nextCandidates, limit: limit, solutions: &solutions)
                if solutions.count >= limit { return }
            }
        }
    }
}
