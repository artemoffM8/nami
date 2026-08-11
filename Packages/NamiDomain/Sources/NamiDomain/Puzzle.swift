//
//  Puzzle.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  Модель каталога. `D`, ожидаемое время и версия rater-а — неизменные свойства
//  выпущенной версии каталога и не меняются задним числом (раздел 9.2).
//

import Foundation

public enum DifficultyTier: String, Codable, CaseIterable, Sendable, Comparable {
    case easy, medium, hard, expert, master

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// Продуктовые диапазоны SE Rating (раздел 8.1).
    public var seRange: ClosedRange<Double> {
        switch self {
        case .easy: 1.0...1.6
        case .medium: 1.7...2.5
        case .hard: 2.6...3.7
        case .expert: 3.8...5.3
        case .master: 5.4...99.0
        }
    }

    public static func forSERating(_ rating: Double) -> DifficultyTier {
        allCases.first { $0.seRange.contains(rating) } ?? .master
    }

    public var titleKey: String { "difficulty.\(rawValue).title" }
    public var subtitleKey: String { "difficulty.\(rawValue).subtitle" }
}

public struct Puzzle: Codable, Equatable, Sendable, Identifiable {
    public let schemaVersion: Int
    public let id: String
    /// 81 символ, `0` = пусто.
    public let puzzle: String
    /// Каноническое решение. Используется проверкой и Reveal, но Assistant
    /// не пытается восстановить ответ из hash.
    public let solution: String
    public let solutionHash: String
    public let seRating: Double
    public let workScore: Int
    public let dependencyDepth: Int
    /// Внутренний рейтинг задачи `D` (600...2400).
    public let difficultyD: Int
    public let tier: DifficultyTier
    public let techniques: [String]
    public let givensCount: Int
    public let estimatedMinutes: Int
    public let expectedActiveSecondsP50: Int
    public let dailyEligible: Bool
    public let raterVersion: String
    public let difficultyMappingVersion: String
    public let hintPlanVersion: Int
    public let contentHash: String

    public var requiredTechniques: [SudokuTechnique] {
        techniques.compactMap(SudokuTechnique.from(catalogKey:))
    }

    public func makeBoard() -> BoardState? { BoardState(givens: puzzle) }

    /// Дешёвая проверка целостности записи каталога.
    public func integrityIsPlausible() -> Bool {
        puzzle.count == 81
        && solution.count == 81
        && !solution.contains("0")
        && givensCount == puzzle.filter { $0 != "0" }.count
    }
}

/// Решение задачи, разобранное в цифры один раз.
///
/// Сверка хода с решением — горячий путь ввода: она вызывается на каждую
/// поставленную цифру, а в «Бумаге» — пачкой по всей отложенной серии за один
/// Check. Разбирать строку заново на каждый вызов значило бы аллоцировать
/// массив из 81 элемента прямо там, где игрок ждёт отклика.
///
/// Кэш опасен ровно одним: если он разойдётся со строкой, из которой сделан,
/// приложение начнёт молча принимать неверные ходы и отвергать верные, и ни
/// один экран об этом не скажет. Поэтому разбор живёт рядом с правилом «цифра
/// совпала с решением» и здесь же покрыт тестом — а не приватным полем экрана,
/// куда тесту не дотянуться.
public struct PuzzleSolution: Equatable, Sendable {

    /// `-1` для символа, который цифрой не является: с ним не совпадёт ни одна
    /// цифра 1...9, и повреждённое решение не станет молча «верным».
    private let digits: [Int]

    public init(_ solution: String) {
        self.digits = solution.map { $0.wholeNumberValue ?? -1 }
    }

    /// Сколько клеток описывает решение. У целого каталога — всегда 81.
    public var count: Int { digits.count }

    /// `nil` — такой клетки в решении нет. Это «неизвестно», а не «неверно»:
    /// решать, ошибка это или повреждённые данные, обязан вызывающий.
    public func digit(at cell: Int) -> Int? {
        guard digits.indices.contains(cell) else { return nil }
        return digits[cell]
    }

    /// Совпадает ли цифра с решением в этой клетке.
    public func matches(cell: Int, digit: Int) -> Bool {
        self.digit(at: cell) == digit
    }
}

public struct PuzzleCatalog: Codable, Sendable {
    public let schemaVersion: Int
    public let catalogVersion: String
    public let raterVersion: String
    public let difficultyMappingVersion: String
    public let generatedAt: String
    public let puzzles: [Puzzle]

    public init(schemaVersion: Int, catalogVersion: String, raterVersion: String,
                difficultyMappingVersion: String, generatedAt: String, puzzles: [Puzzle]) {
        self.schemaVersion = schemaVersion
        self.catalogVersion = catalogVersion
        self.raterVersion = raterVersion
        self.difficultyMappingVersion = difficultyMappingVersion
        self.generatedAt = generatedAt
        self.puzzles = puzzles
    }

    public func puzzles(in tier: DifficultyTier) -> [Puzzle] {
        puzzles.filter { $0.tier == tier }
    }

    public func puzzle(id: String) -> Puzzle? {
        puzzles.first { $0.id == id }
    }
}
