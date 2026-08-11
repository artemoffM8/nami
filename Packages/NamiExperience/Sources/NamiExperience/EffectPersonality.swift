//
//  EffectPersonality.swift
//  NamiExperience
//
//  Created by artemoffM8.
//
//  Чем именно тема отвечает на событие: кругами по воде, вспышкой звезды или
//  листьями. Событие одно и то же — словарь разный.
//
//  Почему это отдельный тип, а не ветвление по `theme.id` в месте отрисовки.
//  Иначе каждое новое место эффектов начинает знать про названия тем, и
//  добавление темы превращается в поиск по всему проекту. Здесь одна таблица.
//
//  Отдельно про «Высокий контраст»: у него намеренно НЕТ декоративных частиц.
//  Эта тема существует ради читаемости, и блики поверх цифр работают против
//  того единственного, ради чего её выбирают.
//

import SwiftUI

public enum EffectPersonality: String, Sendable, CaseIterable {
    /// Бумага и тушь: круги по воде, песчинки, растворение.
    case ink
    /// Космос: вспышки-звёзды, падающие звёзды, линии-созвездия.
    case cosmos
    /// Роща: листья, пыльца, светлячок.
    case grove
    /// Без декора. Остаётся только то, что несёт смысл.
    case plain

    public init(themeID: String) {
        switch themeID {
        case "dark": self = .cosmos
        case "light": self = .grove
        case "high-contrast": self = .plain
        default: self = .ink
        }
    }

    /// Реакция на касание клетки.
    public var tapKind: ParticleKind? {
        switch self {
        case .ink: .ring
        case .cosmos: .starburst
        case .grove: .glow
        case .plain: nil
        }
    }

    /// Что осыпается при стирании цифры.
    public var eraseKind: ParticleKind? {
        switch self {
        case .ink: .dot
        case .cosmos: nil       // цифра схлопывается сама, добавлять нечего
        case .grove: .leaf
        case .plain: nil
        }
    }

    /// Чем отмечается закрытая группа помимо волны.
    public var groupKind: ParticleKind? {
        switch self {
        case .ink: .ring
        case .cosmos: .starburst
        case .grove: .dot
        case .plain: nil
        }
    }

    public var usesParticles: Bool { self != .plain }
}

public enum ParticleKind: String, Sendable {
    /// Расходящееся кольцо — капля по воде.
    case ring
    /// Точка с гравитацией: песчинка, искра, пыльца.
    case dot
    /// Лист: сдувается вбок, покачиваясь.
    case leaf
    /// Вспышка со крестом бликов.
    case starburst
    /// Мягкое радиальное свечение.
    case glow
}
