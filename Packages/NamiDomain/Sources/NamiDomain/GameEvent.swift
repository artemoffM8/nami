//
//  GameEvent.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  Domain публикует семантические события и НЕ знает о цветах, звуках
//  и частицах (раздел 7.4). Их интерпретирует FeedbackCoordinator в
//  NamiExperience.
//

import Foundation

public enum GameEvent: Equatable, Sendable {
    case cellSelected(Int)
    case digitPlaced(cell: Int, digit: Int)
    case digitErased(cell: Int)
    case notesChanged(cell: Int)
    case conflictDetected(cells: [Int])
    case groupCompleted(kind: BoardTopology.UnitKind, unitIndex: Int)
    case puzzleSolved
    case rankPromoted(division: Int)

    /// Приоритет команды. `puzzleSolved > rankPromoted > groupCompleted >
    /// conflictDetected > digit/notes > selection`.
    public var priority: Int {
        switch self {
        case .puzzleSolved: 6
        case .rankPromoted: 5
        case .groupCompleted: 4
        case .conflictDetected: 3
        case .digitPlaced, .digitErased, .notesChanged: 2
        case .cellSelected: 1
        }
    }
}

/// Все производные события одного хода собираются в одну транзакцию,
/// поэтому ход, завершивший строку, столбец и блок, даёт ОДНУ реакцию.
public struct FeedbackTransaction: Equatable, Sendable {
    public let id: UUID
    public let events: [GameEvent]

    public init(id: UUID = UUID(), events: [GameEvent]) {
        self.id = id
        self.events = events
    }

    public var dominant: GameEvent? {
        events.max { $0.priority < $1.priority }
    }
}
