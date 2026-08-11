//
//  DojoGenerator.swift
//  Подбор полей, где целевая техника необходима: поле решается логически,
//  техника использована хотя бы раз, ничего сложнее не потребовалось.
//
//  Замеры частоты (на 500 сгенерированных полей):
//    lockedCandidates / nakedPair / hiddenPair — дрилл за 3–80 попыток,
//    xWing — за 170–370 (редкий паттерн), поэтому лимит выше и клюи варьируются.
//

import Foundation

enum DojoGenerator {

    struct Drill {
        let puzzle: [Int?]
        let solution: [Int]
        let technique: SolveTechnique
    }

    /// Синхронный поиск (вызывать с фонового потока).
    static func findDrill(technique: SolveTechnique,
                          seed: UInt64,
                          maxAttempts: Int? = nil) -> Drill? {
        let attempts = maxAttempts ?? (technique == .xWing ? 1500 : 400)
        let clueOptions = clueCounts(for: technique)

        for a in 0..<attempts {
            let s = seed &+ UInt64(a) &* 0x9E37
            let clues = clueOptions[a % clueOptions.count]
            let (puzzle, solution) = SudokuGenerator.generate(
                seed: s, difficulty: nearestDifficulty(clues: clues))
            let report = LogicalSolver(puzzle: puzzle).solve()
            if report.solved,
               report.used.contains(technique),
               report.used.allSatisfy({ $0 <= technique }) {
                return Drill(puzzle: puzzle, solution: solution, technique: technique)
            }
        }
        return nil
    }

    /// Асинхронная обёртка для UI.
    static func findDrillAsync(technique: SolveTechnique,
                               seed: UInt64,
                               completion: @escaping (Drill?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let drill = findDrill(technique: technique, seed: seed)
            DispatchQueue.main.async { completion(drill) }
        }
    }

    private static func clueCounts(for t: SolveTechnique) -> [Int] {
        switch t {
        case .nakedSingle, .hiddenSingle: return [38, 40]
        case .lockedCandidates, .nakedPair: return [28]
        case .hiddenPair: return [26, 27]
        case .xWing: return [24, 25, 26]
        }
    }

    private static func nearestDifficulty(clues: Int) -> SudokuDifficulty {
        switch clues {
        case ..<27: return .expert
        case ..<31: return .hard
        case ..<37: return .medium
        default: return .easy
        }
    }
}
