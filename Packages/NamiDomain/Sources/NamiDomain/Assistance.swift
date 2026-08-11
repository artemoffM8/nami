//
//  Assistance.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  Профили помощи, изменяемая политика сессии и МОНОТОННЫЙ журнал фактического
//  использования (разделы 4.5, 5.7, 9.3). Ключевой инвариант:
//  смена профиля, изменение настроек и Undo не уменьшают ledger.
//

import Foundation

// MARK: - Профили

public enum AssistanceProfile: String, Codable, CaseIterable, Sendable {
    case paper       // «Бумага»
    case focus       // «Фокус» — по умолчанию
    case assistant   // «Ассистент»

    public var titleKey: String { "assistance.\(rawValue).title" }
    public var summaryKey: String { "assistance.\(rawValue).summary" }

    public var preset: SessionPolicy {
        switch self {
        case .paper:
            SessionPolicy(
                validation: .manualOnly,
                keypadHints: .off,
                fieldCandidates: .off,
                autoReduceNotes: false,
                impossibleNoteWarning: false,
                singleCandidateHighlight: false,
                dimCompletedDigits: false,
                highlightSameDigit: true
            )
        case .focus:
            SessionPolicy(
                validation: .ruleConflictsOnly,
                keypadHints: .off,
                fieldCandidates: .lensOnDemand,
                autoReduceNotes: true,
                impossibleNoteWarning: false,
                singleCandidateHighlight: false,
                dimCompletedDigits: true,
                highlightSameDigit: true
            )
        case .assistant:
            SessionPolicy(
                validation: .againstSolution,
                keypadHints: .dimIllegal,
                fieldCandidates: .selectedCellPersistent,
                autoReduceNotes: true,
                impossibleNoteWarning: true,
                singleCandidateHighlight: true,
                dimCompletedDigits: true,
                highlightSameDigit: true
            )
        }
    }
}

// MARK: - Политика сессии

public struct SessionPolicy: Codable, Equatable, Sendable {

    public enum Validation: String, Codable, Sendable {
        /// Только явное действие «Проверить» — приложение не сверяет ввод само.
        case manualOnly
        /// Мгновенная подсветка конфликтов правил. Нейтрально для рейтинга.
        case ruleConflictsOnly
        /// Автоматическое сравнение ввода с решением.
        case againstSolution
    }

    public enum KeypadHints: String, Codable, Sendable {
        case off
        case dimIllegal
    }

    public enum FieldCandidates: String, Codable, Sendable {
        case off
        case lensOnDemand
        case selectedCellPersistent
        case wholeBoard
    }

    public var validation: Validation
    public var keypadHints: KeypadHints
    public var fieldCandidates: FieldCandidates
    public var autoReduceNotes: Bool
    public var impossibleNoteWarning: Bool
    public var singleCandidateHighlight: Bool
    public var dimCompletedDigits: Bool
    public var highlightSameDigit: Bool

    public init(
        validation: Validation,
        keypadHints: KeypadHints,
        fieldCandidates: FieldCandidates,
        autoReduceNotes: Bool,
        impossibleNoteWarning: Bool,
        singleCandidateHighlight: Bool,
        dimCompletedDigits: Bool,
        highlightSameDigit: Bool
    ) {
        self.validation = validation
        self.keypadHints = keypadHints
        self.fieldCandidates = fieldCandidates
        self.autoReduceNotes = autoReduceNotes
        self.impossibleNoteWarning = impossibleNoteWarning
        self.singleCandidateHighlight = singleCandidateHighlight
        self.dimCompletedDigits = dimCompletedDigits
        self.highlightSameDigit = highlightSameDigit
    }

    /// Совпадает ли текущая политика с пресетом профиля — от этого зависит
    /// метка «Настроено · на основе [профиля]» (раздел 5.7).
    public func matchesPreset(of profile: AssistanceProfile) -> Bool {
        self == profile.preset
    }

    /// Модификатор No Notes выключает всю визуальную помощь по кандидатам.
    public func applyingNoNotes() -> SessionPolicy {
        var copy = self
        copy.keypadHints = .off
        copy.fieldCandidates = .off
        copy.autoReduceNotes = false
        copy.impossibleNoteWarning = false
        copy.singleCandidateHighlight = false
        return copy
    }

    /// Perfect принудительно сверяет с решением — это правило режима,
    /// нейтральное для `validationAid` при успешном прохождении (раздел 5.7).
    public func applyingPerfect() -> SessionPolicy {
        var copy = self
        copy.validation = .againstSolution
        return copy
    }
}

// MARK: - Категории помощи

/// Максимальная фактически использованная помощь по кандидатам (раздел 9.3).
public enum CandidateAid: Int, Codable, Comparable, Sendable, CaseIterable {
    case none = 0
    case keypadDimming = 1
    case lens = 2
    case selectedCellPersistent = 3
    case wholeBoard = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var penalty: Double {
        switch self {
        case .none: 0.00
        case .keypadDimming: 0.02
        case .lens: 0.06
        case .selectedCellPersistent: 0.08
        case .wholeBoard: 0.12
        }
    }
}

/// Максимальный раскрытый слой подсказки (раздел 4.2).
public enum HintLayer: Int, Codable, Comparable, Sendable, CaseIterable {
    case none = 0
    case region = 1
    case techniqueName = 2
    case candidatesAndLogic = 3
    case reveal = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Reveal не имеет коэффициента: партия становится нерейтинговой.
    public var penalty: Double {
        switch self {
        case .none: 0.00
        case .region: 0.03
        case .techniqueName: 0.06
        case .candidatesAndLogic: 0.14
        case .reveal: 0.00
        }
    }

    public var next: HintLayer? {
        HintLayer(rawValue: rawValue + 1)
    }

    public var titleKey: String { "hint.layer.\(rawValue).title" }
}

/// Максимально использованный проверочный сигнал (раздел 9.3).
public enum ValidationAid: Int, Codable, Comparable, Sendable, CaseIterable {
    case none = 0
    case impossibleNoteWarning = 1
    case singleCandidateHighlight = 2
    case manualCheck = 3
    case automaticSolutionCheck = 4

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var penalty: Double {
        switch self {
        case .none: 0.00
        case .impossibleNoteWarning: 0.02
        case .singleCandidateHighlight: 0.03
        case .manualCheck: 0.04
        case .automaticSolutionCheck: 0.06
        }
    }
}

// MARK: - Монотонный журнал использования

public struct AssistanceUsageLedger: Codable, Equatable, Sendable {

    /// Режим объявляется до старта и дальше не меняется.
    public var mode: GameMode = .ranked

    public private(set) var candidateAid: CandidateAid = .none
    public private(set) var hintLayer: HintLayer = .none
    public private(set) var validationAid: ValidationAid = .none
    public private(set) var confirmedGuessStrikes: Int = 0
    public private(set) var accuracyErrors: Int = 0
    /// Пары `(cell, digit)`, уже подтверждённые как неверные — защита от двойного strike.
    public private(set) var confirmedMismatches: Set<String> = []
    public private(set) var revealUsed = false
    /// Perfect: первая неверная цифра завершает попытку без рейтингового
    /// результата (раздел 11). Это правило режима, а не наказание рейтингом.
    public private(set) var perfectFailed = false
    /// Perfect: принудительная сверка нейтральна и не пишет `validationAid`.
    public var validationIsRuleOfMode = false

    public init() {}

    public mutating func record(candidateAid aid: CandidateAid) {
        candidateAid = max(candidateAid, aid)
    }

    public mutating func record(hintLayer layer: HintLayer) {
        hintLayer = max(hintLayer, layer)
        if layer == .reveal { revealUsed = true }
    }

    public mutating func record(validationAid aid: ValidationAid) {
        guard !validationIsRuleOfMode else { return }
        validationAid = max(validationAid, aid)
    }

    public mutating func recordAccuracyError() { accuracyErrors += 1 }

    /// Единственный domain-триггер strike: цифра уже ЯВНО показана игроку как
    /// несовпадающая с каноническим решением (раздел 9.4).
    /// Возвращает `true`, если strike новый.
    @discardableResult
    public mutating func registerSolutionMismatch(cell: Int, digit: Int) -> Bool {
        let key = "\(cell):\(digit)"
        guard !confirmedMismatches.contains(key) else { return false }
        confirmedMismatches.insert(key)
        confirmedGuessStrikes += 1
        return true
    }

    /// Одно нажатие «Проверить» создаёт максимум один strike независимо от
    /// числа неверных клеток (раздел 9.4).
    @discardableResult
    public mutating func registerManualCheck(mismatches: [(cell: Int, digit: Int)]) -> Bool {
        record(validationAid: .manualCheck)
        var created = false
        for mismatch in mismatches {
            let key = "\(mismatch.cell):\(mismatch.digit)"
            if confirmedMismatches.contains(key) { continue }
            confirmedMismatches.insert(key)
            if !created {
                confirmedGuessStrikes += 1
                created = true
            }
        }
        return created
    }

    public mutating func registerPerfectFailure() { perfectFailed = true }

    /// Игрок перезапустил ту же задачу. Доска чистая, но результат
    /// тренировочный: иначе можно было бы подсмотреть подсказками,
    /// начать заново и получить полный рейтинг.
    public private(set) var restartedWithoutRating = false
    public mutating func registerRestart() { restartedWithoutRating = true }

    /// Третий подтверждённый strike переводит попытку в practice.
    public var isPractice: Bool { confirmedGuessStrikes >= 3 || perfectFailed }
    /// Режим может только СНЯТЬ рейтинг: «Релакс» не считается никогда,
    /// «Рейтинг» — лишь если журнал помощи это позволяет.
    public var isRanked: Bool {
        mode.appliesRating && !revealUsed && !isPractice && !restartedWithoutRating
    }

    public var assistPenalty: Double {
        min(candidateAid.penalty + hintLayer.penalty + validationAid.penalty, 0.24)
    }

    public var guessPenalty: Double {
        min(Double(confirmedGuessStrikes) * 0.06, 0.12)
    }

    /// Метка до старта строится из доступных возможностей, а в паузе —
    /// из фактического ledger (раздел 5.7).
    public enum RatingLabel: String, Sendable {
        case full, adjusted, unranked
    }

    public var ratingLabel: RatingLabel {
        if !isRanked { return .unranked }
        return assistPenalty > 0 || guessPenalty > 0 ? .adjusted : .full
    }

    /// Прогноз метки по политике ДО старта: какая максимальная помощь возможна.
    public static func projectedLabel(for policy: SessionPolicy) -> RatingLabel {
        let candidate: CandidateAid = switch policy.fieldCandidates {
        case .off: policy.keypadHints == .dimIllegal ? .keypadDimming : .none
        case .lensOnDemand: .lens
        case .selectedCellPersistent: .selectedCellPersistent
        case .wholeBoard: .wholeBoard
        }
        let validation: ValidationAid = switch policy.validation {
        case .manualOnly: .none
        case .ruleConflictsOnly: .none
        case .againstSolution: .automaticSolutionCheck
        }
        return candidate == .none && validation == .none ? .full : .adjusted
    }
}
