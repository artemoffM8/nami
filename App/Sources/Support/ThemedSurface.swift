//
//  ThemedSurface.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Тема применяется к КАЖДОЙ поверхности, а не только к корневому экрану.
//
//  Почему это отдельный модификатор. Лист (`.sheet`) живёт в собственном
//  окне представления: фон и цветовая схема корневого экрана до него не
//  доходят. Плюс `Form` и `List` рисуют системный сгруппированный фон поверх
//  чего угодно — из-за него «Бумага» выглядела белой, хотя её `appBackground`
//  тёплый `#F1ECE1`.
//
//  `.preferredColorScheme` здесь же: заданный один раз на уровне `App`, он не
//  переезжал в уже открытый лист, поэтому смена темы была видна только после
//  повторного захода в меню.
//

import SwiftUI
import NamiExperience

private struct ThemedSurface: ViewModifier {

    @Environment(ThemeProvider.self) private var theme

    func body(content: Content) -> some View {
        content
            // Убирает системный фон Form/List; на нескроллируемых экранах
            // модификатор безвреден.
            .scrollContentBackground(.hidden)
            .background(theme.color(.appBackground).ignoresSafeArea())
            .tint(theme.color(.accent))
            .preferredColorScheme(theme.current.preferredColorScheme)
    }
}

extension View {
    /// Красит поверхность в активную тему и подхватывает её смену немедленно.
    func themedSurface() -> some View { modifier(ThemedSurface()) }
}
