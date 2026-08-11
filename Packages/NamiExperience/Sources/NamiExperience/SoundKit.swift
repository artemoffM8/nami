//
//  SoundKit.swift
//  NamiExperience
//
//  Created by artemoffM8.
//
//  Звуковой комплект: набор SFX плюс четыре музыкальных слоя одной тональности.
//
//  Почему комплект, а не «выбор мелодии». Звук действия и фоновая музыка должны
//  быть в одном ладу, иначе тихий bell при вводе цифры бьётся с педалью пэда, и
//  это слышно даже тому, кто не назовёт причину. Поэтому SFX и музыка выбираются
//  вместе и по отдельности не смешиваются.
//
//  Файлы лежат в бандле плоско, с префиксом комплекта: `zenGarden__digitPlaced`.
//  Плоско — потому что Xcode по умолчанию схлопывает папки ресурсов в корень
//  бандла, и три файла `select.wav` из разных комплектов затёрли бы друг друга.
//  Префикс делает конфликт невозможным без folder references, которые пришлось
//  бы поддерживать руками в генераторе проекта.
//
//  Формат — CAF/ALAC: сжатие без потерь примерно вчетверо (55 → 14 МБ). AAC
//  здесь не годится принципиально: он добавляет priming-тишину в начало файла,
//  и бесшовный луп перестаёт быть бесшовным.
//

import Foundation

public enum SoundKit: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Исходный набор NAMI: без музыкальных слоёв, зато с вариациями SFX.
    case nami
    case zenGarden
    case deepSpace
    case forestDawn

    public var id: String { rawValue }
    public var titleKey: String { "settings.soundKit.\(rawValue)" }
    public var subtitleKey: String { "settings.soundKit.\(rawValue).subtitle" }

    /// Префикс файлов комплекта. У исходного набора его нет: файлы лежат
    /// под собственными именами и поддерживают вариации `name2`, `name3`.
    public var filePrefix: String? {
        self == .nami ? nil : "\(rawValue)__"
    }

    /// Есть ли у комплекта многослойная музыка.
    public var hasLayeredMusic: Bool { self != .nami }

    /// Тема оформления, с которой комплект задумывался. Предлагается, но не
    /// навязывается: игрок вправе слушать космос над бумажной доской.
    public var suggestedThemeID: String {
        switch self {
        case .nami: "paper-default"
        case .zenGarden: "paper-default"
        case .deepSpace: "dark"
        case .forestDawn: "light"
        }
    }

    /// Слои музыки. Длины намеренно разные (21–43 с): их совпадение
    /// повторяется раз в несколько часов, поэтому петля не опознаётся на слух.
    public static let musicLayers = ["pad", "melody", "texture", "bass"]

    /// Имя файла события в бандле.
    public func resourceName(for asset: SoundAsset, variant: Int = 1) -> String {
        guard let prefix = filePrefix else {
            return variant == 1 ? asset.rawValue : "\(asset.rawValue)\(variant)"
        }
        // У комплектов по одному сэмплу на событие: вариаций нет, и просить
        // их бессмысленно.
        return "\(prefix)\(asset.rawValue)"
    }

    public func musicResourceName(layer: String) -> String? {
        guard let prefix = filePrefix else { return nil }
        return "\(prefix)music_\(layer)"
    }

    /// Сколько вариантов имеет смысл искать на диске.
    public var maximumVariants: Int { filePrefix == nil ? 4 : 1 }
}
