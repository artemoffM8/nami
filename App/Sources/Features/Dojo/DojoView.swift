//
//  DojoView.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Путь техник: список ступеней, урок и упражнение.
//
//  Ступени открываются последовательно. Это не геймификация ради удержания:
//  X-Wing невозможно объяснить тому, кто не видит скрытую единицу, и показать
//  его раньше — значит гарантировать провал, который игрок припишет себе.
//

import SwiftUI
import NamiDomain
import NamiData
import NamiExperience

struct DojoView: View {

    @Environment(AppRouter.self) private var router
    @Environment(ThemeProvider.self) private var theme
    @Environment(PreferencesRepository.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    @State private var openLesson: DojoLesson?

    private var personality: EffectPersonality {
        EffectPersonality(themeID: theme.current.id)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(DojoCurriculum.lessons.enumerated()), id: \.element.id) {
                        index, lesson in
                        row(lesson, index: index)
                    }
                } header: {
                    Text(L.t("dojo.path"))
                } footer: {
                    Text(L.t("dojo.path.hint"))
                }
            }
            .themedSurface()
            .navigationTitle(L.t("dojo.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("common.close")) { dismiss() }
                }
            }
            .sheet(item: $openLesson) { lesson in
                DojoLessonSheet(lesson: lesson)
            }
        }
    }

    @ViewBuilder
    private func row(_ lesson: DojoLesson, index: Int) -> some View {
        let done = preferences.dojoDrills(for: lesson.technique)
        let unlocked = isUnlocked(index)
        let mastered = done >= lesson.drillsToUnlock

        Button {
            openLesson = lesson
        } label: {
            HStack(spacing: 12) {
                if mastered {
                    GardenGlyph(personality: personality,
                                tint: theme.color(.accent),
                                secondary: theme.color(.secondaryText), size: 22)
                } else {
                    Image(systemName: unlocked ? "circle" : "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.t(lesson.titleKey))
                        .foregroundStyle(unlocked ? .primary : .secondary)
                    Text(unlocked
                         ? L.t("dojo.drills", done, lesson.drillsToUnlock)
                         : L.t("dojo.locked"))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if unlocked {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .disabled(!unlocked)
        .buttonStyle(.plain)
    }

    /// Первая ступень открыта всегда; дальше — после нужного числа дриллов
    /// на предыдущей.
    private func isUnlocked(_ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = DojoCurriculum.lessons[index - 1]
        return preferences.dojoDrills(for: previous.technique) >= previous.drillsToUnlock
    }
}

// MARK: - Урок

struct DojoLessonSheet: View {

    let lesson: DojoLesson

    @Environment(AppRouter.self) private var router
    @Environment(ThemeProvider.self) private var theme
    @Environment(PreferencesRepository.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    @State private var drill: DojoDrill?
    @State private var noMaterial = false
    /// Идущий поиск. Хранится, чтобы его можно было отменить и чтобы второй
    /// поиск не встал в очередь за первым.
    @State private var search: Task<Void, Never>?
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L.t(lesson.explanationKey))
                } header: {
                    Text(L.t("dojo.whatItIs"))
                }

                Section {
                    ForEach(Array(lesson.searchKeys.enumerated()), id: \.offset) {
                        offset, key in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(offset + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 14, alignment: .trailing)
                            Text(L.t(key))
                        }
                    }
                } header: {
                    Text(L.t("dojo.howToLook"))
                }

                Section {
                    HStack {
                        Button(L.t("dojo.startDrill")) { start() }
                            // Второй запуск во время поиска не ускорил бы
                            // ответ, а удвоил бы работу.
                            .disabled(isSearching)
                        Spacer()
                        if isSearching {
                            // Поиск идёт в фоне: без явного признака экран
                            // выглядел бы так, будто кнопка не сработала.
                            ProgressView()
                        }
                    }
                    if noMaterial {
                        // Честнее сказать прямо, чем показать пустой экран:
                        // размётка каталога и трасса решателя могли разойтись.
                        Text(L.t("dojo.noMaterial"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .themedSurface()
            .navigationTitle(L.t(lesson.titleKey))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.t("common.close")) { dismiss() }
                }
            }
            .fullScreenCover(item: $drill) { item in
                DojoDrillView(drill: item, lesson: lesson)
            }
        }
        .onDisappear {
            // Экран закрыт — незаконченный поиск больше ни к чему
            // не относится и не должен занимать процессор.
            search?.cancel()
            search = nil
            isSearching = false
        }
    }

    /// Поиск позиции — полный прогон решателя на каждом кандидате, и он
    /// уехал с главного актора. Раньше экран замирал до самого результата.
    private func start() {
        search?.cancel()
        noMaterial = false
        isSearching = true
        let technique = lesson.technique
        let seed = preferences.dojoRevision
        search = Task { @MainActor in
            let found = await router.puzzles.drill(technique: technique, seed: seed)
            // Отменённый поиск не трогает экран: пока он считал, игрок мог
            // уйти или запросить другой.
            guard !Task.isCancelled else { return }
            search = nil
            isSearching = false
            drill = found
            noMaterial = found == nil
        }
    }
}
