//
//  PuzzleRepository.swift
//  NamiData
//
//  Created by artemoffM8.
//
//  Локальный offline-каталог. Пользователь не ждёт генерации: задачи
//  сгенерированы и проверены заранее в ContentTools (раздел 8.3).
//

import Foundation
import NamiDomain

public enum CatalogLoadError: Error, CustomStringConvertible {
    case resourceMissing(String)
    case decodingFailed(String)
    case schemaMismatch(found: Int, expected: Int)
    case integrityFailed(puzzleID: String)

    public var description: String {
        switch self {
        case .resourceMissing(let name): "Ресурс каталога `\(name)` не найден в бандле"
        case .decodingFailed(let reason): "Не удалось декодировать каталог: \(reason)"
        case .schemaMismatch(let found, let expected):
            "Несовместимая schemaVersion каталога: \(found), ожидается \(expected)"
        case .integrityFailed(let id): "Нарушена целостность записи `\(id)`"
        }
    }
}

@MainActor
public final class PuzzleRepository {

    public static let expectedSchemaVersion = 2
    public private(set) var catalog: PuzzleCatalog

    public init(catalog: PuzzleCatalog) {
        self.catalog = catalog
    }

    /// Загрузка встроенного каталога с проверкой схемы и целостности.
    public convenience init(bundle: Bundle = .main, resource: String = "classic") throws {
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            throw CatalogLoadError.resourceMissing("\(resource).json")
        }
        let data = try Data(contentsOf: url)
        let catalog: PuzzleCatalog
        do {
            catalog = try JSONDecoder().decode(PuzzleCatalog.self, from: data)
        } catch {
            throw CatalogLoadError.decodingFailed(String(describing: error))
        }
        guard catalog.schemaVersion == Self.expectedSchemaVersion else {
            throw CatalogLoadError.schemaMismatch(found: catalog.schemaVersion,
                                                  expected: Self.expectedSchemaVersion)
        }
        if let broken = catalog.puzzles.first(where: { !$0.integrityIsPlausible() }) {
            throw CatalogLoadError.integrityFailed(puzzleID: broken.id)
        }
        self.init(catalog: catalog)
    }

    public var catalogVersion: String { catalog.catalogVersion }

    public func puzzle(id: String) -> Puzzle? { catalog.puzzle(id: id) }

    public func puzzles(in tier: DifficultyTier) -> [Puzzle] { catalog.puzzles(in: tier) }

    /// Задача из тира, которую игрок ещё не проходил.
    ///
    /// Раньше здесь стояло `pool.first`, и это давало неприятный эффект:
    /// «Новая игра» посреди партии возвращала ТУ ЖЕ задачу, потому что она
    /// ещё не была завершена и оставалась первой по алфавиту.
    ///
    /// Теперь исключается текущая и недавно предложенные, а из оставшихся
    /// выбирается наименее похожая на текущую — иначе подряд идут задачи с
    /// почти одинаковым узором подсказок и партии сливаются в одну.
    public func nextPuzzle(
        in tier: DifficultyTier,
        excluding completedIDs: Set<String>,
        recentlyOffered: [String] = [],
        unlike current: Puzzle? = nil
    ) -> Puzzle? {
        let all = catalog.puzzles(in: tier).sorted { $0.id < $1.id }
        guard !all.isEmpty else { return nil }

        let blocked = Set(recentlyOffered).union(current.map { [$0.id] } ?? [])

        // Смягчаем условия по очереди: сначала свежие и непохожие, затем просто
        // непройденные, и лишь в самом конце — любые. Тупика быть не должно.
        let candidates = [
            all.filter { !completedIDs.contains($0.id) && !blocked.contains($0.id) },
            all.filter { !completedIDs.contains($0.id) },
            all.filter { !blocked.contains($0.id) },
            all
        ].first { !$0.isEmpty } ?? all

        guard let current else { return candidates.randomElement() }

        // Похожесть = доля совпадающих позиций подсказок. Узор заметнее
        // конкретных цифр: именно по нему доска «выглядит той же самой».
        let ranked = candidates
            .map { (puzzle: $0, similarity: Self.similarity($0, current)) }
            .sorted { $0.similarity < $1.similarity }
        // Берём случайную из наименее похожей трети, чтобы выбор не стал
        // предсказуемым и не выдавал одну и ту же «самую непохожую» задачу.
        let window = max(1, ranked.count / 3)
        return ranked.prefix(window).randomElement()?.puzzle
    }

    /// 0 — узоры подсказок не пересекаются, 1 — совпадают полностью.
    static func similarity(_ lhs: Puzzle, _ rhs: Puzzle) -> Double {
        let left = Array(lhs.puzzle), right = Array(rhs.puzzle)
        guard left.count == 81, right.count == 81 else { return 0 }
        var shared = 0, total = 0
        for index in 0..<81 {
            let hasLeft = left[index] != "0"
            let hasRight = right[index] != "0"
            if hasLeft || hasRight { total += 1 }
            if hasLeft && hasRight { shared += 1 }
        }
        return total == 0 ? 0 : Double(shared) / Double(total)
    }

    /// Рекомендуемая сложность: ближайший тир, чей медианный `D` не сильно
    /// выше текущего рейтинга. Скорость в расчёт не входит.
    /// Упражнение на технику: позиция вырезается из настоящей задачи каталога.
    ///
    /// Кандидаты берутся по размётке, но она — только фильтр: окончательное
    /// «техника здесь нужна» подтверждает трасса решателя. Размётка могла
    /// устареть после смены версии решателя, и доверять ей на слово нельзя.
    ///
    /// Порядок кандидатов задаётся `seed`, а не случаен: повторный вход в
    /// тот же дрилл обязан дать ту же позицию, иначе игрок теряет задачу,
    /// случайно выйдя с экрана.
    ///
    /// Метод асинхронный, потому что дорогая часть уезжает с главного актора.
    /// Отбор кандидатов дёшев и остаётся здесь, у каталога; перебор — нет:
    /// на каждого кандидата приходится полный прогон решателя, и для редкой
    /// техники их до сотен. Синхронно на главном акторе это означало
    /// замерший на секунды экран.
    public func drill(
        technique: SudokuTechnique,
        seed: Int,
        excluding solvedIDs: Set<String> = []
    ) async -> DojoDrill? {
        let key = technique.catalogKey
        let tagged = catalog.puzzles
            .filter { $0.techniques.contains(key) }
            .sorted { $0.id < $1.id }
        guard !tagged.isEmpty else { return nil }

        // Сначала незакрытые, потом всё остальное: материал не должен
        // кончаться — повторить пройденное лучше, чем упереться в пустоту.
        let fresh = tagged.filter { !solvedIDs.contains($0.id) }
        let pool = fresh.isEmpty ? tagged : fresh
        let start = abs(seed) % pool.count

        // За границу актора уходят только значения: `[Puzzle]` и
        // `SudokuTechnique` — Sendable-структуры, `DojoDrillBuilder` состояния
        // не хранит и работает с копиями строк. Ни репозиторий, ни каталог
        // фону не передаются, общей изменяемой памяти не остаётся.
        let search = Task.detached(priority: .utility) {
            Self.firstDrill(technique: technique, pool: pool, start: start)
        }
        // Отмена обязана доходить до перебора: отсоединённая задача её сама
        // не наследует, и брошенный поиск иначе догрёб бы пул до конца.
        return await withTaskCancellationHandler {
            await search.value
        } onCancel: {
            search.cancel()
        }
    }

    /// Первый кандидат, из которого удалось вырезать позицию. Вне актора:
    /// метод не трогает состояние репозитория и получает всё аргументами.
    nonisolated static func firstDrill(
        technique: SudokuTechnique, pool: [Puzzle], start: Int
    ) -> DojoDrill? {
        for offset in 0..<pool.count {
            // Экран мог уйти: считать дальше ради выброшенного результата
            // незачем — проверка стоит один шаг перебора.
            if Task.isCancelled { return nil }
            let puzzle = pool[(start + offset) % pool.count]
            if let drill = DojoDrillBuilder.drill(
                technique: technique, puzzleID: puzzle.id,
                givens: puzzle.puzzle, solution: puzzle.solution) {
                return drill
            }
        }
        return nil
    }

    /// Сколько задач каталога вообще могут дать упражнение на технику.
    /// Нужно, чтобы не показывать ступень, для которой нет материала.
    public func drillMaterialCount(for technique: SudokuTechnique) -> Int {
        let key = technique.catalogKey
        return catalog.puzzles.filter { $0.techniques.contains(key) }.count
    }

    public func recommendedTier(forRating rating: Int) -> DifficultyTier {
        var best = DifficultyTier.easy
        var bestDistance = Int.max
        for tier in DifficultyTier.allCases {
            let values = catalog.puzzles(in: tier).map(\.difficultyD).sorted()
            guard !values.isEmpty else { continue }
            let median = values[values.count / 2]
            // Целимся чуть выше текущего рейтинга: рост даёт задача сложнее.
            let distance = abs(median - (rating + 40))
            if distance < bestDistance {
                bestDistance = distance
                best = tier
            }
        }
        return best
    }

    public func dailyPuzzle(for date: Date) -> Puzzle? {
        guard let id = DailySchedule.puzzleID(for: date, in: catalog) else { return nil }
        return catalog.puzzle(id: id)
    }
}
