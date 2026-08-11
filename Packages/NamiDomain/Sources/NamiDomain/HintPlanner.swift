//
//  HintPlanner.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  Многоступенчатая обучающая подсказка (раздел 4.2) и её ключевой инвариант
//  из критерия приёмки 37: на противоречивой доске возвращается ТОЛЬКО conflict
//  guidance — без trace, без Reveal и без мутации ручных заметок.
//

import Foundation

public enum HintPlan: Equatable, Sendable {
    /// Доска решена — подсказка не нужна.
    case solved
    /// Есть явный конфликт правил: сначала предлагаем его найти.
    case resolveConflicts(cells: [Int])
    /// Позиция противоречива без явного дубля (например, у пустой клетки нет кандидатов).
    case unsolvablePosition
    /// Следующий логический шаг, рассчитанный заново из текущей позиции.
    case step(SolveStep)
    /// Позиция корректна, но текущий набор техник шаг не нашёл.
    case noLogicalStep
}

public struct HintPresentation: Equatable, Sendable {
    public let layer: HintLayer
    /// Клетки, которые подсвечивает слой «Область».
    public let regionCells: [Int]
    public let techniqueNameKey: String?
    public let explanationKey: String?
    /// Кандидаты, которые нужно показать поверх поля на слое 3.
    public let highlightedCandidates: [Elimination]
    /// Цифра открывается только на слое Reveal и делает партию нерейтинговой.
    public let revealedPlacement: Placement?
}

public enum HintPlanner {

    public static func plan(board: BoardState, derived: BoardDerivedState) -> HintPlan {
        if derived.isSolvedByRules { return .solved }
        if !derived.conflicts.isEmpty {
            return .resolveConflicts(cells: derived.conflicts.indices)
        }
        var grid = SolverGrid(board: board)
        if grid.hasContradiction { return .unsolvablePosition }
        guard let step = HumanSolver.findStep(in: &grid) else { return .noLogicalStep }
        return .step(step)
    }

    /// Содержимое конкретного слоя. Каждый слой добавляет ровно одну порцию
    /// информации; поле остаётся видимым, а sheet имеет одну кнопку «Ещё шаг».
    public static func presentation(for step: SolveStep, layer: HintLayer) -> HintPresentation {
        let region: [Int] = {
            if let unit = step.focusUnit { return BoardTopology.units[unit] }
            if let placement = step.placement { return [placement.cell] }
            return step.premises
        }()

        switch layer {
        case .none:
            return HintPresentation(layer: layer, regionCells: [], techniqueNameKey: nil,
                                    explanationKey: nil, highlightedCandidates: [],
                                    revealedPlacement: nil)
        case .region:
            return HintPresentation(layer: layer, regionCells: region, techniqueNameKey: nil,
                                    explanationKey: nil, highlightedCandidates: [],
                                    revealedPlacement: nil)
        case .techniqueName:
            return HintPresentation(layer: layer, regionCells: region,
                                    techniqueNameKey: step.technique.nameKey,
                                    explanationKey: nil, highlightedCandidates: [],
                                    revealedPlacement: nil)
        case .candidatesAndLogic:
            let candidates: [Elimination] = step.placement.map {
                [Elimination(cell: $0.cell, digit: $0.digit)]
            } ?? step.eliminations
            return HintPresentation(layer: layer, regionCells: region,
                                    techniqueNameKey: step.technique.nameKey,
                                    explanationKey: step.technique.explanationKey,
                                    highlightedCandidates: candidates,
                                    revealedPlacement: nil)
        case .reveal:
            return HintPresentation(layer: layer, regionCells: region,
                                    techniqueNameKey: step.technique.nameKey,
                                    explanationKey: step.technique.explanationKey,
                                    highlightedCandidates: step.eliminations,
                                    revealedPlacement: step.placement)
        }
    }

    /// «Линза кандидатов»: overlay рисует только `legalCandidatesMask & ~manualNotesMask`
    /// — ручная заметка визуально побеждает (раздел 4.5).
    public static func lensOverlay(
        for index: Int,
        board: BoardState,
        derived: BoardDerivedState
    ) -> DigitMask {
        guard board[index].value == 0 else { return 0 }
        return derived.legalCandidates[index] & ~board[index].manualNotesMask
    }
}
