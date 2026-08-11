//
//  KeypadView.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Адаптивная панель 1–9 (раздел 5.4): один ряд, если каждая цель сохраняет
//  достаточный размер, иначе 3×3. Ни один вариант не должен ухудшать
//  доступность, поэтому минимальная цель — 44 pt.
//

import SwiftUI
import NamiDomain
import NamiData
import NamiExperience

struct KeypadView: View {

    let illegalDigits: DigitMask
    let completedDigits: DigitMask
    /// Полностью расставленные цифры не приглушаются, а исчезают.
    /// Слот остаётся на месте, иначе панель прыгает под пальцем.
    var hideCompleted = false
    let lockedDigit: Int?
    let layout: PreferencesRepository.KeypadLayout
    let palette: CellPalette
    let onTap: (Int) -> Void
    let onLongPress: (Int) -> Void

    private static let minimumTarget: Double = 44

    var body: some View {
        switch layout {
        case .singleRow:
            singleRow
        case .grid3x3:
            grid
        case .adaptive:
            // ViewThatFits сам выбирает один ряд, пока каждая цель ≥ 44 pt,
            // и переключается на 3×3 на узком экране или при крупных цифрах.
            ViewThatFits(in: .horizontal) {
                singleRow
                grid
            }
        }
    }

    private var singleRow: some View {
        HStack(spacing: 6) {
            ForEach(1...9, id: \.self) { digit in key(digit) }
        }
        .frame(maxWidth: .infinity)
    }

    private var grid: some View {
        VStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(1...3, id: \.self) { column in
                        key(row * 3 + column)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func key(_ digit: Int) -> some View {
        let isIllegal = Digits.contains(illegalDigits, digit)
        let isCompleted = Digits.contains(completedDigits, digit)
        let isHidden = isCompleted && hideCompleted
        let isLocked = lockedDigit == digit

        Button {
            onTap(digit)
        } label: {
            Text(String(digit))
                .font(.system(size: 26, weight: .regular))
                .monospacedDigit()
                .frame(minWidth: Self.minimumTarget, maxWidth: .infinity,
                       minHeight: Self.minimumTarget)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isLocked ? palette.selected : palette.surface.opacity(0.9))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isLocked ? palette.focusRing : palette.note.opacity(0.25),
                                      lineWidth: isLocked ? 2 : 0.8)
                )
                .foregroundStyle(palette.given)
                .opacity(isHidden ? 0 : (isCompleted ? 0.35 : (isIllegal ? 0.45 : 1)))
        }
        .buttonStyle(.plain)
        .disabled(isHidden)
        .animation(.easeOut(duration: 0.18), value: isHidden)
        // Долгое нажатие закрепляет цифру; та же функция есть видимой кнопкой.
        .onLongPressGesture(minimumDuration: 0.35) { onLongPress(digit) }
        .accessibilityHidden(isHidden)
        .accessibilityLabel(String(digit))
        .accessibilityHint(isLocked ? L.t("game.lockDigit") : "")
    }
}
