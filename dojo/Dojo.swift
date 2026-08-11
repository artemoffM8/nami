//
//  Dojo.swift
//  Уроки техник и прогрессия додзё.
//  Правило открытия: следующая техника доступна после 3 решённых дриллов
//  предыдущей. Открытие новой техники = реальный скачок силы игрока.
//

import Foundation
import Combine

// MARK: - Урок

struct DojoLesson {
    let technique: SolveTechnique
    let subtitle: String
    let explanation: String
    let howToFind: [String]

    /// Пример-иллюстрация: ячейки паттерна и ячейки, откуда уходят кандидаты.
    let patternCells: [Int]
    let eliminatedCells: [Int]

    static let all: [DojoLesson] = [
        DojoLesson(
            technique: .nakedSingle,
            subtitle: "База всех баз",
            explanation: "Если в ячейке остался один-единственный возможный кандидат — он и есть ответ. Все остальные восемь цифр уже заняты её строкой, столбцом и блоком.",
            howToFind: [
                "Выбери пустую ячейку",
                "Вычеркни цифры её строки, столбца и блока",
                "Осталась одна — ставь"
            ],
            patternCells: [40],
            eliminatedCells: []),
        DojoLesson(
            technique: .hiddenSingle,
            subtitle: "Цифре больше некуда встать",
            explanation: "В строке, столбце или блоке цифра помещается только в одну ячейку — даже если у самой ячейки кандидатов несколько. Остальные места для этой цифры заблокированы.",
            howToFind: [
                "Возьми цифру, которой мало на поле",
                "Пройди по блоку: куда она может встать?",
                "Место одно — ставь, не глядя на других кандидатов"
            ],
            patternCells: [30],
            eliminatedCells: [31, 32, 39, 41, 48, 50]),
        DojoLesson(
            technique: .lockedCandidates,
            subtitle: "Первая техника исключения",
            explanation: "Если в блоке все кандидаты цифры выстроились в одну строку — в этой строке за пределами блока цифры быть не может. Ход не ставит цифру, но вычёркивает кандидатов — и открывает следующие ходы.",
            howToFind: [
                "В блоке отметь все места для одной цифры",
                "Все в одной строке или столбце?",
                "Вычеркни эту цифру из линии вне блока"
            ],
            patternCells: [27, 28, 29],
            eliminatedCells: [30, 31, 32, 33, 34, 35]),
        DojoLesson(
            technique: .nakedPair,
            subtitle: "Двое заняли два места",
            explanation: "Две ячейки юнита содержат одинаковую пару кандидатов — скажем, {2,7}. Эти две цифры гарантированно займут эти две ячейки, значит из остальных ячеек юнита их можно вычеркнуть.",
            howToFind: [
                "Ищи две ячейки ровно с двумя кандидатами",
                "Пары совпадают?",
                "Вычеркни обе цифры из остального юнита"
            ],
            patternCells: [36, 39],
            eliminatedCells: [37, 38, 40, 41, 42, 43, 44]),
        DojoLesson(
            technique: .hiddenPair,
            subtitle: "Пара, спрятанная в шуме",
            explanation: "Две цифры в юните помещаются только в одни и те же две ячейки. Эти ячейки — их, поэтому все прочие кандидаты в этих двух ячейках можно стереть, оголив пару.",
            howToFind: [
                "Для каждой цифры юнита выпиши её места",
                "Две цифры делят одни и те же 2 ячейки?",
                "Сотри в этих ячейках все прочие кандидаты"
            ],
            patternCells: [3, 5],
            eliminatedCells: []),
        DojoLesson(
            technique: .xWing,
            subtitle: "Прямоугольник силы",
            explanation: "Цифра в двух строках встаёт только в одни и те же два столбца — четыре ячейки образуют прямоугольник. Цифра займёт одну из диагоналей, поэтому в этих двух столбцах вне прямоугольника её можно вычеркнуть.",
            howToFind: [
                "Найди строку, где цифре осталось 2 места",
                "Найди вторую строку с теми же столбцами",
                "Вычеркни цифру из этих столбцов в других строках"
            ],
            patternCells: [10, 16, 64, 70],
            eliminatedCells: [1, 28, 37, 46, 7, 34, 43, 52]),
    ]

    static func lesson(for t: SolveTechnique) -> DojoLesson {
        all.first { $0.technique == t }!
    }
}

// MARK: - Прогрессия

final class DojoStore: ObservableObject {

    static let shared = DojoStore()
    static let drillsToMaster = 3

    /// Порядок открытия.
    static let path: [SolveTechnique] = [
        .nakedSingle, .hiddenSingle, .lockedCandidates,
        .nakedPair, .hiddenPair, .xWing
    ]

    @Published private(set) var completedDrills: [SolveTechnique: Int]

    private let defaults = UserDefaults.standard
    private let key = "dojo.progress"

    private init() {
        let raw = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        var dict: [SolveTechnique: Int] = [:]
        for (k, v) in raw {
            if let i = Int(k), let t = SolveTechnique(rawValue: i) { dict[t] = v }
        }
        completedDrills = dict
    }

    func drills(for t: SolveTechnique) -> Int { completedDrills[t] ?? 0 }

    func isMastered(_ t: SolveTechnique) -> Bool {
        drills(for: t) >= Self.drillsToMaster
    }

    /// Первая техника открыта всегда; дальше — после мастеринга предыдущей.
    func isUnlocked(_ t: SolveTechnique) -> Bool {
        guard let idx = Self.path.firstIndex(of: t) else { return false }
        if idx == 0 { return true }
        return isMastered(Self.path[idx - 1])
    }

    func registerCompletedDrill(_ t: SolveTechnique) {
        completedDrills[t] = drills(for: t) + 1
        let raw = Dictionary(uniqueKeysWithValues:
            completedDrills.map { (String($0.key.rawValue), $0.value) })
        defaults.set(raw, forKey: key)
    }
}
