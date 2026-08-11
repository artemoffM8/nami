//
//  SessionJournal.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  Единый append-only журнал партии: доска и счёт восстанавливаются из ОДНОЙ
//  последовательности событий.
//
//  Зачем. Сейчас доска и счёт сохраняются как два снимка. При падении между
//  их записями они восстановятся на разных состояниях: цифра на доске есть,
//  а очков за неё нет — или наоборот. Заметить это невозможно, а исправить
//  задним числом нельзя, потому что неизвестно, какое из двух состояний верное.
//
//  Журнал снимает проблему по построению: состояние — это функция от истории,
//  а история пишется транзакциями. Либо вся команда игрока попала в журнал,
//  либо не попала ни одна её часть.
//
//  Три инварианта, ради которых всё и затевалось:
//   • последовательность непрерывна — пропуск означает потерю события;
//   • повтор события с тем же отпечатком безвреден, с другим — повреждение;
//   • после `puzzleCompleted` журнал запечатан.
//

import Foundation

// MARK: - Устойчивый отпечаток

/// FNV-1a, 64 бита.
///
/// Стандартный `Hasher` не подходит принципиально: он засеивается случайно при
/// каждом запуске процесса, поэтому сохранённый отпечаток не совпал бы с
/// пересчитанным после перезапуска приложения. Здесь нужна воспроизводимость,
/// а не защита от подбора.
public enum StableDigest {

    private static let offset: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    /// Единственный публичный вход.
    ///
    /// Перегрузок здесь намеренно нет. `Data` удовлетворяет и `Sequence<UInt8>`,
    /// и `Encodable`, поэтому любая пара таких перегрузок делает вызов
    /// неоднозначным — компилятор не может выбрать за нас.
    ///
    /// Ключи сортируются, поэтому результат не зависит от порядка полей в
    /// конкретной версии Swift.
    public static func of(_ value: some Encodable) -> UInt64 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else {
            // Молчаливый ноль опаснее падения: все значения получили бы один
            // отпечаток, и журнал считал бы разные события повторами.
            // Частый источник — кодирование одиночного String или Int:
            // передавайте массив или структуру.
            assertionFailure("не удалось закодировать \(type(of: value)) для отпечатка")
            return 0
        }
        return fnv1a(data)
    }

    private static func fnv1a(_ bytes: some Sequence<UInt8>) -> UInt64 {
        var hash = offset
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }
}

// MARK: - События

public enum PlacementSource: String, Codable, Sendable {
    case user, reveal, systemFill
}

/// Исход одного размещения после проверки.
public struct PlacementOutcome: Codable, Equatable, Sendable {
    public let cell: Int
    public let digit: Int
    public let correct: Bool
    /// Порядок ввода. Пакет применяется хронологически, иначе серия
    /// построится не так, как при мгновенной сверке.
    public let commitSequence: UInt64

    public init(cell: Int, digit: Int, correct: Bool, commitSequence: UInt64) {
        self.cell = cell
        self.digit = digit
        self.correct = correct
        self.commitSequence = commitSequence
    }
}

/// Атомарный результат проверки: цена, исходы и закрытые группы одним событием.
///
/// Разбивать это на отдельные события нельзя: падение между «списали цену» и
/// «применили исходы» оставило бы игрока без результата, но со списанием.
public struct ValidationBatch: Codable, Equatable, Sendable {
    public let validationID: UUID
    public let isManualCheck: Bool
    public let isRuleOfMode: Bool
    public let valueRevision: UInt64
    public let outcomes: [PlacementOutcome]
    public let completedGroups: [Int]

    public init(validationID: UUID, isManualCheck: Bool, isRuleOfMode: Bool,
                valueRevision: UInt64, outcomes: [PlacementOutcome],
                completedGroups: [Int]) {
        self.validationID = validationID
        self.isManualCheck = isManualCheck
        self.isRuleOfMode = isRuleOfMode
        self.valueRevision = valueRevision
        self.outcomes = outcomes.sorted { $0.commitSequence < $1.commitSequence }
        self.completedGroups = completedGroups
    }
}

/// Канонический журнал доски И счёта. Второго журнала не существует:
/// счёт — это проекция этого же потока, а не отдельная история.
public enum GameJournalEvent: Codable, Equatable, Sendable {
    case sessionStarted(SessionDescriptor)
    case digitCommitted(cell: Int, digit: Int, source: PlacementSource)
    case digitRemoved(cell: Int)
    /// Заметки на очки не влияют, но без них восстановленная доска
    /// отличалась бы от той, что игрок оставил, — а он сравнивает глазами.
    case noteToggled(cell: Int, digit: Int)
    /// Отмена и повтор хода.
    ///
    /// Записывается именно намерение, а не «сотри клетку». Постановка цифры
    /// могла убрать её из заметок соседей — компенсирующее событие этого не
    /// вернёт. Воспроизведение ведёт ту же `MoveHistory`, что и игра, поэтому
    /// откат получается точным, а не приблизительным.
    case moveUndone
    case moveRedone
    case validationApplied(ValidationBatch)
    case hintLayerOpened(layer: HintLayer, revision: UInt64, stepDigest: UInt64)
    case candidateAidEscalated(CandidateAid)
    case puzzleCompleted(elapsedMs: Int, expectedMs: Int, paceEligible: Bool)
}

public struct SessionDescriptor: Codable, Equatable, Sendable {
    public let puzzleID: String
    /// Исходная задача. Задаёт, какие клетки нельзя менять.
    public let givens: String
    /// Позиция, С КОТОРОЙ начинается эта сессия журнала. Обычно совпадает с
    /// `givens`, но не всегда.
    ///
    /// Без этого поля журнал не мог выразить две законные ситуации: партию,
    /// сохранённую до появления журнала (доска уже наполовину заполнена), и
    /// перезапуск задачи. В обоих случаях воспроизведение стартовало бы с
    /// пустой доски, расходилось со снимком и помечало партию повреждённой —
    /// за действие, в котором игрок не виноват.
    public let startingBoard: String
    public let solution: String
    public let catalogVersion: String
    public let difficultyD: Int
    public let mode: GameMode
    public let policy: ScoreValidationPolicy
    /// Часть истории, а не текущая настройка. Если игрок переключит
    /// автосокращение после партии, воспроизведение обязано пойти по старому
    /// правилу — иначе заметки восстановятся не те, что были на экране.
    public let autoReduceNotes: Bool
    public let ruleSetID: String

    public init(puzzleID: String, givens: String, solution: String,
                catalogVersion: String, difficultyD: Int,
                mode: GameMode, policy: ScoreValidationPolicy,
                startingBoard: String? = nil,
                autoReduceNotes: Bool = false,
                ruleSetID: String = SessionScoreRuleSet.v1.id) {
        self.startingBoard = startingBoard ?? givens
        self.autoReduceNotes = autoReduceNotes
        self.puzzleID = puzzleID
        self.givens = givens
        self.solution = solution
        self.catalogVersion = catalogVersion
        self.difficultyD = difficultyD
        self.mode = mode
        self.policy = policy
        self.ruleSetID = ruleSetID
    }
}

// MARK: - Конверт

public struct GameEventEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1

    public let id: UUID
    /// Общий для всех событий одной команды игрока. По нему видно, что
    /// «ввод цифры» и «проверка» — одно действие, а не два.
    public let commandID: UUID
    public let sessionID: UUID
    public let sequence: UInt64
    public let schemaVersion: UInt16
    public let payloadDigest: UInt64
    public let payload: GameJournalEvent

    public init(id: UUID = UUID(), commandID: UUID, sessionID: UUID,
                sequence: UInt64, payload: GameJournalEvent,
                schemaVersion: UInt16 = GameEventEnvelope.currentSchemaVersion) {
        self.id = id
        self.commandID = commandID
        self.sessionID = sessionID
        self.sequence = sequence
        self.schemaVersion = schemaVersion
        self.payloadDigest = StableDigest.of(payload)
        self.payload = payload
    }
}

// MARK: - Журнал

public struct SessionJournal: Equatable, Sendable {

    public enum Failure: Error, Equatable, Sendable {
        case wrongSession
        case sequenceGap(expected: UInt64, got: UInt64)
        case corruptedDuplicate(UUID)
        /// Конверт не сходится со СВОИМ ЖЕ отпечатком: нагрузка изменилась
        /// после записи. Это не повтор — событие пришло впервые, — поэтому и
        /// случай отдельный: `corruptedDuplicate` говорит о двух версиях
        /// одного события, а здесь версия одна и она испорчена.
        case corruptedPayload(UUID)
        case unsupportedSchema(UInt16)
        case sealed
    }

    public let sessionID: UUID
    public private(set) var envelopes: [GameEventEnvelope] = []
    public private(set) var lastSequence: UInt64 = 0
    public private(set) var isSealed = false

    private var digestByID: [UUID: UInt64] = [:]

    public init(sessionID: UUID = UUID()) {
        self.sessionID = sessionID
    }

    /// Транзакция целиком или ничего.
    ///
    /// Проверка делается на КОПИИ, и только при полном успехе результат
    /// становится состоянием. Иначе частично применённая команда оставила бы
    /// журнал в состоянии, которого никогда не было.
    @discardableResult
    public mutating func appendTransaction(
        _ events: [GameJournalEvent],
        commandID: UUID = UUID()
    ) throws -> [GameEventEnvelope] {
        guard !isSealed else { throw Failure.sealed }
        var trial = self
        var appended: [GameEventEnvelope] = []
        for event in events {
            let envelope = GameEventEnvelope(commandID: commandID,
                                             sessionID: sessionID,
                                             sequence: trial.lastSequence + 1,
                                             payload: event)
            try trial.accept(envelope)
            appended.append(envelope)
        }
        self = trial
        return appended
    }

    /// Приём готового конверта — путь восстановления из хранилища.
    public mutating func accept(_ envelope: GameEventEnvelope) throws {
        guard envelope.schemaVersion <= GameEventEnvelope.currentSchemaVersion else {
            // Неизвестная версия ОСТАНАВЛИВАЕТ восстановление, а не молча
            // пропускается: пропущенное событие исказит и доску, и счёт.
            throw Failure.unsupportedSchema(envelope.schemaVersion)
        }
        // Отпечаток ПЕРЕСЧИТЫВАЕТСЯ из самой нагрузки, а не просто сверяется с
        // ранее запомненным числом. Сверка с `digestByID` ниже ловит ровно один
        // случай — один идентификатор, доставленный дважды с разным
        // содержимым; конверт, испорченный на диске и пришедший ВПЕРВЫЕ,
        // проходил бы её насквозь вместе со своим (тоже испорченным или просто
        // устаревшим) полем `payloadDigest`. Пересчёт делает это поле настоящей
        // контрольной суммой, ради которой оно и хранится.
        //
        // Считается тем же `StableDigest.of`, что вызывает `init` конверта:
        // вторая, параллельная реализация однажды разошлась бы с первой — и
        // весь сохранённый журнал стал бы «повреждённым» на ровном месте.
        //
        // Порядок важен: версия схемы проверяется раньше, потому что она
        // задаёт, ЧТО именно закодировано и по чему считался отпечаток.
        guard StableDigest.of(envelope.payload) == envelope.payloadDigest else {
            throw Failure.corruptedPayload(envelope.id)
        }
        guard envelope.sessionID == sessionID else { throw Failure.wrongSession }

        if let known = digestByID[envelope.id] {
            // Повторная доставка того же события безвредна и ожидаема.
            guard known == envelope.payloadDigest else {
                throw Failure.corruptedDuplicate(envelope.id)
            }
            return
        }
        guard envelope.sequence == lastSequence + 1 else {
            throw Failure.sequenceGap(expected: lastSequence + 1, got: envelope.sequence)
        }
        guard !isSealed else { throw Failure.sealed }

        envelopes.append(envelope)
        digestByID[envelope.id] = envelope.payloadDigest
        lastSequence = envelope.sequence
        if case .puzzleCompleted = envelope.payload { isSealed = true }
    }

    // MARK: - Границы команд

    /// События, сгруппированные по команде игрока, в порядке появления.
    ///
    /// Это ЕДИНИЦА ЗАПИСИ НА ДИСК. Внутри команды доска и счёт заведомо
    /// расходятся: цифра уже поставлена, а её исход ещё не подтверждён.
    /// Согласованность гарантируется только на границе команды — поэтому
    /// хранилище обязано писать команду целиком, одной транзакцией.
    /// Сохранение по одному событию свело бы весь журнал на нет.
    public var commands: [[GameEventEnvelope]] {
        var result: [[GameEventEnvelope]] = []
        for envelope in envelopes {
            if let last = result.last, last[0].commandID == envelope.commandID {
                result[result.count - 1].append(envelope)
            } else {
                result.append([envelope])
            }
        }
        return result
    }

    /// Сколько событий занимают первые `count` команд. Ровно на этих отсечках
    /// восстановление обязано давать согласованное состояние.
    public func envelopeCount(throughCommand count: Int) -> Int {
        commands.prefix(count).reduce(0) { $0 + $1.count }
    }

    // MARK: - Проекция

    public struct Projection: Equatable, Sendable {
        public var board: BoardState
        public var score: SessionScoreState
        public var descriptor: SessionDescriptor
        /// Растёт при каждом изменении значений: по нему различаются проверки.
        public var valueRevision: UInt64
        /// Стеки Undo/Redo, восстановленные вместе с доской. Раньше история
        /// хранилась отдельным снимком и могла оказаться из другого момента.
        public var history: MoveHistory
    }

    /// Сколько непустых клеток игрок поставил сам, без учёта подсказок задачи.
    static func placedCount(in board: BoardState) -> Int {
        (0..<81).filter { board[$0].value != 0 && !board[$0].isGiven }.count
    }

    /// Восстанавливает доску и счёт из ОДНОЙ истории. Разъехаться они не могут
    /// физически: обоих строит один и тот же проход.
    public func replay() -> Projection? {
        guard case let .sessionStarted(descriptor)? = envelopes.first?.payload,
              var board = BoardState(givens: descriptor.startingBoard),
              let givensBoard = BoardState(givens: descriptor.givens)
        else { return nil }

        // `isGiven` берётся из исходной задачи, а не из стартовой позиции:
        // иначе цифры, поставленные игроком до начала журнала, стали бы
        // неизменяемыми подсказками.
        for index in 0..<81 {
            var cell = board[index]
            cell.isGiven = givensBoard[index].isGiven
            board[index] = cell
        }

        // Бюджет считается от ИСХОДНОЙ задачи. Если считать от стартовой
        // позиции, восстановленная партия получила бы меньше пустых клеток
        // и другую цену клетки — счёт перестал бы быть сопоставимым.
        var score = SessionScoreState(budget: SessionScoreBudget(
            puzzleRating: descriptor.difficultyD,
            emptyCellCount: descriptor.givens.filter { $0 == "0" }.count
        ))
        var revision: UInt64 = 0
        var history = MoveHistory()
        let builder = MoveBuilder()

        /// Ходы проходят через историю ровно так же, как в живой партии:
        /// иначе Undo после восстановления откатил бы не то.
        func perform(_ transaction: MoveTransaction) {
            MoveApplier.apply(transaction, to: &board)
            history.record(transaction)
        }

        for envelope in envelopes.dropFirst() {
            switch envelope.payload {
            case .sessionStarted:
                continue   // второй старт невозможен, но и вреда не несёт

            case let .digitCommitted(cell, digit, source):
                perform(builder.placeDigit(digit, at: cell, board: board,
                                           autoReduceNotes: descriptor.autoReduceNotes,
                                           isReveal: source == .reveal))
                revision += 1
                if source != .user {
                    SessionScoreReducer.apply(.placementNonScoring(cell: cell), to: &score)
                }

            case let .digitRemoved(cell):
                perform(builder.erase(at: cell, board: board))
                revision += 1

            case let .noteToggled(cell, digit):
                perform(builder.toggleNote(digit, at: cell, board: board))

            case .moveUndone:
                history.undo(on: &board)
                revision += 1

            case .moveRedone:
                history.redo(on: &board)
                revision += 1

            case let .validationApplied(batch):
                if batch.isManualCheck {
                    SessionScoreReducer.apply(
                        .manualCheck(revision: batch.valueRevision,
                                     isRuleOfMode: batch.isRuleOfMode), to: &score)
                }
                var sawError = false
                for outcome in batch.outcomes {
                    if !outcome.correct { sawError = true }
                    SessionScoreReducer.apply(
                        .placementConfirmed(cell: outcome.cell, digit: outcome.digit,
                                            correct: outcome.correct), to: &score)
                }
                if sawError { SessionScoreReducer.registerStrike(in: &score) }
                if !batch.completedGroups.isEmpty {
                    SessionScoreReducer.apply(
                        .groupsConfirmed(batch.completedGroups), to: &score)
                }

            case let .hintLayerOpened(layer, hintRevision, digest):
                SessionScoreReducer.apply(
                    .hintOpened(layer: layer, revision: hintRevision,
                                stepHash: digest), to: &score)

            case let .candidateAidEscalated(aid):
                SessionScoreReducer.apply(.candidateAidEscalated(aid), to: &score)

            case let .puzzleCompleted(elapsedMs, expectedMs, paceEligible):
                SessionScoreReducer.apply(.puzzleCompleted, to: &score)
                SessionScoreReducer.apply(
                    .paceResolved(elapsedMs: elapsedMs, expectedMs: expectedMs,
                                  eligible: paceEligible), to: &score)
            }
        }

        return Projection(board: board, score: score, descriptor: descriptor,
                          valueRevision: revision, history: history)
    }
}
