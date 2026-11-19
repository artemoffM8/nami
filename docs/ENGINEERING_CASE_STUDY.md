# NAMI — Engineering Case Study

> A native iOS Sudoku experience designed around learning and clarity rather than pressure-driven engagement.

**Repository:** [NAMI](../README.md) · **Screenshots:** [README gallery](../README.md) · **Project status:** [PROJECT_STATUS.md](../PROJECT_STATUS.md)

## At a glance

| Dimension | Implementation |
|---|---|
| Platform | iOS 18+, Swift 5, SwiftUI, SwiftData |
| Core algorithm | Human-style Sudoku solver covering 21 techniques |
| Architecture | Foundation-only domain, separate persistence and experience modules |
| Data integrity | Append-only command journal with deterministic replay |
| Scoring | Integer-only arithmetic with explicit rounding |
| Quality controls | Documented 176 tests and 2,913 project-verifier checks (repository-reported figures; re-run to confirm) |
| Localization | English and Russian |

## Product problem

Many puzzle apps optimize for urgency, streak retention, and competition. NAMI explores a different product experience: layered hints, a curriculum of solving techniques, and progress that does not punish taking a break.

The technical challenge is to make those mechanics consistent and explainable. A hint, a difficulty rating, and a training drill must agree about *why* a particular move is justified.

## Engineering decisions

### 1. One solver for difficulty and teaching

The domain solver models 21 human techniques. Difficulty reflects the hardest technique needed by a puzzle, rather than an opaque brute-force score. The same solver advances catalog puzzles to reachable positions for technique drills, reducing disagreement between assessment and instruction.

The repository documents checks against a 501-puzzle deduction set and a 345-puzzle catalog, alongside a Python reference implementation. These are project-reported validation results, not independently reproduced measurements in this case study.

### 2. Deterministic scoring

Scoring uses integer arithmetic and a defined rounding rule to avoid floating-point drift across environments. The design also normalizes rewards by puzzle density and penalizes confirmed mistakes more than a single move can reward.

**Trade-off:** this requires more explicit accounting logic, but makes score behavior reproducible and testable.

### 3. An append-only journal for game integrity

Persisting the board and score independently can leave them inconsistent after an interrupted write. NAMI instead records player commands transactionally and derives the current state through replay. Undo can restore not just digits but the associated notes and scoring consequences.

**Trade-off:** replay and journal invariants add complexity, but establish one source of truth.

### 4. A verifier for silent project failures

The project includes a Python verifier for errors that ordinary runtime tests may miss: unregistered test files, incomplete replay handling, missing sound assets, and non-deterministic effects.

This is an example of converting discovered failure modes into repeatable checks rather than relying only on manual review.

## Architecture

```text
SwiftUI application
   |-- NamiExperience: presentation, sound, effects
   |-- NamiData: SwiftData persistence
   `-- NamiDomain: solver, rating, scoring, journal, training
          (Foundation-only domain logic)
```

The domain returns localization keys instead of UI strings, keeping the core logic independent of presentation and language.

## Demonstration

See the [five-screen screenshot gallery](../README.md) for the home screen, puzzle board, layered hints, technique curriculum, and training drill.

For local evaluation, follow the [build and verification instructions](../README.md#building) in the main README. An Apple development environment is required for an iOS build; no hosted demo or App Store release is claimed here.

## What this project demonstrates

- Translating a product philosophy into concrete, testable mechanics
- Algorithm design and explainable behavior
- Separation of domain, persistence, and presentation
- Deterministic state management and crash-consistency thinking
- Engineering quality practices beyond a conventional unit-test suite

## Limitations and next steps

This document describes repository-documented implementation and checks. It does not claim independent execution of the iOS app or verification suite. For current issues and roadmap, consult [PROJECT_STATUS.md](../PROJECT_STATUS.md).

---

*Technical details and source code remain in the [main repository](../README.md).*
