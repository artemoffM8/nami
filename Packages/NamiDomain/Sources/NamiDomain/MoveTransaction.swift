//
//  MoveTransaction.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  «Основное действие и все связанные изменения заметок для точного Undo/Redo»
//  (раздел 13.4). Транзакция хранит полное before/after каждой затронутой клетки,
//  поэтому Undo возвращает и автоматически сокращённые заметки (критерий 5).
//

import Foundation

public struct CellDelta: Equatable, Sendable, Codable {
    public let index: Int
    public let before: CellState
    public let after: CellState

    public init(index: Int, before: CellState, after: CellState) {
        self.index = index
        self.before = before
        self.after = after
    }
}

public struct MoveTransaction: Equatable, Sendable, Codable {
    public enum Kind: Equatable, Sendable, Codable {
        case placeDigit(Int)
        case eraseCell
        case toggleNote(Int)
        case clearNotes
        /// Финальный Reveal — делает партию нерейтинговой (раздел 9.1).
        case revealDigit(Int)
    }

    public let kind: Kind
    public let primaryCell: Int
    public let deltas: [CellDelta]

    public init(kind: Kind, primaryCell: Int, deltas: [CellDelta]) {
        self.kind = kind
        self.primaryCell = primaryCell
        self.deltas = deltas
    }

    public var isEmpty: Bool { deltas.allSatisfy { $0.before == $0.after } }

    /// Цифру открыло приложение, а не игрок. Журналу это нужно, чтобы не
    /// начислить очки за подсказанную клетку при восстановлении.
    public var isReveal: Bool {
        if case .revealDigit = kind { return true }
        return false
    }
}

/// Применение и откат транзакций. Чистая функция над `BoardState`.
public enum MoveApplier {

    public static func apply(_ transaction: MoveTransaction, to board: inout BoardState) {
        for delta in transaction.deltas { board[delta.index] = delta.after }
    }

    public static func revert(_ transaction: MoveTransaction, in board: inout BoardState) {
        for delta in transaction.deltas { board[delta.index] = delta.before }
    }
}

/// Журнал ходов партии. Undo/Redo, ограничение глубины не применяется:
/// 81 клетка даёт короткую историю, а полный журнал нужен для честного Undo.
public struct MoveHistory: Equatable, Sendable, Codable {
    public private(set) var undoStack: [MoveTransaction] = []
    public private(set) var redoStack: [MoveTransaction] = []

    public init() {}

    public init(undoStack: [MoveTransaction], redoStack: [MoveTransaction]) {
        self.undoStack = undoStack
        self.redoStack = redoStack
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var moveCount: Int { undoStack.count }

    public mutating func record(_ transaction: MoveTransaction) {
        guard !transaction.isEmpty else { return }
        undoStack.append(transaction)
        redoStack.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public mutating func undo(on board: inout BoardState) -> MoveTransaction? {
        guard let transaction = undoStack.popLast() else { return nil }
        MoveApplier.revert(transaction, in: &board)
        redoStack.append(transaction)
        return transaction
    }

    @discardableResult
    public mutating func redo(on board: inout BoardState) -> MoveTransaction? {
        guard let transaction = redoStack.popLast() else { return nil }
        MoveApplier.apply(transaction, to: &board)
        undoStack.append(transaction)
        return transaction
    }
}

/// Построение транзакций с учётом политики помощи.
public struct MoveBuilder: Sendable {
    public init() {}

    /// Постановка цифры. При включённом автосокращении убирает цифру из ручных
    /// заметок связанных клеток — и записывает это как побочные изменения,
    /// чтобы Undo вернул их точно.
    public func placeDigit(
        _ digit: Int,
        at index: Int,
        board: BoardState,
        autoReduceNotes: Bool,
        isReveal: Bool = false
    ) -> MoveTransaction {
        var deltas: [CellDelta] = []
        let before = board[index]
        var after = before
        after.value = UInt8(digit)
        after.manualNotesMask = 0
        deltas.append(CellDelta(index: index, before: before, after: after))

        if autoReduceNotes {
            let bit = Digits.bit(digit)
            for peer in BoardTopology.peers[index] {
                let peerBefore = board[peer]
                guard peerBefore.value == 0, peerBefore.manualNotesMask & bit != 0 else { continue }
                var peerAfter = peerBefore
                peerAfter.manualNotesMask &= ~bit
                deltas.append(CellDelta(index: peer, before: peerBefore, after: peerAfter))
            }
        }
        return MoveTransaction(
            kind: isReveal ? .revealDigit(digit) : .placeDigit(digit),
            primaryCell: index,
            deltas: deltas
        )
    }

    public func erase(at index: Int, board: BoardState) -> MoveTransaction {
        let before = board[index]
        var after = before
        after.value = 0
        after.manualNotesMask = 0
        return MoveTransaction(
            kind: .eraseCell,
            primaryCell: index,
            deltas: [CellDelta(index: index, before: before, after: after)]
        )
    }

    public func toggleNote(_ digit: Int, at index: Int, board: BoardState) -> MoveTransaction {
        let before = board[index]
        var after = before
        after.manualNotesMask ^= Digits.bit(digit)
        return MoveTransaction(
            kind: .toggleNote(digit),
            primaryCell: index,
            deltas: [CellDelta(index: index, before: before, after: after)]
        )
    }
}
