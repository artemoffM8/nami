//
//  ResourcePackManager.swift
//  NamiExperience
//
//  Created by artemoffM8.
//
//  Атомарный pipeline `load → validate → register → apply` (раздел 6.4).
//  Любая ошибка отклоняет ВЕСЬ пакет; активной остаётся корневая `paper-default`.
//  Manifest не исполняет код и не может менять правила, геометрию сетки,
//  подсказки или формулу рейтинга.
//

import Foundation
import Observation
import SwiftUI

public enum PackValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case unknownSchemaVersion(Int)
    case appVersionTooLow(required: String, current: String)
    case missingFallback(String)
    case fallbackCycle([String])
    case unknownToken(String)
    case missingToken(String)
    case invalidColor(token: String, value: String)
    case contrastTooLow(Double)
    case unknownMotionProfile(String)
    case rootPackMustNotHaveFallback

    public var description: String {
        switch self {
        case .unknownSchemaVersion(let v): "неизвестная schemaVersion \(v)"
        case .appVersionTooLow(let required, let current):
            "minAppVersion \(required) выше текущей \(current)"
        case .missingFallback(let id): "fallbackID `\(id)` не зарегистрирован"
        case .fallbackCycle(let chain): "цикл в цепочке fallback: \(chain.joined(separator: " → "))"
        case .unknownToken(let token): "неизвестный ключ токена `\(token)`"
        case .missingToken(let token): "отсутствует обязательный токен `\(token)`"
        case .invalidColor(let token, let value): "некорректный цвет `\(value)` в `\(token)`"
        case .contrastTooLow(let value): "контраст \(value) ниже минимального 4.5"
        case .unknownMotionProfile(let id): "неизвестный motion-профиль `\(id)`"
        case .rootPackMustNotHaveFallback: "корневой пакет не может ссылаться на fallback"
        }
    }
}

public struct SemanticVersion: Comparable, Sendable {
    public let major: Int, minor: Int, patch: Int

    public init?(_ text: String) {
        let parts = text.split(separator: ".").map { Int($0) ?? -1 }
        guard parts.count == 3, !parts.contains(-1) else { return nil }
        (major, minor, patch) = (parts[0], parts[1], parts[2])
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public enum ThemeValidator {

    public static let minimumContrast = 4.5
    public static let registeredMotionProfiles: Set<String> = ["calm", "still", "expressive"]
    public static let rootPackID = "paper-default"

    /// Строгая проверка: schema, неизвестные ключи, minAppVersion, fallback,
    /// цикл fallback, все обязательные токены, формат цвета, контраст.
    public static func validate(
        _ theme: ThemeDefinition,
        appVersion: String,
        registered: [String: ThemeDefinition]
    ) -> PackValidationError? {
        guard theme.schemaVersion == ThemeDefinition.currentSchemaVersion else {
            return .unknownSchemaVersion(theme.schemaVersion)
        }
        if let required = SemanticVersion(theme.minAppVersion),
           let current = SemanticVersion(appVersion), required > current {
            return .appVersionTooLow(required: theme.minAppVersion, current: appVersion)
        }

        let known = Set(ThemeToken.allCases.map(\.rawValue))
        for key in theme.tokens.keys where !known.contains(key) {
            return .unknownToken(key)
        }
        for token in ThemeToken.allCases {
            guard let hex = theme.tokens[token.rawValue] else { return .missingToken(token.rawValue) }
            guard Color(hexString: hex) != nil else {
                return .invalidColor(token: token.rawValue, value: hex)
            }
        }
        guard theme.measuredContrast >= minimumContrast else {
            return .contrastTooLow(theme.measuredContrast)
        }
        guard registeredMotionProfiles.contains(theme.motionProfileID) else {
            return .unknownMotionProfile(theme.motionProfileID)
        }

        if theme.id == rootPackID {
            guard theme.fallbackID == nil else { return .rootPackMustNotHaveFallback }
            return nil
        }

        guard let fallbackID = theme.fallbackID else { return .missingFallback("nil") }
        var chain = [theme.id]
        var currentID: String? = fallbackID
        var guardCounter = 0
        while let id = currentID {
            if chain.contains(id) { return .fallbackCycle(chain + [id]) }
            chain.append(id)
            guard let next = registered[id] else { return .missingFallback(id) }
            currentID = next.fallbackID
            guardCounter += 1
            if guardCounter > 16 { return .fallbackCycle(chain) }
        }
        return nil
    }
}

@Observable
@MainActor
public final class ThemeProvider {

    public private(set) var current: ThemeDefinition
    public private(set) var registered: [String: ThemeDefinition]
    public private(set) var lastRejection: PackValidationError?
    public let appVersion: String

    public init(appVersion: String = "1.0.0") {
        self.appVersion = appVersion
        var registry: [String: ThemeDefinition] = [:]
        for theme in BuiltInThemes.all { registry[theme.id] = theme }
        self.registered = registry
        self.current = BuiltInThemes.paperDefault
    }

    public func color(_ token: ThemeToken) -> Color {
        if let hex = current.hex(token), let color = Color(hexString: hex) { return color }
        // Корневой fallback никогда не подводит: его токены проверены тестом.
        if let hex = BuiltInThemes.paperDefault.hex(token),
           let color = Color(hexString: hex) { return color }
        return .primary
    }

    /// Регистрация нового пака. Отклонение НЕ меняет активную тему.
    @discardableResult
    public func register(_ theme: ThemeDefinition) -> Bool {
        if let error = ThemeValidator.validate(theme, appVersion: appVersion, registered: registered) {
            lastRejection = error
            return false
        }
        registered[theme.id] = theme
        return true
    }

    /// Атомарное применение. Некорректный пак мгновенно оставляет `paper-default`.
    @discardableResult
    public func apply(id: String) -> Bool {
        guard let theme = registered[id] else {
            lastRejection = .missingFallback(id)
            current = BuiltInThemes.paperDefault
            return false
        }
        if let error = ThemeValidator.validate(theme, appVersion: appVersion, registered: registered) {
            lastRejection = error
            current = BuiltInThemes.paperDefault
            return false
        }
        current = theme
        lastRejection = nil
        return true
    }

    /// Загрузка стороннего manifest из данных. Ошибка декодирования — тоже отказ.
    @discardableResult
    public func loadPack(from data: Data) -> Bool {
        guard let theme = try? JSONDecoder().decode(ThemeDefinition.self, from: data) else {
            lastRejection = .unknownSchemaVersion(-1)
            return false
        }
        return register(theme)
    }
}
