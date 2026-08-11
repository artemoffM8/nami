//
//  EffectsEngine.swift
//  Центральный диспетчер: игровое событие -> частицы + анимации ячеек + звук.
//  Одна точка входа для геймплей-кода: engine.handle(.place(cell: 40, digit: 5)).
//

import SwiftUI

enum GameEvent {
    case tapEmpty(cell: Int)
    case tapFilled(cell: Int, sameDigitCells: [Int])
    case place(cell: Int)
    case erase(cell: Int)          // стирание/отмена
    case error(cell: Int)
    case hint(cell: Int)
    case blockComplete(cells: [Int])
    case win
}

final class EffectsEngine: ObservableObject {

    @Published var theme: AudioTheme = .zenGarden {
        didSet { AudioManager.shared.setTheme(theme) }
    }

    let particles = ParticleStore()
    @Published var cellFX: [Int: CellFXState] = [:]

    // Board-level состояния (используются DemoBoardView / вашим полем)
    @Published var winDim = false          // space: поле гаснет перед вспышкой
    @Published var winGlowAll = false      // space: все цифры вспыхивают
    @Published var dawn = false            // forest: фон теплеет к золотому
    @Published var winRipples = false      // zen: круги по всему полю (спавнятся частицами)

    // Геометрия поля — задаёт вью через onAppear/onChange(size)
    var boardSize: CGSize = .zero
    var cellSide: CGFloat { boardSize.width / 9 }

    private var pal: ThemePalette { theme.palette }

    func center(of cell: Int) -> CGPoint {
        let row = cell / 9, col = cell % 9
        return CGPoint(x: (CGFloat(col) + 0.5) * cellSide,
                       y: (CGFloat(row) + 0.5) * cellSide)
    }

    private func fx(_ cell: Int, _ mutate: (inout CellFXState) -> Void) {
        var state = cellFX[cell] ?? CellFXState()
        mutate(&state)
        cellFX[cell] = state
    }

    private func after(_ delay: Double, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
    }

    private var now: TimeInterval { Date.timeIntervalSinceReferenceDate }

    // MARK: - Диспетчер

    func handle(_ event: GameEvent) {
        switch event {
        case .tapEmpty(let cell):        tapEmpty(cell)
        case .tapFilled(let cell, let same): tapFilled(cell, same: same)
        case .place(let cell):           place(cell)
        case .erase(let cell):           erase(cell)
        case .error(let cell):           error(cell)
        case .hint(let cell):            hint(cell)
        case .blockComplete(let cells):  blockComplete(cells)
        case .win:                       win()
        }
    }

    // MARK: - Тап по пустой ячейке

    private func tapEmpty(_ cell: Int) {
        AudioManager.shared.play(.select)
        let c = center(of: cell)
        switch theme {
        case .zenGarden:
            // капля по воде: два кольца
            particles.spawn([
                Particle(kind: .ring, birth: now, life: 0.45, pos: c,
                         size: 2, maxRadius: cellSide * 0.75, color: pal.gridLineBold),
                Particle(kind: .ring, birth: now + 0.08, life: 0.5, pos: c,
                         size: 1.2, maxRadius: cellSide * 1.05, color: pal.gridLineBold),
            ])
        case .deepSpace:
            particles.spawn(
                Particle(kind: .starburst, birth: now, life: 0.4, pos: c,
                         size: 5, color: pal.accent))
        case .forestDawn:
            particles.spawn(
                Particle(kind: .glow, birth: now, life: 0.5, pos: c,
                         maxRadius: cellSide * 0.7, color: pal.accent))
        }
    }

    // MARK: - Тап по занятой: реакция одинаковых цифр

    private func tapFilled(_ cell: Int, same: [Int]) {
        AudioManager.shared.play(.select)
        switch theme {
        case .zenGarden:
            // мягкое "дыхание" волной от точки нажатия
            let origin = center(of: cell)
            for target in same {
                let d = distance(origin, center(of: target))
                after(Double(d) / Double(boardSize.width) * 0.4) { [weak self] in
                    self?.fx(target) { $0.breathe = true }
                    self?.after(0.5) { self?.fx(target) { $0.breathe = false } }
                }
            }
        case .deepSpace:
            // созвездие: соединяем одинаковые цифры линиями
            let pts = same.map(center(of:))
            guard pts.count > 1 else { break }
            var links: [Particle] = []
            for i in 0..<(pts.count - 1) {
                links.append(Particle(kind: .link, birth: now + Double(i) * 0.05,
                                      life: 0.7, pos: pts[i], target: pts[i + 1],
                                      color: pal.accent))
            }
            particles.spawn(links)
        case .forestDawn:
            // травинки качаются слева направо со стаггером
            for target in same.sorted(by: { ($0 % 9) < ($1 % 9) }) {
                let delay = Double(target % 9) * 0.03
                after(delay) { [weak self] in
                    self?.sway(target)
                }
            }
        }
    }

    private func sway(_ cell: Int) {
        withAnimation(.easeInOut(duration: 0.15)) { fx(cell) { $0.swayAngle = 3 } }
        after(0.15) { withAnimation(.easeInOut(duration: 0.2)) { self.fx(cell) { $0.swayAngle = -2 } } }
        after(0.35) { withAnimation(.easeInOut(duration: 0.2)) { self.fx(cell) { $0.swayAngle = 0 } } }
    }

    // MARK: - Ввод цифры
    // Появление цифры делает transition в CellView; здесь — звук и частицы.

    private func place(_ cell: Int) {
        AudioManager.shared.play(.place)
        let c = center(of: cell)
        if theme == .forestDawn {
            // искры-пыльца в момент "посадки"
            var dots: [Particle] = []
            for _ in 0..<3 {
                dots.append(Particle(
                    kind: .dot, birth: now + 0.1, life: 0.6,
                    pos: CGPoint(x: c.x + .random(in: -6...6), y: c.y + 8),
                    vel: CGVector(dx: .random(in: -14...14), dy: .random(in: -30 ... -14)),
                    size: 3, color: pal.particle, gravity: 26))
            }
            particles.spawn(dots)
        }
    }

    // MARK: - Стирание / отмена

    private func erase(_ cell: Int) {
        AudioManager.shared.play(.erase)
        let c = center(of: cell)
        switch theme {
        case .zenGarden:
            // песчинки уносятся вверх (сама цифра растворяется transition'ом)
            var dots: [Particle] = []
            for _ in 0..<7 {
                dots.append(Particle(
                    kind: .dot, birth: now, life: 0.7,
                    pos: CGPoint(x: c.x + .random(in: -8...8), y: c.y + .random(in: -8...8)),
                    vel: CGVector(dx: .random(in: -10...10), dy: .random(in: -46 ... -22)),
                    size: .random(in: 2...3.5), color: pal.particle))
            }
            particles.spawn(dots)
        case .deepSpace:
            break // схлопывание в точку — целиком transition
        case .forestDawn:
            var leaves: [Particle] = []
            for i in 0..<3 {
                leaves.append(Particle(
                    kind: .leaf, birth: now + Double(i) * 0.04, life: 0.8,
                    pos: c,
                    vel: CGVector(dx: .random(in: 30...55), dy: .random(in: -18...4)),
                    size: .random(in: 5...8), color: pal.accent.opacity(0.8),
                    spin: .random(in: 0.5...1.2), sway: 6, gravity: 30))
            }
            particles.spawn(leaves)
        }
    }

    // MARK: - Ошибка (мягкая во всех темах)

    private func error(_ cell: Int) {
        AudioManager.shared.play(.error)
        fx(cell) { $0.errorFill = true }
        after(0.9) { withAnimation(.easeOut(duration: 0.6)) { self.fx(cell) { $0.errorFill = false } } }

        switch theme {
        case .zenGarden:
            withAnimation(.linear(duration: 0.35)) { fx(cell) { $0.shakeTrigger += 1 } }
        case .deepSpace:
            fx(cell) { $0.glitch = true }
            after(0.16) { self.fx(cell) { $0.glitch = false } }
            after(0.24) { self.fx(cell) { $0.glitch = true } }
            after(0.32) { self.fx(cell) { $0.glitch = false } }
        case .forestDawn:
            withAnimation(.easeOut(duration: 0.18)) {
                fx(cell) { $0.wiltAngle = 7; $0.desaturate = true }
            }
            after(0.35) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                    self.fx(cell) { $0.wiltAngle = 0; $0.desaturate = false }
                }
            }
        }
    }

    // MARK: - Подсказка

    private func hint(_ cell: Int) {
        AudioManager.shared.play(.place) // мягкий place хорошо ложится и на подсказку
        let c = center(of: cell)

        switch theme {
        case .zenGarden:
            fx(cell) { $0.hintGlow = true }
            particles.spawn(Particle(kind: .glow, birth: now, life: 1.1, pos: c,
                                     maxRadius: cellSide * 0.85, color: pal.hint))
            after(1.1) { withAnimation(.easeOut(duration: 0.5)) { self.fx(cell) { $0.hintGlow = false } } }
        case .deepSpace:
            // падающая звезда от верхнего края к ячейке
            let start = CGPoint(x: min(boardSize.width - 10, c.x + boardSize.width * 0.35),
                                y: -10)
            particles.spawn(Particle(kind: .streak, birth: now, life: 0.45,
                                     pos: start, target: c, size: 2.5, color: pal.hint))
            after(0.4) {
                self.particles.spawn(Particle(kind: .starburst, birth: self.now, life: 0.5,
                                              pos: c, size: 6, color: self.pal.hint))
            }
        case .forestDawn:
            // светлячок прилетает по дуге
            let start = CGPoint(x: -12, y: c.y - boardSize.height * 0.25)
            let control = CGPoint(x: c.x * 0.4, y: min(c.y, 30) - 40)
            particles.spawn(Particle(kind: .firefly, birth: now, life: 1.0,
                                     pos: start, target: c, control: control,
                                     size: 5, color: pal.hint))
        }
    }

    // MARK: - Блок завершён

    private func blockComplete(_ cells: [Int]) {
        AudioManager.shared.play(.block)
        switch theme {
        case .zenGarden, .forestDawn:
            // волна приподнимания по диагонали блока
            let sorted = cells.sorted()
            for (i, cell) in sorted.enumerated() {
                let row = cell / 9 % 3, col = cell % 9 % 3
                let delay = Double(row + col) * 0.06 + Double(i % 2) * 0.01
                after(delay) {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                        self.fx(cell) { $0.lift = true }
                    }
                    self.after(0.25) {
                        withAnimation(.easeOut(duration: 0.3)) { self.fx(cell) { $0.lift = false } }
                    }
                }
            }
            if theme == .forestDawn, let first = cells.min(), let last = cells.max() {
                // пыльца в углах блока
                let a = center(of: first), b = center(of: last)
                let corners = [a, CGPoint(x: b.x, y: a.y), b, CGPoint(x: a.x, y: b.y)]
                var dots: [Particle] = []
                for corner in corners {
                    for _ in 0..<2 {
                        dots.append(Particle(kind: .dot, birth: now + .random(in: 0...0.15),
                                             life: 0.7, pos: corner,
                                             vel: CGVector(dx: .random(in: -20...20),
                                                           dy: .random(in: -40 ... -16)),
                                             size: 2.5, color: pal.particle, gravity: 30))
                    }
                }
                particles.spawn(dots)
            }
        case .deepSpace:
            // бегущий неоновый штрих по периметру блока
            guard let first = cells.min() else { break }
            let row0 = CGFloat(first / 9) * cellSide
            let col0 = CGFloat(first % 9) * cellSide
            let side = cellSide * 3
            let corners = [CGPoint(x: col0, y: row0),
                           CGPoint(x: col0 + side, y: row0),
                           CGPoint(x: col0 + side, y: row0 + side),
                           CGPoint(x: col0, y: row0 + side)]
            var streaks: [Particle] = []
            for i in 0..<4 {
                streaks.append(Particle(kind: .streak, birth: now + Double(i) * 0.11,
                                        life: 0.16, pos: corners[i],
                                        target: corners[(i + 1) % 4],
                                        size: 2, color: pal.accent))
            }
            particles.spawn(streaks)
        }
    }

    // MARK: - Победа

    private func win() {
        AudioManager.shared.play(.win)
        let mid = CGPoint(x: boardSize.width / 2, y: boardSize.height / 2)
        switch theme {
        case .zenGarden:
            // медленные круги по всему полю + лепестки сакуры
            var ps: [Particle] = []
            for i in 0..<4 {
                ps.append(Particle(kind: .ring, birth: now + Double(i) * 0.5, life: 2.2,
                                   pos: mid, size: 2,
                                   maxRadius: boardSize.width * 0.75,
                                   color: pal.accent))
            }
            for _ in 0..<5 {
                ps.append(Particle(kind: .petal,
                                   birth: now + .random(in: 0...1.2), life: 3.5,
                                   pos: CGPoint(x: .random(in: 0...boardSize.width), y: -12),
                                   vel: CGVector(dx: .random(in: -8...8), dy: 40),
                                   size: .random(in: 8...12),
                                   color: Color(hex: 0xE8B4C8),
                                   spin: .random(in: 0.3...0.8), sway: 14, gravity: 6))
            }
            particles.spawn(ps)
        case .deepSpace:
            // поле гаснет, затем цифры вспыхивают созвездием + метеоры
            withAnimation(.easeOut(duration: 0.3)) { winDim = true }
            after(0.35) {
                withAnimation(.easeOut(duration: 0.5)) { self.winDim = false; self.winGlowAll = true }
                var streaks: [Particle] = []
                for _ in 0..<3 {
                    let sx = CGFloat.random(in: 0...self.boardSize.width)
                    streaks.append(Particle(kind: .streak,
                                            birth: self.now + .random(in: 0...1.4), life: 0.6,
                                            pos: CGPoint(x: sx, y: -10),
                                            target: CGPoint(x: sx - 90, y: self.boardSize.height + 10),
                                            size: 2, color: self.pal.particle))
                }
                self.particles.spawn(streaks)
            }
            after(4.0) { withAnimation(.easeOut(duration: 1.0)) { self.winGlowAll = false } }
        case .forestDawn:
            // рассвет + светлячки
            withAnimation(.easeInOut(duration: 2.0)) { dawn = true }
            var flies: [Particle] = []
            for _ in 0..<6 {
                let start = CGPoint(x: .random(in: 0...boardSize.width), y: boardSize.height + 10)
                let target = CGPoint(x: .random(in: 0...boardSize.width),
                                     y: .random(in: 0...boardSize.height * 0.5))
                let control = CGPoint(x: (start.x + target.x) / 2 + .random(in: -60...60),
                                      y: boardSize.height * 0.5)
                flies.append(Particle(kind: .firefly, birth: now + .random(in: 0...1.5),
                                      life: .random(in: 2.0...3.0),
                                      pos: start, target: target, control: control,
                                      size: .random(in: 4...6), color: pal.particle))
            }
            particles.spawn(flies)
            after(5.0) { withAnimation(.easeInOut(duration: 2.0)) { self.dawn = false } }
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}
