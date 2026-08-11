//
//  CellFX.swift
//  Анимационные модификаторы ячеек и transition'ы появления/исчезновения цифр.
//

import SwiftUI

// MARK: - Дрожание (zen error)

struct ShakeEffect: GeometryEffect {
    var amplitude: CGFloat = 2.5
    var shakes: CGFloat = 2
    var animatableData: CGFloat  // 0 -> 1 за время анимации

    func effectValue(size: CGSize) -> ProjectionTransform {
        let x = amplitude * sin(animatableData * .pi * shakes * 2)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

// MARK: - Универсальный модификатор появления цифры (для AnyTransition.modifier)

struct DigitAppearModifier: ViewModifier {
    var blur: CGFloat
    var scale: CGFloat
    var opacity: Double
    var yOffset: CGFloat
    var glow: Double         // сила свечения (space)
    var glowColor: Color

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale, anchor: yOffset == 0 ? .center : .bottom)
            .blur(radius: blur)
            .opacity(opacity)
            .offset(y: yOffset)
            .shadow(color: glowColor.opacity(glow), radius: 8)
            .shadow(color: glowColor.opacity(glow * 0.6), radius: 16)
    }
}

// MARK: - Модификатор исчезновения (undo/erase)

struct DigitRemoveModifier: ViewModifier {
    var scale: CGFloat
    var rotation: Angle
    var xOffset: CGFloat
    var yOffset: CGFloat
    var opacity: Double
    var blur: CGFloat

    func body(content: Content) -> some View {
        content
            .rotationEffect(rotation)
            .scaleEffect(scale)
            .offset(x: xOffset, y: yOffset)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

// MARK: - Готовые transition'ы по темам

extension AnyTransition {

    /// Zen: мазок туши — из лёгкого расфокуса и увеличения "впитывается" в бумагу.
    /// Удаление: развеивается вверх (частицы-песчинки добавляет движок).
    static var inkStroke: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: DigitAppearModifier(blur: 6, scale: 1.35, opacity: 0,
                                            yOffset: 0, glow: 0, glowColor: .clear),
                identity: DigitAppearModifier(blur: 0, scale: 1, opacity: 1,
                                              yOffset: 0, glow: 0, glowColor: .clear)),
            removal: .modifier(
                active: DigitRemoveModifier(scale: 0.9, rotation: .zero, xOffset: 0,
                                            yOffset: -14, opacity: 0, blur: 5),
                identity: DigitRemoveModifier(scale: 1, rotation: .zero, xOffset: 0,
                                              yOffset: 0, opacity: 1, blur: 0))
        )
    }

    /// Space: материализация из расфокуса со вспышкой неона.
    /// Удаление: схлопывание в точку с поворотом ("в чёрную дыру").
    static func materialize(glow: Color) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: DigitAppearModifier(blur: 10, scale: 1.15, opacity: 0,
                                            yOffset: 0, glow: 0.9, glowColor: glow),
                identity: DigitAppearModifier(blur: 0, scale: 1, opacity: 1,
                                              yOffset: 0, glow: 0, glowColor: glow)),
            removal: .modifier(
                active: DigitRemoveModifier(scale: 0.01, rotation: .degrees(90),
                                            xOffset: 0, yOffset: 0, opacity: 0, blur: 2),
                identity: DigitRemoveModifier(scale: 1, rotation: .zero, xOffset: 0,
                                              yOffset: 0, opacity: 1, blur: 0))
        )
    }

    /// Forest: цифра "прорастает" снизу с пружинкой.
    /// Удаление: сдувает вбок с поворотом.
    static var sprout: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: DigitAppearModifier(blur: 0, scale: 0.3, opacity: 0,
                                            yOffset: 8, glow: 0, glowColor: .clear),
                identity: DigitAppearModifier(blur: 0, scale: 1, opacity: 1,
                                              yOffset: 0, glow: 0, glowColor: .clear)),
            removal: .modifier(
                active: DigitRemoveModifier(scale: 0.8, rotation: .degrees(25),
                                            xOffset: 26, yOffset: -6, opacity: 0, blur: 1),
                identity: DigitRemoveModifier(scale: 1, rotation: .zero, xOffset: 0,
                                              yOffset: 0, opacity: 1, blur: 0))
        )
    }

    static func forTheme(_ theme: AudioTheme, accent: Color) -> AnyTransition {
        switch theme {
        case .zenGarden: return .inkStroke
        case .deepSpace: return .materialize(glow: accent)
        case .forestDawn: return .sprout
        }
    }

    static func appearAnimation(_ theme: AudioTheme) -> Animation {
        switch theme {
        case .zenGarden: return .easeOut(duration: 0.35)
        case .deepSpace: return .easeOut(duration: 0.3)
        case .forestDawn: return .spring(response: 0.35, dampingFraction: 0.55)
        }
    }
}

// MARK: - Транзиентное состояние одной ячейки

struct CellFXState {
    var shakeTrigger = 0          // zen error
    var glitch = false            // space error (хроматическая аберрация)
    var wiltAngle: Double = 0     // forest error ("увядание")
    var desaturate = false        // forest error
    var errorFill = false         // подкраска фона ошибки (все темы)
    var lift = false              // волна block-complete
    var swayAngle: Double = 0     // forest: качание одинаковых цифр
    var breathe = false           // zen: "дыхание" одинаковых цифр
    var hintGlow = false          // подсветка подсказки
}
