//
//  FeedbackCoordinator.swift
//  NamiExperience
//
//  Created by artemoffM8.
//
//  Раздел 7.4. Жёсткие инварианты:
//   • одно осмысленное действие -> максимум один sound и один haptic;
//   • победа/группа ЗАМЕНЯЕТ базовый click, а не добавляется к нему;
//   • channel budget 100 мс без очереди: устаревшая низкоприоритетная команда
//     отбрасывается, а не проигрывается позже;
//   • Reduce Motion полностью убирает scale, волны, частицы и параллакс.
//

import Foundation
import Observation
import NamiDomain

public enum EffectIntensity: String, Codable, CaseIterable, Sendable {
    case off, quiet, full

    public var particleScale: Double {
        switch self {
        case .off: 0
        case .quiet: 0.4
        case .full: 1.0
        }
    }

    public var titleKey: String { "settings.effects.\(rawValue)" }
}

public enum AnimationPreset: String, Codable, Sendable {
    case none, fade, lineWave, boxBloom, boardWave, rankGrowth
}

public enum HapticPattern: String, Codable, Sendable {
    case none, selection, lightImpact, groupTransient, success, softRigid
}

public enum SoundAsset: String, Codable, Sendable {
    case none
    case cellSelected       // очень лёгкий отклик на выбор клетки
    case digitPlaced        // мягкий бумажный click
    case digitErased        // мягкое стирание
    case noteToggled        // тихий сухой tap
    case groupCompleted     // короткий pop / стеклянный bell
    case conflict           // по умолчанию выключен
    case victory            // джингл 0.8-1.2 сек
    case uiConfirm          // подтверждение вне игрового поля
}

/// Смысл события для реакции отдельных клеток.
///
/// Именно смысл, а не вид эффекта: чем ответить — дрожанием, миганием или
/// наклоном — решает тема, а координатор про темы ничего не знает.
///
/// Без этого признака различить события было бы нечем: и стирание цифры, и
/// обнаруженный конфликт приходят с `animation == .none`, и клетка дрожала бы
/// при каждом стирании.
public enum ReactionCue: String, Equatable, Sendable {
    case none
    case error
    case group
}

public struct FeedbackCommand: Equatable, Sendable {
    public let transactionID: UUID
    public let animation: AnimationPreset
    public let sound: SoundAsset
    public let haptic: HapticPattern
    public let particleCount: Int
    /// Клетки, которые подсвечивает анимация.
    public let cells: [Int]
    public let cue: ReactionCue

    public init(
        transactionID: UUID,
        animation: AnimationPreset,
        sound: SoundAsset,
        haptic: HapticPattern,
        particleCount: Int,
        cells: [Int],
        cue: ReactionCue = .none
    ) {
        self.transactionID = transactionID
        self.animation = animation
        self.sound = sound
        self.haptic = haptic
        self.particleCount = particleCount
        self.cells = cells
        self.cue = cue
    }
}

/// Настройки, влияющие на выбор команды.
public struct FeedbackSettings: Equatable, Sendable {
    public var intensity: EffectIntensity = .full
    public var soundEnabled = true
    public var hapticsEnabled = true
    public var conflictSoundEnabled = false
    public var conflictHapticEnabled = false
    public var reduceMotion = false
    public var particlesEnabled = true

    public init() {}
}

@Observable
@MainActor
public final class FeedbackCoordinator {

    public var settings = FeedbackSettings()
    /// Последняя выбранная команда — её исполняют плееры и AnimationDirector.
    public private(set) var lastCommand: FeedbackCommand?

    private let clock: any MonotonicClock
    private var lastBaseChannelTime: Double = -.greatestFiniteMagnitude
    /// Cooldown после Undo, чтобы эффект группы нельзя было спамить.
    private var lastGroupEffectTime: Double = -.greatestFiniteMagnitude

    public static let baseChannelBudget: Double = 0.100   // 100 мс
    public static let groupCooldown: Double = 0.350

    private let sound: any SoundPlaying
    private let haptics: any HapticPlaying

    /// Плееры приходят опционально: дефолтное значение аргумента вычисляется
    /// в nonisolated-контексте, а их `init` изолирован на MainActor —
    /// поэтому подстановка происходит уже в теле, внутри изоляции.
    public init(
        clock: any MonotonicClock = SystemMonotonicClock(),
        sound: (any SoundPlaying)? = nil,
        haptics: (any HapticPlaying)? = nil
    ) {
        self.clock = clock
        self.sound = sound ?? SilentSoundPlayer()
        self.haptics = haptics ?? SystemHapticPlayer()
    }

    /// Единственная точка входа: все производные события одного хода приходят вместе.
    @discardableResult
    public func handle(_ transaction: FeedbackTransaction) -> FeedbackCommand? {
        guard let dominant = transaction.dominant else { return nil }
        guard let command = makeCommand(for: dominant, transaction: transaction) else { return nil }

        let now = clock.now
        let isBaseChannel = dominant.priority <= 2

        // Channel budget: без очереди, устаревшая команда просто отбрасывается.
        if isBaseChannel, now - lastBaseChannelTime < Self.baseChannelBudget {
            let visualOnly = FeedbackCommand(
                transactionID: transaction.id,
                animation: command.animation,
                sound: .none,
                haptic: .none,
                particleCount: command.particleCount,
                cells: command.cells,
                cue: command.cue
            )
            lastCommand = visualOnly
            return visualOnly   // визуальное подтверждение ввода показывается ВСЕГДА
        }
        if case .groupCompleted = dominant, now - lastGroupEffectTime < Self.groupCooldown {
            return nil
        }

        if isBaseChannel { lastBaseChannelTime = now }
        if case .groupCompleted = dominant { lastGroupEffectTime = now }

        lastCommand = command
        if command.sound != .none, settings.soundEnabled { sound.play(command.sound) }
        if command.haptic != .none, settings.hapticsEnabled { haptics.play(command.haptic) }
        return command
    }

    /// Визуальная часть команды отыграна. Снимаем её, чтобы `AnimationDirector`
    /// погасил display link и не крутил пустой кадр.
    public func clearVisual(id: UUID) {
        if lastCommand?.transactionID == id { lastCommand = nil }
    }

    /// Undo подавляет повторный celebratory-эффект.
    public func noteUndo() {
        lastGroupEffectTime = clock.now
    }

    // MARK: - Каноническая матрица feel (таблица раздела 7.4)

    private func makeCommand(
        for event: GameEvent,
        transaction: FeedbackTransaction
    ) -> FeedbackCommand? {
        let reduceMotion = settings.reduceMotion
        let particlesAllowed = settings.particlesEnabled
            && settings.intensity != .off
            && !reduceMotion

        switch event {
        case .cellSelected(let cell):
            return FeedbackCommand(transactionID: transaction.id,
                                   animation: reduceMotion ? .none : .fade,
                                   sound: .cellSelected, haptic: .selection,
                                   particleCount: 0, cells: [cell])

        case .digitErased(let cell):
            return FeedbackCommand(transactionID: transaction.id,
                                   animation: .none,
                                   sound: .digitErased, haptic: .selection,
                                   particleCount: 0, cells: [cell])

        case .digitPlaced(let cell, _):
            return FeedbackCommand(transactionID: transaction.id,
                                   animation: .fade,
                                   sound: .digitPlaced, haptic: .lightImpact,
                                   particleCount: 0, cells: [cell])

        case .notesChanged(let cell):
            return FeedbackCommand(transactionID: transaction.id,
                                   animation: .none,
                                   sound: .noteToggled,
                                   haptic: settings.intensity == .off ? .none : .selection,
                                   particleCount: 0, cells: [cell])

        case .conflictDetected(let cells):
            // Цвет + подчёркивание, без частиц. Звук и haptic по умолчанию выключены.
            return FeedbackCommand(transactionID: transaction.id,
                                   animation: .none,
                                   sound: settings.conflictSoundEnabled ? .conflict : .none,
                                   haptic: settings.conflictHapticEnabled ? .softRigid : .none,
                                   particleCount: 0, cells: cells, cue: .error)

        case .groupCompleted(let kind, let unitIndex):
            let preset: AnimationPreset = reduceMotion
                ? .fade
                : (kind == .box ? .boxBloom : .lineWave)
            let particles = particlesAllowed
                ? Int(Double(kind == .box ? 6 : 4) * settings.intensity.particleScale)
                : 0
            return FeedbackCommand(transactionID: transaction.id,
                                   animation: preset,
                                   sound: .groupCompleted,
                                   haptic: .groupTransient,
                                   particleCount: particles,
                                   cells: BoardTopology.units[unitIndex],
                                   cue: .group)

        case .puzzleSolved:
            let particles = particlesAllowed
                ? Int(32 * settings.intensity.particleScale)
                : 0
            return FeedbackCommand(transactionID: transaction.id,
                                   animation: reduceMotion ? .fade : .boardWave,
                                   sound: .victory, haptic: .success,
                                   particleCount: particles, cells: [])

        case .rankPromoted:
            return FeedbackCommand(transactionID: transaction.id,
                                   animation: reduceMotion ? .fade : .rankGrowth,
                                   sound: .none, haptic: .success,
                                   particleCount: 0, cells: [])
        }
    }
}
