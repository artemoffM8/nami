//
//  ParticleVocabulary.swift
//  NamiExperience
//
//  Created by artemoffM8.
//
//  Отрисовка частиц разных видов внутри уже существующего Canvas-оверлея.
//
//  Почему без `Double.random`. В `BoardEffectOverlay` уже записан инвариант:
//  смещения детерминированы по индексу клетки, поэтому кадр воспроизводим и
//  его можно сравнивать в снапшот-тестах. Живой RNG этот инвариант ломает —
//  причём молча: тест начнёт мигать раз в сто прогонов, и виноватым назначат
//  что угодно, кроме частиц.
//
//  Здесь вместо RNG хеш от (клетка, номер частицы, соль). Разброс визуально
//  неотличим от случайного, но один и тот же при каждом запуске.
//

import SwiftUI

/// Детерминированный источник «случайности».
///
/// Splitmix64: одна операция на значение, хорошее перемешивание младших битов.
/// Обычный `hashValue` не подходит — он засеян случайно при каждом запуске.
enum EffectNoise {

    static func raw(_ seed: UInt64) -> UInt64 {
        var z = seed &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Значение в 0...1.
    static func unit(_ cell: Int, _ index: Int, _ salt: UInt64) -> Double {
        let seed = UInt64(bitPattern: Int64(cell &* 8191 &+ index &* 131)) &+ salt
        return Double(raw(seed) >> 11) / Double(1 << 53)
    }

    static func range(_ cell: Int, _ index: Int, _ salt: UInt64,
                      _ bounds: ClosedRange<Double>) -> Double {
        bounds.lowerBound + unit(cell, index, salt) * (bounds.upperBound - bounds.lowerBound)
    }
}

/// Рисование одного вида частиц. Все функции принимают `progress` 0...1 и
/// ничего не хранят: состояние живёт в кадре, а не в объекте.
enum ParticleVocabulary {

    static func draw(
        kind: ParticleKind,
        cellIndex: Int,
        origin: CGPoint,
        cellSide: Double,
        count: Int,
        progress t: Double,
        color: Color,
        in context: inout GraphicsContext
    ) {
        switch kind {
        case .ring: drawRings(origin, cellSide, t, color, &context)
        case .starburst: drawStarburst(origin, cellSide, t, color, &context)
        case .glow: drawGlow(origin, cellSide, t, color, &context)
        case .dot: drawDots(cellIndex, origin, cellSide, count, t, color, &context)
        case .leaf: drawLeaves(cellIndex, origin, cellSide, count, t, color, &context)
        }
    }

    private static func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    // MARK: - Круги по воде

    /// Два кольца со сдвигом: одно кольцо читается как обводка, а не как капля.
    private static func drawRings(
        _ origin: CGPoint, _ side: Double, _ t: Double,
        _ color: Color, _ context: inout GraphicsContext
    ) {
        for (offset, scale) in [(0.0, 0.75), (0.22, 1.05)] {
            let local = (t - offset) / (1 - offset)
            guard local > 0, local <= 1 else { continue }
            let radius = side * scale * easeOut(local)
            let rect = CGRect(x: origin.x - radius, y: origin.y - radius,
                              width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect),
                           with: .color(color.opacity((1 - local) * 0.55)),
                           lineWidth: max(0.5, side * 0.035 * (1 - local)))
        }
    }

    // MARK: - Вспышка

    private static func drawStarburst(
        _ origin: CGPoint, _ side: Double, _ t: Double,
        _ color: Color, _ context: inout GraphicsContext
    ) {
        let scale = 0.3 + easeOut(t) * 1.2
        let alpha = 1 - t
        let core = side * 0.10 * scale
        context.fill(
            Path(ellipseIn: CGRect(x: origin.x - core / 2, y: origin.y - core / 2,
                                   width: core, height: core)),
            with: .color(color.opacity(alpha * 0.9)))

        let arm = side * 0.42 * scale
        for angle in [0.0, Double.pi / 2] {
            var path = Path()
            let dx = cos(angle) * arm, dy = sin(angle) * arm
            path.move(to: CGPoint(x: origin.x - dx, y: origin.y - dy))
            path.addLine(to: CGPoint(x: origin.x + dx, y: origin.y + dy))
            context.stroke(path, with: .color(color.opacity(alpha * 0.45)), lineWidth: 1)
        }
    }

    // MARK: - Свечение

    private static func drawGlow(
        _ origin: CGPoint, _ side: Double, _ t: Double,
        _ color: Color, _ context: inout GraphicsContext
    ) {
        // Появление быстрее ухода: вспышка должна успеть прочитаться.
        let alpha = t < 0.25 ? t / 0.25 : (1 - t) / 0.75
        let radius = side * 0.7
        let rect = CGRect(x: origin.x - radius, y: origin.y - radius,
                          width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect),
                     with: .radialGradient(
                        Gradient(colors: [color.opacity(alpha * 0.5), color.opacity(0)]),
                        center: origin, startRadius: 0, endRadius: radius))
    }

    // MARK: - Песчинки и пыльца

    private static func drawDots(
        _ cell: Int, _ origin: CGPoint, _ side: Double, _ count: Int,
        _ t: Double, _ color: Color, _ context: inout GraphicsContext
    ) {
        let gravity = side * 1.6
        for index in 0..<count {
            let dx = EffectNoise.range(cell, index, 11, -0.22...0.22) * side
            let dy = EffectNoise.range(cell, index, 23, -1.15 ... -0.55) * side
            let jitterX = EffectNoise.range(cell, index, 31, -0.18...0.18) * side
            let jitterY = EffectNoise.range(cell, index, 41, -0.18...0.18) * side

            let x = origin.x + jitterX + dx * t
            let y = origin.y + jitterY + dy * t + 0.5 * gravity * t * t
            let size = side * EffectNoise.range(cell, index, 53, 0.05...0.09) * (1 - 0.5 * t)
            context.fill(
                Path(ellipseIn: CGRect(x: x - size / 2, y: y - size / 2,
                                       width: size, height: size)),
                with: .color(color.opacity((1 - t) * 0.75)))
        }
    }

    // MARK: - Листья

    private static func drawLeaves(
        _ cell: Int, _ origin: CGPoint, _ side: Double, _ count: Int,
        _ t: Double, _ color: Color, _ context: inout GraphicsContext
    ) {
        let gravity = side * 1.2
        for index in 0..<count {
            let dx = EffectNoise.range(cell, index, 61, 0.5...1.1) * side
            let dy = EffectNoise.range(cell, index, 71, -0.4...0.1) * side
            // Покачивание: лист не падает по прямой, и это единственное,
            // что отличает его от точки.
            let sway = sin(t * .pi * 3) * side * 0.12
            let x = origin.x + dx * t + sway
            let y = origin.y + dy * t + 0.5 * gravity * t * t
            let spin = EffectNoise.range(cell, index, 83, 0.5...1.2)

            var local = context
            local.translateBy(x: x, y: y)
            local.rotate(by: .radians(spin * t * 2 * .pi))
            let width = side * EffectNoise.range(cell, index, 97, 0.13...0.2)
            local.fill(
                Path(ellipseIn: CGRect(x: -width / 2, y: -width * 0.25,
                                       width: width, height: width * 0.5)),
                with: .color(color.opacity((1 - t) * 0.8)))
        }
    }
}
