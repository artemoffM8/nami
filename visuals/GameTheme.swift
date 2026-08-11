//
//  GameTheme.swift
//  Визуальные палитры трёх тем. Расширяет AudioTheme из AudioManager.swift,
//  чтобы звук и визуал переключались одним значением.
//

import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

struct ThemePalette {
    let boardBackground: [Color]     // градиент фона
    let gridLine: Color
    let gridLineBold: Color          // границы 3x3 блоков
    let cellHighlight: Color         // подсветка выбранной ячейки
    let sameDigitHighlight: Color
    let digitGiven: Color            // предзаданные цифры
    let digitUser: Color             // цифры игрока
    let accent: Color                // основной эффектный цвет
    let accentSoft: Color
    let error: Color                 // мягкий, не кричащий
    let hint: Color
    let particle: Color
    let digitFont: Font.Design
    let digitGlow: Bool              // светятся ли цифры (space)
}

extension AudioTheme {

    var palette: ThemePalette {
        switch self {
        case .zenGarden:
            return ThemePalette(
                boardBackground: [Color(hex: 0xF6F0E3), Color(hex: 0xEFE6D2)],
                gridLine: Color(hex: 0xCFC5AD),
                gridLineBold: Color(hex: 0x9C9078),
                cellHighlight: Color(hex: 0xEADFC4),
                sameDigitHighlight: Color(hex: 0xE6D9BC).opacity(0.7),
                digitGiven: Color(hex: 0x35312B),
                digitUser: Color(hex: 0x5A5346),
                accent: Color(hex: 0xC9A227),
                accentSoft: Color(hex: 0xC9A227).opacity(0.35),
                error: Color(hex: 0xC96F4A),
                hint: Color(hex: 0xD9B44A),
                particle: Color(hex: 0xB6A98C),
                digitFont: .serif,
                digitGlow: false
            )
        case .deepSpace:
            return ThemePalette(
                boardBackground: [Color(hex: 0x05070D), Color(hex: 0x0A1020)],
                gridLine: Color(hex: 0x1B2735),
                gridLineBold: Color(hex: 0x2C3E55),
                cellHighlight: Color(hex: 0x11263A),
                sameDigitHighlight: Color(hex: 0x0E2233).opacity(0.9),
                digitGiven: Color(hex: 0xA8C6E8),
                digitUser: Color(hex: 0x4FE3D2),
                accent: Color(hex: 0x4FE3D2),
                accentSoft: Color(hex: 0x4FE3D2).opacity(0.3),
                error: Color(hex: 0xE85D75),
                hint: Color(hex: 0x8FA7FF),
                particle: Color(hex: 0xBFE8FF),
                digitFont: .monospaced,
                digitGlow: true
            )
        case .forestDawn:
            return ThemePalette(
                boardBackground: [Color(hex: 0xF1F2E2), Color(hex: 0xDCEBD5)],
                gridLine: Color(hex: 0xB9C9AC),
                gridLineBold: Color(hex: 0x8AA37C),
                cellHighlight: Color(hex: 0xDCEDCB),
                sameDigitHighlight: Color(hex: 0xD4E6C2).opacity(0.8),
                digitGiven: Color(hex: 0x2F4A33),
                digitUser: Color(hex: 0x4C7A55),
                accent: Color(hex: 0x7FB069),
                accentSoft: Color(hex: 0x7FB069).opacity(0.35),
                error: Color(hex: 0xC99A4A),
                hint: Color(hex: 0xE8C878),
                particle: Color(hex: 0xF4E7A8),
                digitFont: .rounded,
                digitGlow: false
            )
        }
    }

    var displayName: String {
        switch self {
        case .zenGarden: return "Дзен-сад"
        case .deepSpace: return "Космос"
        case .forestDawn: return "Лес"
        }
    }
}
