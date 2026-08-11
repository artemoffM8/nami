//
//  DojoTests.swift
//  NamiDomainTests
//
//  Created by artemoffM8.
//
//  Проверяется главное свойство упражнения: позиция взята из настоящей
//  задачи, и в ней действительно нужна изучаемая техника — не проще и не
//  случайно другая.
//

import XCTest
@testable import NamiDomain

final class DojoTests: XCTestCase {

    private static let givens =
        "530070000600195000098000060800060003400803001700020006060000280000419005000080079"
    private static let solution =
        "534678912672195348198342567859761423426853791713924856961537284287419635345286179"

    /// Второй стенд — для исключающих техник. Первый для них не годится
    /// принципиально: его трасса состоит из `fullHouse` и `hiddenSingleBox`,
    /// исключающих шагов в ней НЕТ ВООБЩЕ, а значит и терять ей нечего —
    /// на ней потеря накопленных вычерков не проявляется никогда.
    ///
    /// Это `classic-expert-0032` из каталога. Выбран так: по всем задачам,
    /// размеченным исключающими техниками, взят первый случай, где позиция без
    /// накопленных вычерков перестаёт быть позицией найденного шага. К моменту
    /// голой тройки решатель сделал два исключающих шага (три вычерка); если
    /// их отбросить, вычеркнутые кандидаты возвращаются вместе с пойнтингом,
    /// который их вычеркнул, и решатель предъявляет пойнтинг вместо тройки.
    /// Техника взята не пограничная: голая тройка ломалась на ВСЕХ семи
    /// задачах каталога, где она размечена, — случайной удачей это не объяснить.
    private static let tripleGivens =
        "000090500103054970005070460301600000086000005050302000000000058012500390008030000"
    private static let tripleSolution =
        "274196583163854972895273461321685749486719235957342816639427158712568394548931627"

    // MARK: - Учебный план

    /// Порядок ступеней — это порядок обучения. Если он перестанет совпадать
    /// с рейтингом техник, игрок получит X-Wing раньше скрытой пары.
    ///
    /// Единственное допущенное исключение — `nakedSingle` перед «прямыми»
    /// вариантами: те по смыслу дают одиночку сразу, и объяснить их раньше,
    /// чем саму одиночку, нельзя. Исключение проверяется поимённо, чтобы
    /// случайная перестановка не сошла за осознанную.
    func testCurriculumIsOrderedByDifficulty() {
        // `nakedSingle` стоит раньше, чем велит его рейтинг (перед «прямыми»
        // вариантами), — это единственное осознанное исключение. Убираем его
        // из проверки: он не должен влиять на порядок соседей, иначе поднятая
        // им планка ложно обвинит идущие следом «прямые» техники.
        let allowed: Set<SudokuTechnique> = [.nakedSingle]
        let ratings = DojoCurriculum.lessons
            .map(\.technique)
            .filter { !allowed.contains($0) }
            .map(\.rating)
        XCTAssertEqual(ratings, ratings.sorted(),
                       "порядок ступеней разошёлся с рейтингом техник")
    }

    /// Одиночка обязана идти раньше «прямых» техник: они её частный случай.
    ///
    /// И обязана идти позже скрытых одиночек — это вторая половина того же
    /// правила, и проверять её приходится здесь. Тест порядка выше убирает
    /// `nakedSingle` из списка целиком, поэтому снизу её там не держит ничто:
    /// перенос ступени в самое начало не провалил бы ни одной проверки, хотя
    /// исключение в `DojoCurriculum` разрешает ей стоять раньше рейтинга
    /// РОВНО перед «прямыми» вариантами, а не где угодно. Соседа берём
    /// ближайшего — `hiddenSingleLine` (1.5): порядок `hiddenSingleBox` (1.2)
    /// относительно него уже закреплён тестом порядка.
    func testSingleComesBeforeDirectShortcuts() {
        guard let single = DojoCurriculum.index(of: .nakedSingle),
              let hiddenLine = DojoCurriculum.index(of: .hiddenSingleLine),
              let directPointing = DojoCurriculum.index(of: .directPointing),
              let directPair = DojoCurriculum.index(of: .directHiddenPair) else {
            return XCTFail("ступени не найдены")
        }
        XCTAssertLessThan(hiddenLine, single,
                          "одиночка обогнала скрытую одиночку по строке")
        XCTAssertLessThan(single, directPointing)
        XCTAssertLessThan(single, directPair)
    }

    func testCurriculumHasNoDuplicates() {
        let techniques = DojoCurriculum.lessons.map(\.technique)
        XCTAssertEqual(Set(techniques).count, techniques.count)
    }

    /// `fullHouse` — «осталась одна клетка в юните». Учить там нечему, и
    /// ступень из одного очевидного шага обесценивает весь путь.
    func testCurriculumSkipsTrivialTechnique() {
        XCTAssertNil(DojoCurriculum.lesson(for: .fullHouse))
    }

    // MARK: - Построение упражнения

    func testDrillStopsAtFirstUseOfTechnique() {
        guard let drill = DojoDrillBuilder.drill(
            technique: .hiddenSingleBox, puzzleID: "test",
            givens: Self.givens, solution: Self.solution) else {
            return XCTFail("упражнение не построилось")
        }
        XCTAssertEqual(drill.step.technique, .hiddenSingleBox)
        XCTAssertEqual(drill.position.count, 81)
    }

    /// Позиция обязана быть достижимой из задачи: всё, что уже стоит на
    /// доске, должно совпадать с решением. Иначе тренировка учит на позиции,
    /// которой в этой задаче никогда не было.
    func testDrillPositionAgreesWithSolution() {
        guard let drill = DojoDrillBuilder.drill(
            technique: .hiddenSingleBox, puzzleID: "test",
            givens: Self.givens, solution: Self.solution) else {
            return XCTFail("упражнение не построилось")
        }
        let position = Array(drill.position)
        let solution = Array(Self.solution)
        for index in 0..<81 where position[index] != "0" {
            XCTAssertEqual(position[index], solution[index],
                           "клетка \(index) расходится с решением")
        }
    }

    /// Позиция не должна быть исходной задачей: если техника нужна с первого
    /// хода, упражнение выродится в «решите задачу с нуля».
    func testDrillAdvancesPastEarlierSteps() {
        let trace = HumanSolver.solve(givens: Self.givens)
        // Берём технику, которая заведомо встречается не первой.
        guard let later = trace.steps.first(where: { $0.technique != trace.steps[0].technique })?
            .technique,
              let drill = DojoDrillBuilder.drill(
                technique: later, puzzleID: "test",
                givens: Self.givens, solution: Self.solution) else {
            return XCTFail("в трассе только одна техника")
        }
        let filled = drill.position.filter { $0 != "0" }.count
        let initial = Self.givens.filter { $0 != "0" }.count
        XCTAssertGreaterThan(filled, initial,
                             "позиция совпала с исходной задачей")
    }

    /// Ответ проверяется по шагу решателя, а не по решению задачи: в клетке
    /// может стоять верная цифра, до которой эта техника ещё не доводит.
    func testAnswerCheckMatchesTheStepNotTheSolution() {
        guard let drill = DojoDrillBuilder.drill(
            technique: .hiddenSingleBox, puzzleID: "test",
            givens: Self.givens, solution: Self.solution),
              let placement = drill.step.placement else {
            return XCTFail("упражнение не построилось")
        }
        XCTAssertTrue(drill.isCorrect(cell: placement.cell, digit: placement.digit))
        XCTAssertFalse(drill.isCorrect(cell: placement.cell,
                                       digit: placement.digit % 9 + 1))

        // Другая клетка с верной по решению цифрой ответом не является.
        let solution = Array(Self.solution)
        let position = Array(drill.position)
        if let other = (0..<81).first(where: {
            position[$0] == "0" && $0 != placement.cell
        }) {
            let correctBySolution = solution[other].wholeNumberValue ?? 0
            XCTAssertFalse(drill.isCorrect(cell: other, digit: correctBySolution),
                           "принят ход, которого эта техника не даёт")
        }
    }

    // MARK: - Накопленные вычерки кандидатов

    /// Главное свойство упражнения на исключающую технику: в предъявленной
    /// позиции техника действительно РАБОТАЕТ.
    ///
    /// Проверяется тем же решателем и с той же стороны, с какой позицию
    /// увидит игрок: прогоняем поиск шага по позиции дрилла и требуем не
    /// «какой-нибудь» шаг, а ровно тот, которому учит ступень. Требование
    /// именно на равенство шага, а не только техники: голая тройка в другом
    /// юните — это другая задача, и подсветка посылок увела бы игрока не туда.
    func testEliminationDrillPresentsPositionWhereTechniqueApplies() {
        guard let drill = DojoDrillBuilder.drill(
            technique: .nakedTriple, puzzleID: "classic-expert-0032",
            givens: Self.tripleGivens, solution: Self.tripleSolution),
              var grid = drill.solverGrid() else {
            return XCTFail("упражнение не построилось")
        }
        guard let found = HumanSolver.findStep(in: &grid) else {
            return XCTFail("в позиции дрилла решатель не видит ни одного шага")
        }
        XCTAssertEqual(found.technique, .nakedTriple,
                       "в позиции дрилла нашлась не изучаемая техника")
        XCTAssertEqual(found.placement, drill.step.placement)
        XCTAssertEqual(found.eliminations, drill.step.eliminations,
                       "предъявлен не тот шаг, который нашёл решатель")
        XCTAssertEqual(found.premises, drill.step.premises,
                       "подсветка «где смотреть» указывает на другие клетки")
    }

    /// Тест выше обязан быть чувствительным, а не «зелёным по построению».
    ///
    /// Если бы позиция из одних цифр и так давала голую тройку, проверка
    /// проходила бы и с потерянными вычерками — то есть не проверяла бы
    /// ничего. Здесь фиксируется, что стенд разделяет два поведения: по
    /// цифрам без накопленных вычерков решатель находит ДРУГУЮ технику.
    /// Утверждение намеренно слабое — «не голая тройка», а не «пойнтинг»:
    /// какую именно поблажку даст возврат вычерков, зависит от решателя, а
    /// вот то, что изучаемой техники там нет, — свойство самой потери.
    func testPositionWithoutCarriedEliminationsWouldOfferAnEasierStep() {
        guard let drill = DojoDrillBuilder.drill(
            technique: .nakedTriple, puzzleID: "classic-expert-0032",
            givens: Self.tripleGivens, solution: Self.tripleSolution),
              let board = BoardState(givens: drill.position) else {
            return XCTFail("упражнение не построилось")
        }
        XCTAssertNotEqual(HumanSolver.nextStep(board: board)?.technique, .nakedTriple,
                          "стенд перестал различать потерю вычерков — нужен другой")
    }

    /// Вычерки обязаны доехать до дрилла и обязаны быть настоящими: каждый из
    /// них снимает кандидата, который по строке, столбцу и блоку в позиции
    /// ещё легален. Иначе список — не восстановленное состояние решателя, а
    /// набор безобидных повторов уже сделанной работы.
    func testDrillCarriesEliminationsAccumulatedBeforeThePosition() {
        guard let drill = DojoDrillBuilder.drill(
            technique: .nakedTriple, puzzleID: "classic-expert-0032",
            givens: Self.tripleGivens, solution: Self.tripleSolution),
              let board = BoardState(givens: drill.position),
              let grid = drill.solverGrid() else {
            return XCTFail("упражнение не построилось")
        }
        XCTAssertFalse(drill.priorEliminations.isEmpty,
                       "накопленные вычерки потерялись по дороге в дрилл")
        for elimination in drill.priorEliminations {
            XCTAssertTrue(
                Digits.contains(board.legalCandidates(at: elimination.cell), elimination.digit),
                "вычерк \(elimination) не добавляет ничего к цифрам позиции")
            XCTAssertFalse(
                Digits.contains(grid.candidates[elimination.cell], elimination.digit),
                "вычерк \(elimination) не применён к позиции решателя")
        }
    }

    /// Обратная сторона: там, где решатель до нужной техники не сделал ни
    /// одного исключающего шага, вычеркам взяться неоткуда. Список должен
    /// быть пустым, а не «на всякий случай» полным — лишний вычерк портит
    /// позицию ровно так же, как потерянный.
    func testDrillWithoutEarlierEliminationsCarriesNothing() {
        guard let drill = DojoDrillBuilder.drill(
            technique: .hiddenSingleBox, puzzleID: "test",
            givens: Self.givens, solution: Self.solution) else {
            return XCTFail("упражнение не построилось")
        }
        XCTAssertTrue(drill.priorEliminations.isEmpty)
        XCTAssertEqual(drill.solverGrid()?.candidates,
                       BoardState(givens: drill.position).map { board in
                           (0..<81).map { board.legalCandidates(at: $0) }
                       },
                       "позиция без вычерков разошлась с кандидатами по цифрам")
    }

    /// Позиция исключающего дрилла тоже обязана быть достижимой из задачи.
    /// Проверка та же, что и для одиночек, но на втором стенде: вычерки
    /// кандидатов цифр на доске не ставят и сдвинуть её к решению не могут.
    func testEliminationDrillPositionAgreesWithSolution() {
        guard let drill = DojoDrillBuilder.drill(
            technique: .nakedTriple, puzzleID: "classic-expert-0032",
            givens: Self.tripleGivens, solution: Self.tripleSolution) else {
            return XCTFail("упражнение не построилось")
        }
        let position = Array(drill.position)
        let solution = Array(Self.tripleSolution)
        XCTAssertEqual(position.count, 81)
        for index in 0..<81 where position[index] != "0" {
            XCTAssertEqual(position[index], solution[index],
                           "клетка \(index) расходится с решением")
        }
    }

    func testMissingTechniqueYieldsNoDrill() {
        // `jellyfish` в этой задаче не встречается.
        XCTAssertNil(DojoDrillBuilder.drill(
            technique: .jellyfish, puzzleID: "test",
            givens: Self.givens, solution: Self.solution))
    }
}
