//
//  Dojo.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  Тренировка техник: одна позиция — один логический ход.
//
//  Позиция НЕ генерируется случайным полем, как обычно делают тренажёры.
//  Она вырезается из настоящей задачи каталога: решатель прогоняет партию до
//  того момента, где впервые становится нужна изучаемая техника, и это
//  состояние доски и есть упражнение.
//
//  Две причины сделать именно так:
//
//  1. Задачи каталога уже проверены на единственность решения и оценены. У
//     случайно сгенерированного поля этих гарантий нет, а «тренировка» на
//     поле с двумя решениями учит неправильному.
//  2. «Техника необходима» определяется тем же кодом, который оценивает
//     сложность в игре. Отдельный тренировочный решатель означал бы две
//     разные логики в одном приложении — и расхождение между тем, чему учат,
//     и тем, что требуется.
//
//  Цена — перебор. Один прогон решателя вырезает позицию из ОДНОЙ задачи, но
//  не всякая задача с нужной размёткой её отдаёт: размётка каталога и трасса
//  расходятся после смены версии решателя. Поэтому `PuzzleRepository.drill`
//  идёт по всему пулу кандидатов и тратит на каждого полный прогон — для
//  редкой техники это сотни прогонов. Отсюда `async`, отсоединённая задача,
//  проверка отмены на каждом шаге перебора — и спиннер на экране додзё.
//

import Foundation

/// Ступень пути. Не все 21 техника годятся в тренировку: `fullHouse` — это
/// «осталась одна клетка», учить там нечему, а для `nakedQuad` и `jellyfish`
/// в каталоге нет ни одной задачи.
public struct DojoLesson: Equatable, Sendable, Identifiable {

    public let technique: SudokuTechnique
    /// Сколько дриллов нужно закрыть, чтобы открылась следующая ступень.
    public let drillsToUnlock: Int

    public var id: Int { technique.rawValue }
    public var titleKey: String { technique.nameKey }
    /// Объяснение техники уже есть у самой техники — дублировать его в додзё
    /// значит завести два текста об одном и том же, которые разойдутся.
    public var explanationKey: String { technique.explanationKey }
    /// «Как искать» в три шага — это уже про тренировку, а не про определение.
    public var searchKeys: [String] {
        (1...3).map { "dojo.\(technique.catalogKey).search\($0)" }
    }

    public init(technique: SudokuTechnique, drillsToUnlock: Int = 3) {
        self.technique = technique
        self.drillsToUnlock = drillsToUnlock
    }
}

public enum DojoCurriculum {

    /// Порядок — по рейтингу техники, с одним обдуманным исключением.
    ///
    /// `nakedSingle` (2.3) стоит раньше «прямых» вариантов (1.7 и 2.0), хотя
    /// решателю он даётся тяжелее. Рейтинг SE измеряет трудность для программы,
    /// а путь — для человека, и это разные вещи. «Прямые» техники по смыслу
    /// суть сокращения, которые СРАЗУ дают одиночку: объяснить их тому, кто
    /// ещё не знает, что такое одиночка, невозможно. Прerequisite сильнее
    /// численного рейтинга.
    ///
    /// Список сознательно не совпадает с полным набором техник решателя:
    /// сюда попадают только те, для которых в каталоге хватает материала.
    public static let lessons: [DojoLesson] = [
        DojoLesson(technique: .hiddenSingleBox),
        DojoLesson(technique: .hiddenSingleLine),
        DojoLesson(technique: .nakedSingle),
        DojoLesson(technique: .directPointing),
        DojoLesson(technique: .directHiddenPair),
        DojoLesson(technique: .pointing),
        DojoLesson(technique: .claiming),
        DojoLesson(technique: .nakedPair),
        DojoLesson(technique: .xWing),
        DojoLesson(technique: .hiddenPair),
        DojoLesson(technique: .nakedTriple),
        DojoLesson(technique: .swordfish),
        DojoLesson(technique: .hiddenTriple),
        DojoLesson(technique: .xyWing),
        DojoLesson(technique: .xyzWing),
        DojoLesson(technique: .turbotFish)
    ]

    public static func lesson(for technique: SudokuTechnique) -> DojoLesson? {
        lessons.first { $0.technique == technique }
    }

    public static func index(of technique: SudokuTechnique) -> Int? {
        lessons.firstIndex { $0.technique == technique }
    }
}

/// Одно упражнение: позиция и единственный ожидаемый ход.
public struct DojoDrill: Equatable, Sendable, Identifiable {

    /// Конформанс объявлен здесь, а не в слое интерфейса. Расширение чужого
    /// типа чужим протоколом ломается, как только владелец типа объявит то же
    /// самое у себя, — и компилятор об этом честно предупреждает.
    public var id: String { "\(puzzleID)|\(technique.rawValue)" }

    public let technique: SudokuTechnique
    /// Позиция в момент, когда техника впервые нужна. 81 символ, `0` — пусто.
    public let position: String
    /// Кандидаты, вычеркнутые шагами ДО этой позиции.
    ///
    /// Строки из 81 символа хватает на цифры и не хватает на кандидатов, а
    /// решатель к моменту находки смотрит не на «легальные по строке, столбцу
    /// и блоку», а на них же минус всё, что вычеркнули пойнтинг, пары и рыбы
    /// раньше по трассе. Без этого списка предъявляется НЕ та позиция, на
    /// которой шаг был найден: вычеркнутые кандидаты возвращаются на доску, а
    /// вместе с ними возвращается и тот исключающий шаг, который их вычеркнул.
    /// Решатель на такой позиции честно предъявит его снова — технику проще
    /// изучаемой, — а искомого паттерна в ней может не быть вовсе.
    public let priorEliminations: [Elimination]
    /// Решение исходной задачи — по нему проверяется ввод.
    public let solution: String
    public let puzzleID: String
    /// Ожидаемый шаг: что именно должен найти игрок.
    public let step: SolveStep

    public init(technique: SudokuTechnique, position: String,
                priorEliminations: [Elimination] = [], solution: String,
                puzzleID: String, step: SolveStep) {
        self.technique = technique
        self.position = position
        self.priorEliminations = priorEliminations
        self.solution = solution
        self.puzzleID = puzzleID
        self.step = step
    }

    /// Позиция глазами решателя: цифры плюс накопленные вычерки. Именно из
    /// этой сетки был найден `step`, и проверять «техника здесь работает»
    /// нужно по ней, а не по одним цифрам: `SolverGrid(board:)` восстанавливает
    /// кандидатов с нуля и о вычерках не знает.
    public func solverGrid() -> SolverGrid? {
        guard let board = BoardState(givens: position) else { return nil }
        var grid = SolverGrid(board: board)
        for elimination in priorEliminations { grid.eliminate(elimination) }
        return grid
    }

    /// Клетки, из которых следует вывод, — подсветка «где смотреть».
    public var premises: [Int] { step.premises }

    /// Проверка ответа для техник, которые ставят цифру.
    public func isCorrect(cell: Int, digit: Int) -> Bool {
        guard let placement = step.placement else { return false }
        return placement.cell == cell && placement.digit == digit
    }

    /// Техники-исключения цифру не ставят: игрок отмечает, какого кандидата
    /// больше не может быть. Ответ засчитывается по любому из исключений —
    /// найдя одно, игрок уже увидел паттерн.
    public func isCorrect(elimination: Elimination) -> Bool {
        step.eliminations.contains(elimination)
    }

    public var expectsPlacement: Bool { step.placement != nil }
}

public enum DojoDrillBuilder {

    public enum Failure: Error, Equatable, Sendable {
        /// В каталоге нет задачи, где эта техника была бы нужна.
        case noMaterial(SudokuTechnique)
    }

    /// Вырезает позицию из задачи. Возвращает `nil`, если техника в трассе
    /// так и не встретилась — размётка каталога и трасса могли разойтись
    /// после смены версии решателя, и молча подсунуть чужой шаг нельзя.
    public static func drill(
        technique: SudokuTechnique,
        puzzleID: String,
        givens: String,
        solution: String
    ) -> DojoDrill? {
        guard var board = BoardState(givens: givens) else { return nil }
        let trace = HumanSolver.solve(givens: givens)
        guard trace.status == .solved else { return nil }

        let builder = MoveBuilder()
        var priorEliminations: [Elimination] = []
        for step in trace.steps {
            if step.technique == technique {
                return DojoDrill(technique: technique,
                                 position: board.serialized(),
                                 priorEliminations: priorEliminations,
                                 solution: solution,
                                 puzzleID: puzzleID,
                                 step: step)
            }
            // Шаг применяется ровно так же, как его применил `HumanSolver`:
            // либо цифра, либо вычерки — одно из двух и никогда оба сразу.
            //
            // Вычерки доску не меняют, но меняют ПОЗИЦИЮ: следующие техники
            // опираются на суженных кандидатов. Отбросить их значит вернуть
            // доску в состояние, которого решатель на этой глубине уже не
            // видел, поэтому они копятся и уезжают в дрилл.
            guard let placement = step.placement else {
                priorEliminations.append(contentsOf: step.eliminations)
                continue
            }
            MoveApplier.apply(
                builder.placeDigit(placement.digit, at: placement.cell,
                                   board: board, autoReduceNotes: false),
                to: &board)
        }
        return nil
    }
}
