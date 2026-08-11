//
//  HumanSolver.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  On-device solver, который строит следующий человеческий шаг ЗАНОВО из
//  текущей позиции (раздел 8.3). Offline solve trace сертифицирует сложность,
//  но не является источником подсказки: игрок мог уйти от него.
//
//  Ручные заметки НЕ используются как ограничение — ошибочная заметка не должна
//  прятать валидный ход. Они передаются наверх только как контекст объяснения.
//
//  ВАЖНО: алгоритм построчно совпадает с эталоном
//  ContentTools/python/nami_sudoku.py (raterVersion `nami-human-1`).
//

import Foundation

public struct Elimination: Equatable, Sendable, Hashable, Comparable {
    public let cell: Int
    public let digit: Int

    public init(cell: Int, digit: Int) {
        self.cell = cell
        self.digit = digit
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.cell == rhs.cell ? lhs.digit < rhs.digit : lhs.cell < rhs.cell
    }
}

public struct Placement: Equatable, Sendable {
    public let cell: Int
    public let digit: Int

    public init(cell: Int, digit: Int) {
        self.cell = cell
        self.digit = digit
    }
}

public struct SolveStep: Equatable, Sendable {
    public let technique: SudokuTechnique
    public let placement: Placement?
    public let eliminations: [Elimination]
    /// Клетки, состояние которых использовалось для вывода — «область» слоя 1 подсказки.
    public let premises: [Int]
    /// Клетки, изменённые применением шага. Заполняется при применении.
    public internal(set) var produced: [Int]
    /// Юнит, который стоит подсветить на слое «область», если он один.
    public let focusUnit: Int?

    public var rating: Double { technique.rating }
    public var weight: Int { technique.weight }
}

public enum SolveStatus: String, Sendable, Codable {
    case solved, contradiction, unsolvable
}

public struct SolveTrace: Sendable {
    public let status: SolveStatus
    public let steps: [SolveStep]
    public let seRating: Double
    public let workScore: Int
    public let dependencyDepth: Int
    public let techniques: [SudokuTechnique]
}

/// Рабочая сетка солвера: значения + персистентные кандидаты.
/// Исключения кандидатов сохраняются между шагами — иначе Naked Pair
/// не подготовил бы почву для последующего Hidden Single.
public struct SolverGrid: Sendable {
    public private(set) var values: [UInt8]
    public private(set) var candidates: [DigitMask]

    /// Строится ТОЛЬКО из поставленных цифр. Ручные заметки игнорируются.
    public init(board: BoardState) {
        values = [UInt8](repeating: 0, count: 81)
        candidates = [DigitMask](repeating: 0, count: 81)
        for index in 0..<81 { values[index] = board[index].value }
        for index in 0..<81 where values[index] == 0 {
            var mask = Digits.all
            for peer in BoardTopology.peers[index] {
                let v = values[peer]
                if v != 0 { mask &= ~Digits.bit(Int(v)) }
            }
            candidates[index] = mask
        }
    }

    public init?(givens: String) {
        guard let board = BoardState(givens: givens) else { return nil }
        self.init(board: board)
    }

    @discardableResult
    mutating func place(_ digit: Int, at cell: Int) -> [Int] {
        values[cell] = UInt8(digit)
        candidates[cell] = 0
        var touched = [cell]
        let bit = Digits.bit(digit)
        for peer in BoardTopology.peers[cell] where candidates[peer] & bit != 0 {
            candidates[peer] &= ~bit
            touched.append(peer)
        }
        return touched
    }

    mutating func eliminate(_ elimination: Elimination) {
        candidates[elimination.cell] &= ~Digits.bit(elimination.digit)
    }

    var isSolved: Bool {
        for v in values where v == 0 { return false }
        return true
    }

    var hasContradiction: Bool {
        for index in 0..<81 where values[index] == 0 && candidates[index] == 0 { return true }
        for unit in BoardTopology.units {
            var seen: DigitMask = 0
            for cell in unit {
                let v = values[cell]
                guard v != 0 else { continue }
                let bit = Digits.bit(Int(v))
                if seen & bit != 0 { return true }
                seen |= bit
            }
            var available: DigitMask = 0
            for cell in unit { available |= candidates[cell] }
            let missing = Digits.all & ~seen
            if missing & ~available != 0 { return true }
        }
        return false
    }
}

public enum HumanSolver {

    public static let raterVersion = "nami-human-1"
    public static let maxSteps = 400

    // MARK: - Публичный API

    /// Следующий логический шаг из ТЕКУЩЕЙ позиции. Основа многоступенчатой подсказки.
    /// На противоречивой доске возвращает `nil` — подсказка обязана предложить
    /// сначала найти конфликт и не раскрывать trace (критерий приёмки 37).
    public static func nextStep(board: BoardState) -> SolveStep? {
        var grid = SolverGrid(board: board)
        if grid.isSolved || grid.hasContradiction { return nil }
        return findStep(in: &grid)
    }

    /// Полный проход. Используется в тестах и в ContentTools.
    public static func solve(board: BoardState) -> SolveTrace {
        var grid = SolverGrid(board: board)
        var steps: [SolveStep] = []

        while steps.count < maxSteps {
            if grid.isSolved { return finish(.solved, steps) }
            if grid.hasContradiction { return finish(.contradiction, steps) }
            guard var step = findStep(in: &grid) else { return finish(.unsolvable, steps) }

            if let placement = step.placement {
                step.produced = grid.place(placement.digit, at: placement.cell)
            } else {
                var touched = Set<Int>()
                for elimination in step.eliminations {
                    grid.eliminate(elimination)
                    touched.insert(elimination.cell)
                }
                step.produced = touched.sorted()
            }
            steps.append(step)
        }
        return finish(.unsolvable, steps)
    }

    public static func solve(givens: String) -> SolveTrace {
        guard let board = BoardState(givens: givens) else {
            return SolveTrace(status: .contradiction, steps: [], seRating: 0,
                              workScore: 0, dependencyDepth: 0, techniques: [])
        }
        return solve(board: board)
    }

    // MARK: - Поиск шага

    static func findStep(in grid: inout SolverGrid) -> SolveStep? {
        for technique in SudokuTechnique.allCases {
            if let step = find(technique, in: grid) { return step }
        }
        return nil
    }

    static func find(_ technique: SudokuTechnique, in grid: SolverGrid) -> SolveStep? {
        switch technique {
        case .fullHouse: fullHouse(grid)
        case .hiddenSingleBox: hiddenSingle(grid, units: 18..<27, technique: .hiddenSingleBox)
        case .hiddenSingleLine: hiddenSingle(grid, units: 0..<18, technique: .hiddenSingleLine)
        case .directPointing: directIntersection(grid)
        case .directHiddenPair: directHiddenSubset(grid, size: 2, technique: .directHiddenPair)
        case .nakedSingle: nakedSingle(grid)
        case .directHiddenTriple: directHiddenSubset(grid, size: 3, technique: .directHiddenTriple)
        case .pointing: pointing(grid)
        case .claiming: claiming(grid)
        case .nakedPair: nakedSubset(grid, size: 2, technique: .nakedPair)
        case .xWing: fish(grid, size: 2, technique: .xWing)
        case .hiddenPair: hiddenSubset(grid, size: 2, technique: .hiddenPair)
        case .nakedTriple: nakedSubset(grid, size: 3, technique: .nakedTriple)
        case .swordfish: fish(grid, size: 3, technique: .swordfish)
        case .hiddenTriple: hiddenSubset(grid, size: 3, technique: .hiddenTriple)
        case .xyWing: xyWing(grid)
        case .xyzWing: xyzWing(grid)
        case .nakedQuad: nakedSubset(grid, size: 4, technique: .nakedQuad)
        case .jellyfish: fish(grid, size: 4, technique: .jellyfish)
        case .hiddenQuad: hiddenSubset(grid, size: 4, technique: .hiddenQuad)
        case .turbotFish: turbotFish(grid)
        }
    }

    // MARK: - Конструкторы шагов

    private static func placementStep(
        _ technique: SudokuTechnique,
        cell: Int,
        digit: Int,
        premises: [Int],
        focusUnit: Int?
    ) -> SolveStep {
        var set = Set(premises)
        set.insert(cell)
        return SolveStep(
            technique: technique,
            placement: Placement(cell: cell, digit: digit),
            eliminations: [],
            premises: set.sorted(),
            produced: [],
            focusUnit: focusUnit
        )
    }

    private static func eliminationStep(
        _ technique: SudokuTechnique,
        eliminations: [Elimination],
        premises: [Int],
        focusUnit: Int?
    ) -> SolveStep {
        SolveStep(
            technique: technique,
            placement: nil,
            eliminations: Array(Set(eliminations)).sorted(),
            premises: Set(premises).sorted(),
            produced: [],
            focusUnit: focusUnit
        )
    }

    // MARK: - Техники размещения

    private static func fullHouse(_ grid: SolverGrid) -> SolveStep? {
        for unitIndex in 0..<27 {
            let unit = BoardTopology.units[unitIndex]
            var empty: [Int] = []
            for cell in unit where grid.values[cell] == 0 { empty.append(cell) }
            guard empty.count == 1 else { continue }
            let cell = empty[0]
            guard let digit = Digits.single(grid.candidates[cell]) else { continue }
            return placementStep(.fullHouse, cell: cell, digit: digit,
                                 premises: unit, focusUnit: unitIndex)
        }
        return nil
    }

    private static func hiddenSingle(
        _ grid: SolverGrid,
        units range: Range<Int>,
        technique: SudokuTechnique
    ) -> SolveStep? {
        for unitIndex in range {
            let unit = BoardTopology.units[unitIndex]
            var placed: DigitMask = 0
            for cell in unit {
                let v = grid.values[cell]
                if v != 0 { placed |= Digits.bit(Int(v)) }
            }
            for digit in 1...9 where placed & Digits.bit(digit) == 0 {
                let bit = Digits.bit(digit)
                var spots: [Int] = []
                for cell in unit where grid.candidates[cell] & bit != 0 { spots.append(cell) }
                if spots.count == 1 {
                    return placementStep(technique, cell: spots[0], digit: digit,
                                         premises: unit, focusUnit: unitIndex)
                }
            }
        }
        return nil
    }

    private static func nakedSingle(_ grid: SolverGrid) -> SolveStep? {
        for cell in 0..<81 where grid.values[cell] == 0 {
            if let digit = Digits.single(grid.candidates[cell]) {
                return placementStep(.nakedSingle, cell: cell, digit: digit,
                                     premises: BoardTopology.peers[cell], focusUnit: nil)
            }
        }
        return nil
    }

    // MARK: - Locked candidates

    // MARK: - «Прямые» техники

    // В Sudoku Explainer исключение, которое СРАЗУ открывает скрытого одиночку,
    // стоит дешевле того же исключения самого по себе: игрок не держит в голове
    // отложенный вывод, он видит цифру немедленно. Отсюда 1.7 против 2.6
    // у Pointing и 2.0 против 3.4 у Hidden Pair.
    //
    // Проверка корректна потому, что на момент вызова скрытых одиночек на доске
    // уже нет — техники 1.2 и 1.5 отработали раньше. Значит появившийся после
    // исключений одиночка открыт именно ими.

    /// Первый скрытый одиночка в перечисленных единицах.
    private static func hiddenSingle(
        candidates: [DigitMask],
        values: [UInt8],
        units: [Int]
    ) -> (cell: Int, digit: Int)? {
        for unitIndex in units {
            let unit = BoardTopology.units[unitIndex]
            var placed: DigitMask = 0
            for cell in unit where values[cell] != 0 {
                placed |= Digits.bit(Int(values[cell]))
            }
            for digit in 1...9 {
                let bit = Digits.bit(digit)
                if placed & bit != 0 { continue }
                var spot = -1
                var count = 0
                for cell in unit where candidates[cell] & bit != 0 {
                    spot = cell
                    count += 1
                    if count > 1 { break }
                }
                if count == 1 { return (spot, digit) }
            }
        }
        return nil
    }

    /// Шаг-«прямая»: возвращает ПОСТАНОВКУ, если исключения открывают одиночку.
    /// Именно немедленный результат отличает технику от её обычного варианта.
    private static func directStep(
        _ grid: SolverGrid,
        eliminations: [Elimination],
        technique: SudokuTechnique,
        premises: [Int],
        focusUnit: Int?
    ) -> SolveStep? {
        var trial = grid.candidates
        var touched = Set<Int>()
        for elimination in eliminations {
            trial[elimination.cell] &= ~Digits.bit(elimination.digit)
            touched.formUnion(BoardTopology.unitsOfCell[elimination.cell])
        }
        guard let found = hiddenSingle(candidates: trial,
                                       values: grid.values,
                                       units: touched.sorted())
        else { return nil }
        return placementStep(technique, cell: found.cell, digit: found.digit,
                             premises: premises, focusUnit: focusUnit)
    }

    /// Только box -> line: у SE «прямым» считается именно указывающая пара.
    private static func directIntersection(_ grid: SolverGrid) -> SolveStep? {
        for box in 0..<9 {
            let boxCells = BoardTopology.units[18 + box]
            for digit in 1...9 {
                let bit = Digits.bit(digit)
                var spots: [Int] = []
                for cell in boxCells where grid.candidates[cell] & bit != 0 { spots.append(cell) }
                guard spots.count >= 2 else { continue }

                let rows = Set(spots.map { BoardTopology.rowOf[$0] })
                let columns = Set(spots.map { BoardTopology.columnOf[$0] })
                let line: [Int]
                if rows.count == 1 { line = BoardTopology.units[rows.first!] }
                else if columns.count == 1 { line = BoardTopology.units[9 + columns.first!] }
                else { continue }

                var eliminations: [Elimination] = []
                for cell in line where BoardTopology.boxOf[cell] != box
                    && grid.candidates[cell] & bit != 0 {
                    eliminations.append(Elimination(cell: cell, digit: digit))
                }
                guard !eliminations.isEmpty else { continue }
                if let step = directStep(grid, eliminations: eliminations,
                                         technique: .directPointing,
                                         premises: spots + eliminations.map(\.cell),
                                         focusUnit: 18 + box) {
                    return step
                }
            }
        }
        return nil
    }

    private static func directHiddenSubset(
        _ grid: SolverGrid,
        size: Int,
        technique: SudokuTechnique
    ) -> SolveStep? {
        for unitIndex in 0..<27 {
            let unit = BoardTopology.units[unitIndex]
            // Порядок перебора повторяет Python-эталон: свободные цифры
            // юнита, а не только те, что уже помещаются в подмножество.
            var free: [Int] = []
            for digit in 1...9
            where !unit.contains(where: { grid.values[$0] == UInt8(digit) }) {
                free.append(digit)
            }
            guard free.count >= size else { continue }

            var found: SolveStep?
            Combinations.forEach(free, choose: size) { combo in
                guard found == nil else { return false }
                var cells = Set<Int>()
                var keep: DigitMask = 0
                for digit in combo {
                    let bit = Digits.bit(digit)
                    var places: [Int] = []
                    for cell in unit where grid.candidates[cell] & bit != 0 { places.append(cell) }
                    if places.isEmpty { return true }
                    cells.formUnion(places)
                    keep |= bit
                }
                guard cells.count == size else { return true }

                var eliminations: [Elimination] = []
                for cell in cells.sorted() {
                    let extra = grid.candidates[cell] & ~keep
                    Digits.forEach(extra) { eliminations.append(Elimination(cell: cell, digit: $0)) }
                }
                guard !eliminations.isEmpty else { return true }
                if let step = directStep(grid, eliminations: eliminations,
                                         technique: technique,
                                         premises: cells.sorted() + eliminations.map(\.cell),
                                         focusUnit: unitIndex) {
                    found = step
                    return false
                }
                return true
            }
            if let found { return found }
        }
        return nil
    }

    private static func pointing(_ grid: SolverGrid) -> SolveStep? {
        for box in 0..<9 {
            let boxCells = BoardTopology.units[18 + box]
            for digit in 1...9 {
                let bit = Digits.bit(digit)
                var spots: [Int] = []
                for cell in boxCells where grid.candidates[cell] & bit != 0 { spots.append(cell) }
                guard spots.count >= 2 else { continue }

                let rows = Set(spots.map { BoardTopology.rowOf[$0] })
                let columns = Set(spots.map { BoardTopology.columnOf[$0] })
                let line: [Int]
                if rows.count == 1 { line = BoardTopology.units[rows.first!] }
                else if columns.count == 1 { line = BoardTopology.units[9 + columns.first!] }
                else { continue }

                var eliminations: [Elimination] = []
                for cell in line where BoardTopology.boxOf[cell] != box
                    && grid.candidates[cell] & bit != 0 {
                    eliminations.append(Elimination(cell: cell, digit: digit))
                }
                if !eliminations.isEmpty {
                    return eliminationStep(.pointing, eliminations: eliminations,
                                           premises: spots + eliminations.map(\.cell),
                                           focusUnit: 18 + box)
                }
            }
        }
        return nil
    }

    private static func claiming(_ grid: SolverGrid) -> SolveStep? {
        for lineIndex in 0..<18 {
            let line = BoardTopology.units[lineIndex]
            for digit in 1...9 {
                let bit = Digits.bit(digit)
                var spots: [Int] = []
                for cell in line where grid.candidates[cell] & bit != 0 { spots.append(cell) }
                guard spots.count >= 2 else { continue }
                let boxes = Set(spots.map { BoardTopology.boxOf[$0] })
                guard boxes.count == 1, let box = boxes.first else { continue }

                let lineSet = Set(line)
                var eliminations: [Elimination] = []
                for cell in BoardTopology.units[18 + box]
                where !lineSet.contains(cell) && grid.candidates[cell] & bit != 0 {
                    eliminations.append(Elimination(cell: cell, digit: digit))
                }
                if !eliminations.isEmpty {
                    return eliminationStep(.claiming, eliminations: eliminations,
                                           premises: spots + eliminations.map(\.cell),
                                           focusUnit: lineIndex)
                }
            }
        }
        return nil
    }

    // MARK: - Subsets

    private static func nakedSubset(
        _ grid: SolverGrid,
        size: Int,
        technique: SudokuTechnique
    ) -> SolveStep? {
        for unitIndex in 0..<27 {
            let unit = BoardTopology.units[unitIndex]
            var cells: [Int] = []
            for cell in unit where grid.values[cell] == 0 {
                let count = Digits.count(grid.candidates[cell])
                if count >= 2 && count <= size { cells.append(cell) }
            }
            guard cells.count > size else { continue }

            var found: SolveStep?
            Combinations.forEach(cells, choose: size) { combo in
                guard found == nil else { return false }
                var mask: DigitMask = 0
                for cell in combo { mask |= grid.candidates[cell] }
                guard Digits.count(mask) == size else { return true }

                var eliminations: [Elimination] = []
                let comboSet = Set(combo)
                for cell in unit where !comboSet.contains(cell) && grid.values[cell] == 0 {
                    let intersection = grid.candidates[cell] & mask
                    Digits.forEach(intersection) {
                        eliminations.append(Elimination(cell: cell, digit: $0))
                    }
                }
                if !eliminations.isEmpty {
                    found = eliminationStep(technique, eliminations: eliminations,
                                            premises: combo + eliminations.map(\.cell),
                                            focusUnit: unitIndex)
                    return false
                }
                return true
            }
            if let found { return found }
        }
        return nil
    }

    private static func hiddenSubset(
        _ grid: SolverGrid,
        size: Int,
        technique: SudokuTechnique
    ) -> SolveStep? {
        for unitIndex in 0..<27 {
            let unit = BoardTopology.units[unitIndex]
            var digits: [Int] = []
            var positions: [Int: [Int]] = [:]
            for digit in 1...9 {
                let bit = Digits.bit(digit)
                var spots: [Int] = []
                for cell in unit where grid.candidates[cell] & bit != 0 { spots.append(cell) }
                if !spots.isEmpty && spots.count <= size {
                    digits.append(digit)
                    positions[digit] = spots
                }
            }
            guard digits.count >= size else { continue }

            var found: SolveStep?
            Combinations.forEach(digits, choose: size) { combo in
                guard found == nil else { return false }
                var cells = Set<Int>()
                var keep: DigitMask = 0
                for digit in combo {
                    cells.formUnion(positions[digit] ?? [])
                    keep |= Digits.bit(digit)
                }
                guard cells.count == size else { return true }

                var eliminations: [Elimination] = []
                for cell in cells.sorted() {
                    let extra = grid.candidates[cell] & ~keep
                    Digits.forEach(extra) { eliminations.append(Elimination(cell: cell, digit: $0)) }
                }
                if !eliminations.isEmpty {
                    found = eliminationStep(technique, eliminations: eliminations,
                                            premises: cells.sorted(), focusUnit: unitIndex)
                    return false
                }
                return true
            }
            if let found { return found }
        }
        return nil
    }

    // MARK: - Fish

    private static func fish(
        _ grid: SolverGrid,
        size: Int,
        technique: SudokuTechnique
    ) -> SolveStep? {
        for digit in 1...9 {
            let bit = Digits.bit(digit)
            for baseIsRow in [true, false] {
                let offset = baseIsRow ? 0 : 9
                var lines: [(id: Int, spots: [Int])] = []
                for lineIndex in 0..<9 {
                    var spots: [Int] = []
                    for cell in BoardTopology.units[offset + lineIndex]
                    where grid.candidates[cell] & bit != 0 { spots.append(cell) }
                    if spots.count >= 2 && spots.count <= size {
                        lines.append((lineIndex, spots))
                    }
                }
                guard lines.count >= size else { continue }

                var found: SolveStep?
                Combinations.forEach(Array(lines.indices), choose: size) { comboIndices in
                    guard found == nil else { return false }
                    var cover = Set<Int>()
                    var baseIDs = Set<Int>()
                    var premises: [Int] = []
                    for i in comboIndices {
                        baseIDs.insert(lines[i].id)
                        for cell in lines[i].spots {
                            cover.insert(baseIsRow ? BoardTopology.columnOf[cell]
                                                   : BoardTopology.rowOf[cell])
                            premises.append(cell)
                        }
                    }
                    guard cover.count == size else { return true }

                    var eliminations: [Elimination] = []
                    for x in cover.sorted() {
                        let cross = BoardTopology.units[(baseIsRow ? 9 : 0) + x]
                        for cell in cross {
                            let lineID = baseIsRow ? BoardTopology.rowOf[cell]
                                                   : BoardTopology.columnOf[cell]
                            if baseIDs.contains(lineID) { continue }
                            if grid.candidates[cell] & bit != 0 {
                                eliminations.append(Elimination(cell: cell, digit: digit))
                            }
                        }
                    }
                    if !eliminations.isEmpty {
                        found = eliminationStep(technique, eliminations: eliminations,
                                                premises: premises + eliminations.map(\.cell),
                                                focusUnit: nil)
                        return false
                    }
                    return true
                }
                if let found { return found }
            }
        }
        return nil
    }

    // MARK: - Wings

    private static func xyWing(_ grid: SolverGrid) -> SolveStep? {
        var bivalue: [Int] = []
        for cell in 0..<81 where grid.values[cell] == 0
            && Digits.count(grid.candidates[cell]) == 2 { bivalue.append(cell) }
        let bivalueSet = Set(bivalue)

        for pivot in bivalue {
            let pivotDigits = Digits.list(grid.candidates[pivot])
            let a = pivotDigits[0], b = pivotDigits[1]
            let wings = BoardTopology.peers[pivot].filter { bivalueSet.contains($0) }
            for i in 0..<wings.count {
                for j in (i + 1)..<wings.count {
                    let w1 = wings[i], w2 = wings[j]
                    let m1 = grid.candidates[w1], m2 = grid.candidates[w2]
                    if m1 == m2 { continue }
                    for (x, y) in [(a, b), (b, a)] {
                        let bx = Digits.bit(x), by = Digits.bit(y)
                        guard m1 & bx != 0, m1 & by == 0 else { continue }
                        guard m2 & by != 0, m2 & bx == 0 else { continue }
                        let common = m1 & m2 & ~(bx | by)
                        guard let z = Digits.single(common) else { continue }
                        let bz = Digits.bit(z)
                        let seers = BoardTopology.peerSets[w1]
                            .intersection(BoardTopology.peerSets[w2])
                        var eliminations: [Elimination] = []
                        for cell in seers.sorted() where cell != pivot
                            && grid.candidates[cell] & bz != 0 {
                            eliminations.append(Elimination(cell: cell, digit: z))
                        }
                        if !eliminations.isEmpty {
                            return eliminationStep(
                                .xyWing, eliminations: eliminations,
                                premises: [pivot, w1, w2] + eliminations.map(\.cell),
                                focusUnit: nil)
                        }
                    }
                }
            }
        }
        return nil
    }

    private static func xyzWing(_ grid: SolverGrid) -> SolveStep? {
        for pivot in 0..<81 {
            guard grid.values[pivot] == 0,
                  Digits.count(grid.candidates[pivot]) == 3 else { continue }
            let pivotMask = grid.candidates[pivot]
            let wings = BoardTopology.peers[pivot].filter {
                grid.values[$0] == 0
                && Digits.count(grid.candidates[$0]) == 2
                && grid.candidates[$0] & ~pivotMask == 0
            }
            for i in 0..<wings.count {
                for j in (i + 1)..<wings.count {
                    let w1 = wings[i], w2 = wings[j]
                    let m1 = grid.candidates[w1], m2 = grid.candidates[w2]
                    if m1 == m2 { continue }
                    guard let z = Digits.single(m1 & m2) else { continue }
                    guard m1 | m2 == pivotMask else { continue }
                    let bz = Digits.bit(z)
                    let seers = BoardTopology.peerSets[pivot]
                        .intersection(BoardTopology.peerSets[w1])
                        .intersection(BoardTopology.peerSets[w2])
                    var eliminations: [Elimination] = []
                    for cell in seers.sorted() where grid.candidates[cell] & bz != 0 {
                        eliminations.append(Elimination(cell: cell, digit: z))
                    }
                    if !eliminations.isEmpty {
                        return eliminationStep(
                            .xyzWing, eliminations: eliminations,
                            premises: [pivot, w1, w2] + eliminations.map(\.cell),
                            focusUnit: nil)
                    }
                }
            }
        }
        return nil
    }

    /// Обобщённый turbot fish: сильная связь — слабая связь — сильная связь.
    /// Покрывает Skyscraper, Two-String Kite и часть Empty Rectangle.
    private static func turbotFish(_ grid: SolverGrid) -> SolveStep? {
        for digit in 1...9 {
            let bit = Digits.bit(digit)
            var links: [(Int, Int)] = []
            for unitIndex in 0..<27 {
                var spots: [Int] = []
                for cell in BoardTopology.units[unitIndex]
                where grid.candidates[cell] & bit != 0 { spots.append(cell) }
                if spots.count == 2 { links.append((spots[0], spots[1])) }
            }
            for i in 0..<links.count {
                for j in (i + 1)..<links.count {
                    let first = [(links[i].0, links[i].1), (links[i].1, links[i].0)]
                    let second = [(links[j].0, links[j].1), (links[j].1, links[j].0)]
                    for (a, b) in first {
                        for (c, e) in second {
                            if Set([a, b, c, e]).count != 4 { continue }
                            guard BoardTopology.peerSets[b].contains(c) else { continue }
                            if BoardTopology.peerSets[a].contains(e) { continue }
                            let seers = BoardTopology.peerSets[a]
                                .intersection(BoardTopology.peerSets[e])
                            var eliminations: [Elimination] = []
                            for cell in seers.sorted() where cell != b && cell != c
                                && grid.candidates[cell] & bit != 0 {
                                eliminations.append(Elimination(cell: cell, digit: digit))
                            }
                            if !eliminations.isEmpty {
                                return eliminationStep(
                                    .turbotFish, eliminations: eliminations,
                                    premises: [a, b, c, e] + eliminations.map(\.cell),
                                    focusUnit: nil)
                            }
                        }
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Итог

    private static func finish(_ status: SolveStatus, _ steps: [SolveStep]) -> SolveTrace {
        guard !steps.isEmpty else {
            return SolveTrace(status: status, steps: [], seRating: 0,
                              workScore: 0, dependencyDepth: 0, techniques: [])
        }
        let seRating = steps.map(\.rating).max() ?? 0
        let workScore = steps.reduce(0) { $0 + $1.weight }
        let techniques = Set(steps.map(\.technique)).sorted()

        // dependencyDepth — длина самой длинной цепочки шагов, где следующий шаг
        // читает клетку, изменённую предыдущим (раздел 8.1).
        var depth = [Int](repeating: 1, count: steps.count)
        let producedSets = steps.map { Set($0.produced) }
        for i in 0..<steps.count {
            let premises = Set(steps[i].premises)
            var best = 0
            for j in 0..<i where !premises.isDisjoint(with: producedSets[j]) {
                best = max(best, depth[j])
            }
            depth[i] = best + 1
        }

        return SolveTrace(
            status: status,
            steps: steps,
            seRating: seRating,
            workScore: workScore,
            dependencyDepth: depth.max() ?? 1,
            techniques: techniques
        )
    }
}

/// Комбинации без аллокации массива результатов.
/// `body` возвращает `true`, чтобы продолжить перебор.
enum Combinations {
    static func forEach<T>(_ items: [T], choose k: Int, _ body: ([T]) -> Bool) {
        guard k > 0, items.count >= k else { return }
        var indices = Array(0..<k)
        var buffer = [T]()
        buffer.reserveCapacity(k)
        while true {
            buffer.removeAll(keepingCapacity: true)
            for i in indices { buffer.append(items[i]) }
            if !body(buffer) { return }

            var position = k - 1
            while position >= 0 && indices[position] == items.count - k + position {
                position -= 1
            }
            if position < 0 { return }
            indices[position] += 1
            for next in (position + 1)..<k { indices[next] = indices[next - 1] + 1 }
        }
    }
}
