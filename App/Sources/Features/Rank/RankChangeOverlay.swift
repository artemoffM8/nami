//
//  RankChangeOverlay.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Показ перехода между ступенями.
//
//  Разница с играми, откуда идея: повышение здесь празднуется, а понижение —
//  нет. По ТЗ (раздел 9.7) снижение показывается спокойным перетеканием без
//  вспышек, частиц и звука: отрицательное подкрепление в приложении про
//  ясность работает против самого приложения.
//
//  Анимация никогда не блокирует ввод дольше своей длительности и полностью
//  вырождается в короткий fade при Reduce Motion.
//

import SwiftUI
import NamiDomain
import NamiExperience

struct RankChangeOverlay: View {

    let from: RankDivision
    let to: RankDivision
    let rating: Int
    let theme: ThemeProvider
    let reduceMotion: Bool
    let onFinished: () -> Void

    @State private var phase: Double = 0

    private var isPromotion: Bool { to > from }
    private var duration: Double {
        if reduceMotion { return 0.5 }
        return isPromotion ? 2.4 : 1.2
    }

    var body: some View {
        ZStack {
            theme.color(.appBackground)
                .opacity(0.92)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Text(L.t(isPromotion ? "rank.promoted" : "rank.demoted"))
                    .font(.subheadline)
                    .foregroundStyle(theme.color(.secondaryText))
                    .opacity(min(1, phase * 3))

                badgePair

                Text(RankBadgeView.title(for: to))
                    .font(.title2.weight(.medium))
                    .foregroundStyle(theme.color(.primaryText))
                    .opacity(min(1, max(0, (phase - 0.35) * 3)))

                RankProgressBar(rating: rating, division: to,
                                accent: theme.color(.accent),
                                track: theme.color(.secondaryText))
                    .frame(maxWidth: 260)
                    .opacity(min(1, max(0, (phase - 0.5) * 3)))
            }
            .padding(32)
        }
        .allowsHitTesting(false)
        .task {
            // Одна анимация на весь показ: фаза 0 -> 1 ведёт все слои,
            // поэтому они не могут разъехаться между собой.
            withAnimation(.easeOut(duration: duration)) { phase = 1 }
            try? await Task.sleep(for: .seconds(duration + 0.45))
            onFinished()
        }
    }

    private var badgePair: some View {
        ZStack {
            if isPromotion && !reduceMotion {
                // Волна расходится ровно один раз и гаснет вместе с фазой.
                Circle()
                    .stroke(theme.color(.accent).opacity(0.5 * (1 - phase)), lineWidth: 2)
                    .frame(width: 120 + 190 * phase, height: 120 + 190 * phase)
            }

            // Старый знак уходит, новый приходит — без «прыжка» между ними.
            RankBadgeView(division: from, size: 116,
                          accent: theme.color(.accent),
                          surface: theme.color(.boardSurface),
                          isDimmed: true)
                .opacity(1 - min(1, phase * 2))
                .scaleEffect(reduceMotion ? 1 : 1 - 0.12 * phase)

            RankBadgeView(division: to, size: 116,
                          accent: theme.color(.accent),
                          surface: theme.color(.boardSurface))
                .opacity(min(1, max(0, (phase - 0.3) * 2.4)))
                .scaleEffect(reduceMotion ? 1 : 0.82 + 0.18 * min(1, phase * 1.4))
        }
        .frame(height: 200)
    }
}
