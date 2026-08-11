//
//  SudokuGenerator.swift
//  Детерминированный генератор: один seed -> одна и та же партия на любом
//  устройстве (основа "утренней партии" без сервера).
//  Гарантирует единственность решения. Удаление симметричное (180°) — поля
//  выглядят "как из журнала".
//

import Foundation

// MARK: - Seed-управляемый RNG (SplitMix64)

struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Сложность

enum SudokuDifficulty: String, CaseIterable {
    case easy, medium, hard, expert

    /// Сколько подсказок оставляем на поле.
    var targetClues: Int {
        switch self {
        case .easy: return 40
        case .medium: return 34
        case .hard: return 28
        case .expert: return 24
        }
    }

    var displayName: String {
        switch self {
        case .easy: return "Лёгкая"
        case .medium: return "Средняя"
        case .hard: return "Сложная"
        case .expert: return "Эксперт"
        }
    }
}

// MARK: - Генератор

enum SudokuGenerator {

    /// Возвращает (пазл с nil в пустых ячейках, полное решение).
    static func generate(seed: UInt64,
                         difficulty: SudokuDifficulty) -> (puzzle: [Int?], solution: [Int]) {
        var rng = SeededRNG(seed: seed)

        // 1. Полное валидное решение
        var solution = [Int](repeating: 0, count: 81)
        _ = fill(&solution, index: 0, rng: &rng)

        // 2. Симметричное удаление с проверкой единственности
        var puzzle: [Int?] = solution.map { $0 }
        var clues = 81
        var pairs: [(Int, Int)] = (0..<40).map { ($0, 80 - $0) }
        pairs.shuffle(using: &rng)
        var order: [[Int]] = pairs.map { [$0.0, $0.1] }
        order.append([40]) // центр — сам себе пара
        order.shuffle(using: &rng)

        for group in order {
            guard clues - group.count >= difficulty.targetClues else { continue }
            let backup = group.map { puzzle[$0] }
            for i in group { puzzle[i] = nil }
            if countSolutions(puzzle, limit: 2) == 1 {
                clues -= group.count
            } else {
                for (k, i) in group.enumerated() { puzzle[i] = backup[k] }
            }
            if clues <= difficulty.targetClues { break }
        }
        return (puzzle, solution)
    }

    // MARK: Заполнение (backtracking с перемешанными кандидатами)

    private static func fill(_ board: inout [Int], index: Int,
                             rng: inout SeededRNG) -> Bool {
        if index == 81 { return true }
        var digits = Array(1...9)
        digits.shuffle(using: &rng)
        for d in digits where isValid(board, index: index, digit: d) {
            board[index] = d
            if fill(&board, index: index + 1, rng: &rng) { return true }
            board[index] = 0
        }
        return false
    }

    private static func isValid(_ board: [Int], index: Int, digit: Int) -> Bool {
        let row = index / 9, col = index % 9
        for i in 0..<9 {
            if board[row * 9 + i] == digit { return false }
            if board[i * 9 + col] == digit { return false }
        }
        let r0 = row / 3 * 3, c0 = col / 3 * 3
        for r in r0..<(r0 + 3) {
            for c in c0..<(c0 + 3) where board[r * 9 + c] == digit { return false }
        }
        return true
    }

    // MARK: Подсчёт решений (битовые маски + MRV, с ранним выходом)

    static func countSolutions(_ puzzle: [Int?], limit: Int) -> Int {
        var rows = [Int](repeating: 0, count: 9)
        var cols = [Int](repeating: 0, count: 9)
        var boxes = [Int](repeating: 0, count: 9)
        var board = [Int](repeating: 0, count: 81)

        for i in 0..<81 {
            if let d = puzzle[i] {
                let bit = 1 << d
                let r = i / 9, c = i % 9, b = r / 3 * 3 + c / 3
                if rows[r] & bit != 0 || cols[c] & bit != 0 || boxes[b] & bit != 0 {
                    return 0 // противоречивое поле
                }
                rows[r] |= bit; cols[c] |= bit; boxes[b] |= bit
                board[i] = d
            }
        }
        var count = 0
        solveCount(&board, &rows, &cols, &boxes, limit: limit, count: &count)
        return count
    }

    private static func solveCount(_ board: inout [Int],
                                   _ rows: inout [Int], _ cols: inout [Int],
                                   _ boxes: inout [Int],
                                   limit: Int, count: inout Int) {
        if count >= limit { return }

        // MRV: пустая ячейка с минимумом кандидатов
        var bestIdx = -1, bestMask = 0, bestCount = 10
        for i in 0..<81 where board[i] == 0 {
            let r = i / 9, c = i % 9, b = r / 3 * 3 + c / 3
            let used = rows[r] | cols[c] | boxes[b]
            let mask = ~used & 0b111_1111_1110
            let n = mask.nonzeroBitCount
            if n == 0 { return }        // тупик
            if n < bestCount { bestCount = n; bestIdx = i; bestMask = mask
                if n == 1 { break } }
        }
        if bestIdx == -1 { count += 1; return } // всё заполнено — решение

        let r = bestIdx / 9, c = bestIdx % 9, b = r / 3 * 3 + c / 3
        var mask = bestMask
        while mask != 0 {
            let bit = mask & -mask
            mask &= mask - 1
            let d = bit.trailingZeroBitCount
            board[bestIdx] = d
            rows[r] |= bit; cols[c] |= bit; boxes[b] |= bit
            solveCount(&board, &rows, &cols, &boxes, limit: limit, count: &count)
            board[bestIdx] = 0
            rows[r] &= ~bit; cols[c] &= ~bit; boxes[b] &= ~bit
            if count >= limit { return }
        }
    }
}
