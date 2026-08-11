"""
Сверка нашего rater-а с эталонным Sudoku Explainer.

Берёт задачи из ContentTools/reference/se_reference.txt (рейтинги посчитаны
самим SE) и прогоняет через nami_sudoku.solve_human. Печатает распределение
расхождений и разбор по группам.

Запуск:  python3 compare_se.py
"""

from __future__ import annotations

import collections
import pathlib
import sys

import nami_sudoku as ns

REFERENCE = pathlib.Path(__file__).resolve().parents[1] / "reference" / "se_reference.txt"
TOLERANCE = 1e-9


def load() -> list[tuple[float, str, str]]:
    """[(эталонный SE, название группы, 81 цифра)]"""
    items: list[tuple[float, str, str]] = []
    group = "?"
    for line in REFERENCE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        if line.startswith("#"):
            body = line.lstrip("#").strip()
            # Заголовок группы выглядит как "3.2 X-Wing".
            head = body.split(" ", 1)
            if len(head) == 2 and head[0].replace(".", "", 1).isdigit():
                group = body
            continue
        rating, puzzle = line.split()
        items.append((float(rating), group, puzzle.replace(".", "0")))
    return items


def main() -> int:
    if not REFERENCE.exists():
        sys.exit(f"нет файла {REFERENCE}")

    items = load()
    deltas: collections.Counter[str] = collections.Counter()
    by_group: dict[str, list[float]] = collections.defaultdict(list)
    unsolved: list[tuple[str, float]] = []

    for expected, group, puzzle in items:
        trace = ns.solve_human(puzzle)
        if trace.status != "solved":
            unsolved.append((group, expected))
            by_group[group].append(float("nan"))
            deltas["не решается нашими техниками"] += 1
            continue
        ours = round(trace.se_rating, 2)
        by_group[group].append(ours)
        if abs(ours - expected) < TOLERANCE:
            deltas["совпадает"] += 1
        elif ours > expected:
            deltas["мы завышаем"] += 1
        else:
            deltas["мы занижаем"] += 1

    total = len(items)
    print(f"Задач в эталоне: {total}\n")
    for name, count in deltas.most_common():
        print(f"  {name:<30} {count:>4}  ({count / total:.0%})")

    print("\nПо группам (эталон -> что даём мы):")
    for group in dict.fromkeys(g for _, g, _ in items):
        ours = by_group[group]
        values = sorted({v for v in ours if v == v})
        shown = ", ".join(f"{v:g}" for v in values) or "—"
        nan_count = sum(1 for v in ours if v != v)
        suffix = f", не решено {nan_count}" if nan_count else ""
        expected = float(group.split()[0])
        mark = "  ok" if values == [expected] and not nan_count else "  <-- расходится"
        print(f"  {group:<28} -> {shown}{suffix}{mark}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
