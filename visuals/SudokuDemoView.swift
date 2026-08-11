//
//  SudokuDemoView.swift
//  Демо-экран: рабочая сетка 9×9 со всеми эффектами трёх тем.
//  Тапайте ячейки, вводите цифры, пробуйте ошибку/отмену/подсказку/победу.
//
//  Подключение в своём проекте: замените модель на свою и вызывайте
//  engine.handle(...) в тех же местах геймплея.
//

import SwiftUI

struct SudokuDemoView: View {

    @StateObject private var engine = EffectsEngine()

    // --- мини-модель для демо ---
    @State private var values: [Int?] = SudokuDemoView.demoBoard
    @State private var given: [Bool] = SudokuDemoView.demoBoard.map { $0 != nil }
    @State private var selected: Int? = nil
    @State private var history: [(cell: Int, old: Int?)] = []
    @State private var audioStarted = false

    private var pal: ThemePalette { engine.theme.palette }

    var body: some View {
        VStack(spacing: 14) {
            Picker("Тема", selection: $engine.theme) {
                ForEach(AudioTheme.allCases, id: \.self) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            board
                .aspectRatio(1, contentMode: .fit)
                .padding(.horizontal, 12)

            numberPad
            controls
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
        .background(background.ignoresSafeArea())
        .onAppear {
            guard !audioStarted else { return }
            audioStarted = true
            AudioManager.shared.start(theme: engine.theme)
        }
        .animation(.easeInOut(duration: 0.4), value: engine.theme)
    }

    // MARK: - Фон экрана (forest: "рассвет" на победе)

    private var background: some View {
        LinearGradient(
            colors: engine.dawn
                ? [Color(hex: 0xFBEED2), Color(hex: 0xF3D9A0)]
                : pal.boardBackground,
            startPoint: .top, endPoint: .bottom)
    }

    // MARK: - Поле

    private var board: some View {
        GeometryReader { geo in
            ZStack {
                // ячейки
                VStack(spacing: 0) {
                    ForEach(0..<9, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<9, id: \.self) { col in
                                cellView(row * 9 + col)
                            }
                        }
                    }
                }
                gridLines(size: geo.size)
                ParticleField(store: engine.particles)

                // space win: затемнение
                Color.black.opacity(engine.winDim ? 0.55 : 0)
                    .allowsHitTesting(false)
            }
            .onAppear { engine.boardSize = geo.size }
            .onChange(of: geo.size) { engine.boardSize = $0 }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(pal.gridLineBold, lineWidth: 1.5))
    }

    private func gridLines(size: CGSize) -> some View {
        Canvas { ctx, _ in
            let cs = size.width / 9
            for i in 1..<9 {
                let bold = i % 3 == 0
                let x = CGFloat(i) * cs
                var v = Path(); v.move(to: CGPoint(x: x, y: 0)); v.addLine(to: CGPoint(x: x, y: size.height))
                var h = Path(); h.move(to: CGPoint(x: 0, y: x)); h.addLine(to: CGPoint(x: size.width, y: x))
                let color = bold ? pal.gridLineBold : pal.gridLine
                let width: CGFloat = bold ? 1.5 : 0.6
                ctx.stroke(v, with: .color(color), lineWidth: width)
                ctx.stroke(h, with: .color(color), lineWidth: width)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Ячейка

    @ViewBuilder
    private func cellView(_ index: Int) -> some View {
        let fx = engine.cellFX[index] ?? CellFXState()
        let value = values[index]
        let isSelected = selected == index
        let sameAsSelected = selectedDigit != nil && value == selectedDigit && !isSelected

        ZStack {
            // фон
            Rectangle().fill(cellFill(fx: fx, isSelected: isSelected, same: sameAsSelected))

            // hint-свечение (zen)
            if fx.hintGlow {
                RadialGradient(colors: [pal.hint.opacity(0.55), .clear],
                               center: .center, startRadius: 2, endRadius: 26)
            }

            if let value {
                digitView(value, index: index, fx: fx)
                    .transition(.forTheme(engine.theme, accent: pal.accent))
            }
        }
        .scaleEffect(fx.lift ? 1.07 : 1)
        .zIndex(fx.lift ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { tap(index) }
    }

    private func cellFill(fx: CellFXState, isSelected: Bool, same: Bool) -> Color {
        if fx.errorFill { return pal.error.opacity(0.28) }
        if isSelected { return pal.cellHighlight }
        if same { return pal.sameDigitHighlight }
        return .clear
    }

    @ViewBuilder
    private func digitView(_ value: Int, index: Int, fx: CellFXState) -> some View {
        let base = Text("\(value)")
            .font(.system(size: 24, weight: given[index] ? .semibold : .regular,
                          design: pal.digitFont))

        ZStack {
            // space error: хроматическая аберрация
            if fx.glitch {
                base.foregroundColor(.red.opacity(0.75)).offset(x: -1.6)
                base.foregroundColor(.blue.opacity(0.75)).offset(x: 1.6)
            }
            base
                .foregroundColor(given[index] ? pal.digitGiven : pal.digitUser)
                .shadow(color: glowColor(index: index),
                        radius: glowRadius(index: index))
        }
        .opacity(fx.glitch ? 0.85 : 1)
        .scaleEffect(fx.breathe ? 1.12 : 1)
        .animation(.easeInOut(duration: 0.45), value: fx.breathe)
        .rotationEffect(.degrees(fx.wiltAngle + fx.swayAngle))
        .saturation(fx.desaturate ? 0.25 : 1)
        .modifier(ShakeEffect(animatableData: CGFloat(fx.shakeTrigger)))
    }

    private func glowColor(index: Int) -> Color {
        guard pal.digitGlow else { return .clear }
        let strong = engine.winGlowAll
        return pal.accent.opacity(strong ? 0.95 : (given[index] ? 0.25 : 0.55))
    }

    private func glowRadius(index: Int) -> CGFloat {
        guard pal.digitGlow else { return 0 }
        return engine.winGlowAll ? 12 : 6
    }

    private var selectedDigit: Int? {
        selected.flatMap { values[$0] }
    }

    // MARK: - Ввод

    private func tap(_ index: Int) {
        selected = index
        if let v = values[index] {
            let same = values.indices.filter { values[$0] == v }
            engine.handle(.tapFilled(cell: index, sameDigitCells: same))
        } else {
            engine.handle(.tapEmpty(cell: index))
        }
    }

    private func enter(_ digit: Int) {
        guard let cell = selected, !given[cell] else { return }
        if let conflict = conflictCell(for: digit, at: cell) {
            // показываем ошибку и на вводимой ячейке, и слегка на конфликтной
            withAnimation(.appearAnimation(engine.theme)) { values[cell] = digit }
            history.append((cell, nil))
            engine.handle(.place(cell: cell))
            engine.handle(.error(cell: cell))
            engine.handle(.error(cell: conflict))
            return
        }
        history.append((cell, values[cell]))
        withAnimation(.appearAnimation(engine.theme)) { values[cell] = digit }
        engine.handle(.place(cell: cell))
        checkCompletions(after: cell)
    }

    private func eraseSelected() {
        guard let cell = selected, !given[cell], values[cell] != nil else { return }
        history.append((cell, values[cell]))
        engine.handle(.erase(cell: cell))
        withAnimation(.easeIn(duration: 0.35)) { values[cell] = nil }
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        selected = last.cell
        engine.handle(.erase(cell: last.cell))
        withAnimation(.easeIn(duration: 0.35)) { values[last.cell] = last.old }
    }

    private func showHint() {
        // демо: подсказка = первая пустая ячейка, цифра из решения не считается —
        // берём первую валидную. В реальной игре подставьте цифру из решателя.
        guard let cell = values.firstIndex(where: { $0 == nil }) else { return }
        selected = cell
        let digit = (1...9).first { conflictCell(for: $0, at: cell) == nil } ?? 1
        engine.handle(.hint(cell: cell))
        let delay = engine.theme == .zenGarden ? 0.15 : (engine.theme == .deepSpace ? 0.4 : 0.85)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            history.append((cell, nil))
            withAnimation(.appearAnimation(engine.theme)) { values[cell] = digit }
            checkCompletions(after: cell)
        }
    }

    // MARK: - Правила

    private func conflictCell(for digit: Int, at cell: Int) -> Int? {
        let row = cell / 9, col = cell % 9
        for i in 0..<81 where i != cell && values[i] == digit {
            let r = i / 9, c = i % 9
            if r == row || c == col || (r / 3 == row / 3 && c / 3 == col / 3) { return i }
        }
        return nil
    }

    private func checkCompletions(after cell: Int) {
        let row = cell / 9, col = cell % 9
        let block = (row / 3) * 3 + col / 3
        let blockCells = (0..<81).filter { ($0 / 9) / 3 * 3 + ($0 % 9) / 3 == block }
        if blockCells.allSatisfy({ values[$0] != nil }) {
            engine.handle(.blockComplete(cells: blockCells))
        }
        if values.allSatisfy({ $0 != nil }) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                engine.handle(.win)
            }
        }
    }

    // MARK: - Панель управления

    private var numberPad: some View {
        HStack(spacing: 8) {
            ForEach(1...9, id: \.self) { d in
                Button { enter(d) } label: {
                    Text("\(d)")
                        .font(.system(size: 22, weight: .medium, design: pal.digitFont))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(pal.cellHighlight, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundColor(pal.digitGiven)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            controlButton("Стереть") { eraseSelected() }
            controlButton("Отмена") { undo() }
            controlButton("Подсказка") { showHint() }
            controlButton("Победа ▶") { engine.handle(.win) } // предпросмотр финала
        }
        .padding(.horizontal, 12)
    }

    private func controlButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(pal.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                .foregroundColor(pal.digitGiven)
        }
    }

    // MARK: - Демо-доска

    static let demoBoard: [Int?] = {
        let s = """
        530070000600195000098000060\
        800060003400803001700020006\
        060000280000419005000080079
        """
        return s.compactMap { $0.wholeNumberValue }
            .map { $0 == 0 ? nil : $0 }
    }()
}

#Preview {
    SudokuDemoView()
}
