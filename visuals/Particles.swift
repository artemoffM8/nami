//
//  Particles.swift
//  Универсальная система частиц поверх игрового поля.
//  Рендер: TimelineView(.animation) + Canvas — 60 fps, без SpriteKit.
//

import SwiftUI

struct Particle: Identifiable {
    enum Kind {
        case ring          // расходящееся кольцо (капля по воде)
        case dot           // точка с физикой (песчинка/пыльца/искра)
        case petal         // лепесток сакуры (падает, покачиваясь)
        case leaf          // листик (сдувается вбок)
        case starburst     // вспышка-звезда с крестом бликов
        case streak        // падающая звезда: полёт из точки A в B
        case link          // линия-созвездие между двумя точками
        case firefly       // светлячок: полёт по кривой Безье к цели
        case glow          // мягкое радиальное свечение
    }

    let id = UUID()
    let kind: Kind
    let birth: TimeInterval
    let life: TimeInterval
    var pos: CGPoint            // старт / центр
    var target: CGPoint = .zero // для streak / link / firefly
    var control: CGPoint = .zero// контрольная точка Безье (firefly)
    var vel: CGVector = .zero
    var size: CGFloat = 4
    var maxRadius: CGFloat = 40 // для ring
    var color: Color = .white
    var spin: CGFloat = 0       // вращение (обороты за жизнь)
    var sway: CGFloat = 0       // амплитуда покачивания (petal/leaf)
    var gravity: CGFloat = 0
}

// MARK: - Хранилище

final class ParticleStore: ObservableObject {
    // Массив читается Canvas'ом каждый кадр; objectWillChange не нужен
    // на каждый кадр — только при добавлении.
    @Published private(set) var particles: [Particle] = []

    func spawn(_ p: Particle) { particles.append(p) }
    func spawn(_ ps: [Particle]) { particles.append(contentsOf: ps) }

    func prune(now: TimeInterval) {
        guard particles.contains(where: { now - $0.birth > $0.life }) else { return }
        particles.removeAll { now - $0.birth > $0.life }
    }

    var isEmpty: Bool { particles.isEmpty }
}

// MARK: - Рендер

struct ParticleField: View {
    @ObservedObject var store: ParticleStore

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                paused: store.isEmpty)) { timeline in
            Canvas { ctx, _ in
                let now = timeline.date.timeIntervalSinceReferenceDate
                for p in store.particles {
                    let t = (now - p.birth) / p.life
                    guard t >= 0, t <= 1 else { continue }
                    draw(p, progress: t, in: &ctx)
                }
            }
            .onChange(of: timeline.date) { _ in
                store.prune(now: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .allowsHitTesting(false)
    }

    private func easeOut(_ t: Double) -> Double { 1 - pow(1 - t, 3) }

    private func draw(_ p: Particle, progress t: Double, in ctx: inout GraphicsContext) {
        switch p.kind {

        case .ring:
            let r = p.maxRadius * easeOut(t)
            let rect = CGRect(x: p.pos.x - r, y: p.pos.y - r, width: r * 2, height: r * 2)
            let width = max(0.5, p.size * (1 - t))
            ctx.stroke(Path(ellipseIn: rect),
                       with: .color(p.color.opacity((1 - t) * 0.8)),
                       lineWidth: width)

        case .dot:
            let dt = t * p.life
            let x = p.pos.x + p.vel.dx * dt
            let y = p.pos.y + p.vel.dy * dt + 0.5 * p.gravity * dt * dt
            let s = p.size * (1 - 0.5 * t)
            let rect = CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s)
            ctx.fill(Path(ellipseIn: rect), with: .color(p.color.opacity(1 - t)))

        case .petal, .leaf:
            let dt = t * p.life
            let swayX = sin(t * .pi * 3) * p.sway
            let x = p.pos.x + p.vel.dx * dt + swayX
            let y = p.pos.y + p.vel.dy * dt + 0.5 * p.gravity * dt * dt
            var local = ctx
            local.translateBy(x: x, y: y)
            local.rotate(by: .radians(p.spin * t * 2 * .pi + Double(swayX) * 0.05))
            let w = p.size, h = p.size * (p.kind == .petal ? 0.65 : 0.5)
            let rect = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
            local.fill(Path(ellipseIn: rect), with: .color(p.color.opacity((1 - t) * 0.9)))

        case .starburst:
            let scale = 0.3 + easeOut(t) * 1.2
            let alpha = (1 - t)
            var local = ctx
            local.translateBy(x: p.pos.x, y: p.pos.y)
            // ядро
            let core = p.size * scale
            local.fill(Path(ellipseIn: CGRect(x: -core / 2, y: -core / 2, width: core, height: core)),
                       with: .color(p.color.opacity(alpha)))
            // крест бликов
            let arm = p.size * 3.5 * scale
            for angle in [0.0, .pi / 2] {
                var beam = local
                beam.rotate(by: .radians(angle))
                var path = Path()
                path.move(to: CGPoint(x: -arm, y: 0))
                path.addLine(to: CGPoint(x: arm, y: 0))
                beam.stroke(path, with: .color(p.color.opacity(alpha * 0.6)), lineWidth: 1)
            }

        case .streak:
            // голова летит от pos к target, за ней хвост
            let head = lerp(p.pos, p.target, easeOut(t))
            let tailT = max(0, easeOut(t) - 0.25)
            let tail = lerp(p.pos, p.target, tailT)
            var path = Path()
            path.move(to: tail)
            path.addLine(to: head)
            ctx.stroke(path,
                       with: .linearGradient(
                           Gradient(colors: [p.color.opacity(0), p.color.opacity(1 - t * 0.5)]),
                           startPoint: tail, endPoint: head),
                       lineWidth: p.size)
            let s = p.size * 1.8
            ctx.fill(Path(ellipseIn: CGRect(x: head.x - s / 2, y: head.y - s / 2, width: s, height: s)),
                     with: .color(p.color.opacity(1 - t)))

        case .link:
            // fade in -> fade out
            let alpha = t < 0.3 ? t / 0.3 : (1 - t) / 0.7
            var path = Path()
            path.move(to: p.pos)
            path.addLine(to: p.target)
            ctx.stroke(path, with: .color(p.color.opacity(alpha * 0.5)), lineWidth: 0.8)

        case .firefly:
            // квадратичная Безье pos -> control -> target
            let q = easeOut(t)
            let a = lerp(p.pos, p.control, q)
            let b = lerp(p.control, p.target, q)
            let pt = lerp(a, b, q)
            let flicker = 0.7 + 0.3 * sin(t * .pi * 8)
            let alpha = (t > 0.85 ? (1 - t) / 0.15 : 1) * flicker
            let glowR = p.size * 2.2
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - glowR, y: pt.y - glowR,
                                            width: glowR * 2, height: glowR * 2)),
                     with: .color(p.color.opacity(alpha * 0.25)))
            let s = p.size
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - s / 2, y: pt.y - s / 2, width: s, height: s)),
                     with: .color(p.color.opacity(alpha)))

        case .glow:
            let alpha = t < 0.25 ? t / 0.25 : (1 - t) / 0.75
            let r = p.maxRadius
            let rect = CGRect(x: p.pos.x - r, y: p.pos.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect),
                     with: .radialGradient(
                        Gradient(colors: [p.color.opacity(alpha * 0.7), p.color.opacity(0)]),
                        center: p.pos, startRadius: 0, endRadius: r))
        }
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}
