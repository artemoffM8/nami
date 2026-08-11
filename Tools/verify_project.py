#!/usr/bin/env python3
"""
Проверка целостности сгенерированного проекта БЕЗ Xcode.

Что проверяется:
  1. project.pbxproj действительно парсится как OpenStep plist;
  2. все ссылки на объекты разрешаются (нет висящих ID);
  3. каждый .swift из App/Sources попал в PBXSourcesBuildPhase ровно один раз;
  4. каждый файл из дерева групп существует на диске;
  5. каждый локальный пакет объявлен и как XCLocalSwiftPackageReference,
     и как XCSwiftPackageProductDependency таргета;
  6. каталог задач валиден: схема, единственность решения, hash, тиры.

Запуск:  python3 Tools/verify_project.py
"""

from __future__ import annotations

import hashlib
import json
import re
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "ContentTools" / "python"))


# ------------------------------------------------------------------ парсер

class PlistParser:
    def __init__(self, text: str):
        self.text = text
        self.pos = 0

    def error(self, message: str):
        line = self.text.count("\n", 0, self.pos) + 1
        raise ValueError(f"{message} (строка {line})")

    def skip(self):
        while self.pos < len(self.text):
            ch = self.text[self.pos]
            if ch in " \t\n\r":
                self.pos += 1
            elif self.text.startswith("//", self.pos):
                end = self.text.find("\n", self.pos)
                self.pos = len(self.text) if end < 0 else end
            elif self.text.startswith("/*", self.pos):
                end = self.text.find("*/", self.pos + 2)
                if end < 0:
                    self.error("незакрытый комментарий")
                self.pos = end + 2
            else:
                return

    def parse(self):
        self.skip()
        value = self.parse_value()
        self.skip()
        if self.pos != len(self.text):
            self.error("лишние данные после корневого объекта")
        return value

    def parse_value(self):
        self.skip()
        ch = self.text[self.pos]
        if ch == "{":
            return self.parse_dict()
        if ch == "(":
            return self.parse_array()
        if ch == '"':
            return self.parse_quoted()
        return self.parse_bare()

    def parse_dict(self):
        self.pos += 1
        result = {}
        while True:
            self.skip()
            if self.text[self.pos] == "}":
                self.pos += 1
                return result
            key = self.parse_value()
            self.skip()
            if self.text[self.pos] != "=":
                self.error(f"ожидался `=` после ключа {key}")
            self.pos += 1
            value = self.parse_value()
            self.skip()
            if self.text[self.pos] != ";":
                self.error(f"ожидался `;` после значения ключа {key}")
            self.pos += 1
            result[key] = value

    def parse_array(self):
        self.pos += 1
        result = []
        while True:
            self.skip()
            if self.text[self.pos] == ")":
                self.pos += 1
                return result
            result.append(self.parse_value())
            self.skip()
            if self.text[self.pos] == ",":
                self.pos += 1

    def parse_quoted(self):
        self.pos += 1
        out = []
        while True:
            ch = self.text[self.pos]
            if ch == "\\":
                nxt = self.text[self.pos + 1]
                out.append({"n": "\n", "t": "\t"}.get(nxt, nxt))
                self.pos += 2
            elif ch == '"':
                self.pos += 1
                return "".join(out)
            else:
                out.append(ch)
                self.pos += 1

    def parse_bare(self):
        start = self.pos
        while self.pos < len(self.text) and self.text[self.pos] not in " \t\n\r;,=()<>{}":
            self.pos += 1
        if start == self.pos:
            self.error(f"пустой токен у символа {self.text[self.pos]!r}")
        return self.text[start:self.pos]


# ------------------------------------------------------------------ проверки

failures: list[str] = []
checks = 0


def check(condition: bool, message: str):
    global checks
    checks += 1
    if not condition:
        failures.append(message)


def verify_project():
    path = ROOT / "NamiApp.xcodeproj" / "project.pbxproj"
    check(path.exists(), "project.pbxproj отсутствует")
    if not path.exists():
        return

    document = PlistParser(path.read_text(encoding="utf-8")).parse()
    objects = document["objects"]
    check(isinstance(objects, dict) and len(objects) > 20,
          "objects пуст или не разобрался")

    root = document["rootObject"]
    check(root in objects, f"rootObject {root} не найден среди объектов")
    project = objects[root]
    check(project["isa"] == "PBXProject", "rootObject не является PBXProject")

    # 2. Все ссылки разрешаются.
    def walk(value):
        if isinstance(value, dict):
            for item in value.values():
                yield from walk(item)
        elif isinstance(value, list):
            for item in value:
                yield from walk(item)
        elif isinstance(value, str):
            yield value

    id_like = {key for key in objects}
    dangling = set()
    for value in walk(objects):
        token = value.strip()
        if len(token) == 24 and all(c in "0123456789ABCDEF" for c in token):
            if token not in id_like:
                dangling.add(token)
    check(not dangling, f"висящие ссылки на объекты: {sorted(dangling)[:5]}")

    # 3. Все исходники в фазе Sources ровно один раз.
    targets = [objects[t] for t in project["targets"]]
    check(len(targets) == 2, "ожидались app-таргет и тестовый таргет")
    target = next(t for t in targets
                  if t["productType"] == "com.apple.product-type.application")
    test_target = next((t for t in targets
                        if t["productType"] == "com.apple.product-type.bundle.unit-test"), None)
    check(test_target is not None, "нет unit-test таргета")

    phases = [objects[p] for p in target["buildPhases"]]
    sources_phase = next(p for p in phases if p["isa"] == "PBXSourcesBuildPhase")
    resources_phase = next(p for p in phases if p["isa"] == "PBXResourcesBuildPhase")

    def phase_names(phase):
        names = []
        for build_id in phase["files"]:
            build = objects[build_id]
            names.append(objects[build["fileRef"]]["path"])
        return names

    compiled = phase_names(sources_phase)
    on_disk = sorted(p.name for p in (ROOT / "App" / "Sources").rglob("*.swift"))
    check(sorted(compiled) == on_disk,
          f"фаза Sources расходится с диском:\n  только в проекте: "
          f"{sorted(set(compiled) - set(on_disk))}\n  только на диске: "
          f"{sorted(set(on_disk) - set(compiled))}")
    check(len(compiled) == len(set(compiled)), "дубликаты в фазе Sources")

    bundled = phase_names(resources_phase)
    check("classic.json" in bundled, "каталог задач не попал в ресурсы")
    check("Assets.xcassets" in bundled, "Assets.xcassets не попал в ресурсы")

    # 4. Файлы дерева групп существуют на диске.
    def group_paths(group_id, prefix: Path) -> list[Path]:
        group = objects[group_id]
        base = prefix / group.get("path", "") if "path" in group else prefix
        result = []
        for child_id in group.get("children", []):
            child = objects[child_id]
            if child["isa"] == "PBXGroup":
                result += group_paths(child_id, base)
            elif child.get("sourceTree") == "<group>":
                result.append(base / child["path"])
        return result

    missing = [p for p in group_paths(project["mainGroup"], ROOT) if not p.exists()]
    check(not missing, f"в дереве проекта есть несуществующие файлы: {missing[:5]}")

    # 5. Локальные пакеты.
    package_names = {objects[p]["relativePath"].split("/")[-1]
                     for p in project.get("packageReferences", [])}
    product_names = {objects[p]["productName"]
                     for p in target.get("packageProductDependencies", [])}
    expected = {"NamiDomain", "NamiData", "NamiExperience"}
    check(package_names == expected, f"packageReferences: {package_names}")
    check(product_names == expected, f"packageProductDependencies: {product_names}")
    for name in expected:
        check((ROOT / "Packages" / name / "Package.swift").exists(),
              f"нет Packages/{name}/Package.swift")

    # Настройки: базовые живут на уровне проекта, специфичные — на таргете.
    project_configs = objects[project["buildConfigurationList"]]["buildConfigurations"]
    for config_id in project_configs:
        settings = objects[config_id]["buildSettings"]
        check(settings.get("IPHONEOS_DEPLOYMENT_TARGET") == "18.0",
              "deployment target не 18.0")
        check(settings.get("SWIFT_VERSION") in {"5.0", "6.0"}, "неожиданный SWIFT_VERSION")
        check(settings.get("SWIFT_STRICT_CONCURRENCY") == "complete",
              "строгая конкурентность не включена")

    target_configs = objects[target["buildConfigurationList"]]["buildConfigurations"]
    check(len(target_configs) == 2, "у таргета должно быть Debug и Release")
    for config_id in target_configs:
        settings = objects[config_id]["buildSettings"]
        check((ROOT / settings["INFOPLIST_FILE"]).exists(), "INFOPLIST_FILE не найден")
        check(settings["PRODUCT_BUNDLE_IDENTIFIER"] == "com.nami.sudoku",
              "bundle id не совпадает")
        check(settings["TARGETED_DEVICE_FAMILY"] == "1,2", "нет поддержки iPhone и iPad")

    scheme = ROOT / "NamiApp.xcodeproj/xcshareddata/xcschemes/NamiApp.xcscheme"
    check(scheme.exists(), "shared-схема отсутствует")
    if scheme.exists():
        check(target["name"] in scheme.read_text(), "схема ссылается не на тот таргет")


def verify_catalog():
    import nami_sudoku as ns

    path = ROOT / "App" / "Resources" / "Puzzles" / "classic.json"
    check(path.exists(), "classic.json отсутствует")
    if not path.exists():
        return
    catalog = json.loads(path.read_text())
    puzzles = catalog["puzzles"]

    check(catalog["schemaVersion"] == 2, "schemaVersion каталога не 2")
    check(len(puzzles) >= 150, f"в каталоге только {len(puzzles)} задач, нужно >= 150")

    ids = [p["id"] for p in puzzles]
    check(len(ids) == len(set(ids)), "дубликаты id в каталоге")

    tiers = {"easy", "medium", "hard", "expert", "master"}
    present = {p["tier"] for p in puzzles}
    check(present == tiers, f"не все тиры представлены: {present}")

    for record in puzzles:
        pid = record["id"]
        check(len(record["puzzle"]) == 81 and len(record["solution"]) == 81,
              f"{pid}: неверная длина строки")
        check("0" not in record["solution"], f"{pid}: решение неполное")
        check(record["solutionHash"] ==
              "sha256:" + hashlib.sha256(record["solution"].encode()).hexdigest(),
              f"{pid}: solutionHash не совпадает")
        payload = {k: v for k, v in record.items() if k != "contentHash"}
        expected_hash = "sha256:" + hashlib.sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        check(record["contentHash"] == expected_hash, f"{pid}: contentHash не совпадает")
        check(record["givensCount"] == sum(1 for c in record["puzzle"] if c != "0"),
              f"{pid}: givensCount не совпадает")
        check(600 <= record["difficultyD"] <= 2400, f"{pid}: D вне диапазона")

    # Полная перепроверка десяти случайных задач: единственность + рейтинг.
    import random
    random.seed(11)
    for record in random.sample(puzzles, min(10, len(puzzles))):
        count, solution = ns.count_solutions(record["puzzle"], limit=2)
        check(count == 1, f"{record['id']}: решений {count}, а не одно")
        check(solution == record["solution"], f"{record['id']}: решение не совпадает")
        trace = ns.solve_human(record["puzzle"])
        check(trace.status == "solved", f"{record['id']}: не решается техниками")
        check(abs(trace.se_rating - record["seRating"]) < 1e-6,
              f"{record['id']}: seRating {trace.se_rating} != {record['seRating']}")
        check(trace.work_score == record["workScore"], f"{record['id']}: workScore")


# ------------------------------------------------------------------ локализация

STRINGS = Path("App/Sources/Support/Strings.swift")

# Семейства ключей, которые собираются интерполяцией и поэтому не находятся
# грепом по `L.t("…")`. Значение — (файл с enum, имя enum, шаблон ключа).
KEY_FAMILIES = [
    ("Packages/NamiDomain/Sources/NamiDomain/SudokuTechnique.swift",
     "SudokuTechnique", ["technique.{}.name", "technique.{}.explanation"]),
    ("Packages/NamiDomain/Sources/NamiDomain/Puzzle.swift",
     "DifficultyTier", ["difficulty.{}.title", "difficulty.{}.subtitle"]),
    ("Packages/NamiDomain/Sources/NamiDomain/Assistance.swift",
     "AssistanceProfile", ["assistance.{}.title", "assistance.{}.summary"]),
    ("Packages/NamiDomain/Sources/NamiDomain/RatingEngine.swift",
     "ResultReasonCode", ["result.reason.{}"]),
    ("Packages/NamiData/Sources/NamiData/PreferencesRepository.swift",
     "KeypadLayout", ["settings.keypad.{}"]),
    ("Packages/NamiData/Sources/NamiData/PreferencesRepository.swift",
     "AppLanguage", ["settings.language.{}"]),
]


def dict_literal(text: str, name: str) -> dict[str, str]:
    """Читает `static let <name>: [String: String] = [ … ]` из Strings.swift."""
    marker = f"static let {name}: [String: String] = ["
    start = text.index(marker) + len(marker)
    depth = 1
    pos = start
    while depth > 0:
        if text[pos] == "[":
            depth += 1
        elif text[pos] == "]":
            depth -= 1
        pos += 1
    body = text[start:pos - 1]
    pairs = re.findall(r'"((?:[^"\\]|\\.)*)"\s*:\s*"((?:[^"\\]|\\.)*)"', body)
    return {k: v for k, v in pairs}


def enum_cases(relative: str, enum_name: str) -> list[str]:
    text = (ROOT / relative).read_text(encoding="utf-8")
    match = re.search(rf"enum {enum_name}\b[^{{]*{{", text)
    if not match:
        return []
    pos = match.end()
    depth = 1
    while depth > 0 and pos < len(text):
        if text[pos] == "{":
            depth += 1
        elif text[pos] == "}":
            depth -= 1
        pos += 1
    body = text[match.end():pos - 1]
    names: list[str] = []
    for line in body.splitlines():
        line = line.strip()
        # Только объявления `case a, b` — не `case .x:` из switch.
        if not line.startswith("case ") or ":" in line.split("//")[0]:
            continue
        for item in line[5:].split("//")[0].split(","):
            item = item.split("=")[0].strip()
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", item):
                names.append(item)
    return names


def verify_localization():
    path = ROOT / STRINGS
    check(path.exists(), "Strings.swift отсутствует")
    if not path.exists():
        return
    text = path.read_text(encoding="utf-8")

    ru = dict_literal(text, "ru")
    en = dict_literal(text, "en")
    check(len(ru) > 250, f"в русском словаре только {len(ru)} ключей")

    missing_en = sorted(set(ru) - set(en))
    missing_ru = sorted(set(en) - set(ru))
    check(not missing_en, f"нет английского перевода: {missing_en[:8]}")
    check(not missing_ru, f"нет русского оригинала: {missing_ru[:8]}")

    # Форматные спецификаторы обязаны совпадать по составу и порядку,
    # иначе String(format:) прочитает не тот аргумент и уронит приложение.
    spec = re.compile(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?[@dfsu%]")
    for key in sorted(set(ru) & set(en)):
        ru_specs = [s for s in spec.findall(ru[key]) if s != "%%"]
        en_specs = [s for s in spec.findall(en[key]) if s != "%%"]
        check(ru_specs == en_specs,
              f"{key}: спецификаторы расходятся {ru_specs} != {en_specs}")

    # Каждый ключ, который код запрашивает литералом, обязан существовать.
    used: set[str] = set()
    for swift in sorted((ROOT / "App" / "Sources").rglob("*.swift")):
        if swift.name == STRINGS.name:
            continue
        for key in re.findall(r'L\.t\(\s*"([^"]+)"', swift.read_text(encoding="utf-8")):
            # Интерполяция внутри литерала — это семейство ключей,
            # оно проверяется отдельно по case-ам enum-а.
            if "\\(" not in key:
                used.add(key)
    check(len(used) > 100, f"найдено подозрительно мало обращений: {len(used)}")
    unknown = sorted(used - set(ru))
    check(not unknown, f"код просит несуществующие ключи: {unknown[:8]}")

    # Число аргументов на месте вызова против числа спецификаторов.
    # Это ровно та ошибка, из-за которой экран статистики падал: формат
    # поменяли на «%d/%d», а один из вызовов остался с одним аргументом.
    mismatched_arity: list[str] = []
    for swift in sorted((ROOT / "App" / "Sources").rglob("*.swift")):
        if swift.name == STRINGS.name:
            continue
        text = swift.read_text(encoding="utf-8")
        for match in re.finditer(r'L\.t\(\s*"([^"]+)"\s*(,)?', text):
            key = match.group(1)
            if "\\(" in key or not match.group(2):
                continue
            # Считаем запятые верхнего уровня до закрывающей скобки вызова.
            position, depth, arguments = match.end(), 1, 1
            while position < len(text) and depth > 0:
                char = text[position]
                if char in "([{":
                    depth += 1
                elif char in ")]}":
                    depth -= 1
                    if depth == 0:
                        break
                elif char == "," and depth == 1:
                    arguments += 1
                position += 1
            template = ru.get(key)
            if template is None:
                continue
            expected = len([s for s in spec.findall(template) if s != "%%"])
            if expected != arguments:
                mismatched_arity.append(
                    f"{swift.name}:{key} формат ждёт {expected}, передано {arguments}")
    check(not mismatched_arity,
          f"аргументы не совпадают с форматом: {mismatched_arity[:5]}")

    # Ключи, собираемые интерполяцией из enum-ов, грепом не видны.
    for relative, enum_name, patterns in KEY_FAMILIES:
        cases = enum_cases(relative, enum_name)
        check(bool(cases), f"не удалось прочитать case-ы {enum_name}")
        for case in cases:
            for pattern in patterns:
                key = pattern.format(case)
                check(key in ru, f"{enum_name}: нет ключа {key}")


# ------------------------------------------------------------------ солвер

def _replay(puzzle: str, funcs):
    """Прогоняет солвер и отдаёт все ходы: [(техника, клетка, цифра, ставим?)]."""
    import nami_sudoku as ns
    grid = ns.Grid(puzzle)
    moves = []
    for _ in range(400):
        if grid.solved() or grid.contradiction():
            break
        step = None
        for _, fn in funcs:
            step = fn(grid)
            if step is not None:
                break
        if step is None:
            break
        if step.placement:
            cell, digit = step.placement
            moves.append((step.technique, cell, digit, True))
            grid.place(cell, digit)
        else:
            for cell, digit in step.eliminations:
                moves.append((step.technique, cell, digit, False))
                grid.cands[cell] &= ~(1 << digit)
    return moves, grid.solved()


def verify_solver():
    """Два свойства, которые важнее любого совпадения цифр.

    1. Корректность: солвер не имеет права поставить цифру, отличную от решения,
       или вычеркнуть кандидата, который в решении стоит. Ошибка здесь означает,
       что игрок может получить подсказку, ведущую в тупик.
    2. Теснота рейтинга: заявленный seRating обязан быть НЕОБХОДИМЫМ. Если задача
       решается только техниками попроще, рейтинг завышен и тир врёт.
    """
    import nami_sudoku as ns

    path = ROOT / "App" / "Resources" / "Puzzles" / "classic.json"
    if not path.exists():
        return
    puzzles = json.loads(path.read_text(encoding="utf-8"))["puzzles"]

    unsound = []
    inflated = []
    for record in puzzles:
        solution = record["solution"]
        moves, _ = _replay(record["puzzle"], ns.TECHNIQUE_FUNCS)
        for technique, cell, digit, is_placement in moves:
            wrong = (int(solution[cell]) != digit) if is_placement \
                else (int(solution[cell]) == digit)
            if wrong:
                unsound.append(f"{record['id']}/{technique} r{cell // 9 + 1}c{cell % 9 + 1}")
                break

        limit = record["seRating"] - 1e-9
        easier = [(k, f) for k, f in ns.TECHNIQUE_FUNCS
                  if ns.TECHNIQUES[k].rating < limit]
        _, solved_without = _replay(record["puzzle"], easier)
        if solved_without:
            inflated.append(record["id"])

    check(not unsound, f"солвер делает неверные выводы: {unsound[:5]}")
    check(not inflated, f"seRating завышен, задача проще заявленного: {inflated[:5]}")


def verify_catalog_variety():
    """Задачи внутри тира не должны выглядеть одинаково.

    «Новая игра» выбирает наименее похожую задачу по УЗОРУ подсказок — какие
    клетки заполнены. Если в тире много задач с одинаковым узором, выбор
    ничего не спасёт: доски будут выглядеть той же самой.
    """
    path = ROOT / "App" / "Resources" / "Puzzles" / "classic.json"
    if not path.exists():
        return
    puzzles = json.loads(path.read_text(encoding="utf-8"))["puzzles"]

    by_tier: dict[str, list[str]] = {}
    for record in puzzles:
        by_tier.setdefault(record["tier"], []).append(record["puzzle"])

    def pattern(text: str) -> int:
        mask = 0
        for index, char in enumerate(text):
            if char != "0":
                mask |= 1 << index
        return mask

    for tier, boards in by_tier.items():
        masks = [pattern(board) for board in boards]
        check(len(set(masks)) == len(masks),
              f"{tier}: есть задачи с полностью одинаковым узором подсказок")

        # Худшая пара: если даже она различается слабо, тир однообразен.
        worst = 0.0
        for i in range(len(masks)):
            for j in range(i + 1, len(masks)):
                shared = bin(masks[i] & masks[j]).count("1")
                union = bin(masks[i] | masks[j]).count("1")
                if union:
                    worst = max(worst, shared / union)
        check(worst < 0.95,
              f"{tier}: пара задач совпадает по узору на {worst:.0%}")


def verify_se_reference():
    """Сверка с внешним эталоном Sudoku Explainer.

    Инвариант здесь СМЕНИЛСЯ после реализации «прямых» техник, и это осознанно.

    Раньше требовалось «никогда не оценивать ниже SE». Теперь наш солвер видит
    короткие пути, которых нет у SE: исключение, немедленно открывающее
    скрытого одиночку, стоит 1.7 вместо 2.6. Поэтому занижение относительно SE
    стало НОРМОЙ — оно означает, что задача действительно решается дешевле.
    Безопасность обеспечивают два других инварианта, а не сравнение с чужой
    программой: солвер не делает неверных выводов и не завышает рейтинг
    (см. `verify_solver`).

    Что здесь всё ещё ловится: ЗАВЫШЕНИЕ. Если мы оцениваем задачу выше SE —
    значит потеряли технику, которая у SE есть. Порог держим жёстким.
    """
    import nami_sudoku as ns

    path = ROOT / "ContentTools" / "reference" / "se_reference.txt"
    if not path.exists():
        return

    over = []
    count = 0
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        expected_text, puzzle = line.split()
        expected = float(expected_text)
        trace = ns.solve_human(puzzle.replace(".", "0"))
        count += 1
        if trace.status != "solved":
            continue
        ours = round(trace.se_rating, 2)
        if ours > expected + 1e-9:
            over.append(f"{puzzle[:12]}… {ours} > {expected}")

    check(count > 100, f"эталон подозрительно мал: {count} задач")
    # Пять — текущий фактический уровень; рост означает потерянную технику.
    check(len(over) <= 5,
          f"завышаем относительно SE на {len(over)} задачах: {over[:5]}")


def verify_journal():
    """Журнал событий: полнота воспроизведения и устойчивость отпечатка.

    Проверяется статически то, что дороже всего поймать в рантайме: забытый
    case в `replay` не падает и не ломает сборку — он просто молча теряет
    часть истории, и партия восстанавливается неправильно.
    """
    path = ROOT / "Packages/NamiDomain/Sources/NamiDomain/SessionJournal.swift"
    check(path.exists(), "SessionJournal.swift отсутствует")
    if not path.exists():
        return
    text = path.read_text(encoding="utf-8")

    body = re.search(r"public enum GameJournalEvent[^{]*\{(.*?)\n\}", text, re.S)
    check(body is not None, "не найдено объявление GameJournalEvent")
    if not body:
        return
    declared = set(re.findall(r"^\s*case (\w+)", body.group(1), re.M))
    check(len(declared) >= 7, f"подозрительно мало событий журнала: {len(declared)}")

    replay = re.search(r"public func replay\(\)(.*?)\n    \}\n\}", text, re.S)
    check(replay is not None, "не найдено тело replay()")
    if not replay:
        return
    handled = set(re.findall(r"case (?:let )?\.(\w+)", replay.group(1)))
    missing = declared - handled
    check(not missing, "replay() не обрабатывает события: " + ", ".join(sorted(missing)))
    check("default:" not in replay.group(1),
          "в replay() есть default: новое событие будет молча проигнорировано")

    # Отпечаток обязан быть воспроизводимым между запусками процесса.
    check("Hasher()" not in text, "SessionJournal использует Hasher() — он засеян случайно")
    for guard in ("case sequenceGap", "case corruptedDuplicate",
                  "case unsupportedSchema", "case sealed"):
        check(guard in text, f"в SessionJournal нет защиты {guard}")

    # Транзакция обязана применяться к копии, иначе откат невозможен.
    check("var trial = self" in text and "self = trial" in text,
          "appendTransaction применяет события напрямую — откат пакета невозможен")


    # Тестовые файлы перечислены в pbxproj поимённо, а не собираются по маске.
    # Новый файл на диске молча не попадает в сборку: тесты «проходят», просто
    # потому что их не запускали. Ровно это и проверяем.
    pbx = (ROOT / "NamiApp.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
    tests_dir = ROOT / "Packages/NamiDomain/Tests/NamiDomainTests"
    for swift in sorted(tests_dir.glob("*.swift")):
        check(swift.name in pbx,
              f"{swift.name} есть на диске, но не включён в NamiApp.xcodeproj "
              f"— перегенерируйте Tools/generate_xcodeproj.py")

    # Ни один сохраняемый ключ не должен считаться стандартным Hasher.
    for swift in sorted((ROOT / "App/Sources").rglob("*.swift")):
        check("Hasher()" not in swift.read_text(encoding="utf-8"),
              f"{swift.name}: Hasher() даёт разный результат после перезапуска")


def verify_sound_kits():
    """Комплектность звука.

    Отсутствующий файл не роняет приложение и не ломает сборку — он просто
    молчит. Поймать это можно только сверкой списка, поэтому она здесь.
    """
    sounds = ROOT / "App/Resources/Sounds"
    assets = ["cellSelected", "digitPlaced", "digitErased", "noteToggled",
              "groupCompleted", "conflict", "victory", "uiConfirm"]
    layers = ["pad", "melody", "texture", "bass"]
    kits = ["zenGarden", "deepSpace", "forestDawn"]

    pbx = (ROOT / "NamiApp.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")

    for kit in kits:
        for asset in assets:
            name = f"{kit}__{asset}.caf"
            check((sounds / name).exists(), f"нет файла звука {name}")
            check(name in pbx, f"{name} не включён в проект — звука не будет")
        for layer in layers:
            name = f"{kit}__music_{layer}.caf"
            check((sounds / name).exists(), f"нет слоя музыки {name}")
            check(name in pbx, f"{name} не включён в проект — слой будет молчать")

    # Исходный набор NAMI остаётся набором по умолчанию.
    for asset in assets:
        check((sounds / f"{asset}.wav").exists() or (sounds / f"{asset}.caf").exists(),
              f"пропал звук базового набора: {asset}")
    check((sounds / "ambientLoop.wav").exists() or (sounds / "ambientLoop.caf").exists(),
          "пропал ambientLoop базового набора")

    # Названия комплектов должны совпадать с enum SoundKit, иначе выбор в
    # настройках будет указывать на несуществующие файлы.
    kit_source = (ROOT / "Packages/NamiExperience/Sources/NamiExperience/SoundKit.swift")
    check(kit_source.exists(), "SoundKit.swift отсутствует")
    if kit_source.exists():
        text = kit_source.read_text(encoding="utf-8")
        for kit in kits + ["nami"]:
            check(f"case {kit}" in text, f"в SoundKit нет случая {kit}")


def verify_effects():
    """Эффекты: детерминизм кадра и полнота таблицы тем."""
    exp = ROOT / "Packages/NamiExperience/Sources/NamiExperience"

    # Кадр обязан быть воспроизводимым: в BoardEffectOverlay это записано
    # прямо в комментарии, и снапшот-тест на живом RNG начнёт мигать раз в
    # сотню прогонов — с диагнозом «что угодно, кроме частиц».
    # Движок звука останавливается системой молча. Если источником правды
    # снова станет собственный флаг, звук будет пропадать до перезапуска
    # приложения — этот баг уже был, и поймать его тестом невозможно.
    players = exp / "Players.swift"
    check(players.exists(), "Players.swift отсутствует")
    if players.exists():
        text = players.read_text(encoding="utf-8")
        check("engine.isRunning" in text,
              "Players: состояние движка обязано читаться из engine.isRunning")
        check("AVAudioEngineConfigurationChange" in text,
              "Players: не отслеживается смена аудиомаршрута")
        check("mediaServicesWereResetNotification" in text,
              "Players: не отслеживается сброс медиасервисов")
        check("interruptionNotification" in text,
              "Players: не отслеживается прерывание сессии")
        check("func resumeIfNeeded" in text, "Players: нет подъёма движка")
    root = ROOT / "App/Sources/App/NamiApp.swift"
    check("resumeIfNeeded" in root.read_text(encoding="utf-8"),
          "возврат из фона не поднимает движок звука")

    for name in ("AnimationDirector.swift", "ParticleVocabulary.swift"):
        path = exp / name
        check(path.exists(), f"{name} отсутствует")
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        check(".random(" not in text,
              f"{name}: живой RNG ломает воспроизводимость кадра")
        check("Hasher()" not in text and ".hashValue" not in text,
              f"{name}: hashValue засеян случайно, разброс будет разным между запусками")

    # Реакция клетки обязана выбираться по СМЫСЛУ события, а не по виду
    # анимации: стирание цифры и конфликт оба приходят с `animation == .none`,
    # и по анимации клетка дрожала бы при каждом стирании.
    board = ROOT / "App/Sources/Features/Game/BoardView.swift"
    if board.exists():
        text = board.read_text(encoding="utf-8")
        check("effect.cue" in text,
              "BoardView выбирает реакцию не по cue — стирание будет выглядеть ошибкой")
        check("effect.animation" not in text,
              "BoardView не должен ветвиться по animation при выборе реакции")

    # Каждая тема обязана иметь личность эффектов, иначе новая тема молча
    # получит поведение по умолчанию и никто этого не заметит.
    theme_text = (exp / "Theme.swift").read_text(encoding="utf-8")
    theme_ids = re.findall(r'id:\s*"([a-z-]+)"', theme_text)
    check(len(theme_ids) >= 4, f"тем найдено подозрительно мало: {theme_ids}")
    personality = (exp / "EffectPersonality.swift").read_text(encoding="utf-8")
    for theme_id in theme_ids:
        # `paper-default` покрыт веткой default — это осознанный запас
        # на будущие бумажные темы.
        if theme_id == "paper-default":
            continue
        check(f'"{theme_id}"' in personality,
              f"тема {theme_id} не описана в EffectPersonality")

    # Комплект звука предлагает тему — она должна существовать.
    kit_text = (exp / "SoundKit.swift").read_text(encoding="utf-8")
    for suggested in re.findall(r'case \.\w+: "([a-z-]+)"', kit_text):
        check(suggested in theme_ids,
              f"SoundKit предлагает несуществующую тему {suggested}")


def verify_rank_progress():
    """«До следующего ранга — 0» показывать нельзя.

    Порог берётся по очкам, но повышение подтверждается тремя результатами.
    В промежутке строка «осталось 0» стоит при неподвижном ранге и читается
    как поломка — именно так этот баг и был найден.
    """
    for name in ("App/Sources/Features/Statistics/StatisticsView.swift",
                 "App/Sources/Features/Home/HomeView.swift"):
        path = ROOT / name
        check(path.exists(), f"{name} отсутствует")
        if not path.exists():
            continue
        text = path.read_text(encoding="utf-8")
        check("pointsToNext" in text, f"{name}: расстояние до ранга не считается")
        check("distance > 0" in text or "distance == 0" in text,
              f"{name}: нулевое расстояние не отделено от положительного")
        check("promotionConfirmation" in text,
              f"{name}: пройденный порог не объясняется подтверждением")


def verify_dojo():
    """Додзё: у каждой ступени должен быть материал в каталоге.

    Ступень без задачи выглядит как рабочая — она открывается, показывает
    урок и молча упирается в «нет материала» на кнопке тренировки. Поймать
    это можно только сверкой учебного плана с размёткой каталога.
    """
    lessons_path = ROOT / "Packages/NamiDomain/Sources/NamiDomain/Dojo.swift"
    check(lessons_path.exists(), "Dojo.swift отсутствует")
    if not lessons_path.exists():
        return
    text = lessons_path.read_text(encoding="utf-8")
    planned = re.findall(r"DojoLesson\(technique: \.(\w+)\)", text)
    check(len(planned) >= 10, f"в учебном плане подозрительно мало ступеней: {len(planned)}")

    catalog = json.loads((ROOT / "App/Resources/Puzzles/classic.json").read_text())
    tagged = {}
    for puzzle in catalog["puzzles"]:
        for key in puzzle.get("techniques", []):
            tagged[key] = tagged.get(key, 0) + 1

    for technique in planned:
        count = tagged.get(technique, 0)
        # Меньше трёх задач — и на трёх дриллах ступени игрок увидит одну и
        # ту же позицию дважды.
        check(count >= 3,
              f"техника {technique} в учебном плане, но в каталоге задач: {count}")

    # Строки «как искать» обязаны существовать: без них урок покажет ключи.
    strings = (ROOT / "App/Sources/Support/Strings.swift").read_text(encoding="utf-8")
    for technique in planned:
        for step in (1, 2, 3):
            key = f'"dojo.{technique}.search{step}"'
            check(strings.count(key) == 2,
                  f"нет пары ru/en для {key}")


def verify_score_integrity():
    """Пять инвариантов честности счёта, найденных на ревью.

    Каждый из них ломается молча: игра работает, а число в таблице
    неправильное. Тестом ловится только часть, остальное — только сверкой
    мест, где решение принимается.
    """
    store = ROOT / "App/Sources/Features/Game/GameSessionStore.swift"
    router = ROOT / "App/Sources/App/AppRouter.swift"
    saved = ROOT / "Packages/NamiData/Sources/NamiData/SavedGameStore.swift"
    journal = ROOT / "Packages/NamiDomain/Sources/NamiDomain/SessionJournal.swift"
    for path in (store, router, saved, journal):
        check(path.exists(), f"{path.name} отсутствует")
    if not all(p.exists() for p in (store, router, saved, journal)):
        return
    store_text = store.read_text(encoding="utf-8")
    router_text = router.read_text(encoding="utf-8")
    saved_text = saved.read_text(encoding="utf-8")
    journal_text = journal.read_text(encoding="utf-8")

    # 1. Номер ревизии продолжается после восстановления, иначе первые Check
    #    после перезапуска бесплатны и сохраняют серию.
    check("valueRevision = journal?.replay()?.valueRevision" in store_text,
          "valueRevision не восстанавливается — Check после перезапуска будет бесплатным")

    # 2. Режим партии переживает восстановление.
    check("mode: persisted.mode" in router_text,
          "режим не берётся из сохранения — «Релакс» станет рейтинговым")
    check("gameModeRaw" in saved_text, "режим не сохраняется на диск")

    # 3. Перезапуск начинает новый журнал, а не дописывает старый.
    check("startFreshJournal" in store_text,
          "restart() не начинает новый журнал — партия будет помечена повреждённой")

    # 4. Reveal не начисляет очки в живой партии.
    check("transaction.isReveal" in store_text,
          "Reveal начисляет очки в живой партии, но не при воспроизведении")

    # 5. В рекорды пишется только счёт, имеющий право на запись.
    check("isRecordable" in router_text,
          "счёт пишется в рекорды без проверки isRecordable")

    # Журнал обязан уметь стартовать не с исходной задачи: иначе старые
    # сохранения и перезапуск объявляются повреждёнными.
    check("startingBoard" in journal_text,
          "журнал не умеет стартовать не с givens")

    # Отложенные ходы не должны переживать стирание и отмену.
    check(store_text.count("pendingPlacements.removeAll") >= 3,
          "стёртые и отменённые ходы остаются в очереди на начисление")


def main():
    verify_project()
    verify_catalog()
    verify_localization()
    verify_solver()
    verify_catalog_variety()
    verify_se_reference()
    verify_journal()
    verify_sound_kits()
    verify_effects()
    verify_rank_progress()
    verify_dojo()
    verify_score_integrity()

    if failures:
        print(f"ПРОВАЛЕНО: {len(failures)} из {checks} проверок\n")
        for item in failures:
            print(" ✗", item)
        sys.exit(1)
    print(f"OK: все {checks} проверок пройдены")


if __name__ == "__main__":
    main()
