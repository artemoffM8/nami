//
//  Players.swift
//  NamiExperience
//
//  Created by artemoffM8.
//
//  Исполнители команд feedback. Разделены протоколами, чтобы FeedbackCoordinator
//  тестировался детерминированно и не тянул за собой AVFoundation/CoreHaptics.
//
//  Звуки предзагружаются: загрузки файла в момент касания нет (раздел 7.1).
//  Отсутствующий asset НЕ роняет приложение — он просто не звучит.
//

import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreHaptics)
import CoreHaptics
#endif

// MARK: - Протоколы

@MainActor
public protocol SoundPlaying: AnyObject {
    func play(_ asset: SoundAsset)
    func preload()
    /// Смена комплекта на лету. Уже загруженные буферы не переиспользуются:
    /// половина звуков из одного набора и половина из другого звучали бы
    /// как сбой, а не как выбор.
    func use(kit: SoundKit)
    /// Поднять движок, если система его остановила.
    func resumeIfNeeded()
}

public extension SoundPlaying {
    func use(kit: SoundKit) {}
    func resumeIfNeeded() {}
}

@MainActor
public protocol HapticPlaying: AnyObject {
    func play(_ pattern: HapticPattern)
    func prepare()
}

/// Пустая реализация для тестов, превью и режима «звук выключен».
@MainActor
public final class SilentSoundPlayer: SoundPlaying {
    public private(set) var played: [SoundAsset] = []
    public init() {}
    public func play(_ asset: SoundAsset) { played.append(asset) }
    public func preload() {}
}

@MainActor
public final class SilentHapticPlayer: HapticPlaying {
    public private(set) var played: [HapticPattern] = []
    public init() {}
    public func play(_ pattern: HapticPattern) { played.append(pattern) }
    public func prepare() {}
}

/// Хранилище токенов NotificationCenter, снимающее подписку при разрушении.
final class ObserverTokens: @unchecked Sendable {
    private var tokens: [NSObjectProtocol] = []
    var isEmpty: Bool { tokens.isEmpty }
    func append(_ token: NSObjectProtocol) { tokens.append(token) }
    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
}

/// Учёт владельцев аудиосессии. Сессия у приложения одна, а плеера два, и
/// выключение музыки не должно её отбирать: `setActive(false)` под работающим
/// движком SFX оставил бы звуки действий без вывода, причём молча — движок
/// продолжил бы считать себя запущенным. Поэтому владение считается явно, а не
/// угадывается по коду ошибки `isBusy`.
///
/// Владельцы живут столько же, сколько приложение, поэтому хранить их слабо
/// незачем: набор идентификаторов не переживает своих объектов.
@MainActor
enum AudioSessionOwnership {

    private static var owners: Set<ObjectIdentifier> = []

    /// Категория `.ambient`: уважает беззвучный режим и не прерывает чужую музыку.
    static func activate(_ owner: AnyObject) {
        owners.insert(ObjectIdentifier(owner))
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }

    /// Отпускает долю владельца. Сессия гаснет только когда её не держит никто.
    static func release(_ owner: AnyObject) {
        owners.remove(ObjectIdentifier(owner))
        guard owners.isEmpty else { return }
        #if os(iOS)
        // `.notifyOthersOnDeactivation` — чужой плеер, приглушённый на время,
        // вернёт себе полную громкость сразу, а не на следующем треке.
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
        #endif
    }
}

// MARK: - Звук

/// Короткие заранее загруженные буферы через AVAudioEngine.
/// Категория `.ambient`: уважает беззвучный режим и не прерывает музыку игрока.
@Observable
@MainActor
public final class BundledSoundPlayer: SoundPlaying {

    /// Не `let`: после сброса медиасервисов движок нужно заменить новым
    /// экземпляром, переконфигурация старого звук не возвращает (см. `rebuild`).
    private var engine = AVAudioEngine()
    private var players: [SoundAsset: AVAudioPlayerNode] = [:]
    /// Несколько вариантов на событие. Один и тот же сэмпл, повторённый
    /// подряд, читается ухом как механика уже к десятому нажатию — вариации
    /// снимают это надёжнее, чем смена тембра.
    private var buffers: [SoundAsset: [AVAudioPCMBuffer]] = [:]
    private var lastVariant: [SoundAsset: Int] = [:]
    /// Буферы загружены и граф собран. НЕ означает, что движок жив: его
    /// останавливает система, и об этом нас не спрашивают.
    private var isPrepared = false
    /// Токены наблюдателей живут в отдельной коробке, а не свойством класса:
    /// `deinit` не изолирован на MainActor и изолированное свойство прочитать
    /// не может, а снимать подписку всё равно нужно.
    private let observers = ObserverTokens()
    /// Подписки, привязанные к конкретному экземпляру движка (`object: engine`).
    /// Живут в отдельной коробке: при пересборке движка старая коробка
    /// освобождается и снимает подписку сама, иначе наблюдатель остался бы
    /// висеть на выброшенном движке и никогда больше не сработал.
    private var engineObservers = ObserverTokens()
    private let bundle: Bundle
    public private(set) var kit: SoundKit = .nami
    /// Нормализация субъективной громкости. Значения из SOUND_DESIGN.md
    /// звукового пакета; конфликт держим ниже рекомендованного диапазона —
    /// по ТЗ ошибка должна быть почти неслышной (раздел 7.1).
    private let gains: [SoundAsset: Float] = [
        .cellSelected: 0.40, .digitPlaced: 0.80, .digitErased: 0.55,
        .noteToggled: 0.50, .groupCompleted: 0.75, .conflict: 0.06,
        .victory: 0.70, .uiConfirm: 0.45
    ]

    private static let allAssets: [SoundAsset] = [
        .cellSelected, .digitPlaced, .digitErased, .noteToggled,
        .groupCompleted, .conflict, .victory, .uiConfirm
    ]

    public init(bundle: Bundle = .main, kit: SoundKit = .nami) {
        self.bundle = bundle
        self.kit = kit
    }

    public func use(kit newKit: SoundKit) {
        guard newKit != kit else { return }
        kit = newKit
        // Полная пересборка графа. Держать два набора буферов ради экономии
        // 200 мс на редком переключении — плохой размен: это удвоило бы
        // память на весь остаток сессии.
        rebuild()
    }

    public func preload() {
        guard !isPrepared else { return }
        observeSystemEvents()
        configureSession()
        loadBuffers()
        guard !players.isEmpty else {
            #if DEBUG
            print("[sound] ни один файл не загрузился — приложение будет молчать")
            #endif
            return
        }
        startEngine()
    }

    /// Поднимает движок, если система его остановила.
    ///
    /// Это не перестраховка. `AVAudioEngine` останавливается сам при уходе в
    /// фон, при смене аудиомаршрута (наушники) и при сбросе медиасервисов, а
    /// уведомить приложение об этом никто не обязан. Пока состояние хранилось
    /// флагом `isRunning`, он оставался `true`, `play()` писал буферы в мёртвый
    /// движок — и звук пропадал до перезапуска приложения. Поэтому источник
    /// правды теперь `engine.isRunning`, а не наш флаг.
    public func resumeIfNeeded() {
        guard isPrepared, !engine.isRunning else { return }
        configureSession()
        startEngine()
        #if DEBUG
        print("[sound] движок был остановлен системой, поднят заново")
        #endif
    }

    private func observeSystemEvents() {
        guard observers.isEmpty else { return }
        observeEngine()

        #if os(iOS)
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.ended.rawValue else { return }
            MainActor.assumeIsolated { self?.resumeIfNeeded() }
        })

        // Сброс медиасервисов уничтожает ВСЕ объекты аудио: тут мало поднять
        // движок, нужно пересобрать граф с нуля.
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
        #endif
    }

    /// Подписка на уведомления самого движка. Вынесена отдельно, потому что
    /// адресована конкретному экземпляру и переезжает вместе с ним.
    private func observeEngine() {
        // Присваивание освобождает прежнюю коробку, а её `deinit` снимает
        // старую подписку: двух наблюдателей на одном событии не возникает.
        let box = ObserverTokens()
        // Смена аудиомаршрута перестраивает граф и останавливает движок.
        box.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeIfNeeded() }
        })
        engineObservers = box
    }

    /// Полная пересборка звукового графа.
    ///
    /// Движок именно заменяется новым экземпляром, а не перенастраивается:
    /// после `mediaServicesWereReset` все объекты аудио уничтожены на стороне
    /// системы, и оживить старый `AVAudioEngine` нельзя — приложение остаётся
    /// немым до перезапуска. Дальше повторяется ровно тот же путь, что и при
    /// первом `preload()`: сессия, `loadBuffers()` (attach + connect к
    /// `mainMixerNode` в формате файла), `startEngine()`.
    private func rebuild() {
        engine.stop()
        // Узлы отцеплять не нужно: они принадлежат выбрасываемому движку и
        // уходят вместе с ним. На сброшенном движке `detach` бессмыслен.
        players.removeAll()
        buffers.removeAll()
        lastVariant.removeAll()
        isPrepared = false
        engine = AVAudioEngine()
        observeEngine()
        configureSession()
        loadBuffers()
        guard !players.isEmpty else { return }
        startEngine()
    }

    private func loadBuffers() {
        for asset in Self.allAssets {
            // Варианты лежат как name.wav, name2.wav, name3.wav… Список
            // обрывается на первом отсутствующем — добавить вариант можно
            // одним файлом, без правки кода.
            var loaded: [AVAudioPCMBuffer] = []
            var format: AVAudioFormat?
            for variant in 1...kit.maximumVariants {
                let name = kit.resourceName(for: asset, variant: variant)
                guard let url = bundle.url(forResource: name, withExtension: "caf")
                        ?? bundle.url(forResource: name, withExtension: "wav"),
                      let file = try? AVAudioFile(forReading: url),
                      let buffer = AVAudioPCMBuffer(
                        pcmFormat: file.processingFormat,
                        frameCapacity: AVAudioFrameCount(file.length)),
                      (try? file.read(into: buffer)) != nil
                else { break }
                format = file.processingFormat
                loaded.append(buffer)
            }
            guard let format, !loaded.isEmpty else { continue }   // нет файла — молчим

            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            node.volume = gains[asset] ?? 0.8
            players[asset] = node
            buffers[asset] = loaded
        }
    }

    private func startEngine() {
        engine.prepare()
        let started = (try? engine.start()) != nil
        isPrepared = true
        for node in players.values { node.play() }
        #if DEBUG
        // Отсутствие звука выглядит как «просто тихо», поэтому загрузку видно
        // в консоли: иначе пропавший из бандла файл нечем поймать.
        let loaded = players.keys.sorted { $0.rawValue < $1.rawValue }
            .map { "\($0.rawValue)×\(buffers[$0]?.count ?? 0)" }
            .joined(separator: ", ")
        print("[sound] комплект \(kit.rawValue), движок "
              + "\(started ? "запущен" : "НЕ запустился"), "
              + "загружено \(players.count)/\(Self.allAssets.count): \(loaded)")
        #endif
    }

    public func play(_ asset: SoundAsset) {
        guard isPrepared, let node = players[asset],
              let variants = buffers[asset], !variants.isEmpty else { return }
        // Последняя линия обороны: если движок успели остановить между
        // уведомлением и касанием, поднимаем его прямо здесь. Молчание
        // вместо звука игрок замечает, а лишние 2 мс — нет.
        if !engine.isRunning {
            resumeIfNeeded()
            guard engine.isRunning else { return }
        }
        // Подряд один и тот же вариант не берём: именно повтор, а не тембр,
        // делает звук «неживым».
        var index = Int.random(in: variants.indices)
        if variants.count > 1, index == lastVariant[asset] {
            index = (index + 1) % variants.count
        }
        lastVariant[asset] = index
        node.scheduleBuffer(variants[index], at: nil, options: .interrupts)
    }

    public func stop() {
        engine.stop()
        // Долю в сессии тоже отдаём: движок остановлен, держать её нечем.
        // `play()` и `resumeIfNeeded()` поднимут обе обратно.
        AudioSessionOwnership.release(self)
    }

    private func configureSession() {
        AudioSessionOwnership.activate(self)
    }
}

// MARK: - Фоновая музыка

/// Бесшовный ambient-луп. Отдельный движок, а не общий с SFX: музыку нужно
/// уметь останавливать и запускать независимо, не трогая звуки действий.
///
/// По ТЗ музыка выключена по умолчанию, всегда тише SFX и никогда не
/// перебивает то, что игрок уже слушает — за это отвечает категория `.ambient`,
/// установленная `BundledSoundPlayer`.
@Observable
@MainActor
public final class AmbientMusicPlayer {

    /// Один слой: свой узел, свой луп, своя медленно плывущая громкость.
    private struct Layer {
        let name: String
        let node: AVAudioPlayerNode
        /// Буфер держим при себе: остановка движка снимает всё запланированное,
        /// и при включении музыки луп ставится заново — читать файл повторно
        /// ради этого не нужно.
        let pcm: AVAudioPCMBuffer
        let base: Float
        let driftRange: ClosedRange<Float>
    }

    private let engine = AVAudioEngine()
    /// Одиночный луп исходного набора NAMI.
    private let singleNode = AVAudioPlayerNode()
    private var singleBuffer: AVAudioPCMBuffer?
    private var layers: [Layer] = []
    private let bundle: Bundle
    private var isPrepared = false
    private var preparedKit: SoundKit?
    private var driftTask: Task<Void, Never>?

    /// Базовые громкости слоёв. Бас и пэд держат основу, мелодия появляется
    /// эпизодически — иначе она тянет внимание на себя, а это фон.
    private static let layerBase: [String: Float] = [
        "pad": 0.85, "texture": 0.55, "bass": 0.60, "melody": 0.35
    ]
    private static let layerDrift: [String: ClosedRange<Float>] = [
        "pad": 0.60...1.00, "texture": 0.20...0.70,
        "bass": 0.35...0.75, "melody": 0.00...0.55
    ]

    /// Заметно тише любого SFX: музыка — фон, а не событие.
    public var volume: Float = 0.30 {
        didSet { applyVolume() }
    }

    public private(set) var kit: SoundKit = .nami

    public init(bundle: Bundle = .main, kit: SoundKit = .nami) {
        self.bundle = bundle
        self.kit = kit
    }

    public private(set) var isPlaying = false

    public func use(kit newKit: SoundKit) {
        guard newKit != kit else { return }
        let wasPlaying = isPlaying
        stop()
        kit = newKit
        teardown()
        if wasPlaying { start() }
    }

    public func start() {
        guard !isPlaying else { return }
        guard prepare() else { return }
        // Движок остановлен либо нами в `stop()`, либо системой, пока музыка
        // молчала: `prepare()` вернёт true по флагу, а звука не будет.
        if !engine.isRunning {
            configureSession()
            guard (try? engine.start()) != nil else { return }
        }
        // Луп планируется на каждый запуск: остановка движка снимает очередь
        // узла. Буферы уже в памяти, файл не читается.
        scheduleLoops()
        if layers.isEmpty { singleNode.play() } else {
            // Все слои стартуют одним вызовом: разъехавшийся на кадры старт
            // слышен как фазовое биение на низких частотах.
            for layer in layers { layer.node.play() }
            startDrift()
        }
        isPlaying = true
    }

    public func stop() {
        guard isPlaying else { return }
        driftTask?.cancel()
        driftTask = nil
        if layers.isEmpty { singleNode.stop() } else {
            for layer in layers { layer.node.stop() }
        }
        isPlaying = false
        // Раньше узлы просто ставились на паузу: движок продолжал крутить
        // рендер-поток, а аудиосессия оставалась активной до конца жизни
        // приложения — при выключенной музыке. Теперь останавливаем движок и
        // отдаём свою долю сессии (она погаснет, только если её не держит
        // SFX-плеер). Граф и буферы остаются в памяти, поэтому возврат через
        // `start()` — без чтения файлов; платим за это тем, что луп начинается
        // сначала, иначе за остановленным движком позицию не сохранить.
        engine.stop()
        AudioSessionOwnership.release(self)
    }

    /// Ставит лупы на узлы. Отдельно от `prepare()`, потому что нужен при
    /// каждом запуске, а граф собирается один раз.
    private func scheduleLoops() {
        if layers.isEmpty {
            // `.loops` крутит один и тот же буфер без стыка и без повторного
            // чтения файла.
            guard let singleBuffer else { return }
            singleNode.scheduleBuffer(singleBuffer, at: nil, options: .loops)
        } else {
            for layer in layers {
                layer.node.scheduleBuffer(layer.pcm, at: nil, options: .loops)
            }
        }
    }

    /// Категория сессии ставится и здесь. Раньше её выставлял только
    /// `BundledSoundPlayer`, и при выключенных звуках музыка оставалась
    /// с категорией по умолчанию — то есть глушила чужой плеер.
    private func configureSession() {
        AudioSessionOwnership.activate(self)
    }

    private func teardown() {
        engine.stop()
        // Смена комплекта при выключенной музыке не должна оставлять сессию
        // на нас: если музыку включат, `prepare()` возьмёт её заново.
        AudioSessionOwnership.release(self)
        for layer in layers { engine.detach(layer.node) }
        if preparedKit == .nami { engine.detach(singleNode) }
        layers.removeAll()
        singleBuffer = nil
        isPrepared = false
        preparedKit = nil
    }

    private func applyVolume() {
        if layers.isEmpty {
            singleNode.volume = volume
        } else {
            for layer in layers { layer.node.volume = volume * layer.base }
        }
    }

    /// Медленный дрейф громкостей. Файлы статичны, но их сумма всё время
    /// разная — именно это, а не длина лупа, мешает узнать повтор.
    private func startDrift() {
        driftTask?.cancel()
        driftTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(12))
                guard let self, self.isPlaying else { return }
                for layer in self.layers {
                    let target = Float.random(in: layer.driftRange)
                    // Мгновенный скачок громкости слышен как щелчок,
                    // поэтому переход растянут на четыре секунды.
                    await self.ramp(layer.node, to: self.volume * target, seconds: 4)
                    if Task.isCancelled { return }
                }
            }
        }
    }

    private func ramp(_ node: AVAudioPlayerNode, to target: Float, seconds: Double) async {
        let steps = 20
        let start = node.volume
        for step in 1...steps {
            guard !Task.isCancelled else { return }
            node.volume = start + (target - start) * Float(step) / Float(steps)
            try? await Task.sleep(for: .seconds(seconds / Double(steps)))
        }
    }

    private func prepare() -> Bool {
        if isPrepared, preparedKit == kit { return true }
        return kit.hasLayeredMusic ? prepareLayered() : prepareSingle()
    }

    private func buffer(named name: String) -> (AVAudioPCMBuffer, AVAudioFormat)? {
        guard let url = bundle.url(forResource: name, withExtension: "caf")
                ?? bundle.url(forResource: name, withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url),
              let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: pcm)) != nil
        else { return nil }
        return (pcm, file.processingFormat)
    }

    private func prepareLayered() -> Bool {
        configureSession()
        var built: [Layer] = []
        for name in SoundKit.musicLayers {
            guard let resource = kit.musicResourceName(layer: name),
                  let (pcm, format) = buffer(named: resource) else { continue }
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            let base = Self.layerBase[name] ?? 0.5
            node.volume = volume * base
            built.append(Layer(name: name, node: node, pcm: pcm, base: base,
                               driftRange: Self.layerDrift[name] ?? 0.3...0.8))
        }
        guard !built.isEmpty else {
            #if DEBUG
            print("[music] слои комплекта \(kit.rawValue) не загрузились")
            #endif
            // Сессию взяли, а звучать нечем: держать её за собой не за что.
            AudioSessionOwnership.release(self)
            return false
        }
        engine.prepare()
        guard (try? engine.start()) != nil else {
            for layer in built { engine.detach(layer.node) }
            AudioSessionOwnership.release(self)
            return false
        }
        layers = built
        isPrepared = true
        preparedKit = kit
        #if DEBUG
        print("[music] \(kit.rawValue): слоёв \(built.count) — "
              + built.map(\.name).joined(separator: ", "))
        #endif
        return true
    }

    private func prepareSingle() -> Bool {
        // Сессию берём и здесь, как в слоёном пути: раньше исходный комплект
        // запускал движок, ни разу её не настроив, и при выключенных SFX
        // категория оставалась дефолтной. Заодно это делает нас её явным
        // владельцем — иначе `stop()` отпускал бы то, чего не брал.
        configureSession()
        guard let (pcm, format) = buffer(named: "ambientLoop") else {
            #if DEBUG
            print("[music] трек не загрузился — музыки не будет")
            #endif
            AudioSessionOwnership.release(self)
            return false        // трека нет — тишина, а не падение
        }
        engine.attach(singleNode)
        engine.connect(singleNode, to: engine.mainMixerNode, format: format)
        singleNode.volume = volume
        engine.prepare()
        guard (try? engine.start()) != nil else {
            AudioSessionOwnership.release(self)
            return false
        }
        // Сам луп ставит `start()`: планировать здесь значило бы держать
        // очередь узла ещё до того, как музыку включили.
        singleBuffer = pcm
        isPrepared = true
        preparedKit = kit
        return true
    }
}

// MARK: - Haptics

/// Core Haptics при наличии поддержки, стандартные generators — как fallback.
@MainActor
public final class SystemHapticPlayer: HapticPlaying {

    #if canImport(UIKit)
    private let selection = UISelectionFeedbackGenerator()
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let notification = UINotificationFeedbackGenerator()
    #endif

    #if canImport(CoreHaptics)
    private var engine: CHHapticEngine?
    #endif

    public init() {}

    public func prepare() {
        #if canImport(UIKit)
        selection.prepare()
        light.prepare()
        rigid.prepare()
        notification.prepare()
        #endif
        #if canImport(CoreHaptics)
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        engine?.isAutoShutdownEnabled = true
        try? engine?.start()
        #endif
    }

    public func play(_ pattern: HapticPattern) {
        switch pattern {
        case .none:
            return
        case .selection:
            #if canImport(UIKit)
            selection.selectionChanged()
            #endif
        case .lightImpact:
            #if canImport(UIKit)
            light.impactOccurred(intensity: 0.6)
            #endif
        case .softRigid:
            #if canImport(UIKit)
            rigid.impactOccurred(intensity: 0.25)
            #endif
        case .groupTransient:
            if playTransient(intensity: 0.6, sharpness: 0.45) { return }
            #if canImport(UIKit)
            light.impactOccurred(intensity: 0.7)
            #endif
        case .success:
            #if canImport(UIKit)
            notification.notificationOccurred(.success)
            #endif
        }
    }

    private func playTransient(intensity: Float, sharpness: Float) -> Bool {
        #if canImport(CoreHaptics)
        guard let engine else { return false }
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: 0
        )
        guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
              let player = try? engine.makePlayer(with: pattern) else { return false }
        try? player.start(atTime: CHHapticTimeImmediate)
        return true
        #else
        return false
        #endif
    }
}
