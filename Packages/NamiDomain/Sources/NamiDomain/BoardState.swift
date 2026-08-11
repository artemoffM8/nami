//
//  BoardState.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  Раздел 13.4 ТЗ. В клетке нет производного состояния: конфликт,
//  legalCandidatesMask, «та же цифра» и связанные области вычисляются
//  валидатором и не хранятся вторым источником истины.
//

import Foundation

public struct CellState: Equatable, Sendable, Codable {
    /// 0 = пусто, иначе 1...9.
    public var value: UInt8
    /// Ручные заметки игрока, биты 1...9. Assistant overlay сюда не пишет никогда.
    public var manualNotesMask: DigitMask
    public var isGiven: Bool

    public init(value: UInt8 = 0, manualNotesMask: DigitMask = 0, isGiven: Bool = false) {
        self.value = value
        self.manualNotesMask = manualNotesMask
        self.isGiven = isGiven
    }

    public var isEmpty: Bool { value == 0 }
}

public struct BoardState: Equatable, Sendable {
    public private(set) var cells: ContiguousArray<CellState>

    /// Инвариант размера 81 проверяется инициализатором (раздел 13.4).
    public init(cells: ContiguousArray<CellState>) {
        precondition(cells.count == BoardTopology.cellCount, "BoardState требует ровно 81 клетку")
        self.cells = cells
    }

    public init(empty: Void = ()) {
        self.cells = ContiguousArray(repeating: CellState(), count: BoardTopology.cellCount)
    }

    /// Строка из 81 символа, `0` или `.` = пустая клетка. Все заполненные — givens.
    public init?(givens: String) {
        let chars = Array(givens)
        guard chars.count == BoardTopology.cellCount else { return nil }
        var cells = ContiguousArray<CellState>()
        cells.reserveCapacity(BoardTopology.cellCount)
        for ch in chars {
            if ch == "0" || ch == "." {
                cells.append(CellState())
            } else if let d = ch.wholeNumberValue, (1...9).contains(d) {
                cells.append(CellState(value: UInt8(d), isGiven: true))
            } else {
                return nil
            }
        }
        self.cells = cells
    }

    public subscript(index: Int) -> CellState {
        get { cells[index] }
        set { cells[index] = newValue }
    }

    public subscript(row row: Int, column column: Int) -> CellState {
        get { cells[BoardTopology.index(row: row, column: column)] }
        set { cells[BoardTopology.index(row: row, column: column)] = newValue }
    }

    public var isComplete: Bool {
        for cell in cells where cell.value == 0 { return false }
        return true
    }

    public var filledCount: Int {
        cells.reduce(into: 0) { $0 += $1.value == 0 ? 0 : 1 }
    }

    public func serialized() -> String {
        String(cells.map { Character(String($0.value)) })
    }

    /// Легальные кандидаты клетки по правилам строки/столбца/блока.
    /// Производное значение, не хранится в клетке.
    public func legalCandidates(at index: Int) -> DigitMask {
        guard cells[index].value == 0 else { return 0 }
        var mask = Digits.all
        for peer in BoardTopology.peers[index] {
            let v = cells[peer].value
            if v != 0 { mask &= ~Digits.bit(Int(v)) }
        }
        return mask
    }
}
