> 🇷🇺 Русская версия: [README.ru.md](README.ru.md)

# NAMI

An anxiety-free Sudoku for iOS: no streaks that reset, no timer in your face,
no global leaderboards. Instead — a clarity rating, technique training, and a
calendar that can only grow.

SwiftUI + SwiftData, iOS 18+, Swift 5. Localized in English and Russian.

---

## What's interesting here, engineering-wise

The app is built around three problems, each of which turned out to be harder
than it looks.

### A difficulty rating you can trust

The solver reproduces 21 human techniques — from `fullHouse` to `turbotFish`,
including the three "direct" variants from Sudoku Explainer. It doesn't
brute-force: it deduces, and a puzzle's rating equals the difficulty of the
hardest technique the puzzle required.

Verified by two properties, not by agreement with someone else's program:

- **correctness** — not a single wrong deduction across 501 puzzles;
- **tightness** — not a single overestimated rating across the 345-puzzle catalog.

A reference implementation in Python is kept line-for-line with the Swift
version and guarded by a regression test. The academic anchor is Pelánek's
survey (arXiv 1403.7373), which shows technique-based ratings correlate with
real solvers' times at about 0.69 — which is why the app has a telemetry seam
for recalibrating the `SE → D` mapping on real data.

### Scoring that matches bit for bit

Not a single `Double` on the path to the final score. Floating-point
arithmetic can drift in the last digit across devices and compiler versions,
and a leaderboard must match exactly — so all scoring is integer-only with a
single `roundHalfUp` rounding.

The score budget is normalized by the number of empty cells: puzzles with
different given densities are otherwise incomparable. The budget remainder is
distributed by **award order**, not by cell index — otherwise a player could
hoard known "expensive" cells for a high multiplier.

The penalty for a confirmed mistake is, by construction, larger than the
maximum reward for a single move, so guessing digits has negative expected
value. This is enforced by a test, not by an argument.

### A journal instead of two snapshots

The board and the score are projections of a single append-only history. They
used to be saved separately, and a crash between the two writes left them at
different moments of the game: the digit is on the board, the points for it
are not. There was nothing to notice it with.

A player command is written in one transaction. States legitimately diverge
inside a command, so the unit of disk write is the command, not the event —
expressed in the API by a type, not by a comment. Undo restores exactly,
including notes removed by auto-reduction: the journal records intent, and
replay drives the same `MoveHistory` as a live game.

### Training on real positions

A drill isn't generated from a random grid. The solver runs a catalog puzzle
up to the first moment the studied technique is required — that board state
is the exercise. The position is guaranteed to be reachable, the puzzle is
verified to have a unique solution, and "the technique is required here" is
decided by the same code that rates difficulty in the game.

---

## Structure

| Module | Lines | Contents |
|---|---:|---|
| `Packages/NamiDomain` | 3,591 | Solver, rating, scoring, journal, dojo. Foundation only |
| `Packages/NamiData` | 925 | SwiftData models and repositories |
| `Packages/NamiExperience` | 1,801 | Themes, sound, effects, animations |
| `App/Sources` | 5,023 | Screens and orchestration |
| Tests | 1,625 | 139 tests, all in the domain |

The domain knows nothing about UI, storage, or localization: it returns
string keys, and the text lives in the app.

---

## Verification

```bash
python3 Tools/generate_xcodeproj.py   # the project is generated, never hand-edited
python3 Tools/verify_project.py       # 2,903 checks, ~2 s
```

The verifier is not a linter. It hosts checks for classes of errors **that
don't crash** and therefore evade tests:

- a test file exists on disk but isn't included in the project — tests "pass" without running;
- a forgotten `case` in `replay()` silently drops part of the history;
- a live RNG in effect rendering breaks frame reproducibility;
- a missing sound-kit file manifests only as silence;
- a technique in the curriculum with no material in the catalog;
- five score-integrity invariants found in review.

Every one of these checks appeared after a real defect, not in advance.

---

## Assets

The catalog is 345 puzzles with SE ratings, technique annotations and expected
solve times. The audio is synthesized in code (FM synthesis, Karplus–Strong,
Schroeder reverb) and is licensing-clean. Three themed sound kits are stored
as CAF/ALAC: lossless 4× compression, 55 → 14 MB, PCM verified byte-for-byte.
AAC won't do here — it adds priming silence and breaks seamless loops.

---

## Status

Runs on device. Known issues, next steps, and approaches tried and rejected
are in [PROJECT_STATUS.md](PROJECT_STATUS.md) (in Russian).

## Building

Requires Xcode 26 and the iOS 18 SDK.

```bash
python3 Tools/generate_xcodeproj.py   # the project is generated by a script
open NamiApp.xcodeproj
```

No signing is needed for the simulator. To build for a device, provide your
own development team — it is intentionally absent from the repository:

```bash
export NAMI_DEVELOPMENT_TEAM=XXXXXXXXXX
python3 Tools/generate_xcodeproj.py
```

## License

© 2026 artemoffM8. Source published for reference; see [LICENSE](LICENSE).
