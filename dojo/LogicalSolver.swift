//
//  LogicalSolver.swift
//  Пошаговый логический решатель: решает поле человеческими техниками
//  и сообщает, какие из них понадобились. Сердце "додзё": по нему
//  отбираются поля, где нужная техника необходима.
//

import Foundation

enum SolveTechnique: Int, CaseIterable, Comparable {
    case nakedSingle = 0
    case hiddenSingle
    case lockedCandidates   // pointing / claiming
    case nakedPair
    case hiddenPair
    case xWing

    static func < (a: SolveTechnique, b: SolveTechnique) -> Bool {
        a.rawValue < b.rawValue
    }

    var title: String {
        switch self {
        case .nakedSingle:      return "Единственный кандидат"
        case .hiddenSingle:     return "Скрытая единица"
        case .lockedCandidates: return "Запертые кандидаты"
        case .nakedPair:        return "Голая пара"
        case .hiddenPair:       return "Скрытая пара"
        case .xWing:            return "X-Wing"
        }
    }
}

struct SolveReport {
    let solved: Bool
    let used: Set<SolveTechnique>
    var hardest: SolveTechnique? { used.max() }
}

final class LogicalSolver {

    private var board: [Int]          // 0 = пусто
    private var cand: [Int]           // битмаски кандидатов

    // 27 юнитов: 9 строк, 9 столбцов, 9 блоков
    static let units: [[Int]] = {
        var u: [[Int]] = []
        for r in 0..<9 { u.append((0..<9).map { r * 9 + $0 }) }
        for c in 0..<9 { u.append((0..<9).map { $0 * 9 + c }) }
        for b in 0..<9 {
            let r0 = b / 3 * 3, c0 = b % 3 * 3
            u.append((0..<9).map { (r0 + $0 / 3) * 9 + (c0 + $0 % 3) })
        }
        return u
    }()

    init(puzzle: [Int?]) {
        board = puzzle.map { $0 ?? 0 }
        cand = [Int](repeating: 0, count: 81)
        for i in 0..<81 where board[i] == 0 {
            var used = 0
            let r = i / 9, c = i % 9, r0 = r / 3 * 3, c0 = c / 3 * 3
            for k in 0..<9 {
                used |= 1 << board[r * 9 + k]
                used |= 1 << board[k * 9 + c]
                used |= 1 << board[(r0 + k / 3) * 9 + (c0 + k % 3)]
            }
            cand[i] = ~used & 0b111_1111_1110
        }
    }

    func solve() -> SolveReport {
        var used = Set<SolveTechnique>()
        while true {
            if !board.contains(0) { return SolveReport(solved: true, used: used) }
            if board.indices.contains(where: { board[$0] == 0 && cand[$0] == 0 }) {
                return SolveReport(solved: false, used: used) // противоречие
            }
            if nakedSingle()      { used.insert(.nakedSingle); continue }
            if hiddenSingle()     { used.insert(.hiddenSingle); continue }
            if lockedCandidates() { used.insert(.lockedCandidates); continue }
            if nakedPair()        { used.insert(.nakedPair); continue }
            if hiddenPair()       { used.insert(.hiddenPair); continue }
            if xWing()            { used.insert(.xWing); continue }
            return SolveReport(solved: false, used: used) // застряли
        }
    }

    // MARK: - Размещение

    private func place(_ i: Int, _ d: Int) {
        board[i] = d
        cand[i] = 0
        let bit = 1 << d
        let r = i / 9, c = i % 9, r0 = r / 3 * 3, c0 = c / 3 * 3
        for k in 0..<9 {
            cand[r * 9 + k] &= ~bit
            cand[k * 9 + c] &= ~bit
            cand[(r0 + k / 3) * 9 + (c0 + k % 3)] &= ~bit
        }
    }

    // MARK: - Техники (каждая возвращает true при прогрессе)

    private func nakedSingle() -> Bool {
        for i in 0..<81 where board[i] == 0 && cand[i].nonzeroBitCount == 1 {
            place(i, cand[i].trailingZeroBitCount)
            return true
        }
        return false
    }

    private func hiddenSingle() -> Bool {
        for unit in Self.units {
            for d in 1...9 {
                let bit = 1 << d
                let spots = unit.filter { cand[$0] & bit != 0 }
                if spots.count == 1 {
                    place(spots[0], d)
                    return true
                }
            }
        }
        return false
    }

    private func lockedCandidates() -> Bool {
        // Pointing: в блоке кандидаты цифры лежат в одной строке/столбце ->
        // убрать цифру из этой строки/столбца вне блока.
        for b in 0..<9 {
            let box = Self.units[18 + b]
            for d in 1...9 {
                let bit = 1 << d
                let spots = box.filter { cand[$0] & bit != 0 }
                guard spots.count >= 2 else { continue }
                let rows = Set(spots.map { $0 / 9 })
                let cols = Set(spots.map { $0 % 9 })
                if rows.count == 1 {
                    if eliminate(bit, in: Self.units[rows.first!],
                                 except: Set(box)) { return true }
                }
                if cols.count == 1 {
                    if eliminate(bit, in: Self.units[9 + cols.first!],
                                 except: Set(box)) { return true }
                }
            }
        }
        // Claiming: в строке/столбце кандидаты цифры лежат в одном блоке ->
        // убрать цифру из остального блока.
        for u in 0..<18 {
            let line = Self.units[u]
            for d in 1...9 {
                let bit = 1 << d
                let spots = line.filter { cand[$0] & bit != 0 }
                guard spots.count >= 2 else { continue }
                let boxes = Set(spots.map { ($0 / 9) / 3 * 3 + ($0 % 9) / 3 })
                if boxes.count == 1 {
                    if eliminate(bit, in: Self.units[18 + boxes.first!],
                                 except: Set(line)) { return true }
                }
            }
        }
        return false
    }

    private func nakedPair() -> Bool {
        for unit in Self.units {
            let pairsCells = unit.filter { cand[$0].nonzeroBitCount == 2 }
            guard pairsCells.count >= 2 else { continue }
            for i in 0..<(pairsCells.count - 1) {
                for j in (i + 1)..<pairsCells.count
                where cand[pairsCells[i]] == cand[pairsCells[j]] {
                    let mask = cand[pairsCells[i]]
                    let keep: Set<Int> = [pairsCells[i], pairsCells[j]]
                    if eliminate(mask, in: unit, except: keep) { return true }
                }
            }
        }
        return false
    }

    private func hiddenPair() -> Bool {
        for unit in Self.units {
            for d1 in 1...8 {
                let s1 = unit.filter { cand[$0] & (1 << d1) != 0 }
                guard s1.count == 2 else { continue }
                for d2 in (d1 + 1)...9 {
                    let s2 = unit.filter { cand[$0] & (1 << d2) != 0 }
                    guard s2 == s1 else { continue }
                    let mask = (1 << d1) | (1 << d2)
                    var changed = false
                    for cell in s1 where cand[cell] != mask {
                        cand[cell] = mask
                        changed = true
                    }
                    if changed { return true }
                }
            }
        }
        return false
    }

    private func xWing() -> Bool {
        for d in 1...9 {
            let bit = 1 << d
            // по строкам
            var rowCols: [Int: [Int]] = [:] // строка -> колонки (ровно 2)
            for r in 0..<9 {
                let cols = (0..<9).filter { cand[r * 9 + $0] & bit != 0 }
                if cols.count == 2 { rowCols[r] = cols }
            }
            let rows = Array(rowCols.keys)
            for i in 0..<max(0, rows.count - 1) {
                for j in (i + 1)..<rows.count where rowCols[rows[i]]! == rowCols[rows[j]]! {
                    let cols = rowCols[rows[i]]!
                    let keep: Set<Int> = [rows[i] * 9 + cols[0], rows[i] * 9 + cols[1],
                                          rows[j] * 9 + cols[0], rows[j] * 9 + cols[1]]
                    var changed = false
                    for c in cols {
                        if eliminate(bit, in: Self.units[9 + c], except: keep) { changed = true }
                    }
                    if changed { return true }
                }
            }
            // по столбцам (транспонированный случай)
            var colRows: [Int: [Int]] = [:]
            for c in 0..<9 {
                let rws = (0..<9).filter { cand[$0 * 9 + c] & bit != 0 }
                if rws.count == 2 { colRows[c] = rws }
            }
            let cols = Array(colRows.keys)
            for i in 0..<max(0, cols.count - 1) {
                for j in (i + 1)..<cols.count where colRows[cols[i]]! == colRows[cols[j]]! {
                    let rws = colRows[cols[i]]!
                    let keep: Set<Int> = [rws[0] * 9 + cols[i], rws[1] * 9 + cols[i],
                                          rws[0] * 9 + cols[j], rws[1] * 9 + cols[j]]
                    var changed = false
                    for r in rws {
                        if eliminate(bit, in: Self.units[r], except: keep) { changed = true }
                    }
                    if changed { return true }
                }
            }
        }
        return false
    }

    /// Убрать биты mask из кандидатов юнита (кроме except). true, если что-то изменилось.
    private func eliminate(_ mask: Int, in unit: [Int], except: Set<Int>) -> Bool {
        var changed = false
        for cell in unit where !except.contains(cell) && cand[cell] & mask != 0 {
            cand[cell] &= ~mask
            changed = true
        }
        return changed
    }
}
