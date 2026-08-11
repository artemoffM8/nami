//
//  JournalArchive.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  Перевод журнала в байты и обратно, с проверкой на входе.
//
//  Зачем отдельный тип и почему он в домене, а не в слое хранения. Восстановление
//  — это место, где ошибка стоит дороже всего: она молчаливая. Логику, которую
//  нельзя прогнать тестами, здесь держать нельзя, поэтому в `NamiData` остаётся
//  только чтение и запись байтов, а все решения принимаются тут.
//
//  Главное решение — что делать при расхождении журнала и снимка доски.
//  Выбрасывать партию несоразмерно: игрок теряет полчаса из-за нашей ошибки
//  хранения. Молча продолжать — тоже нельзя: счёт может оказаться завышенным, а
//  таблица лидеров обязана быть честной. Поэтому доска остаётся, а счёт теряет
//  право на запись.
//

import Foundation

public enum JournalArchive {

    /// Что удалось восстановить.
    public enum Restoration: Equatable, Sendable {
        /// Журнала нет — это партия, начатая до появления журнала, либо
        /// первая запись ещё не случилась.
        case empty
        /// Журнал прочитан и сошёлся с доской.
        case restored(SessionJournal, SessionScoreState)
        /// Журнал прочитан, но разошёлся с доской. Играть можно, писать в
        /// таблицу — нет.
        case distrusted(SessionJournal, SessionScoreState, reason: String)
        /// Журнал нечитаем. Счёт начинается заново; доска берётся из снимка.
        case unreadable(reason: String)
    }

    public static func encode(_ journal: SessionJournal) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(journal.envelopes)) ?? Data()
    }

    /// Читает журнал и сверяет его с уже восстановленной доской.
    ///
    /// `board` приходит из снимка — того же самого, что писался в одной
    /// транзакции с журналом. Именно поэтому расхождение здесь означает
    /// повреждение, а не гонку.
    public static func restore(_ data: Data, board: BoardState) -> Restoration {
        guard !data.isEmpty else { return .empty }

        let envelopes: [GameEventEnvelope]
        do {
            envelopes = try JSONDecoder().decode([GameEventEnvelope].self, from: data)
        } catch {
            return .unreadable(reason: "журнал не разобрался: \(error)")
        }
        guard let first = envelopes.first else { return .empty }

        var journal = SessionJournal(sessionID: first.sessionID)
        for envelope in envelopes {
            do {
                try journal.accept(envelope)
            } catch {
                // Обрываем на первом же нарушении, а не пропускаем событие:
                // пропуск исказил бы и доску, и счёт, но выглядел бы успехом.
                return .unreadable(reason: "событие \(envelope.sequence): \(error)")
            }
        }
        guard let projection = journal.replay() else {
            return .unreadable(reason: "журнал без события старта")
        }

        let fromJournal = SessionJournal.placedCount(in: projection.board)
        let fromSnapshot = SessionJournal.placedCount(in: board)
        guard fromJournal == fromSnapshot else {
            var distrusted = projection.score
            distrusted.markIntegrityBroken()
            return .distrusted(
                journal, distrusted,
                reason: "в журнале \(fromJournal) клеток, в снимке \(fromSnapshot)")
        }
        return .restored(journal, projection.score)
    }
}
