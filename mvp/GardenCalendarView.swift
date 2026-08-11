//
//  GardenCalendarView.swift
//  Календарь-сад: решённый день = камешек / звезда / цветок (по теме).
//  Пропуск дня НЕ ломает сад — просто пустая клетка. Никакой тревоги.
//
//  DailyView — готовый экран: календарь + карточка сегодняшней партии.
//  Подключение: DailyView(theme: engine.theme) { puzzle in
//      // открыть игровой экран с puzzle.puzzle / puzzle.solution
//  }
//

import SwiftUI

// MARK: - Глиф решённого дня

struct GardenGlyph: View {
    let theme: AudioTheme
    var size: CGFloat = 18

    var body: some View {
        Canvas { ctx, canvasSize in
            let w = canvasSize.width, h = canvasSize.height
            let c = CGPoint(x: w / 2, y: h / 2)
            switch theme {
            case .zenGarden:
                // камешек: два овала + блик
                ctx.fill(Path(ellipseIn: CGRect(x: w * 0.18, y: h * 0.42,
                                                width: w * 0.64, height: h * 0.42)),
                         with: .color(Color(hex: 0xA79B82)))
                ctx.fill(Path(ellipseIn: CGRect(x: w * 0.30, y: h * 0.20,
                                                width: w * 0.42, height: h * 0.34)),
                         with: .color(Color(hex: 0xBFB49A)))
                ctx.fill(Path(ellipseIn: CGRect(x: w * 0.38, y: h * 0.25,
                                                width: w * 0.12, height: h * 0.08)),
                         with: .color(.white.opacity(0.55)))
            case .deepSpace:
                // четырёхлучевая звезда
                var star = Path()
                let long = w * 0.42, short = w * 0.12
                star.move(to: CGPoint(x: c.x, y: c.y - long))
                star.addQuadCurve(to: CGPoint(x: c.x + long, y: c.y),
                                  control: CGPoint(x: c.x + short, y: c.y - short))
                star.addQuadCurve(to: CGPoint(x: c.x, y: c.y + long),
                                  control: CGPoint(x: c.x + short, y: c.y + short))
                star.addQuadCurve(to: CGPoint(x: c.x - long, y: c.y),
                                  control: CGPoint(x: c.x - short, y: c.y + short))
                star.addQuadCurve(to: CGPoint(x: c.x, y: c.y - long),
                                  control: CGPoint(x: c.x - short, y: c.y - short))
                ctx.fill(star, with: .color(Color(hex: 0x4FE3D2)))
                let g = w * 0.5
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - g, y: c.y - g,
                                                width: g * 2, height: g * 2)),
                         with: .radialGradient(
                            Gradient(colors: [Color(hex: 0x4FE3D2).opacity(0.35), .clear]),
                            center: c, startRadius: 0, endRadius: g))
            case .forestDawn:
                // цветок: 5 лепестков + сердцевина
                for k in 0..<5 {
                    var petal = ctx
                    petal.translateBy(x: c.x, y: c.y)
                    petal.rotate(by: .radians(Double(k) / 5 * 2 * .pi))
                    petal.fill(Path(ellipseIn: CGRect(x: -w * 0.10, y: -h * 0.46,
                                                      width: w * 0.20, height: h * 0.34)),
                               with: .color(Color(hex: 0xE8A0B8)))
                }
                let core = w * 0.22
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - core / 2, y: c.y - core / 2,
                                                width: core, height: core)),
                         with: .color(Color(hex: 0xE8C878)))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Календарь месяца

struct GardenCalendarView: View {
    let theme: AudioTheme
    @ObservedObject var store: DailyStore
    @State private var monthAnchor = Date()

    private var cal: Calendar { Calendar.current }
    private var pal: ThemePalette { theme.palette }

    private var monthTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "LLLL yyyy"
        return f.string(from: monthAnchor).capitalized
    }

    private var monthKey: String {
        let c = cal.dateComponents([.year, .month], from: monthAnchor)
        return String(format: "%04d-%02d", c.year!, c.month!)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(monthTitle).font(.system(.headline, design: pal.digitFont))
                Spacer()
                Button { shift(1) } label: { Image(systemName: "chevron.right") }
            }
            .foregroundColor(pal.digitGiven)
            .padding(.horizontal, 6)

            let cells = monthCells()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7),
                      spacing: 6) {
                ForEach(cells.indices, id: \.self) { i in
                    dayCell(cells[i])
                }
            }

            Text("В саду за месяц: \(store.completedCount(inMonth: monthKey))")
                .font(.system(size: 13, design: pal.digitFont))
                .foregroundColor(pal.digitUser)
        }
        .padding(14)
        .background(pal.cellHighlight.opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func dayCell(_ day: (number: Int, key: String)?) -> some View {
        if let day {
            VStack(spacing: 2) {
                Text("\(day.number)")
                    .font(.system(size: 11, design: pal.digitFont))
                    .foregroundColor(pal.digitUser)
                if store.isCompleted(day.key) {
                    GardenGlyph(theme: theme, size: 16)
                } else {
                    Circle().fill(pal.gridLine.opacity(0.4))
                        .frame(width: 4, height: 4)
                        .padding(.vertical, 6)
                }
            }
            .frame(minHeight: 34)
        } else {
            Color.clear.frame(minHeight: 34)
        }
    }

    /// nil = пустая ведущая клетка до первого числа.
    private func monthCells() -> [(number: Int, key: String)?] {
        let comps = cal.dateComponents([.year, .month], from: monthAnchor)
        guard let first = cal.date(from: comps),
              let range = cal.range(of: .day, in: .month, for: first) else { return [] }
        let firstWeekday = cal.component(.weekday, from: first)
        let leading = (firstWeekday - cal.firstWeekday + 7) % 7
        var cells: [(Int, String)?] = Array(repeating: nil, count: leading)
        for day in range {
            cells.append((day, String(format: "%04d-%02d-%02d",
                                      comps.year!, comps.month!, day)))
        }
        return cells
    }

    private func shift(_ delta: Int) {
        if let d = cal.date(byAdding: .month, value: delta, to: monthAnchor) {
            monthAnchor = d
        }
    }
}

// MARK: - Экран "Утренняя партия"

struct DailyView: View {
    let theme: AudioTheme
    let onPlay: (DailyPuzzle) -> Void

    @ObservedObject private var store = DailyStore.shared

    // Генерация с проверкой единственности небесплатна — считаем один раз.
    @State private var today = DailyPuzzle.forDate(Date())

    private var pal: ThemePalette { theme.palette }

    var body: some View {
        VStack(spacing: 18) {
            GardenCalendarView(theme: theme, store: store)

            let puzzle = today
            let done = store.isCompleted(puzzle.dateKey)

            VStack(spacing: 8) {
                Text("Утренняя партия")
                    .font(.system(.title3, design: pal.digitFont).weight(.semibold))
                    .foregroundColor(pal.digitGiven)
                Text(puzzle.difficulty.displayName)
                    .font(.system(size: 14, design: pal.digitFont))
                    .foregroundColor(pal.digitUser)

                Button {
                    onPlay(puzzle)
                } label: {
                    HStack(spacing: 8) {
                        if done {
                            GardenGlyph(theme: theme, size: 18)
                            Text("Решено")
                        } else {
                            Text("Играть")
                        }
                    }
                    .font(.system(size: 16, weight: .medium, design: pal.digitFont))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(done ? pal.accentSoft : pal.accent.opacity(0.85),
                                in: RoundedRectangle(cornerRadius: 12))
                    .foregroundColor(done ? pal.digitGiven : .white)
                }
                .disabled(done)
            }
            .padding(16)
            .background(pal.cellHighlight.opacity(0.5),
                        in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(.horizontal, 16)
        .background(
            LinearGradient(colors: pal.boardBackground,
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
    }
}
