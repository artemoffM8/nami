"""
NAMI ContentTools — генерация и рейтинг offline-каталога задач.

Пайплайн (раздел 8.3 ТЗ):
  1. полное корректное решение
  2. симметричное удаление цифр
  3. проверка единственности после каждого удаления
  4. human-style rater (nami_sudoku.solve_human)
  5. seRating = max rating шага
  6. workScore = сумма весов, dependencyDepth = глубина зависимостей
  7. отбрасывание задач с перебором / несколькими решениями
  8. сохранение solve trace (техники) для учебных сценариев

Запуск:  python3 generate_catalog.py --out ../../App/Resources/Puzzles/classic.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import time
from collections import Counter

import nami_sudoku as ns

SCHEMA_VERSION = 2
CATALOG_VERSION = "classic-2026.07-1"
DIFFICULTY_MAPPING_VERSION = "d-map-1"
HINT_PLAN_VERSION = 2

# Продуктовые границы NAMI (раздел 8.1)
TIERS = [
    ("easy", 1.0, 1.6),
    ("medium", 1.7, 2.5),
    ("hard", 2.6, 3.7),
    ("expert", 3.8, 5.3),
    ("master", 5.4, 99.0),
]
QUOTA = {"easy": 80, "medium": 90, "hard": 80, "expert": 55, "master": 40}

# Опорные значения для перевода SE -> внутренний рейтинг D (600...2400)
SE_TO_D_ANCHORS = [(1.0, 650), (1.6, 900), (2.5, 1150),
                   (3.7, 1450), (5.3, 1800), (7.0, 2200), (9.0, 2400)]
REF_WORK = {"easy": 260, "medium": 520, "hard": 900, "expert": 1400, "master": 2000}
BASE_MINUTES = {"easy": 5, "medium": 12, "hard": 24, "expert": 38, "master": 55}


def tier_for(se: float) -> str:
    for name, lo, hi in TIERS:
        if lo - 1e-9 <= se <= hi + 1e-9:
            return name
    return "master"


def se_to_d(se: float) -> int:
    pts = SE_TO_D_ANCHORS
    if se <= pts[0][0]:
        return pts[0][1]
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        if se <= x1:
            k = (se - x0) / (x1 - x0)
            return round(y0 + k * (y1 - y0))
    return pts[-1][1]


def difficulty_d(se: float, work: int, depth: int, tier: str) -> int:
    base = se_to_d(se)
    ref = REF_WORK[tier]
    work_adj = max(-60, min(60, round((work - ref) / ref * 60)))
    depth_adj = max(-20, min(20, (depth - 10) * 3))
    return max(600, min(2400, base + work_adj + depth_adj))


def expected_seconds(tier: str, work: int) -> int:
    ref = REF_WORK[tier]
    factor = max(0.6, min(1.6, work / ref))
    return int(round(BASE_MINUTES[tier] * 60 * factor))


# ------------------------------------------------------------------ generation

def full_solution(rng: random.Random) -> str:
    values = [0] * 81
    cands = [ns.FULL_MASK] * 81

    def assign(cell, d) -> bool:
        values[cell] = d
        cands[cell] = 0
        bit = 1 << d
        undo = []
        for p in ns.PEERS[cell]:
            if cands[p] & bit:
                cands[p] &= ~bit
                undo.append(p)
                if not values[p] and not cands[p]:
                    for q in undo:
                        cands[q] |= bit
                    values[cell] = 0
                    return False
        return True

    def rec() -> bool:
        best, best_n = -1, 10
        for i in range(81):
            if values[i]:
                continue
            n = ns.POPCOUNT[cands[i]]
            if n == 0:
                return False
            if n < best_n:
                best, best_n = i, n
        if best < 0:
            return True
        snapshot_v, snapshot_c = values[:], cands[:]
        options = ns.bits(cands[best])
        rng.shuffle(options)
        for d in options:
            if assign(best, d) and rec():
                return True
            values[:] = snapshot_v
            cands[:] = snapshot_c
        return False

    ok = rec()
    assert ok
    return "".join(str(v) for v in values)


def carve(solution: str, rng: random.Random, symmetric: bool, min_givens: int) -> str:
    cells = list(range(81))
    rng.shuffle(cells)
    puzzle = list(solution)
    givens = 81
    for cell in cells:
        if givens <= min_givens:
            break
        group = [cell]
        if symmetric:
            mirror = 80 - cell
            if mirror != cell:
                group.append(mirror)
        if any(puzzle[c] == "0" for c in group):
            continue
        if givens - len(group) < min_givens:
            continue
        backup = [puzzle[c] for c in group]
        for c in group:
            puzzle[c] = "0"
        if ns.has_unique_solution("".join(puzzle)):
            givens -= len(group)
        else:
            for c, v in zip(group, backup):
                puzzle[c] = v
    return "".join(puzzle)


def make_candidate(rng: random.Random):
    solution = full_solution(rng)
    symmetric = rng.random() < 0.7
    min_givens = rng.choice([22, 22, 24, 26, 28, 30, 34, 38])
    puzzle = carve(solution, rng, symmetric, min_givens)
    trace = ns.solve_human(puzzle)
    if trace.status != "solved":
        return None
    n, sol = ns.count_solutions(puzzle, limit=2)
    if n != 1 or sol != solution:
        return None
    return puzzle, solution, trace


def build_record(index: int, tier: str, puzzle: str, solution: str, trace) -> dict:
    d_value = difficulty_d(trace.se_rating, trace.work_score,
                           trace.dependency_depth, tier)
    rec = {
        "schemaVersion": SCHEMA_VERSION,
        "id": f"classic-{tier}-{index:04d}",
        "puzzle": puzzle,
        "solution": solution,
        "solutionHash": "sha256:" + hashlib.sha256(solution.encode()).hexdigest(),
        "seRating": round(trace.se_rating, 2),
        "workScore": trace.work_score,
        "dependencyDepth": trace.dependency_depth,
        "difficultyD": d_value,
        "tier": tier,
        "techniques": trace.techniques,
        "givensCount": sum(1 for ch in puzzle if ch != "0"),
        "estimatedMinutes": max(3, round(expected_seconds(tier, trace.work_score) / 60)),
        "expectedActiveSecondsP50": expected_seconds(tier, trace.work_score),
        "dailyEligible": tier != "master",
        "raterVersion": ns.RATER_VERSION,
        "difficultyMappingVersion": DIFFICULTY_MAPPING_VERSION,
        "hintPlanVersion": HINT_PLAN_VERSION,
    }
    payload = json.dumps(rec, sort_keys=True, separators=(",", ":"))
    rec["contentHash"] = "sha256:" + hashlib.sha256(payload.encode()).hexdigest()
    return rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=20260731)
    ap.add_argument("--budget", type=float, default=900.0, help="секунд")
    ap.add_argument("--resume", action="store_true",
                    help="перерейтинговать существующий каталог и дособрать недостающее")
    args = ap.parse_args()

    # Зерно сдвигается по числу уже собранных задач. Иначе каждый повторный
    # прогон воспроизводит ту же последовательность кандидатов, дедупликация
    # выбрасывает их все, и каталог не растёт при любом числе попыток.
    rng = random.Random(args.seed)
    buckets: dict[str, list] = {t: [] for t in QUOTA}
    start = time.time()
    attempts = 0

    # Возобновление. После правки солвера рейтинги существующих задач меняются,
    # поэтому старый каталог нельзя просто дополнить — его надо ПЕРЕСЧИТАТЬ
    # текущим рейтером и разложить по тирам заново. Уже найденные задачи при
    # этом не теряются: генерация самая дорогая часть, а рейтинг дешёвый.
    if args.resume:
        try:
            with open(args.out, encoding="utf-8") as f:
                existing = json.load(f)["puzzles"]
        except (OSError, ValueError, KeyError):
            existing = []
        seen: set[str] = set()
        rescored = 0
        for record in existing:
            puzzle = record["puzzle"]
            if puzzle in seen:
                continue
            seen.add(puzzle)
            trace = ns.solve_human(puzzle)
            if trace.status != "solved":
                continue
            tier = tier_for(trace.se_rating)
            if len(buckets[tier]) >= QUOTA[tier]:
                continue
            buckets[tier].append((puzzle, record["solution"], trace))
            rescored += 1
        print(f"возобновление: перенесено {rescored} из {len(existing)}")
        rng = random.Random(args.seed + rescored * 7919)

    known = {p for items in buckets.values() for p, _, _ in items}
    while time.time() - start < args.budget:
        if all(len(buckets[t]) >= QUOTA[t] for t in QUOTA):
            break
        attempts += 1
        made = make_candidate(rng)
        if made is None:
            continue
        puzzle, solution, trace = made
        if puzzle in known:
            continue
        known.add(puzzle)
        tier = tier_for(trace.se_rating)
        if len(buckets[tier]) >= QUOTA[tier]:
            continue
        buckets[tier].append((puzzle, solution, trace))

    records = []
    for tier, _, _ in TIERS:
        items = sorted(buckets[tier], key=lambda x: (x[2].se_rating, x[2].work_score))
        for i, (puzzle, solution, trace) in enumerate(items, start=1):
            records.append(build_record(i, tier, puzzle, solution, trace))

    catalog = {
        "schemaVersion": SCHEMA_VERSION,
        "catalogVersion": CATALOG_VERSION,
        "raterVersion": ns.RATER_VERSION,
        "difficultyMappingVersion": DIFFICULTY_MAPPING_VERSION,
        "generatedAt": "2026-07-31",
        "puzzles": records,
    }
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=1)
        f.write("\n")

    counts = Counter(r["tier"] for r in records)
    print(f"attempts={attempts} elapsed={time.time() - start:.0f}s total={len(records)}")
    for tier, _, _ in TIERS:
        got = counts.get(tier, 0)
        ses = [r["seRating"] for r in records if r["tier"] == tier]
        rng_txt = f"{min(ses)}-{max(ses)}" if ses else "-"
        print(f"  {tier:<7} {got:>3}/{QUOTA[tier]:<3} SE {rng_txt}")


if __name__ == "__main__":
    main()
