//
//  NamiApp.swift
//  NamiApp
//
//  Created by artemoffM8.
//
//  Точка входа и сборка зависимостей. Слои соединяются здесь, а не в View.
//

import SwiftUI
import SwiftData
import NamiDomain
import NamiData
import NamiExperience

@main
struct NamiApp: App {

    @State private var dependencies: Dependencies

    init() {
        _dependencies = State(initialValue: Dependencies.bootstrap())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                // Смена языка перестраивает дерево: строки берутся из словаря
                // в момент отрисовки, поэтому иначе экран останется на старом.
                // Роутер и сессия живут в environment и переживают пересборку.
                .id(dependencies.preferences.language)
                .environment(dependencies.router)
                .environment(dependencies.theme)
                .environment(dependencies.preferences)
                .environment(dependencies.feedback)
                .environment(dependencies.music)
                .environment(dependencies.sound)
                .modelContainer(dependencies.container)
        }
    }
}

struct RootView: View {

    @Environment(AppRouter.self) private var router
    @Environment(ThemeProvider.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(FeedbackCoordinator.self) private var feedback
    @Environment(PreferencesRepository.self) private var preferences
    @Environment(AmbientMusicPlayer.self) private var music
    @Environment(BundledSoundPlayer.self) private var sound

    var body: some View {
        Group {
            switch router.screen {
            case .onboarding:
                OnboardingView()
            case .home:
                HomeView()
            case .game:
                if let session = router.session {
                    GameView().environment(session)
                } else {
                    HomeView()
                }
            case .result(let payload):
                ResultView(payload: payload)
            }
        }
        .background(theme.color(.appBackground).ignoresSafeArea())
        // Схема и акцент живут здесь, а не на уровне App: тело App не
        // перевычисляется при смене темы, из-за чего цвет менялся только
        // после переоткрытия экрана.
        .tint(theme.color(.accent))
        .preferredColorScheme(theme.current.preferredColorScheme)
        .modifier(FeedbackSync(apply: syncFeedbackSettings))
        .modifier(MusicSync(apply: syncMusic, stop: music.stop))
        .modifier(SoundKitSync(apply: syncSoundKit))
        // Возврат из фона обязан поднимать движок звука. Система его
        // останавливает молча, и без этого звуки пропадают до перезапуска
        // приложения — ровно то, что и происходило.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { sound.resumeIfNeeded() }
        }
    }

    /// Комплект меняется целиком: и звуки действий, и музыка. Половина набора
    /// от одной темы, половина от другой звучала бы как сбой.
    private func syncSoundKit() {
        let kit = SoundKit(rawValue: preferences.soundKitRaw) ?? .nami
        sound.use(kit: kit)
        music.use(kit: kit)
    }

    private func syncMusic() {
        if preferences.musicEnabled {
            music.start()
        } else {
            music.stop()
        }
    }

    private func syncFeedbackSettings() {
        var settings = FeedbackSettings()
        settings.intensity = EffectIntensity(rawValue: preferences.effectIntensityRaw) ?? .full
        settings.soundEnabled = preferences.soundEnabled
        settings.hapticsEnabled = preferences.hapticsEnabled
        settings.conflictSoundEnabled = preferences.conflictSoundEnabled
        settings.reduceMotion = reduceMotion || preferences.reduceMotionBoost
        settings.particlesEnabled = settings.intensity != .off && !settings.reduceMotion
        feedback.settings = settings
    }
}

// Наблюдение вынесено в отдельные модификаторы: шесть `onChange` подряд
// на одном `body` компилятор перестаёт разбирать за разумное время.

/// Пересобирает настройки обратной связи при изменении любой из их частей.
private struct FeedbackSync: ViewModifier {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(PreferencesRepository.self) private var preferences

    let apply: () -> Void

    func body(content: Content) -> some View {
        content
            .task { apply() }
            .onChange(of: reduceMotion) { _, _ in apply() }
            .onChange(of: preferences.effectIntensityRaw) { _, _ in apply() }
            .onChange(of: preferences.soundEnabled) { _, _ in apply() }
            .onChange(of: preferences.hapticsEnabled) { _, _ in apply() }
    }
}

/// Применяет выбранный звуковой комплект.
private struct SoundKitSync: ViewModifier {

    @Environment(PreferencesRepository.self) private var preferences

    let apply: () -> Void

    func body(content: Content) -> some View {
        content
            .task { apply() }
            .onChange(of: preferences.soundKitRaw) { _, _ in apply() }
    }
}

/// Включает и глушит фоновую музыку.
private struct MusicSync: ViewModifier {

    @Environment(\.scenePhase) private var scenePhase
    @Environment(PreferencesRepository.self) private var preferences

    let apply: () -> Void
    let stop: () -> Void

    func body(content: Content) -> some View {
        content
            .task { apply() }
            .onChange(of: preferences.musicEnabled) { _, _ in apply() }
            .onChange(of: scenePhase) { _, phase in
                // Уходя в фон, музыку глушим: она не должна играть поверх того,
                // что игрок включил, вернувшись к себе.
                if phase == .active { apply() } else { stop() }
            }
    }
}

@MainActor
struct Dependencies {

    let container: ModelContainer
    let router: AppRouter
    let theme: ThemeProvider
    let preferences: PreferencesRepository
    let feedback: FeedbackCoordinator
    /// Нужен наверху, чтобы переключать комплект: FeedbackCoordinator знает
    /// плеер как протокол и не должен решать, из какого набора звучать.
    let sound: BundledSoundPlayer
    let music: AmbientMusicPlayer

    static func bootstrap() -> Dependencies {
        let container = makeContainer()
        let context = container.mainContext

        let theme = ThemeProvider(appVersion: Bundle.main.appVersion)
        let preferences = PreferencesRepository()
        L.apply(preferences.language)
        let haptics = SystemHapticPlayer()
        let kit = SoundKit(rawValue: preferences.soundKitRaw) ?? .nami
        let sound = BundledSoundPlayer(kit: kit)
        haptics.prepare()
        sound.preload()

        let feedback = FeedbackCoordinator(sound: sound, haptics: haptics)
        let progress = ProgressRepository(context: context)
        let savedGames = SavedGameStore(context: context)
        let applier = RatingResultApplier(context: context, progress: progress)

        let puzzles: PuzzleRepository
        do {
            puzzles = try PuzzleRepository()
        } catch {
            // Каталог обязан быть в бандле; пустой каталог даёт понятную ошибку
            // на главном экране вместо падения.
            assertionFailure("Каталог не загрузился: \(error)")
            puzzles = PuzzleRepository(catalog: PuzzleCatalog(
                schemaVersion: 2, catalogVersion: "empty", raterVersion: "-",
                difficultyMappingVersion: "-", generatedAt: "-", puzzles: []
            ))
        }

        let router = AppRouter(
            puzzles: puzzles,
            progress: progress,
            savedGames: savedGames,
            applier: applier,
            preferences: preferences,
            feedback: feedback,
            theme: theme
        )

        return Dependencies(container: container, router: router, theme: theme,
                            preferences: preferences, feedback: feedback,
                            sound: sound, music: AmbientMusicPlayer(kit: kit))
    }

    private static func makeContainer() -> ModelContainer {
        let schema = Schema(PersistenceSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        if let container = try? ModelContainer(for: schema, configurations: configuration) {
            return container
        }
        // Повреждённое хранилище не должно ронять запуск: работаем в памяти.
        let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // swiftlint:disable:next force_try
        return try! ModelContainer(for: schema, configurations: fallback)
    }
}

extension Bundle {
    var appVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }
}
