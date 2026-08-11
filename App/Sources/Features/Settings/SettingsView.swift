//
//  SettingsView.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Раздел 5.7. Первый уровень содержит ТОЛЬКО профиль помощи, тему,
//  интенсивность эффектов, звук, таймер, крупные цифры и язык.
//  Тонкие параметры живут за кнопкой «Настроить».
//

import SwiftUI
import NamiDomain
import NamiData
import NamiExperience

struct SettingsView: View {

    @Environment(AppRouter.self) private var router
    @Environment(ThemeProvider.self) private var theme
    @Environment(PreferencesRepository.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    @State private var profile: AssistanceProfile = .focus
    @State private var policy: SessionPolicy = AssistanceProfile.focus.preset
    @State private var showHowToPlay = false

    var body: some View {
        NavigationStack {
            Form {
                Section(L.t("settings.assistance")) {
                    Picker(L.t("settings.assistance"), selection: $profile) {
                        ForEach(AssistanceProfile.allCases, id: \.self) { item in
                            Text(L.t(item.titleKey)).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(L.t(profile.summaryKey))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !policy.matchesPreset(of: profile) {
                        Text(L.t("assistance.customized", L.t(profile.titleKey)))
                            .font(.caption2)
                            .foregroundStyle(theme.color(.accent))
                    }

                    NavigationLink(L.t("assistance.customize")) {
                        AssistanceTuningView(policy: $policy)
                    }
                }

                Section {
                    Picker(L.t("settings.theme"), selection: themeBinding) {
                        ForEach(BuiltInThemes.all, id: \.id) { item in
                            Text(L.t(item.nameKey)).tag(item.id)
                        }
                    }
                    Picker(L.t("settings.effects"), selection: effectsBinding) {
                        ForEach(EffectIntensity.allCases, id: \.self) { item in
                            Text(L.t(item.titleKey)).tag(item.rawValue)
                        }
                    }
                    Toggle(L.t("settings.sound"), isOn: soundBinding)
                    Toggle(L.t("settings.music"), isOn: musicBinding)
                    // Комплект выбирается один на звуки и музыку: они написаны
                    // в одной тональности, и смешивать их незачем.
                    Picker(L.t("settings.soundKit"), selection: soundKitBinding) {
                        ForEach(SoundKit.allCases) { item in
                            Text(L.t(item.titleKey)).tag(item.rawValue)
                        }
                    }
                    .disabled(!preferences.soundEnabled && !preferences.musicEnabled)
                    Toggle(L.t("settings.haptics"), isOn: hapticsBinding)
                    Toggle(L.t("settings.timer"), isOn: timerBinding)
                    Toggle(L.t("settings.largeDigits"), isOn: largeDigitsBinding)
                    Picker(L.t("settings.keypad"), selection: keypadBinding) {
                        ForEach(PreferencesRepository.KeypadLayout.allCases, id: \.self) { item in
                            Text(L.t(item.titleKey)).tag(item)
                        }
                    }
                }

                Section(L.t("settings.accessibility")) {
                    Toggle(L.t("settings.reduceMotion"), isOn: reduceMotionBinding)
                    Toggle(L.t("settings.tapToClear"), isOn: tapToClearBinding)
                    Toggle(L.t("settings.interfaceTips"), isOn: tipsBinding)
                        .disabled(router.progress.coachCardsComplete)
                    Toggle(L.t("settings.struggleNudges"), isOn: struggleBinding)
                    Button(L.t("home.howToPlay")) { showHowToPlay = true }
                }

                Section(L.t("settings.app")) {
                    Picker(L.t("settings.language"), selection: languageBinding) {
                        ForEach(PreferencesRepository.AppLanguage.allCases, id: \.self) { item in
                            Text(L.t(item.titleKey)).tag(item)
                        }
                    }
                    Text(L.t("settings.versions",
                             router.puzzles.catalogVersion,
                             HumanSolver.raterVersion,
                             RatingEngine.algorithmVersion))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            // Модификатор нужен именно на Form: системный сгруппированный фон
            // рисуется самим списком и снаружи его не перекрыть.
            .themedSurface()
            .navigationTitle(L.t("settings.title"))
            .sheet(isPresented: $showHowToPlay) { HowToPlayView().themedSurface() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.t("common.done")) {
                        router.progress.store(assistanceProfile: profile,
                                              policy: policy.matchesPreset(of: profile) ? nil : policy)
                        dismiss()
                    }
                }
            }
            .onAppear {
                profile = router.progress.assistanceProfile()
                policy = router.progress.sessionPolicy()
            }
            .onChange(of: profile) { _, newValue in
                policy = newValue.preset
            }
        }
    }

    // MARK: - Bindings через PreferencesRepository (feature views не читают ключи сами)

    private var themeBinding: Binding<String> {
        Binding(get: { preferences.themeID },
                set: {
                    // Явный выбор закрепляется за текущим режимом, иначе
                    // следующий старт партии вернул бы предложение режима.
                    preferences.setThemeID($0, for: preferences.gameMode)
                    theme.apply(id: $0)
                })
    }
    private var effectsBinding: Binding<String> {
        Binding(get: { preferences.effectIntensityRaw },
                set: { preferences.effectIntensityRaw = $0 })
    }
    private var soundBinding: Binding<Bool> {
        Binding(get: { preferences.soundEnabled }, set: { preferences.soundEnabled = $0 })
    }
    private var soundKitBinding: Binding<String> {
        Binding(get: { preferences.soundKitRaw }, set: { preferences.soundKitRaw = $0 })
    }
    private var musicBinding: Binding<Bool> {
        Binding(get: { preferences.musicEnabled }, set: { preferences.musicEnabled = $0 })
    }
    private var hapticsBinding: Binding<Bool> {
        Binding(get: { preferences.hapticsEnabled }, set: { preferences.hapticsEnabled = $0 })
    }
    private var timerBinding: Binding<Bool> {
        Binding(get: { preferences.showTimer }, set: { preferences.showTimer = $0 })
    }
    private var largeDigitsBinding: Binding<Bool> {
        Binding(get: { preferences.largeDigits }, set: { preferences.largeDigits = $0 })
    }
    /// Словарь переключается до записи настройки, чтобы пересобранное
    /// по `.id` дерево уже читало строки нового языка.
    private var languageBinding: Binding<PreferencesRepository.AppLanguage> {
        Binding(get: { preferences.language },
                set: { L.apply($0); preferences.language = $0 })
    }
    private var keypadBinding: Binding<PreferencesRepository.KeypadLayout> {
        Binding(get: { preferences.keypadLayout }, set: { preferences.keypadLayout = $0 })
    }
    private var reduceMotionBinding: Binding<Bool> {
        Binding(get: { preferences.reduceMotionBoost }, set: { preferences.reduceMotionBoost = $0 })
    }
    private var tipsBinding: Binding<Bool> {
        Binding(get: { preferences.showInterfaceTips }, set: { preferences.showInterfaceTips = $0 })
    }
    private var struggleBinding: Binding<Bool> {
        Binding(get: { preferences.struggleNudges }, set: { preferences.struggleNudges = $0 })
    }
    private var tapToClearBinding: Binding<Bool> {
        Binding(get: { preferences.tapToClear }, set: { preferences.tapToClear = $0 })
    }
}

/// Тонкая настройка помощи. Каждый параметр имеет явную категорию
/// `neutral / candidateAid / hintAid / validationAid` (критерий приёмки 28).
struct AssistanceTuningView: View {

    @Binding var policy: SessionPolicy

    var body: some View {
        Form {
            Section {
                Picker(L.t("settings.validation"), selection: $policy.validation) {
                    Text(L.t("settings.validation.manualOnly")).tag(SessionPolicy.Validation.manualOnly)
                    Text(L.t("settings.validation.ruleConflictsOnly")).tag(SessionPolicy.Validation.ruleConflictsOnly)
                    Text(L.t("settings.validation.againstSolution")).tag(SessionPolicy.Validation.againstSolution)
                }
                Text(category(for: policy.validation)).font(.caption2).foregroundStyle(.secondary)
            }

            Section {
                Picker(L.t("settings.keypadHints"), selection: $policy.keypadHints) {
                    Text(L.t("settings.keypadHints.off")).tag(SessionPolicy.KeypadHints.off)
                    Text(L.t("settings.keypadHints.dimIllegal")).tag(SessionPolicy.KeypadHints.dimIllegal)
                }
                Picker(L.t("settings.fieldCandidates"), selection: $policy.fieldCandidates) {
                    Text(L.t("settings.fieldCandidates.off")).tag(SessionPolicy.FieldCandidates.off)
                    Text(L.t("settings.fieldCandidates.lensOnDemand")).tag(SessionPolicy.FieldCandidates.lensOnDemand)
                    Text(L.t("settings.fieldCandidates.selectedCellPersistent")).tag(SessionPolicy.FieldCandidates.selectedCellPersistent)
                    Text(L.t("settings.fieldCandidates.wholeBoard")).tag(SessionPolicy.FieldCandidates.wholeBoard)
                }
                Text("candidateAid").font(.caption2).foregroundStyle(.secondary)
            }

            Section {
                Toggle(L.t("settings.autoReduceNotes"), isOn: $policy.autoReduceNotes)
                Toggle(L.t("settings.impossibleNote"), isOn: $policy.impossibleNoteWarning)
                Toggle(L.t("settings.singleCandidate"), isOn: $policy.singleCandidateHighlight)
                Toggle(L.t("settings.dimCompleted"), isOn: $policy.dimCompletedDigits)
                Toggle(L.t("settings.sameDigit"), isOn: $policy.highlightSameDigit)
            }
        }
        .themedSurface()
        .navigationTitle(L.t("settings.helpTuning"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func category(for validation: SessionPolicy.Validation) -> String {
        switch validation {
        case .manualOnly: "neutral (до нажатия «Проверить»)"
        case .ruleConflictsOnly: "neutral"
        case .againstSolution: "validationAid 0.06"
        }
    }
}
