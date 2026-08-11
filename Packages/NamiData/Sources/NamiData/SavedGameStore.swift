//
//  SavedGameStore.swift
//  NamiData
//
//  Created by artemoffM8.
//
//  Автосохранение (раздел 13.7): debounce не более 500 мс после содержательного
//  хода и немедленная запись при `inactive`/`background`.
//  Запись выполняется как единый snapshot; несовместимая схема не перезаписывает
//  профиль, а предлагает безопасно начать задачу заново.
//

import Foundation
import SwiftData
import NamiDomain

/// Полное состояние партии в форме, пригодной для сериализации.
public struct PersistedSession: Sendable, Equatable {
    public var puzzleID: String
    public var catalogVersion: String
    public var board: BoardState
    public var givens: String
    public var history: MoveHistory
    public var initialProfileID: AssistanceProfile
    public var sessionPolicy: SessionPolicy
    public var ledger: AssistanceUsageLedger
    public var timing: TimingSnapshot
    public var modifiers: [ChallengeModifier]
    public var paceMode: RatingPaceMode
    public var dailyCompetitionVersion: String?
    /// Режим партии. Восстанавливается вместе с доской: без него «Релакс»
    /// молча превращался в рейтинговую партию.
    public var mode: GameMode
    /// Журнал партии. Он же — единственный источник счёта: до его появления
    /// очки не сохранялись вообще, и восстановленная рейтинговая партия
    /// возвращала доску с обнулённым счётом.
    public var journal: SessionJournal?
    /// Счёт, восстановленный из журнала. При записи не используется.
    public var restoredScore: SessionScoreState?
    /// Журнал разошёлся со снимком: играть можно, писать в таблицу — нет.
    public var integrityWarning: String?

    public init(
        puzzleID: String,
        catalogVersion: String,
        board: BoardState,
        givens: String,
        history: MoveHistory,
        initialProfileID: AssistanceProfile,
        sessionPolicy: SessionPolicy,
        ledger: AssistanceUsageLedger,
        timing: TimingSnapshot,
        modifiers: [ChallengeModifier],
        paceMode: RatingPaceMode,
        dailyCompetitionVersion: String?,
        mode: GameMode = .ranked,
        journal: SessionJournal? = nil,
        restoredScore: SessionScoreState? = nil,
        integrityWarning: String? = nil
    ) {
        self.mode = mode
        self.journal = journal
        self.restoredScore = restoredScore
        self.integrityWarning = integrityWarning
        self.puzzleID = puzzleID
        self.catalogVersion = catalogVersion
        self.board = board
        self.givens = givens
        self.history = history
        self.initialProfileID = initialProfileID
        self.sessionPolicy = sessionPolicy
        self.ledger = ledger
        self.timing = timing
        self.modifiers = modifiers
        self.paceMode = paceMode
        self.dailyCompetitionVersion = dailyCompetitionVersion
    }
}

public enum SavedGameLoadResult: Sendable {
    case none
    case restored(PersistedSession)
    /// Схема несовместима или файл повреждён: профиль НЕ трогаем,
    /// пользователю предлагается начать задачу заново.
    case incompatible(reason: String)
}

@MainActor
public final class SavedGameStore {

    public static let debounceInterval: Duration = .milliseconds(500)

    private let context: ModelContext
    private var pendingTask: Task<Void, Never>?

    public init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Запись

    /// Автосохранение после содержательного хода. Повторные вызовы схлопываются.
    public func scheduleSave(_ session: PersistedSession) {
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounceInterval)
            guard !Task.isCancelled else { return }
            self?.saveNow(session)
        }
    }

    /// Немедленная запись — вызывается при `scenePhase == .inactive/.background`.
    public func saveNow(_ session: PersistedSession) {
        pendingTask?.cancel()
        pendingTask = nil

        let record = existingRecord() ?? {
            let created = SavedGame(
                puzzleID: session.puzzleID,
                catalogVersion: session.catalogVersion,
                boardSerialized: session.board.serialized(),
                givensSerialized: session.givens,
                notesMasks: [],
                historyData: Data(),
                initialProfileID: session.initialProfileID.rawValue,
                sessionPolicyData: Data(),
                ledgerData: Data(),
                timingData: Data(),
                challengeModifiers: [],
                ratingPaceModeRaw: session.paceMode.rawValue,
                dailyCompetitionVersion: session.dailyCompetitionVersion
            )
            context.insert(created)
            return created
        }()

        record.schemaVersion = PersistenceSchema.currentVersion
        record.puzzleID = session.puzzleID
        record.catalogVersion = session.catalogVersion
        record.boardSerialized = session.board.serialized()
        record.givensSerialized = session.givens
        record.notesMasks = session.board.cells.map { Int($0.manualNotesMask) }
        record.historyData = DomainCoding.encode(session.history)
        record.initialProfileID = session.initialProfileID.rawValue
        record.sessionPolicyData = DomainCoding.encode(session.sessionPolicy)
        record.ledgerData = DomainCoding.encode(session.ledger)
        record.timingData = DomainCoding.encode(session.timing)
        record.challengeModifiers = session.modifiers.map(\.rawValue)
        record.ratingPaceModeRaw = session.paceMode.rawValue
        record.dailyCompetitionVersion = session.dailyCompetitionVersion
        record.journalData = session.journal.map(JournalArchive.encode)
        record.gameModeRaw = session.mode.rawValue
        record.updatedAt = .now

        // Один `save()` на снимок и журнал. Разделить их на две транзакции
        // означало бы вернуть ровно ту рассинхронизацию, от которой журнал
        // и защищает: падение между записями оставило бы доску и счёт из
        // разных моментов партии.
        try? context.save()
    }

    public func clear() {
        pendingTask?.cancel()
        pendingTask = nil
        if let record = existingRecord() {
            context.delete(record)
            try? context.save()
        }
    }

    // MARK: - Чтение

    public var hasSavedGame: Bool { existingRecord() != nil }

    public func load(catalogVersion: String) -> SavedGameLoadResult {
        guard let record = existingRecord() else { return .none }

        guard record.schemaVersion == PersistenceSchema.currentVersion else {
            return .incompatible(reason: "schemaVersion \(record.schemaVersion)")
        }
        guard record.catalogVersion == catalogVersion else {
            return .incompatible(reason: "catalogVersion \(record.catalogVersion)")
        }
        guard record.boardSerialized.count == 81,
              record.givensSerialized.count == 81,
              record.notesMasks.count == 81 else {
            return .incompatible(reason: "повреждённый snapshot доски")
        }
        guard var board = BoardState(givens: record.boardSerialized),
              let givensBoard = BoardState(givens: record.givensSerialized) else {
            return .incompatible(reason: "не удалось разобрать доску")
        }
        // Флаг isGiven берём из исходной строки задачи, а не из текущих значений.
        for index in 0..<81 {
            var cell = board[index]
            cell.isGiven = givensBoard[index].isGiven
            cell.manualNotesMask = DigitMask(truncatingIfNeeded: record.notesMasks[index])
            if cell.value != 0 { cell.manualNotesMask = 0 }
            board[index] = cell
        }

        let history = DomainCoding.decode(MoveHistory.self, from: record.historyData) ?? MoveHistory()
        let profile = AssistanceProfile(rawValue: record.initialProfileID) ?? .focus
        let policy = DomainCoding.decode(SessionPolicy.self, from: record.sessionPolicyData)
            ?? profile.preset
        let ledger = DomainCoding.decode(AssistanceUsageLedger.self, from: record.ledgerData)
            ?? AssistanceUsageLedger()
        var timing = DomainCoding.decode(TimingSnapshot.self, from: record.timingData)
            ?? TimingSnapshot()
        // Восстановление всегда снимает право на бонус темпа (раздел 13.8).
        timing.speedEligible = false

        // Журнал читается ПОСЛЕ доски: сверка идёт против уже восстановленного
        // снимка, с которым он писался одной транзакцией.
        var journal: SessionJournal?
        var restoredScore: SessionScoreState?
        var integrityWarning: String?
        switch JournalArchive.restore(record.journalData ?? Data(), board: board) {
        case .empty:
            break
        case let .restored(readJournal, score):
            journal = readJournal
            restoredScore = score
        case let .distrusted(readJournal, score, reason):
            journal = readJournal
            restoredScore = score
            integrityWarning = reason
        case let .unreadable(reason):
            // Партию не выбрасываем: доска цела и играбельна. Но счёт начать
            // заново честнее, чем показать неизвестно откуда взявшееся число.
            integrityWarning = reason
        }

        return .restored(PersistedSession(
            puzzleID: record.puzzleID,
            catalogVersion: record.catalogVersion,
            board: board,
            givens: record.givensSerialized,
            history: history,
            initialProfileID: profile,
            sessionPolicy: policy,
            ledger: ledger,
            timing: timing,
            modifiers: record.challengeModifiers.compactMap(ChallengeModifier.init(rawValue:)),
            paceMode: RatingPaceMode(rawValue: record.ratingPaceModeRaw) ?? .disabled,
            dailyCompetitionVersion: record.dailyCompetitionVersion,
            // Отсутствие поля означает партию, сохранённую до его появления.
            // Такие партии были только рейтинговыми — «Релакса» тогда ещё
            // не существовало, так что запасной вариант honest, а не удобный.
            mode: record.gameModeRaw.flatMap(GameMode.init(rawValue:)) ?? .ranked,
            journal: journal,
            restoredScore: restoredScore,
            integrityWarning: integrityWarning
        ))
    }

    private func existingRecord() -> SavedGame? {
        let descriptor = FetchDescriptor<SavedGame>(predicate: #Predicate { $0.slot == "current" })
        return try? context.fetch(descriptor).first
    }
}
