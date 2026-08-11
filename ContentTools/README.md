# ContentTools

Генерация и рейтинг каталога выполняются ТОЛЬКО здесь. В iOS-таргет попадает
лишь runtime-часть `HumanSolver`: тяжёлый rater на устройстве не запускается
(раздел 13.3 ТЗ).

## python/

- `nami_sudoku.py` — **эталонная** реализация human-style солвера и rater-а,
  версия `nami-human-1`. Swift-порт в `Packages/NamiDomain/.../HumanSolver.swift`
  построчно совпадает с ним; расхождение ловит `SolverRegressionTests`.
- `generate_catalog.py` — полный пайплайн: решение → симметричное удаление →
  проверка единственности → рейтинг → отбрасывание перебора → JSON.

```bash
python3 generate_catalog.py --out ../../App/Resources/Puzzles/classic.json --budget 120
```

## Sources/ContentRaterCLI/ — не реализовано

По ТЗ здесь должен жить macOS/CLI-инструмент, сверяющий `seRating`
с закреплённой версией SukakuExplainer на эталонном наборе.
Сейчас источником истины является Python-реализация выше.

Чтобы закрыть требование ТЗ «SE Rating совпадает с эталонным rater-ом»
(критерий приёмки 3), нужно:

1. взять SukakuExplainer v1.17.8 (Java) и прогнать им 200–500 задач;
2. сравнить с `nami_sudoku.solve_human`;
3. либо подтвердить совпадение, либо подстроить таблицу техник
   (`_T` в `nami_sudoku.py` и `SudokuTechnique` в Swift — они обязаны
   меняться синхронно) и выпустить новый `raterVersion`.

Java-зависимость в iOS-приложение не попадает: сверка нужна только
на этапе сборки каталога.
