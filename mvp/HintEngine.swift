//
//  HintEngine.swift
//  Трёхступенчатые подсказки: игрок учится, а не читерит.
//    1-й тап: "посмотри сюда" — подсветить регион
//    2-й тап: назвать технику и ячейки-кандидаты
//    3-й тап: открыть цифру
//  После любого хода лестница сбрасывается (controller.reset()).
//
//  Интеграция с демо: замените showHint() на requestHint(...) — пример внизу.
//

import Foundation
import Combine

// MARK: - Модель подсказки

struct SudokuHint {
    enum Technique {
        case nakedSingle            // в ячейке остался один кандидат
        case hiddenSingleRow
        case hiddenSingleCol
        case hiddenSingleBox
        case analysis               // фолбэк: ячейка с минимумом кандидатов

        var title: String {
            switch self {
            case .nakedSingle:      return "Единственный кандидат"
            case .hiddenSingleRow:  return "Скрытая единица в строке"
            case .hiddenSingleCol:  return "Скрытая единица в столбце"
            case .hiddenSingleBox:  return "Скрытая единица в блоке"
            case .analysis:         return "Анализ кандидатов"
            }
        }
    }

    let cell: Int
    let digit: Int
    let technique: Technique
    let regionCells: [Int]      // регион для 1-й ступени

    var stage1Text: String {
        switch technique {
        case .hiddenSingleRow: return "Присмотрись к этой строке"
        case .hiddenSingleCol: return "Присмотрись к этому столбцу"
        case .hiddenSingleBox, .nakedSingle: return "Присмотрись к этому блоку"
        case .analysis: return "Начни с этой области"
        }
    }

    var stage2Text: String {
        switch technique {
        case .nakedSingle:
            return "\(title): в подсвеченной ячейке возможна только одна цифра — какая?"
        case .hiddenSingleRow, .hiddenSingleCol, .hiddenSingleBox:
            return "\(title): цифра \(digit) помещается здесь только в одну ячейку"
        case .analysis:
            return "\(title): у подсвеченной ячейки меньше всего вариантов — переберите их"
        }
    }
}

// MARK: - Поиск следующего хода

enum HintEngine {

    static func nextHint(values: [Int?]) -> SudokuHint? {
        var cand = [Int](repeating: 0, count: 81) // битмаски кандидатов
        for i in 0..<81 where values[i] == nil {
            var used = 0
            let row = i / 9, col = i % 9
            let r0 = row / 3 * 3, c0 = col / 3 * 3
            for k in 0..<9 {
                if let d = values[row * 9 + k] { used |= 1 << d }
                if let d = values[k * 9 + col] { used |= 1 << d }
                if let d = values[(r0 + k / 3) * 9 + (c0 + k % 3)] { used |= 1 << d }
            }
            cand[i] = ~used & 0b111_1111_1110
        }

        // 1. Naked single
        for i in 0..<81 where values[i] == nil && cand[i].nonzeroBitCount == 1 {
            return SudokuHint(cell: i,
                              digit: cand[i].trailingZeroBitCount,
                              technique: .nakedSingle,
                              regionCells: boxCells(of: i))
        }

        // 2. Hidden single: строка / столбец / блок
        for unit in 0..<9 {
            if let h = hiddenSingle(in: rowCells(unit), cand: cand, values: values,
                                    technique: .hiddenSingleRow) { return h }
            if let h = hiddenSingle(in: colCells(unit), cand: cand, values: values,
                                    technique: .hiddenSingleCol) { return h }
            if let h = hiddenSingle(in: boxCellsByIndex(unit), cand: cand, values: values,
                                    technique: .hiddenSingleBox) { return h }
        }

        // 3. Фолбэк: ячейка с минимумом кандидатов (без раскрытия логики).
        //    Цифру берём корректную — первый кандидат, ведущий к решению.
        var best = -1, bestN = 10
        for i in 0..<81 where values[i] == nil {
            let n = cand[i].nonzeroBitCount
            if n < bestN { bestN = n; best = i }
        }
        guard best >= 0 else { return nil }
        var mask = cand[best]
        while mask != 0 {
            let d = (mask & -mask).trailingZeroBitCount
            mask &= mask - 1
            var trial = values
            trial[best] = d
            if SudokuGenerator.countSolutions(trial, limit: 1) >= 1 {
                return SudokuHint(cell: best, digit: d,
                                  technique: .analysis,
                                  regionCells: boxCells(of: best))
            }
        }
        return nil
    }

    private static func hiddenSingle(in cells: [Int], cand: [Int], values: [Int?],
                                     technique: SudokuHint.Technique) -> SudokuHint? {
        for d in 1...9 {
            let bit = 1 << d
            let spots = cells.filter { values[$0] == nil && cand[$0] & bit != 0 }
            if spots.count == 1,
               cand[spots[0]].nonzeroBitCount > 1 { // иначе это naked single
                return SudokuHint(cell: spots[0], digit: d,
                                  technique: technique, regionCells: cells)
            }
        }
        return nil
    }

    static func rowCells(_ r: Int) -> [Int] { (0..<9).map { r * 9 + $0 } }
    static func colCells(_ c: Int) -> [Int] { (0..<9).map { $0 * 9 + c } }
    static func boxCellsByIndex(_ b: Int) -> [Int] {
        let r0 = b / 3 * 3, c0 = b % 3 * 3
        return (0..<9).map { (r0 + $0 / 3) * 9 + (c0 + $0 % 3) }
    }
    static func boxCells(of cell: Int) -> [Int] {
        boxCellsByIndex((cell / 9) / 3 * 3 + (cell % 9) / 3)
    }
}

// MARK: - Контроллер лестницы подсказок

enum HintAction {
    case highlightRegion(cells: [Int], message: String)
    case explain(cells: [Int], focus: Int, message: String)
    case reveal(cell: Int, digit: Int)
    case none
}

final class StagedHintController: ObservableObject {

    @Published private(set) var stage = 0
    private var current: SudokuHint?

    /// Вызывать по кнопке "Подсказка". Каждый вызов поднимает ступень.
    func requestHint(values: [Int?]) -> HintAction {
        if current == nil || stage == 0 {
            current = HintEngine.nextHint(values: values)
            stage = 0
        }
        guard let hint = current else { return .none }
        stage += 1
        switch stage {
        case 1:
            return .highlightRegion(cells: hint.regionCells,
                                    message: hint.stage1Text)
        case 2:
            return .explain(cells: hint.regionCells, focus: hint.cell,
                            message: hint.stage2Text)
        default:
            defer { reset() }
            return .reveal(cell: hint.cell, digit: hint.digit)
        }
    }

    /// Вызывать после любого хода игрока — поле изменилось, лестница неактуальна.
    func reset() {
        stage = 0
        current = nil
    }
}

/*
 ИНТЕГРАЦИЯ В SudokuDemoView (замена showHint):

 @StateObject private var hints = StagedHintController()

 private func showHint() {
     switch hints.requestHint(values: values) {
     case .highlightRegion(let cells, let message):
         // подсветить cells (напр. временно errorFill=false, hintGlow=true),
         // показать message тостом/подписью
         for c in cells { engine.cellFX[c, default: CellFXState()].hintGlow = true }
         DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
             for c in cells { engine.cellFX[c]?.hintGlow = false }
         }
     case .explain(_, let focus, let message):
         selected = focus
         // показать message; подсветка как выше, фокус ярче
     case .reveal(let cell, let digit):
         selected = cell
         engine.handle(.hint(cell: cell))          // светлячок/звезда/свечение
         DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
             history.append((cell, values[cell]))
             withAnimation(.appearAnimation(engine.theme)) { values[cell] = digit }
             checkCompletions(after: cell)
         }
     case .none: break
     }
 }

 // И в enter()/eraseSelected()/undo() добавить: hints.reset()
 */
