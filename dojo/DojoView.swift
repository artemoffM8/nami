//
//  DojoView.swift
//  Экран додзё: путь техник -> урок с иллюстрацией -> тренировочные поля.
//
//  Подключение: DojoView(theme: engine.theme) { drill in
//      // открыть игровой экран с drill.puzzle; по решении:
//      // DojoStore.shared.registerCompletedDrill(drill.technique)
//  }
//

import SwiftUI

struct DojoView: View {
    let theme: AudioTheme
    let onPlay: (DojoGenerator.Drill) -> Void

    @ObservedObject private var store = DojoStore.shared
    @State private var openedLesson: SolveTechnique?

    private var pal: ThemePalette { theme.palette }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Text("Додзё")
                    .font(.system(.title2, design: pal.digitFont).weight(.semibold))
                    .foregroundColor(pal.digitGiven)
                Text("Каждая техника — реальный скачок силы")
                    .font(.system(size: 13, design: pal.digitFont))
                    .foregroundColor(pal.digitUser)
                    .padding(.bottom, 6)

                ForEach(DojoStore.path, id: \.self) { technique in
                    techniqueCard(technique)
                }
            }
            .padding(16)
        }
        .background(
            LinearGradient(colors: pal.boardBackground,
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
        .sheet(item: $openedLesson) { technique in
            LessonSheet(theme: theme,
                        lesson: DojoLesson.lesson(for: technique),
                        onPlay: onPlay)
        }
    }

    @ViewBuilder
    private func techniqueCard(_ t: SolveTechnique) -> some View {
        let unlocked = store.isUnlocked(t)
        let done = store.drills(for: t)
        let mastered = store.isMastered(t)

        Button {
            if unlocked { openedLesson = t }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(mastered ? pal.accent : pal.accentSoft)
                        .frame(width: 38, height: 38)
                    if mastered {
                        GardenGlyph(theme: theme, size: 20)
                    } else if unlocked {
                        Text("\(done)/\(DojoStore.drillsToMaster)")
                            .font(.system(size: 12, weight: .semibold,
                                          design: pal.digitFont))
                            .foregroundColor(pal.digitGiven)
                    } else {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 14))
                            .foregroundColor(pal.digitUser.opacity(0.6))
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title)
                        .font(.system(size: 16, weight: .medium, design: pal.digitFont))
                        .foregroundColor(unlocked ? pal.digitGiven
                                                  : pal.digitUser.opacity(0.5))
                    Text(DojoLesson.lesson(for: t).subtitle)
                        .font(.system(size: 12, design: pal.digitFont))
                        .foregroundColor(pal.digitUser.opacity(unlocked ? 1 : 0.5))
                }
                Spacer()
                if unlocked {
                    Image(systemName: "chevron.right")
                        .foregroundColor(pal.digitUser.opacity(0.5))
                }
            }
            .padding(12)
            .background(pal.cellHighlight.opacity(unlocked ? 0.55 : 0.3),
                        in: RoundedRectangle(cornerRadius: 12))
        }
        .disabled(!unlocked)
    }
}

// Для .sheet(item:)
extension SolveTechnique: Identifiable {
    public var id: Int { rawValue }
}

// MARK: - Урок

struct LessonSheet: View {
    let theme: AudioTheme
    let lesson: DojoLesson
    let onPlay: (DojoGenerator.Drill) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isSearching = false
    @State private var searchFailed = false

    private var pal: ThemePalette { theme.palette }

    var body: some View {
        VStack(spacing: 16) {
            Capsule().fill(pal.gridLine).frame(width: 36, height: 4).padding(.top, 10)

            Text(lesson.technique.title)
                .font(.system(.title3, design: pal.digitFont).weight(.semibold))
                .foregroundColor(pal.digitGiven)

            TechniqueIllustration(theme: theme, lesson: lesson)
                .frame(width: 200, height: 200)

            Text(lesson.explanation)
                .font(.system(size: 14, design: pal.digitFont))
                .foregroundColor(pal.digitGiven)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 22)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(lesson.howToFind.indices, id: \.self) { i in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(i + 1)")
                            .font(.system(size: 12, weight: .semibold,
                                          design: pal.digitFont))
                            .frame(width: 18, height: 18)
                            .background(pal.accentSoft, in: Circle())
                        Text(lesson.howToFind[i])
                            .font(.system(size: 13, design: pal.digitFont))
                    }
                    .foregroundColor(pal.digitGiven)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 26)

            Spacer()

            if searchFailed {
                Text("Не удалось подобрать поле — попробуйте ещё раз")
                    .font(.system(size: 12, design: pal.digitFont))
                    .foregroundColor(pal.error)
            }

            Button {
                startDrill()
            } label: {
                Group {
                    if isSearching {
                        ProgressView().tint(.white)
                    } else {
                        Text("Тренировка")
                    }
                }
                .font(.system(size: 16, weight: .medium, design: pal.digitFont))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(pal.accent.opacity(0.85),
                            in: RoundedRectangle(cornerRadius: 12))
                .foregroundColor(.white)
            }
            .disabled(isSearching)
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
        }
        .background(
            LinearGradient(colors: pal.boardBackground,
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea())
    }

    private func startDrill() {
        isSearching = true
        searchFailed = false
        // Seed от времени: тренировочные поля каждый раз новые.
        let seed = UInt64(Date().timeIntervalSince1970)
        DojoGenerator.findDrillAsync(technique: lesson.technique, seed: seed) { drill in
            isSearching = false
            if let drill {
                dismiss()
                onPlay(drill)
            } else {
                searchFailed = true
            }
        }
    }
}

// MARK: - Иллюстрация паттерна

struct TechniqueIllustration: View {
    let theme: AudioTheme
    let lesson: DojoLesson

    private var pal: ThemePalette { theme.palette }

    var body: some View {
        Canvas { ctx, size in
            let cs = size.width / 9
            // подсветки
            for cell in lesson.eliminatedCells {
                ctx.fill(Path(cellRect(cell, cs)), with: .color(pal.error.opacity(0.18)))
            }
            for cell in lesson.patternCells {
                ctx.fill(Path(cellRect(cell, cs)), with: .color(pal.accent.opacity(0.45)))
            }
            // сетка
            for i in 0...9 {
                let bold = i % 3 == 0
                let x = CGFloat(i) * cs
                var v = Path(); v.move(to: CGPoint(x: x, y: 0))
                v.addLine(to: CGPoint(x: x, y: size.height))
                var h = Path(); h.move(to: CGPoint(x: 0, y: x))
                h.addLine(to: CGPoint(x: size.width, y: x))
                let color = bold ? pal.gridLineBold : pal.gridLine
                ctx.stroke(v, with: .color(color), lineWidth: bold ? 1.4 : 0.5)
                ctx.stroke(h, with: .color(color), lineWidth: bold ? 1.4 : 0.5)
            }
            // маркеры: точка в паттерне, крестик в исключаемых
            for cell in lesson.patternCells {
                let r = cellRect(cell, cs).insetBy(dx: cs * 0.36, dy: cs * 0.36)
                ctx.fill(Path(ellipseIn: r), with: .color(pal.accent))
            }
            for cell in lesson.eliminatedCells {
                let r = cellRect(cell, cs).insetBy(dx: cs * 0.32, dy: cs * 0.32)
                var x1 = Path(); x1.move(to: CGPoint(x: r.minX, y: r.minY))
                x1.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                x1.move(to: CGPoint(x: r.maxX, y: r.minY))
                x1.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                ctx.stroke(x1, with: .color(pal.error.opacity(0.8)), lineWidth: 1.4)
            }
        }
        .background(pal.cellHighlight.opacity(0.35),
                    in: RoundedRectangle(cornerRadius: 8))
    }

    private func cellRect(_ cell: Int, _ cs: CGFloat) -> CGRect {
        CGRect(x: CGFloat(cell % 9) * cs, y: CGFloat(cell / 9) * cs,
               width: cs, height: cs)
    }
}
