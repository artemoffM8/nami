//
//  StruggleDetector.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  Ненавязчивая помощь, когда игрок застрял. Обобщение «Guess Guard»
//  из раздела 9.4 на все виды затыка.
//
//  Правила, которые делают это НЕнавязчивым:
//   • не раньше минуты с начала партии — иначе лезем под руку сразу;
//   • максимум два предложения за партию;
//   • пауза между предложениями не меньше двух минут;
//   • любое действие игрока сбрасывает счётчики затыка;
//   • «Не сейчас» глушит детектор до конца партии;
//   • предложение НИКОГДА не блокирует поле и ничего не подсказывает само —
//     оно только предлагает открыть первый слой подсказки.
//
//  Детектор не знает про рейтинг: цена подсказки объявляется в UI.
//

import Foundation

public struct StruggleSignal: Equatable, Sendable {

    public enum Reason: String, Sendable, CaseIterable {
        /// Долго нет ввода, хотя логический ход на доске есть.
        case idleWithAvailableStep
        /// Несколько конфликтов правил за короткое окно.
        case repeatedConflicts
        /// Игрок раз за разом откатывает ходы.
        case repeatedUndo
        /// Активное время сильно превысило медиану, а доска почти не двигается.
        case overtime
    }

    public let reason: Reason

    public init(reason: Reason) { self.reason = reason }

    public var titleKey: String { "nudge.\(reason.rawValue).title" }
    public var bodyKey: String { "nudge.\(reason.rawValue).body" }
}

public struct StruggleDetector: Sendable {

    public struct Configuration: Sendable {
        public var minimumGameSeconds: Double = 60
        public var idleSeconds: Double = 75
        public var cooldownSeconds: Double = 120
        public var maxNudgesPerGame: Int = 2
        public var conflictsInWindow: Int = 3
        public var conflictWindowSeconds: Double = 60
        public var undoInWindow: Int = 4
        public var undoWindowSeconds: Double = 45
        /// Во сколько раз активное время должно превысить медиану задачи.
        public var overtimeFactor: Double = 1.8
        /// Насколько мало должно быть заполнено, чтобы «долго» значило «застрял».
        public var overtimeProgressCeiling: Double = 0.75

        public init() {}
    }

    public private(set) var configuration: Configuration
    public private(set) var nudgesShown = 0
    public private(set) var isMutedForGame = false

    /// «Игрок ещё ничего не сделал» — как и `lastNudgeAt`, признак задаётся
    /// сентинелом, а не нулём: ноль означал бы «активность была в начале
    /// эпохи часов», а у монотонных часов начало эпохи — это старт процесса,
    /// то есть буквально только что.
    private var lastActivityAt: Double = -.greatestFiniteMagnitude
    private var lastNudgeAt: Double = -.greatestFiniteMagnitude
    private var conflictTimes: [Double] = []
    private var undoTimes: [Double] = []
    /// Затык по «слишком долго» предлагаем один раз за партию.
    private var overtimeOffered = false

    public init(configuration: Configuration = Configuration(), startedAt: Double = -.greatestFiniteMagnitude) {
        self.configuration = configuration
        self.lastActivityAt = startedAt
    }

    // MARK: - Вход

    /// Любое осмысленное действие: ввод, заметка, стирание, выбор клетки.
    public mutating func recordActivity(at now: Double) {
        lastActivityAt = now
    }

    public mutating func recordConflict(at now: Double) {
        lastActivityAt = now
        conflictTimes.append(now)
        conflictTimes.removeAll { now - $0 > configuration.conflictWindowSeconds }
    }

    public mutating func recordUndo(at now: Double) {
        lastActivityAt = now
        undoTimes.append(now)
        undoTimes.removeAll { now - $0 > configuration.undoWindowSeconds }
    }

    /// Игрок сам открыл подсказку — предлагать её же бессмысленно.
    public mutating func recordHintOpened(at now: Double) {
        lastActivityAt = now
        conflictTimes.removeAll()
        undoTimes.removeAll()
        lastNudgeAt = now
    }

    /// «Не сейчас»: до конца партии молчим.
    public mutating func mute() { isMutedForGame = true }

    public mutating func nudgeAccepted(at now: Double) {
        nudgesShown += 1
        lastNudgeAt = now
        conflictTimes.removeAll()
        undoTimes.removeAll()
    }

    // MARK: - Решение

    /// Возвращает сигнал, если пора мягко предложить помощь.
    /// Вызывается периодически; сам по себе вызов ничего не меняет.
    public func evaluate(
        now: Double,
        gameSeconds: Double,
        expectedSeconds: Double,
        filledRatio: Double,
        hasLogicalStep: Bool
    ) -> StruggleSignal? {
        guard !isMutedForGame else { return nil }
        guard nudgesShown < configuration.maxNudgesPerGame else { return nil }
        guard gameSeconds >= configuration.minimumGameSeconds else { return nil }
        guard now - lastNudgeAt >= configuration.cooldownSeconds else { return nil }

        // Порядок важен: сначала самые конкретные причины, потом общая.
        if conflictTimes.count >= configuration.conflictsInWindow {
            return StruggleSignal(reason: .repeatedConflicts)
        }
        if undoTimes.count >= configuration.undoInWindow {
            return StruggleSignal(reason: .repeatedUndo)
        }
        // Молчим, если логического хода нет: предлагать «поищите ход»,
        // когда его не существует, — издевательство.
        if hasLogicalStep, now - lastActivityAt >= configuration.idleSeconds {
            return StruggleSignal(reason: .idleWithAvailableStep)
        }
        if !overtimeOffered,
           expectedSeconds > 0,
           gameSeconds >= expectedSeconds * configuration.overtimeFactor,
           filledRatio < configuration.overtimeProgressCeiling,
           hasLogicalStep {
            return StruggleSignal(reason: .overtime)
        }
        return nil
    }

    /// Отмечает, что сигнал показан, чтобы он не повторялся сразу же.
    public mutating func markShown(_ signal: StruggleSignal, at now: Double) {
        lastNudgeAt = now
        nudgesShown += 1
        if signal.reason == .overtime { overtimeOffered = true }
        conflictTimes.removeAll()
        undoTimes.removeAll()
    }
}
