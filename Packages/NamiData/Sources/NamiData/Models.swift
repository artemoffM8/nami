//
//  Models.swift
//  NamiData
//
//  Created by artemoffM8.
//
//  SwiftData-модели (раздел 13.7). Сложные value-типы домена хранятся как
//  JSON-Data с типизированными аксессорами: это делает миграцию предсказуемой
//  и не пускает SwiftData внутрь доменных структур.
//

import Foundation
import SwiftData
import NamiDomain

public enum PersistenceSchema {
    public static let currentVersion = 1

    @MainActor
    public static let models: [any PersistentModel.Type] = [
        SavedGame.self,
        GameResult.self,
        AppliedRatingResult.self,
        PlayerProfile.self,
        DailyProgress.self,
        UnlockedExperiencePack.self
    ]
}

// MARK: - Сохранённая партия

@Model
public final class SavedGame {
    /// Одна активная партия за раз в MVP.
    @Attribute(.unique) public var slot: String
    public var schemaVersion: Int
    public var puzzleID: String
    public var catalogVersion: String
    public var boardSerialized: String
    public var givensSerialized: String
    public var notesMasks: [Int]
    public var historyData: Data
    public var initialProfileID: String
    public var sessionPolicyData: Data
    public var ledgerData: Data
    public var timingData: Data
    public var challengeModifiers: [String]
    public var ratingPaceModeRaw: String
    public var dailyCompetitionVersion: String?
    /// Журнал событий партии. Пишется той же транзакцией, что и снимок выше:
    /// именно поэтому доска и счёт не могут оказаться из разных моментов.
    ///
    /// Тип опциональный не для удобства, а ради миграции: у партий, сохранённых
    /// до появления журнала, поля просто нет. Добавление необязательного
    /// свойства SwiftData переносит автоматически, и старое сохранение
    /// открывается, а не превращается в «несовместимую схему».
    public var journalData: Data?
    /// Режим партии. До появления поля восстановление всегда получало
    /// «рейтинг», и партия, начатая в «Релаксе», после перезапуска начинала
    /// менять рейтинг — притом что игроку обещали обратное.
    public var gameModeRaw: String?
    public var updatedAt: Date

    public init(
        slot: String = "current",
        schemaVersion: Int = PersistenceSchema.currentVersion,
        puzzleID: String,
        catalogVersion: String,
        boardSerialized: String,
        givensSerialized: String,
        notesMasks: [Int],
        historyData: Data,
        initialProfileID: String,
        sessionPolicyData: Data,
        ledgerData: Data,
        timingData: Data,
        challengeModifiers: [String],
        ratingPaceModeRaw: String,
        dailyCompetitionVersion: String?,
        journalData: Data? = nil,
        gameModeRaw: String? = nil,
        updatedAt: Date = .now
    ) {
        self.journalData = journalData
        self.gameModeRaw = gameModeRaw
        self.slot = slot
        self.schemaVersion = schemaVersion
        self.puzzleID = puzzleID
        self.catalogVersion = catalogVersion
        self.boardSerialized = boardSerialized
        self.givensSerialized = givensSerialized
        self.notesMasks = notesMasks
        self.historyData = historyData
        self.initialProfileID = initialProfileID
        self.sessionPolicyData = sessionPolicyData
        self.ledgerData = ledgerData
        self.timingData = timingData
        self.challengeModifiers = challengeModifiers
        self.ratingPaceModeRaw = ratingPaceModeRaw
        self.dailyCompetitionVersion = dailyCompetitionVersion
        self.updatedAt = updatedAt
    }
}

// MARK: - Результаты

@Model
public final class GameResult {
    @Attribute(.unique) public var id: String
    public var puzzleID: String
    public var catalogVersion: String
    public var tierRaw: String
    public var completedAt: Date
    public var activeSeconds: Int
    public var challengeElapsedSeconds: Int
    public var deltaR: Int
    public var ratingAfter: Int
    public var isRanked: Bool
    public var isPractice: Bool
    public var reasonCodeRaw: String
    public var ledgerData: Data
    public var initialProfileID: String
    public var ratingAlgorithmVersion: String
    public var isDaily: Bool
    public var dailyScore: Int?
    /// Попытка сопоставима с personal best: без паузы, без подсказок глубже
    /// «Области», без Reveal и без подтверждённых ошибок (раздел 11).
    public var wasComparable: Bool = false
    public var challengeModifiers: [String] = []
    public var ratingPaceModeRaw: String = RatingPaceMode.disabled.rawValue
    /// Техники, которых требовала задача. Нужны для коллекции в статистике.
    public var techniques: [String] = []

    /// Счёт партии. Опционален не для удобства, а ради миграции: у партий,
    /// сыгранных до появления счёта, его нет, и `nil` честнее нуля — иначе
    /// старые результаты испортили бы рекорды нулями.
    public var sessionScore: Int?
    /// Максимальный множитель за партию, в промилле. Хранится отдельно от
    /// счёта: длинная серия — самостоятельное достижение, а итоговое число
    /// зависит ещё и от сложности задачи.
    public var maxMultiplierPermille: Int?

    public init(
        id: String,
        puzzleID: String,
        catalogVersion: String,
        tierRaw: String,
        completedAt: Date,
        activeSeconds: Int,
        challengeElapsedSeconds: Int,
        deltaR: Int,
        ratingAfter: Int,
        isRanked: Bool,
        isPractice: Bool,
        reasonCodeRaw: String,
        ledgerData: Data,
        initialProfileID: String,
        ratingAlgorithmVersion: String,
        isDaily: Bool,
        dailyScore: Int?,
        wasComparable: Bool = false,
        challengeModifiers: [String] = [],
        ratingPaceModeRaw: String = RatingPaceMode.disabled.rawValue,
        techniques: [String] = [],
        sessionScore: Int? = nil,
        maxMultiplierPermille: Int? = nil
    ) {
        self.sessionScore = sessionScore
        self.maxMultiplierPermille = maxMultiplierPermille
        self.id = id
        self.puzzleID = puzzleID
        self.catalogVersion = catalogVersion
        self.tierRaw = tierRaw
        self.completedAt = completedAt
        self.activeSeconds = activeSeconds
        self.challengeElapsedSeconds = challengeElapsedSeconds
        self.deltaR = deltaR
        self.ratingAfter = ratingAfter
        self.isRanked = isRanked
        self.isPractice = isPractice
        self.reasonCodeRaw = reasonCodeRaw
        self.ledgerData = ledgerData
        self.initialProfileID = initialProfileID
        self.ratingAlgorithmVersion = ratingAlgorithmVersion
        self.isDaily = isDaily
        self.dailyScore = dailyScore
        self.wasComparable = wasComparable
        self.challengeModifiers = challengeModifiers
        self.ratingPaceModeRaw = ratingPaceModeRaw
        self.techniques = techniques
    }
}

/// Гарантия exactly-once: уникальный `ratedResultID` и сохранённый итог,
/// чтобы повтор после crash/retry был no-op (раздел 9.7).
@Model
public final class AppliedRatingResult {
    @Attribute(.unique) public var ratedResultID: String
    public var appliedAt: Date
    public var deltaR: Int
    public var ratingAfter: Int
    public var snapshotData: Data

    public init(ratedResultID: String, appliedAt: Date, deltaR: Int,
                ratingAfter: Int, snapshotData: Data) {
        self.ratedResultID = ratedResultID
        self.appliedAt = appliedAt
        self.deltaR = deltaR
        self.ratingAfter = ratingAfter
        self.snapshotData = snapshotData
    }
}

// MARK: - Профиль

@Model
public final class PlayerProfile {
    @Attribute(.unique) public var id: String
    public var snapshotData: Data
    public var assistanceProfileRaw: String
    public var sessionPolicyData: Data?
    public var interfaceCoachNotesShown: Bool
    public var interfaceCoachHintShown: Bool
    public var onboardingCompleted: Bool
    public var createdAt: Date

    public init(
        id: String = "player",
        snapshotData: Data,
        assistanceProfileRaw: String = AssistanceProfile.focus.rawValue,
        sessionPolicyData: Data? = nil,
        interfaceCoachNotesShown: Bool = false,
        interfaceCoachHintShown: Bool = false,
        onboardingCompleted: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.snapshotData = snapshotData
        self.assistanceProfileRaw = assistanceProfileRaw
        self.sessionPolicyData = sessionPolicyData
        self.interfaceCoachNotesShown = interfaceCoachNotesShown
        self.interfaceCoachHintShown = interfaceCoachHintShown
        self.onboardingCompleted = onboardingCompleted
        self.createdAt = createdAt
    }
}

@Model
public final class DailyProgress {
    /// `yyyy-MM-dd` в календаре пользователя.
    @Attribute(.unique) public var dayKey: String
    public var puzzleID: String
    public var completedAt: Date?
    public var dailyScore: Int?
    public var competitionVersion: String
    public var leaderboardSubmitted: Bool

    public init(dayKey: String, puzzleID: String, completedAt: Date? = nil,
                dailyScore: Int? = nil, competitionVersion: String,
                leaderboardSubmitted: Bool = false) {
        self.dayKey = dayKey
        self.puzzleID = puzzleID
        self.completedAt = completedAt
        self.dailyScore = dailyScore
        self.competitionVersion = competitionVersion
        self.leaderboardSubmitted = leaderboardSubmitted
    }
}

@Model
public final class UnlockedExperiencePack {
    @Attribute(.unique) public var packID: String
    public var kind: String          // theme | sound | motion | haptic
    public var unlockedAt: Date

    public init(packID: String, kind: String, unlockedAt: Date = .now) {
        self.packID = packID
        self.kind = kind
        self.unlockedAt = unlockedAt
    }
}

// MARK: - Кодирование доменных типов

public enum DomainCoding {
    /// JSONEncoder/JSONDecoder не Sendable, поэтому создаются на месте,
    /// а не хранятся статически: в Swift 6 общий изменяемый кодер — гонка.
    ///
    /// Внимание: снисходительный запасной вариант (`Data()` при ошибке)
    /// годится только там, где потеря блока данных заметна сразу — снимок
    /// партии не откроется, и игрок это увидит. Для значений, потеря которых
    /// молчалива, он неприменим: рейтинговый snapshot читается и пишется
    /// через `RatingSnapshotArchive`, который различает «данных ещё нет» и
    /// «данные не читаются» и бросает вместо пустых байтов.
    public static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}
