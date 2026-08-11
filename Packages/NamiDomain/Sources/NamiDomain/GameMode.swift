//
//  GameMode.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  Верхний выбор перед партией: считается результат или нет.
//
//  Зачем это отдельная сущность, а не производная от журнала помощи.
//  Раньше рейтинговость решалась четырьмя скрытыми условиями — открыл цифру,
//  три подтверждённые ошибки, перезапуск, повтор задачи — и игрок узнавал
//  о них ПОСЛЕ партии. Явный режим переворачивает порядок: обещание даётся
//  до старта, а журнал помощи может только подтвердить его, но не создать.
//
//  Инвариант: режим способен ТОЛЬКО снять рейтинг, но никогда его не вернуть.
//  `relaxed` — всегда без рейтинга; `ranked` — при условии чистого журнала.
//

import Foundation

public enum GameMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Помощь бесплатна, ошибки ничего не стоят, результат не считается.
    case relaxed
    /// Работают коэффициенты помощи, результат меняет рейтинг.
    case ranked

    public var id: String { rawValue }

    public var titleKey: String { "mode.\(rawValue).title" }
    public var subtitleKey: String { "mode.\(rawValue).subtitle" }
    public var badgeKey: String { "mode.\(rawValue).badge" }

    /// Тема, которую режим предлагает при первом входе. Явный выбор игрока
    /// её перекрывает и запоминается отдельно для каждого режима.
    public var suggestedThemeID: String {
        switch self {
        case .relaxed: "paper-default"
        case .ranked: "dark"
        }
    }

    public var appliesRating: Bool { self == .ranked }
}
