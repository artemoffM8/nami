//
//  BoardTopology.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  Предрасчитанная топология доски 9×9: 27 групп, 20 peers для каждой клетки.
//  Раздел 13.4 ТЗ: «заранее рассчитаны 27 groups и 20 peers для каждой клетки».
//
//  Всё считается один раз при первом обращении и дальше только читается,
//  поэтому в горячем пути нет ни аллокаций, ни арифметики индексов.
//

import Foundation

/// Битовая маска цифр 1...9. Бит 0 не используется — это позволяет
/// писать `mask & (1 << digit)` без смещения на единицу.
public typealias DigitMask = UInt16

public enum Digits {
    /// Все девять цифр: биты 1...9.
    public static let all: DigitMask = 0b11_1111_1110

    @inlinable
    public static func bit(_ digit: Int) -> DigitMask { DigitMask(1) << DigitMask(digit) }

    @inlinable
    public static func contains(_ mask: DigitMask, _ digit: Int) -> Bool {
        mask & bit(digit) != 0
    }

    @inlinable
    public static func count(_ mask: DigitMask) -> Int { mask.nonzeroBitCount }

    /// Единственная цифра в маске или `nil`.
    @inlinable
    public static func single(_ mask: DigitMask) -> Int? {
        mask.nonzeroBitCount == 1 ? Int(mask.trailingZeroBitCount) : nil
    }

    /// Цифры маски по возрастанию. Аллоцирует — не для горячего пути.
    public static func list(_ mask: DigitMask) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(mask.nonzeroBitCount)
        var m = mask
        while m != 0 {
            let d = m.trailingZeroBitCount
            result.append(d)
            m &= m - 1
        }
        return result
    }

    /// Итерация без аллокации.
    @inlinable
    public static func forEach(_ mask: DigitMask, _ body: (Int) -> Void) {
        var m = mask
        while m != 0 {
            body(m.trailingZeroBitCount)
            m &= m - 1
        }
    }
}

public enum BoardTopology {
    public static let cellCount = 81
    public static let unitCount = 27

    /// Индексы юнитов: 0...8 строки, 9...17 столбцы, 18...26 блоки 3×3.
    public enum UnitKind: Int, Sendable, CaseIterable {
        case row, column, box

        public var range: Range<Int> {
            switch self {
            case .row: 0..<9
            case .column: 9..<18
            case .box: 18..<27
            }
        }
    }

    public static let rowOf: [Int] = (0..<81).map { $0 / 9 }
    public static let columnOf: [Int] = (0..<81).map { $0 % 9 }
    public static let boxOf: [Int] = (0..<81).map { ($0 / 9 / 3) * 3 + ($0 % 9) / 3 }

    /// 27 юнитов по 9 клеток.
    public static let units: [[Int]] = {
        var result: [[Int]] = []
        result.reserveCapacity(27)
        for r in 0..<9 { result.append((0..<9).map { r * 9 + $0 }) }
        for c in 0..<9 { result.append((0..<9).map { $0 * 9 + c }) }
        for b in 0..<9 {
            let br = (b / 3) * 3, bc = (b % 3) * 3
            var cells: [Int] = []
            cells.reserveCapacity(9)
            for dr in 0..<3 { for dc in 0..<3 { cells.append((br + dr) * 9 + bc + dc) } }
            result.append(cells)
        }
        return result
    }()

    /// Три юнита, содержащих клетку: строка, столбец, блок.
    public static let unitsOfCell: [[Int]] = {
        var result = [[Int]](repeating: [], count: 81)
        for (index, unit) in units.enumerated() {
            for cell in unit { result[cell].append(index) }
        }
        return result
    }()

    /// 20 связанных клеток для каждой клетки.
    public static let peers: [[Int]] = {
        (0..<81).map { cell in
            var set = Set<Int>()
            for unitIndex in unitsOfCell[cell] { set.formUnion(units[unitIndex]) }
            set.remove(cell)
            return set.sorted()
        }
    }()

    /// Те же peers как множество — для быстрых проверок «видит ли клетка клетку».
    public static let peerSets: [Set<Int>] = peers.map(Set.init)

    @inlinable
    public static func sees(_ a: Int, _ b: Int) -> Bool {
        a != b && (rowOf[a] == rowOf[b] || columnOf[a] == columnOf[b] || boxOf[a] == boxOf[b])
    }

    public static func index(row: Int, column: Int) -> Int { row * 9 + column }
}
