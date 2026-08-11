"""
NAMI — human-style Sudoku solver / rater (reference implementation).

Этот модуль является ЭТАЛОНОМ алгоритма, который построчно портирован в
Swift (Packages/NamiDomain/Sources/NamiDomain/HumanSolver.swift).
Любое изменение здесь обязано быть отражено там, иначе упадёт тест
`CatalogRegressionTests`.

Алгоритм (детерминированный, versioned as `nami-human-1`):

    повторять:
        если доска решена -> success
        если есть противоречие -> contradiction
        для каждой техники T в порядке возрастания (rating, ordinal):
            найти ПЕРВОЕ применение T в фиксированном порядке обхода
            если найдено: применить только его, записать шаг, начать заново
        иначе -> unsolvable (требуется перебор)

    seRating       = max(rating шага)
    workScore      = sum(weight шага)
    dependencyDepth = длина самой длинной цепочки зависимостей между шагами
"""

from __future__ import annotations

from dataclasses import dataclass, field
from itertools import combinations

RATER_VERSION = "nami-human-1"
FULL_MASK = 0b1111111110  # биты 1...9, бит 0 не используется


# ---------------------------------------------------------------- topology

def _build_topology():
    rows = [[r * 9 + c for c in range(9)] for r in range(9)]
    cols = [[r * 9 + c for r in range(9)] for c in range(9)]
    boxes = []
    for b in range(9):
        br, bc = (b // 3) * 3, (b % 3) * 3
        boxes.append([(br + dr) * 9 + (bc + dc) for dr in range(3) for dc in range(3)])
    units = rows + cols + boxes  # 0-8 rows, 9-17 cols, 18-26 boxes
    unit_of = [[] for _ in range(81)]
    for ui, u in enumerate(units):
        for cell in u:
            unit_of[cell].append(ui)
    peers = []
    for cell in range(81):
        s = set()
        for ui in unit_of[cell]:
            s.update(units[ui])
        s.discard(cell)
        peers.append(sorted(s))
    return rows, cols, boxes, units, unit_of, peers


ROWS, COLS, BOXES, UNITS, UNIT_OF, PEERS = _build_topology()
PEER_SETS = [set(p) for p in PEERS]
ROW_OF = [i // 9 for i in range(81)]
COL_OF = [i % 9 for i in range(81)]
BOX_OF = [(i // 9 // 3) * 3 + (i % 9) // 3 for i in range(81)]

POPCOUNT = [bin(m).count("1") for m in range(1 << 10)]


def bits(mask: int):
    return [d for d in range(1, 10) if mask >> d & 1]


# ---------------------------------------------------------------- technique table

@dataclass(frozen=True)
class Technique:
    key: str
    rating: float
    weight: int
    ordinal: int


_T = [
    ("fullHouse", 1.0, 4),
    ("hiddenSingleBox", 1.2, 14),
    ("hiddenSingleLine", 1.5, 15),
    ("directPointing", 1.7, 20),
    ("directHiddenPair", 2.0, 25),
    ("nakedSingle", 2.3, 4),
    ("directHiddenTriple", 2.5, 35),
    ("pointing", 2.6, 50),
    ("claiming", 2.8, 50),
    ("nakedPair", 3.0, 60),
    ("xWing", 3.2, 100),
    ("hiddenPair", 3.4, 70),
    ("nakedTriple", 3.6, 80),
    ("swordfish", 3.8, 140),
    ("hiddenTriple", 4.0, 100),
    ("xyWing", 4.2, 160),
    ("xyzWing", 4.4, 180),
    ("nakedQuad", 5.0, 130),
    ("jellyfish", 5.2, 470),
    ("hiddenQuad", 5.4, 150),
    ("turbotFish", 6.6, 140),
]
TECHNIQUES = {k: Technique(k, r, w, i) for i, (k, r, w) in enumerate(_T)}
TECHNIQUE_ORDER = [TECHNIQUES[k] for k, _, _ in _T]


# ---------------------------------------------------------------- state


@dataclass
class SolveStep:
    technique: str
    rating: float
    weight: int
    placement: tuple | None            # (cell, digit) или None
    eliminations: tuple                # tuple[(cell, digit)]
    premises: tuple                    # клетки, состояние которых использовалось
    produced: tuple                    # клетки, состояние которых изменилось


class Grid:
    __slots__ = ("values", "cands")

    def __init__(self, puzzle: str):
        self.values = [0] * 81
        self.cands = [0] * 81
        for i, ch in enumerate(puzzle):
            if ch.isdigit() and ch != "0":
                self.values[i] = int(ch)
        for i in range(81):
            if self.values[i]:
                continue
            m = FULL_MASK
            for p in PEERS[i]:
                v = self.values[p]
                if v:
                    m &= ~(1 << v)
            self.cands[i] = m

    def place(self, cell: int, digit: int) -> list[int]:
        self.values[cell] = digit
        self.cands[cell] = 0
        touched = [cell]
        bit = 1 << digit
        for p in PEERS[cell]:
            if self.cands[p] & bit:
                self.cands[p] &= ~bit
                touched.append(p)
        return touched

    def solved(self) -> bool:
        return all(self.values)

    def contradiction(self) -> bool:
        for i in range(81):
            if not self.values[i] and not self.cands[i]:
                return True
        for u in UNITS:
            seen = 0
            for c in u:
                v = self.values[c]
                if v:
                    b = 1 << v
                    if seen & b:
                        return True
                    seen |= b
            missing = FULL_MASK & ~seen
            avail = 0
            for c in u:
                avail |= self.cands[c]
            if missing & ~avail:
                return True
        return False


# ---------------------------------------------------------------- techniques
# Каждая функция возвращает SolveStep или None. Порядок обхода фиксирован.


def t_full_house(g: Grid):
    for u in UNITS:
        empty = [c for c in u if not g.values[c]]
        if len(empty) == 1:
            cell = empty[0]
            m = g.cands[cell]
            if POPCOUNT[m] == 1:
                d = bits(m)[0]
                return _placement_step("fullHouse", g, cell, d, u)
    return None


def _hidden_single(g: Grid, unit_ids, key):
    for ui in unit_ids:
        u = UNITS[ui]
        placed = 0
        for c in u:
            if g.values[c]:
                placed |= 1 << g.values[c]
        for d in range(1, 10):
            if placed >> d & 1:
                continue
            spots = [c for c in u if g.cands[c] >> d & 1]
            if len(spots) == 1:
                return _placement_step(key, g, spots[0], d, u)
    return None


def t_hidden_single_box(g: Grid):
    return _hidden_single(g, range(18, 27), "hiddenSingleBox")


def t_hidden_single_line(g: Grid):
    return _hidden_single(g, range(0, 18), "hiddenSingleLine")


def t_naked_single(g: Grid):
    for cell in range(81):
        if g.values[cell]:
            continue
        if POPCOUNT[g.cands[cell]] == 1:
            d = bits(g.cands[cell])[0]
            return _placement_step("nakedSingle", g, cell, d, PEERS[cell])
    return None


def _placement_step(key, g: Grid, cell, digit, premise_cells):
    t = TECHNIQUES[key]
    return SolveStep(
        technique=key, rating=t.rating, weight=t.weight,
        placement=(cell, digit), eliminations=(),
        premises=tuple(sorted(set(premise_cells) | {cell})),
        produced=(),
    )


def _elim_step(key, elims, premises):
    t = TECHNIQUES[key]
    return SolveStep(
        technique=key, rating=t.rating, weight=t.weight,
        placement=None, eliminations=tuple(sorted(set(elims))),
        premises=tuple(sorted(set(premises))), produced=(),
    )


# ---------------------------------------------------------------- «прямые» техники
#
# В Sudoku Explainer исключение, которое СРАЗУ открывает скрытого одиночку,
# стоит дешевле того же исключения самого по себе: игрок не держит в голове
# отложенный вывод, он видит цифру немедленно. Отсюда 1.7 против 2.6 у
# Pointing и 2.0 против 3.4 у Hidden Pair.
#
# Проверка простая: на момент вызова скрытых одиночек на доске нет — техники
# 1.2 и 1.5 отработали раньше. Значит если после исключений одиночка появился,
# его открыли именно эти исключения.


def _hidden_single_in(cands, values, unit_ids=None):
    """Первый скрытый одиночка или None. `unit_ids` сужает поиск."""
    for ui in (range(27) if unit_ids is None else unit_ids):
        u = UNITS[ui]
        placed = 0
        for c in u:
            if values[c]:
                placed |= 1 << values[c]
        for d in range(1, 10):
            if placed >> d & 1:
                continue
            spots = [c for c in u if cands[c] >> d & 1]
            if len(spots) == 1:
                return spots[0], d
    return None


def _direct(g: Grid, elims, key, premises):
    """Шаг-«прямая», если исключения открывают одиночку. Возвращает ПОСТАНОВКУ:
    именно немедленный результат отличает эту технику от обычной."""
    trial = list(g.cands)
    touched = set()
    for c, d in elims:
        trial[c] &= ~(1 << d)
        touched |= set(UNIT_OF[c])
    # Одиночку ищем только там, где исключения реально что-то изменили:
    # иначе техника присваивает себе чужой вывод и рейтинг падает ниже SE.
    found = _hidden_single_in(trial, g.values, sorted(touched))
    if found is None:
        return None
    cell, digit = found
    return _placement_step(key, g, cell, digit, list(premises))


def _intersections(g: Grid, box_only: bool = False):
    """Общий обход для Pointing и Claiming: (исключения, посылки)."""
    for b in range(9):
        box = BOXES[b]
        for d in range(1, 10):
            spots = [c for c in box if g.cands[c] >> d & 1]
            if len(spots) < 2:
                continue
            rs = {ROW_OF[c] for c in spots}
            cs = {COL_OF[c] for c in spots}
            if len(rs) == 1:
                line = ROWS[next(iter(rs))]
            elif len(cs) == 1:
                line = COLS[next(iter(cs))]
            else:
                continue
            elims = [(c, d) for c in line if BOX_OF[c] != b and g.cands[c] >> d & 1]
            if elims:
                yield elims, spots + [c for c, _ in elims]
    if box_only:
        return
    for li in range(18):
        line = UNITS[li]
        for d in range(1, 10):
            spots = [c for c in line if g.cands[c] >> d & 1]
            if len(spots) < 2:
                continue
            bs = {BOX_OF[c] for c in spots}
            if len(bs) != 1:
                continue
            b = next(iter(bs))
            elims = [(c, d) for c in BOXES[b] if c not in line and g.cands[c] >> d & 1]
            if elims:
                yield elims, spots + [c for c, _ in elims]


def t_direct_pointing(g: Grid):
    for elims, premises in _intersections(g, box_only=True):
        step = _direct(g, elims, "directPointing", premises)
        if step is not None:
            return step
    return None


def _direct_hidden_subset(g: Grid, size, key):
    for u in UNITS:
        free = [d for d in range(1, 10)
                if not any(g.values[c] == d for c in u)]
        for combo in combinations(free, size):
            spots = set()
            ok = True
            for d in combo:
                places = [c for c in u if g.cands[c] >> d & 1]
                if not places:
                    ok = False
                    break
                spots |= set(places)
            if not ok or len(spots) != size:
                continue
            mask = 0
            for d in combo:
                mask |= 1 << d
            elims = []
            for c in spots:
                extra = g.cands[c] & ~mask
                if extra:
                    elims += [(c, d) for d in bits(extra)]
            if not elims:
                continue
            step = _direct(g, elims, key, list(spots) + [c for c, _ in elims])
            if step is not None:
                return step
    return None


def t_direct_hidden_pair(g: Grid):
    return _direct_hidden_subset(g, 2, "directHiddenPair")


def t_direct_hidden_triple(g: Grid):
    return _direct_hidden_subset(g, 3, "directHiddenTriple")


def t_pointing(g: Grid):
    for b in range(9):
        box = BOXES[b]
        for d in range(1, 10):
            spots = [c for c in box if g.cands[c] >> d & 1]
            if len(spots) < 2:
                continue
            rs = {ROW_OF[c] for c in spots}
            cs = {COL_OF[c] for c in spots}
            if len(rs) == 1:
                line = ROWS[next(iter(rs))]
            elif len(cs) == 1:
                line = COLS[next(iter(cs))]
            else:
                continue
            elims = [(c, d) for c in line if BOX_OF[c] != b and g.cands[c] >> d & 1]
            if elims:
                return _elim_step("pointing", elims, spots + [c for c, _ in elims])
    return None


def t_claiming(g: Grid):
    for li in range(18):
        line = UNITS[li]
        for d in range(1, 10):
            spots = [c for c in line if g.cands[c] >> d & 1]
            if len(spots) < 2:
                continue
            bs = {BOX_OF[c] for c in spots}
            if len(bs) != 1:
                continue
            b = next(iter(bs))
            elims = [(c, d) for c in BOXES[b]
                     if c not in line and g.cands[c] >> d & 1]
            if elims:
                return _elim_step("claiming", elims, spots + [c for c, _ in elims])
    return None


def _naked_subset(g: Grid, size, key):
    for u in UNITS:
        cells = [c for c in u if not g.values[c] and 2 <= POPCOUNT[g.cands[c]] <= size]
        if len(cells) <= size:
            continue
        for combo in combinations(cells, size):
            m = 0
            for c in combo:
                m |= g.cands[c]
            if POPCOUNT[m] != size:
                continue
            elims = []
            for c in u:
                if c in combo or g.values[c]:
                    continue
                inter = g.cands[c] & m
                if inter:
                    elims += [(c, d) for d in bits(inter)]
            if elims:
                return _elim_step(key, elims, list(combo) + [c for c, _ in elims])
    return None


def _hidden_subset(g: Grid, size, key):
    for u in UNITS:
        pos = {}
        for d in range(1, 10):
            spots = [c for c in u if g.cands[c] >> d & 1]
            if 0 < len(spots) <= size:
                pos[d] = spots
        if len(pos) < size:
            continue
        for combo in combinations(sorted(pos), size):
            cells = set()
            for d in combo:
                cells.update(pos[d])
            if len(cells) != size:
                continue
            keep = 0
            for d in combo:
                keep |= 1 << d
            elims = []
            for c in sorted(cells):
                extra = g.cands[c] & ~keep
                if extra:
                    elims += [(c, d) for d in bits(extra)]
            if elims:
                return _elim_step(key, elims, sorted(cells))
    return None


def t_naked_pair(g):   return _naked_subset(g, 2, "nakedPair")
def t_naked_triple(g): return _naked_subset(g, 3, "nakedTriple")
def t_naked_quad(g):   return _naked_subset(g, 4, "nakedQuad")
def t_hidden_pair(g):   return _hidden_subset(g, 2, "hiddenPair")
def t_hidden_triple(g): return _hidden_subset(g, 3, "hiddenTriple")
def t_hidden_quad(g):   return _hidden_subset(g, 4, "hiddenQuad")


def _fish(g: Grid, size, key):
    for d in range(1, 10):
        for base_is_row in (True, False):
            base_units = ROWS if base_is_row else COLS
            lines = []
            for li in range(9):
                spots = [c for c in base_units[li] if g.cands[c] >> d & 1]
                if 2 <= len(spots) <= size:
                    lines.append((li, spots))
            if len(lines) < size:
                continue
            for combo in combinations(lines, size):
                cover = set()
                for _, spots in combo:
                    for c in spots:
                        cover.add(COL_OF[c] if base_is_row else ROW_OF[c])
                if len(cover) != size:
                    continue
                base_ids = {li for li, _ in combo}
                elims = []
                for x in sorted(cover):
                    cross = COLS[x] if base_is_row else ROWS[x]
                    for c in cross:
                        line_id = ROW_OF[c] if base_is_row else COL_OF[c]
                        if line_id in base_ids:
                            continue
                        if g.cands[c] >> d & 1:
                            elims.append((c, d))
                if elims:
                    prem = [c for _, spots in combo for c in spots]
                    return _elim_step(key, elims, prem + [c for c, _ in elims])
    return None


def t_x_wing(g):    return _fish(g, 2, "xWing")
def t_swordfish(g): return _fish(g, 3, "swordfish")
def t_jellyfish(g): return _fish(g, 4, "jellyfish")


def t_xy_wing(g: Grid):
    bival = [c for c in range(81) if not g.values[c] and POPCOUNT[g.cands[c]] == 2]
    bival_set = set(bival)
    for pivot in bival:
        a, b = bits(g.cands[pivot])
        wings = [c for c in PEERS[pivot] if c in bival_set]
        for i in range(len(wings)):
            for j in range(i + 1, len(wings)):
                w1, w2 = wings[i], wings[j]
                m1, m2 = g.cands[w1], g.cands[w2]
                if m1 == m2:
                    continue
                for x, y in ((a, b), (b, a)):
                    if not (m1 >> x & 1) or (m1 >> y & 1):
                        continue
                    if not (m2 >> y & 1) or (m2 >> x & 1):
                        continue
                    cm = m1 & m2 & ~((1 << x) | (1 << y))
                    if POPCOUNT[cm] != 1:
                        continue
                    z = bits(cm)[0]
                    elims = [(c, z) for c in sorted(PEER_SETS[w1] & PEER_SETS[w2])
                             if c != pivot and g.cands[c] >> z & 1]
                    if elims:
                        return _elim_step("xyWing", elims,
                                          [pivot, w1, w2] + [c for c, _ in elims])
    return None


def t_xyz_wing(g: Grid):
    for pivot in range(81):
        if g.values[pivot] or POPCOUNT[g.cands[pivot]] != 3:
            continue
        wings = [c for c in PEERS[pivot]
                 if not g.values[c] and POPCOUNT[g.cands[c]] == 2
                 and g.cands[c] & ~g.cands[pivot] == 0]
        for i in range(len(wings)):
            for j in range(i + 1, len(wings)):
                w1, w2 = wings[i], wings[j]
                if g.cands[w1] == g.cands[w2]:
                    continue
                cm = g.cands[w1] & g.cands[w2]
                if POPCOUNT[cm] != 1:
                    continue
                if g.cands[w1] | g.cands[w2] != g.cands[pivot]:
                    continue
                z = bits(cm)[0]
                seers = PEER_SETS[pivot] & PEER_SETS[w1] & PEER_SETS[w2]
                elims = [(c, z) for c in sorted(seers) if g.cands[c] >> z & 1]
                if elims:
                    return _elim_step("xyzWing", elims,
                                      [pivot, w1, w2] + [c for c, _ in elims])
    return None


def t_turbot_fish(g: Grid):
    """Обобщённый turbot fish: сильная связь - слабая связь - сильная связь.
    Покрывает Skyscraper, Two-String Kite и часть Empty Rectangle."""
    for d in range(1, 10):
        links = []
        for ui in range(27):
            spots = [c for c in UNITS[ui] if g.cands[c] >> d & 1]
            if len(spots) == 2:
                links.append(tuple(spots))
        n = len(links)
        for i in range(n):
            for j in range(i + 1, n):
                for a, b in ((links[i][0], links[i][1]), (links[i][1], links[i][0])):
                    for c, e in ((links[j][0], links[j][1]), (links[j][1], links[j][0])):
                        if len({a, b, c, e}) != 4:
                            continue
                        if c not in PEER_SETS[b]:          # слабая связь b - c
                            continue
                        if e in PEER_SETS[a]:              # иначе это просто сильная связь
                            continue
                        seers = PEER_SETS[a] & PEER_SETS[e]
                        elims = [(x, d) for x in sorted(seers)
                                 if x not in (b, c) and g.cands[x] >> d & 1]
                        if elims:
                            return _elim_step("turbotFish", elims,
                                              [a, b, c, e] + [x for x, _ in elims])
    return None


TECHNIQUE_FUNCS = [
    ("fullHouse", t_full_house),
    ("hiddenSingleBox", t_hidden_single_box),
    ("hiddenSingleLine", t_hidden_single_line),
    ("directPointing", t_direct_pointing),
    ("directHiddenPair", t_direct_hidden_pair),
    ("nakedSingle", t_naked_single),
    ("directHiddenTriple", t_direct_hidden_triple),
    ("pointing", t_pointing),
    ("claiming", t_claiming),
    ("nakedPair", t_naked_pair),
    ("xWing", t_x_wing),
    ("hiddenPair", t_hidden_pair),
    ("nakedTriple", t_naked_triple),
    ("swordfish", t_swordfish),
    ("hiddenTriple", t_hidden_triple),
    ("xyWing", t_xy_wing),
    ("xyzWing", t_xyz_wing),
    ("nakedQuad", t_naked_quad),
    ("jellyfish", t_jellyfish),
    ("hiddenQuad", t_hidden_quad),
    ("turbotFish", t_turbot_fish),
]
assert [k for k, _ in TECHNIQUE_FUNCS] == [k for k, _, _ in _T]


# ---------------------------------------------------------------- rater

@dataclass
class SolveTrace:
    status: str                      # solved | contradiction | unsolvable
    steps: list = field(default_factory=list)
    se_rating: float = 0.0
    work_score: int = 0
    dependency_depth: int = 0
    techniques: list = field(default_factory=list)


def solve_human(puzzle: str, max_steps: int = 400) -> SolveTrace:
    g = Grid(puzzle)
    steps: list[SolveStep] = []
    while len(steps) < max_steps:
        if g.solved():
            return _finish("solved", steps)
        if g.contradiction():
            return _finish("contradiction", steps)
        step = None
        for _, fn in TECHNIQUE_FUNCS:
            step = fn(g)
            if step is not None:
                break
        if step is None:
            return _finish("unsolvable", steps)
        if step.placement:
            cell, digit = step.placement
            touched = g.place(cell, digit)
            step.produced = tuple(touched)
        else:
            touched = []
            for cell, d in step.eliminations:
                g.cands[cell] &= ~(1 << d)
                touched.append(cell)
            step.produced = tuple(sorted(set(touched)))
        steps.append(step)
    return _finish("unsolvable", steps)


def _finish(status: str, steps: list[SolveStep]) -> SolveTrace:
    tr = SolveTrace(status=status, steps=steps)
    if not steps:
        return tr
    tr.se_rating = max(s.rating for s in steps)
    tr.work_score = sum(s.weight for s in steps)
    tr.techniques = sorted({s.technique for s in steps},
                           key=lambda k: TECHNIQUES[k].ordinal)
    # dependencyDepth: длина самой длинной цепочки step -> step
    depth = [1] * len(steps)
    for i, s in enumerate(steps):
        prem = set(s.premises)
        best = 0
        for j in range(i):
            if prem & set(steps[j].produced):
                if depth[j] > best:
                    best = depth[j]
        depth[i] = best + 1
    tr.dependency_depth = max(depth)
    return tr


# ---------------------------------------------------------------- exact solver

def count_solutions(puzzle, limit: int = 2):
    """Подсчёт решений (до limit) битмаск-перебором с MRV."""
    values = [0] * 81
    cands = [FULL_MASK] * 81
    if isinstance(puzzle, str):
        seq = [0 if ch in ".0" else int(ch) for ch in puzzle]
    else:
        seq = list(puzzle)

    def assign(vals, cds, cell, d) -> bool:
        vals[cell] = d
        cds[cell] = 0
        bit = 1 << d
        for p in PEERS[cell]:
            if cds[p] & bit:
                cds[p] &= ~bit
                if not vals[p] and not cds[p]:
                    return False
        return True

    for i, d in enumerate(seq):
        if d and not assign(values, cands, i, d):
            return 0, None

    found = []

    def rec(vals, cds):
        if len(found) >= limit:
            return
        best, best_n = -1, 10
        for i in range(81):
            if vals[i]:
                continue
            n = POPCOUNT[cds[i]]
            if n == 0:
                return
            if n < best_n:
                best, best_n = i, n
                if n == 1:
                    break
        if best < 0:
            found.append("".join(str(v) for v in vals))
            return
        for d in bits(cds[best]):
            nv, nc = vals[:], cds[:]
            if assign(nv, nc, best, d):
                rec(nv, nc)
                if len(found) >= limit:
                    return

    rec(values, cands)
    return len(found), (found[0] if found else None)


def has_unique_solution(puzzle) -> bool:
    n, _ = count_solutions(puzzle, limit=2)
    return n == 1
