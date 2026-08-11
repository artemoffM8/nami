//
//  PreferencesRepository.swift
//  NamiData
//
//  Created by artemoffM8.
//
//  Единая точка доступа к настройкам (раздел 13.7): feature views НЕ читают
//  произвольные ключи UserDefaults напрямую.
//

import Foundation
import Observation
import NamiDomain

@Observable
@MainActor
public final class PreferencesRepository {

    private enum Key {
        static let themeID = "nami.theme.id"
        static let effectIntensity = "nami.effects.intensity"
        static let soundEnabled = "nami.sound.enabled"
        static let musicEnabled = "nami.music.enabled"
        static let soundKit = "nami.sound.kit"
        static let dojoDrills = "nami.dojo.drills."
        static let dojoSeed = "nami.dojo.seed"
        static let hapticsEnabled = "nami.haptics.enabled"
        static let conflictSound = "nami.sound.conflict"
        static let showTimer = "nami.timer.visible"
        static let largeDigits = "nami.digits.large"
        static let keypadLayout = "nami.keypad.layout"
        static let reduceMotionBoost = "nami.motion.reduceBoost"
        static let showInterfaceTips = "nami.coach.enabled"
        static let tapToClear = "nami.input.tapToClear"
        static let struggleNudges = "nami.coach.struggleNudges"
        static let howToPlaySeen = "nami.coach.howToPlaySeen"
        static let language = "nami.language"
        static let gameMode = "nami.mode"
        static let themeForMode = "nami.theme.forMode."
    }

    public enum KeypadLayout: String, CaseIterable, Sendable {
        case adaptive, singleRow, grid3x3
        public var titleKey: String { "settings.keypad.\(rawValue)" }
    }

    /// Язык интерфейса. `.system` — единственное значение по умолчанию:
    /// пока игрок явно не выбрал язык, приложение обязано слушаться устройства.
    public enum AppLanguage: String, CaseIterable, Sendable {
        case system, ru, en
        public var titleKey: String { "settings.language.\(rawValue)" }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.themeID: "paper-default",
            Key.effectIntensity: "full",
            Key.soundEnabled: true,
            Key.musicEnabled: false,          // музыка выключена по умолчанию
            Key.hapticsEnabled: true,
            Key.conflictSound: false,         // звук ошибки по умолчанию выключен
            Key.showTimer: false,             // таймер скрыт по умолчанию
            Key.largeDigits: false,
            Key.keypadLayout: KeypadLayout.adaptive.rawValue,
            Key.reduceMotionBoost: false,
            Key.showInterfaceTips: true,
            Key.tapToClear: true,
            Key.struggleNudges: true,
            Key.howToPlaySeen: false,
            Key.language: AppLanguage.system.rawValue,
            Key.gameMode: GameMode.ranked.rawValue
        ])
    }

    private func string(_ key: String) -> String { defaults.string(forKey: key) ?? "" }
    private func set(_ value: Any?, _ key: String) { defaults.set(value, forKey: key) }

    public var themeID: String {
        get { access(keyPath: \.themeID); return string(Key.themeID) }
        set { withMutation(keyPath: \.themeID) { set(newValue, Key.themeID) } }
    }

    public var effectIntensityRaw: String {
        get { access(keyPath: \.effectIntensityRaw); return string(Key.effectIntensity) }
        set { withMutation(keyPath: \.effectIntensityRaw) { set(newValue, Key.effectIntensity) } }
    }

    public var soundEnabled: Bool {
        get { access(keyPath: \.soundEnabled); return defaults.bool(forKey: Key.soundEnabled) }
        set { withMutation(keyPath: \.soundEnabled) { set(newValue, Key.soundEnabled) } }
    }

    public var musicEnabled: Bool {
        get { access(keyPath: \.musicEnabled); return defaults.bool(forKey: Key.musicEnabled) }
        set { withMutation(keyPath: \.musicEnabled) { set(newValue, Key.musicEnabled) } }
    }

    /// Звуковой комплект — строкой, как и `effectIntensityRaw`: тип живёт в
    /// NamiExperience, а слой данных о нём знать не обязан.
    ///
    /// По умолчанию исходный набор NAMI: у него есть вариации сэмплов, а у
    /// тематических комплектов по одному звуку на событие — в частом действии
    /// это слышно.
    public var soundKitRaw: String {
        get { access(keyPath: \.soundKitRaw)
              return defaults.string(forKey: Key.soundKit) ?? "nami" }
        set { withMutation(keyPath: \.soundKitRaw) { set(newValue, Key.soundKit) } }
    }

    // MARK: - Додзё

    /// Сколько дриллов техники закрыто. Хранится по ключу техники, а не
    /// массивом: порядок ступеней в учебном плане ещё будет меняться, и
    /// индексы сместились бы вместе с ним.
    public func dojoDrills(for technique: SudokuTechnique) -> Int {
        access(keyPath: \.dojoRevision)
        return defaults.integer(forKey: Key.dojoDrills + technique.catalogKey)
    }

    public func registerDojoDrill(_ technique: SudokuTechnique) {
        let key = Key.dojoDrills + technique.catalogKey
        let next = defaults.integer(forKey: key) + 1
        withMutation(keyPath: \.dojoRevision) {
            defaults.set(next, forKey: key)
            // Общий счётчик изменений: наблюдать за каждым ключом техники
            // по отдельности @Observable не умеет.
            defaults.set(defaults.integer(forKey: Key.dojoSeed) + 1, forKey: Key.dojoSeed)
        }
    }

    /// Растёт с каждым закрытым дриллом. Служит и триггером обновления
    /// интерфейса, и seed-ом для выбора следующей задачи.
    public var dojoRevision: Int {
        get { access(keyPath: \.dojoRevision)
              return defaults.integer(forKey: Key.dojoSeed) }
        set { withMutation(keyPath: \.dojoRevision) { set(newValue, Key.dojoSeed) } }
    }

    public var hapticsEnabled: Bool {
        get { access(keyPath: \.hapticsEnabled); return defaults.bool(forKey: Key.hapticsEnabled) }
        set { withMutation(keyPath: \.hapticsEnabled) { set(newValue, Key.hapticsEnabled) } }
    }

    public var conflictSoundEnabled: Bool {
        get { access(keyPath: \.conflictSoundEnabled); return defaults.bool(forKey: Key.conflictSound) }
        set { withMutation(keyPath: \.conflictSoundEnabled) { set(newValue, Key.conflictSound) } }
    }

    public var showTimer: Bool {
        get { access(keyPath: \.showTimer); return defaults.bool(forKey: Key.showTimer) }
        set { withMutation(keyPath: \.showTimer) { set(newValue, Key.showTimer) } }
    }

    public var largeDigits: Bool {
        get { access(keyPath: \.largeDigits); return defaults.bool(forKey: Key.largeDigits) }
        set { withMutation(keyPath: \.largeDigits) { set(newValue, Key.largeDigits) } }
    }

    public var keypadLayout: KeypadLayout {
        get {
            access(keyPath: \.keypadLayout)
            return KeypadLayout(rawValue: string(Key.keypadLayout)) ?? .adaptive
        }
        set { withMutation(keyPath: \.keypadLayout) { set(newValue.rawValue, Key.keypadLayout) } }
    }

    public var reduceMotionBoost: Bool {
        get { access(keyPath: \.reduceMotionBoost); return defaults.bool(forKey: Key.reduceMotionBoost) }
        set { withMutation(keyPath: \.reduceMotionBoost) { set(newValue, Key.reduceMotionBoost) } }
    }

    /// Активна только до показа обеих карточек InterfaceCoach (раздел 5.1).
    public var showInterfaceTips: Bool {
        get { access(keyPath: \.showInterfaceTips); return defaults.bool(forKey: Key.showInterfaceTips) }
        set { withMutation(keyPath: \.showInterfaceTips) { set(newValue, Key.showInterfaceTips) } }
    }

    /// Обзор основных функций уже показывали хотя бы раз.
    public var howToPlaySeen: Bool {
        get { access(keyPath: \.howToPlaySeen); return defaults.bool(forKey: Key.howToPlaySeen) }
        set { withMutation(keyPath: \.howToPlaySeen) { set(newValue, Key.howToPlaySeen) } }
    }

    /// Предлагать помощь, когда игрок застрял.
    public var struggleNudges: Bool {
        get { access(keyPath: \.struggleNudges); return defaults.bool(forKey: Key.struggleNudges) }
        set { withMutation(keyPath: \.struggleNudges) { set(newValue, Key.struggleNudges) } }
    }

    public var language: AppLanguage {
        get {
            access(keyPath: \.language)
            return AppLanguage(rawValue: string(Key.language)) ?? .system
        }
        set { withMutation(keyPath: \.language) { set(newValue.rawValue, Key.language) } }
    }

    /// Последний выбранный режим — он же предлагается в следующий раз.
    public var gameMode: GameMode {
        get {
            access(keyPath: \.gameMode)
            return GameMode(rawValue: string(Key.gameMode)) ?? .ranked
        }
        set { withMutation(keyPath: \.gameMode) { set(newValue.rawValue, Key.gameMode) } }
    }

    /// Тема, выбранная игроком ЯВНО для этого режима. `nil` — игрок не выбирал,
    /// значит применяется предложение самого режима. Так режим задаёт вид по
    /// умолчанию, но никогда не затирает осознанный выбор.
    public func themeID(for mode: GameMode) -> String? {
        defaults.string(forKey: Key.themeForMode + mode.rawValue)
    }

    public func setThemeID(_ id: String, for mode: GameMode) {
        withMutation(keyPath: \.themeID) {
            set(id, Key.themeForMode + mode.rawValue)
            set(id, Key.themeID)
        }
    }

    public var tapToClear: Bool {
        get { access(keyPath: \.tapToClear); return defaults.bool(forKey: Key.tapToClear) }
        set { withMutation(keyPath: \.tapToClear) { set(newValue, Key.tapToClear) } }
    }
}
