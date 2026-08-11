//
//  GameTiming.swift
//  NamiDomain
//
//  Created by artemoffM8.
//
//  Раздел 13.8. Источник истины — монотонные часы, а не UI-таймер и не Timer tick.
//  Единое событие `gameSuspended` объединяет Pause, уход с экрана и
//  scenePhase .inactive/.background.
//

import Foundation

public struct TimingSnapshot: Codable, Equatable, Sendable {
    /// Момент первого показа сетки (для Daily — нажатия «Начать»).
    public var timingStartedAt: Date?
    /// Накопленное активное время без интервалов приостановки.
    public var activeSecondsAtSave: Double = 0
    /// Соревновательное время Daily: включает интервалы приостановки.
    public var challengeElapsedAtSave: Double = 0
    public var suspendedAt: Date?
    /// Любое `gameSuspended` после старта необратимо снимает право на бонус темпа.
    public var speedEligible = true
    public var leaderboardEligible = true
    public var clockAnomalyDetected = false

    public init() {}

    public var hasStarted: Bool { timingStartedAt != nil }
    public var isSuspended: Bool { suspendedAt != nil }
}

/// Монотонные часы, подменяемые в тестах.
public protocol MonotonicClock: Sendable {
    /// Секунды от произвольной точки отсчёта; не зависит от системного времени.
    var now: Double { get }
    var wallClock: Date { get }
}

public struct SystemMonotonicClock: MonotonicClock {

    /// Точка отсчёта монотонной шкалы — первое обращение к часам в процессе.
    ///
    /// `ContinuousClock` на Darwin читает `CLOCK_MONOTONIC_RAW`
    /// (`mach_continuous_time`), а не календарь: перевод системного времени
    /// и коррекция NTP на него не влияют, и он продолжает идти, пока
    /// устройство спит. Второе не менее важно, чем первое: активное время
    /// партии не должно зависеть от того, гас ли экран.
    ///
    /// Абсолютное значение `now` смысла не имеет и никогда не попадает на
    /// диск — все потребители считают только разности (`GameTimer`,
    /// `StruggleDetector`, channel budget в `FeedbackCoordinator`).
    /// На диск уходит `wallClock`, он и остаётся календарным.
    private static let origin = ContinuousClock.now

    public init() {}

    public var now: Double {
        let elapsed = Self.origin.duration(to: ContinuousClock.now).components
        return Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
    }

    public var wallClock: Date { Date() }
}

/// Управляет активным и соревновательным временем партии.
public struct GameTimer: Sendable {
    public private(set) var snapshot: TimingSnapshot
    private var runningSince: Double?
    private var suspendedSince: Double?
    private let clock: any MonotonicClock

    public init(snapshot: TimingSnapshot = TimingSnapshot(), clock: any MonotonicClock = SystemMonotonicClock()) {
        self.snapshot = snapshot
        self.clock = clock
    }

    /// Атомарно устанавливается при первом показе сетки.
    public mutating func start() {
        guard snapshot.timingStartedAt == nil else { return }
        snapshot.timingStartedAt = clock.wallClock
        runningSince = clock.now
    }

    public mutating func resume() {
        guard snapshot.hasStarted, runningSince == nil else { return }
        if let suspendedSince {
            snapshot.challengeElapsedAtSave += clock.now - suspendedSince
            self.suspendedSince = nil
        }
        snapshot.suspendedAt = nil
        runningSince = clock.now
    }

    /// Pause, Back/Home и переход сцены в inactive/background — одно событие.
    public mutating func suspend() {
        guard snapshot.hasStarted else { return }
        if let runningSince {
            let delta = clock.now - runningSince
            snapshot.activeSecondsAtSave += delta
            snapshot.challengeElapsedAtSave += delta
            self.runningSince = nil
        }
        guard suspendedSince == nil else { return }
        suspendedSince = clock.now
        snapshot.suspendedAt = clock.wallClock
        // Необратимо: сопоставимый personal best и бонус испытания больше недоступны.
        snapshot.speedEligible = false
    }

    /// Активное время без пауз — база для бонуса темпа и аналитики.
    public var activeSeconds: Double {
        var total = snapshot.activeSecondsAtSave
        if let runningSince { total += clock.now - runningSince }
        return total
    }

    /// Daily elapsed: паузы и уход в фон НЕ ускоряют результат.
    public var challengeElapsedSeconds: Double {
        var total = snapshot.challengeElapsedAtSave
        if let runningSince { total += clock.now - runningSince }
        else if let suspendedSince { total += clock.now - suspendedSince }
        return total
    }

    /// Перезапуск задачи. Время считается заново, потому что доска пустая:
    /// показывать накопленное с брошенной попытки — врать игроку.
    /// Право на бонус темпа и рекорд НЕ возвращается: попытка уже не первая.
    public mutating func restartAttempt() {
        snapshot.activeSecondsAtSave = 0
        snapshot.challengeElapsedAtSave = 0
        snapshot.suspendedAt = nil
        snapshot.speedEligible = false
        snapshot.leaderboardEligible = false
        suspendedSince = nil
        runningSince = clock.now
    }

    /// Восстановление после перезапуска процесса. Единственная точка вызова —
    /// `GameSessionStore.init`, и вызывается она РОВНО ОДИН РАЗ, до первого
    /// `resume()`. Порядок здесь не стилистика:
    ///
    ///  • интервал, пока приложения не было, засчитывается в соревновательное
    ///    время Daily по календарным часам (монотонной шкалы того процесса
    ///    больше нет), а дальше время снова считает монотонная — поэтому
    ///    `suspendedSince` переставляется на «сейчас» и следующий `resume()`
    ///    добавит только то, что прошло уже в этом процессе;
    ///  • на уже идущем таймере (`runningSince != nil`) вызов потерял бы
    ///    накопленный отрезок активного времени, поэтому вход и один.
    ///
    /// Откат системных часов не даёт завершить Daily в leaderboard
    /// (`DailyScore.isLeaderboardEligible`), но не мешает закончить партию.
    ///
    /// Для свежей партии вызов — no-op: `timingStartedAt` ещё nil, и право
    /// на бонус темпа она не теряет.
    public mutating func restore(wallClockNow: Date) {
        guard let startedAt = snapshot.timingStartedAt else { return }
        if wallClockNow < startedAt {
            snapshot.clockAnomalyDetected = true
            snapshot.leaderboardEligible = false
        }
        if let suspendedAt = snapshot.suspendedAt {
            if wallClockNow < suspendedAt {
                snapshot.clockAnomalyDetected = true
                snapshot.leaderboardEligible = false
            } else {
                snapshot.challengeElapsedAtSave += wallClockNow.timeIntervalSince(suspendedAt)
            }
            snapshot.suspendedAt = wallClockNow
            suspendedSince = clock.now
        }
        runningSince = nil
        snapshot.speedEligible = false
    }
}
