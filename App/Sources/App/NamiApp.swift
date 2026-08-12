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

    @State private var launch: Launch

    init() {
        _launch = State(initialValue: Dependencies.bootstrap())
    }

    var body: some Scene {
        WindowGroup {
            switch launch {
            case .ready(let dependencies):
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
            case .storageUnavailable(let reason):
                StorageUnavailableView(reason: reason)
            }
        }
    }
}

/// Что получилось на запуске. Отдельное состояние нужно ровно для одного
/// случая: хранилище не открылось совсем. Раньше здесь стоял `try!`, и
/// единственным исходом было падение.
@MainActor
enum Launch {
    case ready(Dependencies)
    case storageUnavailable(reason: String)
}

/// Хранилище не открылось ни на диске, ни в памяти. Честный экран лучше
/// падения и намного лучше «нового» приложения без единой записи: игрок
/// должен знать, что его данные на месте, а не удалены.
struct StorageUnavailableView: View {

    let reason: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 40, weight: .light))
            Text("Хранилище недоступно")
                .font(.title3)
            Text("Данные на устройстве не удалены. Перезапустите приложение; если это не поможет — обновите его до последней версии.")
                .font(.callout)
                .multilineTextAlignment(.center)
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        // Предупреждение живёт здесь, а не на главном экране: сбой хранилища
        // отправляет игрока на онбординг (база пуста), и на главный экран он
        // может не попасть вовсе — а узнать о потере записи обязан.
        .modifier(StartupWarningAlert())
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

/// Показывает предупреждение запуска на любом экране.
private struct StartupWarningAlert: ViewModifier {

    @Environment(AppRouter.self) private var router

    func body(content: Content) -> some View {
        content.alert(
            router.startupWarning ?? "",
            isPresented: Binding(
                get: { router.startupWarning != nil },
                set: { if !$0 { router.dismissWarning() } }
            )
        ) {
            Button(L.t("common.close")) { router.dismissWarning() }
        }
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

    static func bootstrap() -> Launch {
        let container: ModelContainer
        let storageFailure: String?
        switch makeStorage() {
        case .onDisk(let opened):
            container = opened
            storageFailure = nil
        case .inMemory(let opened, let reason):
            container = opened
            storageFailure = reason
        case .unavailable(let reason):
            return .storageUnavailable(reason: reason)
        }
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

        // Работа в памяти обязана быть заметной. Без этого сообщения запуск
        // после неудачной миграции выглядел как новое приложение: рейтинг,
        // ранг, рекорды и Daily исчезали молча, а сыгранное за сессию
        // терялось при выходе.
        if let storageFailure {
            router.reportStartupIssue(
                "Хранилище не открылось, прогресс этой сессии не сохранится. "
                + "Данные на устройстве не удалены. \(storageFailure)"
            )
        }

        return .ready(Dependencies(container: container, router: router, theme: theme,
                                   preferences: preferences, feedback: feedback,
                                   sound: sound, music: AmbientMusicPlayer(kit: kit)))
    }

    /// Чем закончилось открытие хранилища.
    private enum Storage {
        case onDisk(ModelContainer)
        /// Диск не открылся, но приложение работает — без сохранения.
        case inMemory(ModelContainer, reason: String)
        case unavailable(reason: String)
    }

    private static func makeStorage() -> Storage {
        let schema = Schema(PersistenceSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return .onDisk(try ModelContainer(for: schema, configurations: configuration))
        } catch {
            // Файл на диске НЕ удаляем и не пересоздаём. Несовместимая схема
            // или временный сбой — не повод уничтожать единственную копию
            // прогресса: она остаётся на месте и после обновления читается.
            // Причину обрезаем: ошибки SwiftData бывают на десятки строк,
            // а в предупреждении нужна опознаваемая, а не полная.
            let reason = String("\(error)".prefix(180))
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            do {
                return .inMemory(try ModelContainer(for: schema, configurations: fallback),
                                 reason: reason)
            } catch {
                return .unavailable(reason: reason)
            }
        }
    }
}

extension Bundle {
    var appVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }
}
