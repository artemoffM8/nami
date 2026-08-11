//
//  SudokuValidator.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  Один проход по доске рассчитывает всё производное состояние сразу
//  (раздел 13.5: «производные флаги рассчитываются один раз после действия игрока»).
//

import Foundation

/// Компактный набор из 81 бита. Хранится в двух UInt64, копируется дёшево,
/// сравнивается за две инструкции — важно для Equatable-оптимизации SwiftUI.
public struct CellSet: Equatable, Sendable {
    public private(set) var low: UInt64 = 0
    public private(set) var high: UInt64 = 0

    public init() {}

    /// Не `@inlinable`: инлайнить нельзя, пока сеттеры `low`/`high` приватные,
    /// а делать их публичными — открыть внутреннее представление наружу.
    public mutating func insert(_ index: Int) {
        if index < 64 { low |= UInt64(1) << UInt64(index) }
        else { high |= UInt64(1) << UInt64(index - 64) }
    }

    @inlinable
    public func contains(_ index: Int) -> Bool {
        index < 64 ? (low >> UInt64(index)) & 1 == 1 : (high >> UInt64(index - 64)) & 1 == 1
    }

    public var isEmpty: Bool { low == 0 && high == 0 }
    public var count: Int { low.nonzeroBitCount + high.nonzeroBitCount }

    public var indices: [Int] {
        var result: [Int] = []
        var l = low
        while l != 0 { result.append(l.trailingZeroBitCount); l &= l - 1 }
        var h = high
        while h != 0 { result.append(64 + h.trailingZeroBitCount); h &= h - 1 }
        return result
    }
}

/// Полностью производное состояние доски. Пересчитывается один раз за ход.
public struct BoardDerivedState: Equatable, Sendable {
    /// Клетки, нарушающие правило строки/столбца/блока.
    public var conflicts = CellSet()
    /// Легальные кандидаты для каждой пустой клетки.
    public var legalCandidates = [DigitMask](repeating: 0, count: BoardTopology.cellCount)
    /// Цифры, размещённые все девять раз (для приглушения панели).
    public var completedDigits: DigitMask = 0
    /// Юниты, полностью заполненные и без конфликтов.
    public var completedUnits = Set<Int>()
    /// Сколько раз каждая цифра стоит на доске, индексы 0...9.
    public var placedCounts = [Int](repeating: 0, count: 10)
    public var isSolvedByRules = false

    public init() {}
}

public enum SudokuValidator {

    public static func derive(_ board: BoardState) -> BoardDerivedState {
        var state = BoardDerivedState()

        // Значения по юнитам за один проход.
        for unitIndex in 0..<BoardTopology.unitCount {
            let unit = BoardTopology.units[unitIndex]
            var seen: DigitMask = 0
            var duplicated: DigitMask = 0
            var filled = 0
            for cell in unit {
                let v = board.cells[cell].value
                guard v != 0 else { continue }
                filled += 1
                let bit = Digits.bit(Int(v))
                if seen & bit != 0 { duplicated |= bit }
                seen |= bit
            }
            if duplicated != 0 {
                for cell in unit {
                    let v = board.cells[cell].value
                    if v != 0, duplicated & Digits.bit(Int(v)) != 0 {
                        state.conflicts.insert(cell)
                    }
                }
            }
            if filled == 9 && duplicated == 0 { state.completedUnits.insert(unitIndex) }
        }

        for index in 0..<BoardTopology.cellCount {
            let v = board.cells[index].value
            if v == 0 {
                state.legalCandidates[index] = board.legalCandidates(at: index)
            } else {
                state.placedCounts[Int(v)] += 1
            }
        }

        for digit in 1...9 where state.placedCounts[digit] == 9 {
            state.completedDigits |= Digits.bit(digit)
        }

        state.isSolvedByRules = board.isComplete && state.conflicts.isEmpty
        return state
    }

    /// Юниты, ставшие завершёнными именно этим ходом (переход «не завершена → завершена»,
    /// раздел 7.3). Возвращает пары (kind, unitIndex).
    public static func newlyCompletedUnits(
        before: BoardDerivedState,
        after: BoardDerivedState
    ) -> [(kind: BoardTopology.UnitKind, unitIndex: Int)] {
        after.completedUnits
            .subtracting(before.completedUnits)
            .sorted()
            .map { index in
                let kind: BoardTopology.UnitKind = index < 9 ? .row : (index < 18 ? .column : .box)
                return (kind, index)
            }
    }
}
