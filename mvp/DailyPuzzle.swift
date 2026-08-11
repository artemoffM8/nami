//
//  DailyPuzzle.swift
//  "Утренняя партия": одна особая головоломка в день, одинаковая у всех.
//  Seed = дата, сложность = кривая недели (пн легко -> вс эксперт).
//  DailyStore хранит решённые дни (для календаря-сада) и прогресс сегодняшней.
//

import Foundation
import Combine

struct DailyPuzzle {
    let dateKey: String        // "2026-08-07"
    let difficulty: SudokuDifficulty
    let puzzle: [Int?]
    let solution: [Int]

    static func forDate(_ date: Date, calendar: Calendar = .current) -> DailyPuzzle {
        let comps = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let y = comps.year!, m = comps.month!, d = comps.day!

        // Кривая недели: 1=вс ... 7=сб (Gregorian)
        let difficulty: SudokuDifficulty
        switch comps.weekday! {
        case 2, 3: difficulty = .easy      // пн, вт
        case 4, 5: difficulty = .medium    // ср, чт
        case 6, 7: difficulty = .hard      // пт, сб
        default:   difficulty = .expert    // вс
        }

        let seed = UInt64(y) &* 10_000 &+ UInt64(m) &* 100 &+ UInt64(d)
        let (puzzle, solution) = SudokuGenerator.generate(seed: seed &* 0x5DEECE66D,
                                                          difficulty: difficulty)
        let key = String(format: "%04d-%02d-%02d", y, m, d)
        return DailyPuzzle(dateKey: key, difficulty: difficulty,
                           puzzle: puzzle, solution: solution)
    }
}

// MARK: - Хранилище

final class DailyStore: ObservableObject {

    static let shared = DailyStore()

    /// Решённые дни — из них растёт сад.
    @Published private(set) var completedDays: Set<String>

    private let defaults = UserDefaults.standard
    private let completedKey = "daily.completed"

    private init() {
        completedDays = Set(defaults.stringArray(forKey: completedKey) ?? [])
    }

    // MARK: Завершение

    func markCompleted(_ dateKey: String) {
        completedDays.insert(dateKey)
        defaults.set(Array(completedDays), forKey: completedKey)
        defaults.removeObject(forKey: progressKey(dateKey))
    }

    func isCompleted(_ dateKey: String) -> Bool {
        completedDays.contains(dateKey)
    }

    /// Сколько "камешков" выросло в саду за месяц (yyyy-MM).
    func completedCount(inMonth monthKey: String) -> Int {
        completedDays.filter { $0.hasPrefix(monthKey) }.count
    }

    // MARK: Прогресс незаконченной партии (переживает перезапуск)

    private func progressKey(_ dateKey: String) -> String { "daily.progress.\(dateKey)" }

    func saveProgress(_ values: [Int?], for dateKey: String) {
        let raw = values.map { $0 ?? 0 }
        defaults.set(raw, forKey: progressKey(dateKey))
    }

    func loadProgress(for dateKey: String) -> [Int?]? {
        guard let raw = defaults.array(forKey: progressKey(dateKey)) as? [Int],
              raw.count == 81 else { return nil }
        return raw.map { $0 == 0 ? nil : $0 }
    }
}
