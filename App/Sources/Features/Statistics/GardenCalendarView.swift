//
//  GardenCalendarView.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Календарь-сад: день с решённой партией отмечен глифом темы.
//
//  Главное решение здесь — чего тут НЕТ. Нет серии подряд идущих дней и нет
//  её обнуления. По ТЗ такие метрики создают тревогу: пропустив день, игрок
//  теряет не прогресс, а цифру, которую сам себе назначил ценностью. Поэтому
//  пропуск — просто клетка без глифа, а итог месяца — счётчик «в саду», который
//  умеет только расти.
//
//  Данные берутся из уже существующих дат завершений: нового хранилища сад
//  не заводит и знать о нём ничего не нужно.
//

import SwiftUI
import NamiDomain
import NamiExperience

struct GardenCalendarView: View {

    let completionDates: [Date]
    let personality: EffectPersonality
    let tint: Color
    let secondary: Color

    /// Дни с решённой партией. Set, а не массив: клеток в месяце до 31,
    /// а завершений за год — сотни.
    ///
    /// Хранимое свойство, а не вычисляемое: вычисляемое пересобирало весь
    /// набор на каждую клетку сетки и ещё раз на счётчик месяца — 31–37
    /// полных проходов по завершениям за отрисовку. Теперь проход ровно один
    /// на создание представления, то есть на новые данные, а листание месяцев
    /// (`monthAnchor` — @State) его не повторяет вовсе.
    private let completedDays: Set<Date>

    @State private var monthAnchor = Date()

    private var calendar: Calendar { Calendar.current }

    init(completionDates: [Date], personality: EffectPersonality,
         tint: Color, secondary: Color) {
        self.completionDates = completionDates
        self.personality = personality
        self.tint = tint
        self.secondary = secondary
        let calendar = Calendar.current
        self.completedDays = Set(completionDates.map { calendar.startOfDay(for: $0) })
    }

    private var monthTitle: String {
        let formatter = DateFormatter()
        // Язык берётся из настройки приложения, а не из системы: игрок мог
        // выбрать английский на русском телефоне, и месяц обязан следовать
        // за интерфейсом.
        formatter.locale = Locale(identifier: L.language == .ru ? "ru_RU" : "en_US")
        formatter.setLocalizedDateFormatFromTemplate("LLLL yyyy")
        return formatter.string(from: monthAnchor).capitalized
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            grid
            Text(L.t("garden.monthCount", monthTotal))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel(L.t("garden.previousMonth"))
            Spacer()
            Text(monthTitle).font(.subheadline.weight(.medium))
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel(L.t("garden.nextMonth"))
                // Вперёд за текущий месяц идти незачем: там заведомо пусто,
                // и пустой экран выглядел бы как потеря данных.
                .disabled(isCurrentMonth)
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint)
    }

    private var grid: some View {
        let cells = monthCells()
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7),
                         spacing: 6) {
            ForEach(cells.indices, id: \.self) { index in
                if let day = cells[index] {
                    dayCell(day)
                } else {
                    Color.clear.frame(minHeight: 34)
                }
            }
        }
    }

    private func dayCell(_ day: (number: Int, date: Date)) -> some View {
        let isDone = completedDays.contains(day.date)
        return VStack(spacing: 2) {
            Text("\(day.number)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if isDone {
                GardenGlyph(personality: personality, tint: tint,
                            secondary: secondary, size: 16)
            } else {
                Circle()
                    .fill(secondary.opacity(0.25))
                    .frame(width: 4, height: 4)
                    .padding(.vertical, 6)
            }
        }
        .frame(minHeight: 34)
        .accessibilityElement()
        .accessibilityLabel(isDone
            ? L.t("garden.day.done", day.number)
            : L.t("garden.day.empty", day.number))
    }

    /// `nil` — ведущие пустые клетки до первого числа месяца.
    private func monthCells() -> [(number: Int, date: Date)?] {
        let components = calendar.dateComponents([.year, .month], from: monthAnchor)
        guard let first = calendar.date(from: components),
              let range = calendar.range(of: .day, in: .month, for: first) else { return [] }
        let firstWeekday = calendar.component(.weekday, from: first)
        // Сдвиг считается от первого дня недели ЛОКАЛИ: в России неделя
        // начинается с понедельника, в США — с воскресенья.
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7

        var cells: [(number: Int, date: Date)?] = Array(repeating: nil, count: leading)
        for day in range {
            guard let date = calendar.date(byAdding: .day, value: day - 1, to: first) else {
                continue
            }
            cells.append((day, calendar.startOfDay(for: date)))
        }
        return cells
    }

    private var monthTotal: Int {
        monthCells().compactMap { $0 }.filter { completedDays.contains($0.date) }.count
    }

    private var isCurrentMonth: Bool {
        calendar.isDate(monthAnchor, equalTo: Date(), toGranularity: .month)
    }

    private func shift(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: monthAnchor)
        else { return }
        monthAnchor = next
    }
}
