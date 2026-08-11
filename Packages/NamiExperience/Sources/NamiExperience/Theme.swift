//
//  Theme.swift
//  NamiExperience
//
//  Created by artemoffM8.
//
//  Семантические токены вместо прямых цветов во View (раздел 6.2).
//  Manifest — чистые данные: он выбирает только зарегистрированные токены
//  и presets и не может менять геометрию сетки, шрифты, правила или рейтинг.
//

import SwiftUI

public enum ThemeToken: String, CaseIterable, Codable, Sendable {
    case appBackground
    case boardSurface
    case gridLineThin
    case gridLineThick
    case givenDigit
    case userDigit
    case manualNote
    case assistedCandidate
    case selectedCell
    case relatedCell
    case sameDigit
    case conflict
    case focusRing
    case accent
    case primaryText
    case secondaryText
}

public struct ThemeDefinition: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: String
    public let nameKey: String
    public let minAppVersion: String
    /// Обязателен для любого пака кроме корневого `paper-default`.
    public let fallbackID: String?
    public let colorScheme: String        // light | dark | system
    /// Шестнадцатеричные цвета по каждому семантическому токену.
    public let tokens: [String: String]
    public let thinLineWidth: Double
    public let thickLineWidth: Double
    public let shadowOpacity: Double
    public let motionProfileID: String
    /// Минимальный контраст цифры к поверхности, проверяется валидатором.
    public let measuredContrast: Double
    public let isHighContrast: Bool

    public init(
        schemaVersion: Int = ThemeDefinition.currentSchemaVersion,
        id: String,
        nameKey: String,
        minAppVersion: String = "1.0.0",
        fallbackID: String?,
        colorScheme: String,
        tokens: [String: String],
        thinLineWidth: Double = 0.6,
        thickLineWidth: Double = 2.2,
        shadowOpacity: Double = 0.05,
        motionProfileID: String = "calm",
        measuredContrast: Double,
        isHighContrast: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.nameKey = nameKey
        self.minAppVersion = minAppVersion
        self.fallbackID = fallbackID
        self.colorScheme = colorScheme
        self.tokens = tokens
        self.thinLineWidth = thinLineWidth
        self.thickLineWidth = thickLineWidth
        self.shadowOpacity = shadowOpacity
        self.motionProfileID = motionProfileID
        self.measuredContrast = measuredContrast
        self.isHighContrast = isHighContrast
    }

    public func hex(_ token: ThemeToken) -> String? { tokens[token.rawValue] }

    public var preferredColorScheme: ColorScheme? {
        switch colorScheme {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

// MARK: - Встроенные темы

public enum BuiltInThemes {

    /// Единственный корневой fallback. Не ссылается дальше (раздел 6.4).
    public static let paperDefault = ThemeDefinition(
        id: "paper-default",
        nameKey: "theme.paper.title",
        fallbackID: nil,
        colorScheme: "light",
        tokens: [
            ThemeToken.appBackground.rawValue: "#F1ECE1",
            ThemeToken.boardSurface.rawValue: "#FBF8F1",
            ThemeToken.gridLineThin.rawValue: "#C9C0AD",
            ThemeToken.gridLineThick.rawValue: "#6F675A",
            ThemeToken.givenDigit.rawValue: "#242B2B",
            ThemeToken.userDigit.rawValue: "#2F7774",
            ThemeToken.manualNote.rawValue: "#7A7263",
            ThemeToken.assistedCandidate.rawValue: "#A9A091",
            ThemeToken.selectedCell.rawValue: "#C6E3DE",
            ThemeToken.relatedCell.rawValue: "#E4DCC8",
            ThemeToken.sameDigit.rawValue: "#CFE4D6",
            ThemeToken.conflict.rawValue: "#B23A2F",
            ThemeToken.focusRing.rawValue: "#2F7774",
            ThemeToken.accent.rawValue: "#2F7774",
            ThemeToken.primaryText.rawValue: "#242B2B",
            ThemeToken.secondaryText.rawValue: "#6F675A"
        ],
        shadowOpacity: 0.04,
        measuredContrast: 11.2
    )

    public static let light = ThemeDefinition(
        id: "light",
        nameKey: "theme.light.title",
        fallbackID: "paper-default",
        colorScheme: "light",
        tokens: [
            ThemeToken.appBackground.rawValue: "#F2F4F7",
            ThemeToken.boardSurface.rawValue: "#FFFFFF",
            ThemeToken.gridLineThin.rawValue: "#D3D8DF",
            ThemeToken.gridLineThick.rawValue: "#5E6875",
            ThemeToken.givenDigit.rawValue: "#1F262E",
            ThemeToken.userDigit.rawValue: "#2A6FB0",
            ThemeToken.manualNote.rawValue: "#6C7581",
            ThemeToken.assistedCandidate.rawValue: "#9AA3AF",
            ThemeToken.selectedCell.rawValue: "#C3DCF4",
            ThemeToken.relatedCell.rawValue: "#DDE5EF",
            ThemeToken.sameDigit.rawValue: "#C9E1F5",
            ThemeToken.conflict.rawValue: "#B3352C",
            ThemeToken.focusRing.rawValue: "#2A6FB0",
            ThemeToken.accent.rawValue: "#2A6FB0",
            ThemeToken.primaryText.rawValue: "#1F262E",
            ThemeToken.secondaryText.rawValue: "#5E6875"
        ],
        measuredContrast: 13.4
    )

    public static let dark = ThemeDefinition(
        id: "dark",
        nameKey: "theme.dark.title",
        fallbackID: "paper-default",
        colorScheme: "dark",
        tokens: [
            ThemeToken.appBackground.rawValue: "#172220",
            ThemeToken.boardSurface.rawValue: "#24312E",
            ThemeToken.gridLineThin.rawValue: "#3A4A46",
            ThemeToken.gridLineThick.rawValue: "#8AA39D",
            ThemeToken.givenDigit.rawValue: "#E7ECE9",
            ThemeToken.userDigit.rawValue: "#70AAA5",
            ThemeToken.manualNote.rawValue: "#93A6A2",
            ThemeToken.assistedCandidate.rawValue: "#6C807C",
            ThemeToken.selectedCell.rawValue: "#456A63",
            ThemeToken.relatedCell.rawValue: "#334845",
            ThemeToken.sameDigit.rawValue: "#3C5854",
            ThemeToken.conflict.rawValue: "#E2796C",
            ThemeToken.focusRing.rawValue: "#70AAA5",
            ThemeToken.accent.rawValue: "#70AAA5",
            ThemeToken.primaryText.rawValue: "#E7ECE9",
            ThemeToken.secondaryText.rawValue: "#A7B7B3"
        ],
        measuredContrast: 10.8
    )

    public static let highContrast = ThemeDefinition(
        id: "high-contrast",
        nameKey: "theme.highContrast.title",
        fallbackID: "paper-default",
        colorScheme: "light",
        tokens: [
            ThemeToken.appBackground.rawValue: "#FFFFFF",
            ThemeToken.boardSurface.rawValue: "#FFFFFF",
            ThemeToken.gridLineThin.rawValue: "#767676",
            ThemeToken.gridLineThick.rawValue: "#000000",
            ThemeToken.givenDigit.rawValue: "#000000",
            ThemeToken.userDigit.rawValue: "#00427A",
            ThemeToken.manualNote.rawValue: "#3D3D3D",
            ThemeToken.assistedCandidate.rawValue: "#6B6B6B",
            ThemeToken.selectedCell.rawValue: "#CFE3F7",
            ThemeToken.relatedCell.rawValue: "#DEDEDE",
            ThemeToken.sameDigit.rawValue: "#DCEBFA",
            ThemeToken.conflict.rawValue: "#A0060B",
            ThemeToken.focusRing.rawValue: "#00427A",
            ThemeToken.accent.rawValue: "#00427A",
            ThemeToken.primaryText.rawValue: "#000000",
            ThemeToken.secondaryText.rawValue: "#3D3D3D"
        ],
        thinLineWidth: 0.8,
        thickLineWidth: 2.6,
        shadowOpacity: 0.0,
        measuredContrast: 21.0,
        isHighContrast: true
    )

    public static let all: [ThemeDefinition] = [paperDefault, light, dark, highContrast]
}

// MARK: - Цвета

public extension Color {
    /// `#RRGGBB` или `#RRGGBBAA`.
    init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8,
              let value = UInt64(text, radix: 16) else { return nil }
        let r, g, b, a: Double
        if text.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        } else {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
