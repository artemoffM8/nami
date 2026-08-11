# NOVEMI — система очков за партию v1

Статус: готово к прототипу в Xcode и закрытому TestFlight.  
Связанный документ: `NAMI_Sudoku_iOS_TZ_v2.md`.  
Версия формулы: `novemi-session-score-v1`.

## 1. Продуктовое решение

NOVEMI хранит три разных результата и никогда не смешивает их в одно число:

1. **Счёт партии (`SessionScore`)** — живые очки текущей головоломки. Именно здесь
   работают серия, множитель, штрафы и положительный бонус темпа.
2. **Рейтинг ясности (`R`, `deltaR`)** — долгосрочная оценка мастерства из
   основного ТЗ. Его по-прежнему определяют сложность и самостоятельность, а не
   размер аркадного счёта.
3. **Ранг** — устойчивое отображение рейтинга с подтверждением перехода тремя
   результатами. Счёт партии не покупает ранг и не является валютой.

Для Daily итоговый `SessionScore` становится единственным видимым Daily Score
новой версии. Старая формула `10000 - time - penalties` не пересчитывается:
новый алгоритм получает новый `dailyScoreVersion` и отдельный leaderboard.

### Неподвижные принципы

- правильный ход нельзя объявлять угадыванием только потому, что он не совпал с
  текущим trace `HumanSolver`;
- подтверждённая ошибка — только видимо проверенное несовпадение с каноническим
  решением;
- медленный игрок не теряет очки из-за времени;
- скорость даёт только положительный бонус и только в заранее выбранном
  испытании или Daily;
- множитель не уменьшается от паузы или долгого размышления;
- Reveal делает результат тренировочным, но не отнимает уже заработанные очки;
- очки, рейтинг и UI-анимации вычисляются разными слоями;
- одна цифра, одна группа и одна ошибочная пара награждаются/штрафуются не более
  одного раза;
- итог и его четыре строки всегда сходятся арифметически.

## 2. Важное ограничение режима «Бумага»

Если счётчик реагирует только на правильную цифру, он косвенно выполняет
автопроверку. Поэтому живое подтверждение правильности нельзя тайно включать в
чистом профиле «Бумага».

Используются две политики:

| Политика | Где | Когда меняется счёт и множитель |
|---|---|---|
| `immediateValidated` | Assistant с auto-check, явно выбранный Flow/Scored Challenge и одинаковый для всех Daily | сразу после подтверждённого ввода |
| `deferredValidation` | «Бумага» и Focus без сравнения с решением | одним пакетом после явного Check или завершения |

В `deferredValidation` HUD показывает только уже подтверждённые очки и нейтральную
точку ожидания. По тапу доступно объяснение: «5 ходов будут учтены после проверки
или завершения». Он не сообщает, какие из этих ходов правильны.

Выбор `immediateValidated` до показа поля явно называется «Живой счёт с
проверкой». Он записывает то же `validationAid`, что и автоматическая проверка
Assistant; система не выдаёт эту помощь за полностью самостоятельную игру.
Flow/Scored Challenge может иметь отдельный leaderboard, но его SessionScore
никогда напрямую не превращается в рейтинг `R`.

При Check reducer атомарно применяет единый validation batch: списывает цену и
сбрасывает прежнюю неподтверждённую серию, затем обрабатывает только текущие
неснятые размещения по `commitSequence`. Каждая новая подтверждённая ошибка
получает свой штраф и сбрасывает серию в своей позиции; последующие правильные
ходы могут построить новую. Весь Check создаёт не более одного
`confirmedErrorStrike`. В интерфейсе пакет показывается одной сводкой, а не
очередью анимаций.

Скрытая ошибочная цифра, исправленная до Check, не создаёт
`confirmedErrorStrike` и не получает штраф: приложение не показывало игроку
результат сравнения.

## 3. Нормализованная база очков

Количество исходно пустых клеток различается, поэтому фиксированные `100 очков
за цифру` делают пазлы несопоставимыми. NOVEMI выделяет каждой задаче общий
placement budget.

```text
D = внутренний рейтинг задачи, обычно 600...2400
ratingDelta = clamp(D - 600, 0, 1800)
factorNum = 1_800_000 + 350 * ratingDelta
factorDen = 1_800_000
N = количество исходно пустых клеток

scaled(x) = roundHalfUp(x * factorNum / factorDen)
B = scaled(4000)

q = B div N
r = B mod N

cellBase(k) = q + 1, если awardOrdinal k < r
              q,     в остальных случаях
```

`awardOrdinal` — номер впервые награждаемой клетки `0...N-1` по порядку
подтверждения, а не абсолютный индекс клетки. Поэтому сумма базовых долей всегда
равна `B`, а игрок не может оставить заранее известные «дорогие» CellID до
высокого множителя. Reveal/auto-fill потребляет ordinal, но получает ноль.

Единое округление:

```text
roundHalfUp(a / b) = (a + b / 2) div b
```

Оно применяется ко всем неотрицательным рациональным значениям: `scaled`,
placement points, group/completion bonus, error/check/hint penalty и pace
bonus. Вычитание штрафов происходит уже после округления каждого domain event.

Отношение `factorNum/factorDen` увеличивает потенциальный результат за сложную
задачу, но `N` не позволяет получить лишние очки только из-за малого количества
givens.

Все вычисления в приложении целочисленные. Коэффициенты хранятся в permille и
basis points; `Float`/`Double` не используются как источник итогового счёта.

## 4. Живая серия и множитель

Серия увеличивается только после впервые подтверждённой правильной цифры.
Порог зависит от числа исходно пустых клеток, поэтому множитель достигает
максимума примерно после 60% чисто заполненного поля и не разгоняется раньше
только потому, что конкретная задача длиннее.

```text
streakAfter = streakBefore + 1
tier = min(10, floor(50 * streakAfter / (3 * N)))
multiplierPermille = 1000 + 100 * tier
placementPoints = roundHalfUp(
    cellBase(awardOrdinal) * multiplierPermille / 1000
)
```

Множитель меняется шагами ×0.10 и ограничен ×2.00. Например, при `N = 50`
ступени появляются примерно на сериях 3, 6, 9, 12, 15, 18, 21, 24, 27 и 30.
Reveal и автоматическое заполнение клетки дают за неё `0`.

Множитель никогда:

- не зависит от интервала между двумя ходами;
- не сгорает от размышления;
- не уменьшается из-за Pause;
- не получает отдельной валюты, energy или fever timer;
- не превышает ×2.00.

## 5. Бонусы за структуру

Помимо цифр начисляются два простых бонуса:

```text
groupBonus      = scaled(30)
completionBonus = scaled(400)
```

- `groupBonus` выдаётся один раз за каждую впервые подтверждённо завершённую
  строку, столбец или блок 3×3;
- бонус группы не умножается на серию, поэтому порядок заполнения нельзя
  использовать для фарма;
- один ход может завершить до трёх групп и получить сумму трёх бонусов, но UI
  объединяет их в одну реакцию;
- `completionBonus` выдаётся один раз при запечатанном `puzzleCompleted`;
- Undo/Erase не позволяют повторно получить бонус группы или завершения.

В режиме «Бумага» локально корректная, но не подтверждённая решением группа не
раскрывает скрытую правильность. Её бонус также откладывается до Check/финиша.

## 6. Штрафы

### 6.1. Подтверждённая ошибка

```text
errorPenalty = max(
    roundHalfUp(3 * B / 100),
    roundHalfUp(5 * B / (2 * N))
)
```

После ошибки:

- текущая серия становится `0`;
- множитель становится `×1.00`;
- первый и второй `confirmedErrorStrike` оставляют результат записываемым;
- третий `confirmedErrorStrike` переводит результат в `practice`: игру можно закончить, счёт
  продолжает работать для обратной связи, но personal best, Daily leaderboard и
  `deltaR` не меняются.

Штраф всегда сильнее максимальной награды `2.00 * cellBase` одного угаданного
хода и дополнительно сбрасывает серию. Перебор цифр поэтому имеет отрицательную
ожидаемую ценность.

Один Check с несколькими неверными клетками создаёт максимум один
`confirmedErrorStrike`, но отдельный `errorPenalty` за каждую новую уникальную
пару `(cell, digit)`. Все найденные пары сразу заносятся в `penalizedAttempts`;
UI объединяет сумму в один delta. Повтор той же пары или повторная доставка
события не штрафует ещё раз.

Простой `ruleConflict` сам по себе:

- не начисляет очки;
- не создаёт `confirmedErrorStrike`;
- не сбрасывает множитель;
- остаётся визуальным конфликтом до исправления.

Это нужно потому, что новая правильная цифра может конфликтовать с ранее
введённой ошибкой.

### 6.2. Ручная проверка

```text
checkPenalty = roundHalfUp(3 * B / 100)
```

- цена видна рядом с кнопкой до первого использования;
- Check тарифицируется только если `valueRevision` доски изменился;
- повторная проверка неизменившейся позиции бесплатна и отвечает «Уже
  проверено»;
- двойной tap с одним `checkID` идемпотентен;
- при найденной ошибке дополнительно применяется правило подтверждённой ошибки;
- validation pipeline всегда имеет порядок `цена + reset → outcomes по
  commitSequence → группы`; ошибка внутри outcomes получает свой penalty/reset,
  поэтому последующие правильные ходы могут построить новую серию;
- в обязательном Perfect-профиле системная проверка является правилом режима и
  не получает `checkPenalty`.

### 6.3. Подсказка

Цена одного `HintSession` считается от `B`:

| Максимальный слой одной подсказки | Полная цена |
|---|---:|
| Область | 1.00% B |
| Название техники | 3.00% B |
| Объяснение и кандидаты | 6.00% B |
| Reveal | результат тренировочный |

При переходе внутри одной шторки с «Области» на «Технику» списывается только
разница до 3.00%. Повторное открытие уже оплаченного слоя бесплатно. Новая
подсказка для нового шага создаёт новый `HintSession` и новую цену.

Влияние на серию:

- область: `streak = floor(streak / 2)`;
- техника: `streak = 0`;
- объяснение: `streak = 0`;
- Reveal: `streak = 0`, целевая клетка получает `0`, результат становится
  тренировочным и нерейтинговым.

### 6.4. Кандидаты и «Линза»

Существующая помощь кандидатами входит в одну строку «Помощь», а не создаёт ещё
пять строк в результате.

| Максимальный фактически использованный слой | Цена за сессию |
|---|---:|
| Ручные заметки и автосокращение | 0 |
| Подсказка только на цифровой панели | 0.50% B |
| Линза выбранной клетки | 1.00% B |
| Постоянные кандидаты выбранной клетки | 2.00% B |
| Кандидаты всего поля | 5.00% B |

При повышении слоя списывается только разница между новым и уже оплаченным
уровнем. Кандидаты всего поля сбрасывают серию; остальные слои множитель не
меняют.

### 6.5. Нижняя граница и штрафной остаток

Reducer хранит знаковый `scoreBalance`, но основной HUD никогда не показывает
отрицательное итоговое число:

```text
scoreBalance = positivePoints - penaltyLedger
displayScore = max(0, scoreBalance)
```

Штраф не исчезает, если счёт пока равен нулю: иначе два первых перебора в начале
партии стали бы бесплатными. Это не скрывается от игрока. Если
`scoreBalance < 0`, delta-строка говорит, например: `Штрафной остаток −80`; по
тапу HUD доступно то же объяснение. Следующие очки сначала погашают остаток.

В penalty ledger записывается полный штраф. Итог при этом не может быть ниже
нуля. Если ledger больше всех положительных очков, суммирующая строка breakdown
использует только его эффективную часть до нуля, а непогашенный остаток
показывается отдельной несуммируемой подписью в «Подробнее».

## 7. Undo, Erase и защита от фарма

`SessionScore` является журналом подтверждённых достижений, а не функцией
текущей картинки доски.

- исходно пустая клетка награждается максимум один раз за сессию;
- правильный ввод → Erase/Undo → тот же правильный ввод не даёт новых очков и не
  увеличивает серию;
- подтверждённый штраф не отменяется Undo;
- скрытая ошибка Paper, не прошедшая Check, штрафом не является;
- строка/столбец/блок награждаются максимум один раз;
- Reveal навсегда добавляет клетку в `nonScoringCells`;
- повторный puzzle ID может быть решён для удовольствия, но не обновляет
  personal best, рейтинг или leaderboard;
- после `puzzleCompleted` reducer запечатывает результат и игнорирует новые
  scoring-события.

Такой ledger позволяет Undo оставаться полезным, но не превращает его в способ
перестраивать порядок множителей.

## 8. Положительный бонус темпа

Темп не влияет на живой множитель и рассчитывается только в финале.

```text
guard expectedActiveMs > 0 else paceRateBps = 0

scaledElapsed = checkedMultiply(eligibleElapsedMs, 1000)
timeRatioPermille = ceilDiv(scaledElapsed, expectedActiveMs)

paceRate =
    15%, если timeRatioPermille <= 700
    10%, если timeRatioPermille <= 850
     5%, если timeRatioPermille <= 1000
     0%, если timeRatioPermille > 1000

paceBonus = roundHalfUp(scoreBeforePace * paceRateBps / 10000)
finalScore = clamp(scoreBeforePace + paceBonus, 0, 999999)
```

`ceilDiv(a, b)` вычисляется через quotient/remainder, без потенциально
переполняющего `a + b - 1`. Для умножения используется checked/full-width
операция `UInt64`; overflow, нулевой `expectedActiveMs` или повреждённый catalog
делают только `paceBonus = 0` и добавляют integrity reason, но не мешают
завершить задачу.

`scoreBeforePace` уже включает цифры, группы, завершение и применённые штрафы.

Бонус возможен только:

- в `AgainstPersonalBest`, `TimedLimit` или Daily;
- без Reveal и третьего `confirmedErrorStrike`;
- без подтверждённых ошибок;
- без любого Manual Check;
- без любого Hint;
- без candidate aid выше `neutral`;
- при `speedEligible == true`.

Classic всегда получает `paceBonus = 0`. Медленное прохождение также получает
`0`, но никогда отрицательное значение.

В Against PB/Timed первое `gameSuspended` после старта делает
`speedEligible = false`, не отнимая основной счёт. В Daily пауза не
останавливает `challengeElapsed`: она просто не помогает времени.

Источник времени и правила старта остаются из основного ТЗ:

- monotonic active clock для Classic/Against PB/Timed;
- явная кнопка «Начать» для Daily;
- `Timer`/`TimelineView` только отображает производное значение и не считает
  очки tick-by-tick;
- изменение системных часов не меняет результат.

## 9. Итоговая формула и breakdown

```text
placementTotal  = сумма впервые начисленных placementPoints
structureTotal  = сумма groupBonus + completionBonus
positiveTotal   = placementTotal + structureTotal
penaltyLedger   = сумма назначенных штрафов
effectivePenalty = min(penaltyLedger, positiveTotal)
penaltyRemainder = penaltyLedger - effectivePenalty

scoreBeforePace = positiveTotal - effectivePenalty

paceBonus = eligible positive bonus
sessionScore = clamp(scoreBeforePace + paceBonus, 0, 999999)
```

Экран «Как начислено» содержит не более четырёх строк:

1. `Правильные цифры` — placementTotal;
2. `Строки, блоки и финиш` — structureTotal;
3. `Ошибки и помощь` — `-effectivePenalty`;
4. `Бонус темпа` — paceBonus, только когда режим его допускает.

Ниже отдельным блоком показывается `Рейтинг ясности +deltaR`. Он не входит в
сумму очков. Если `penaltyRemainder > 0`, «Подробнее» отдельно говорит
`Непогашенный штраф: N`; эта подпись не является пятой суммирующей строкой.

### Пример

Для задачи `D = 1200`, `N = 50`:

```text
F ≈ 1.1167
B = 4467
cellBase = 89 или 90
groupBonus = 34
completionBonus = 447
checkPenalty = 134
```

Правильная цифра на серии 10 получает примерно:

```text
M = 1 + 0.10 * floor(50 * 10 / (3 * 50)) = 1.30
roundHalfUp(90 * 1300 / 1000) = 117
```

Подтверждённая ошибка получает:

```text
max(
    roundHalfUp(3 * 4467 / 100),
    roundHalfUp(5 * 4467 / (2 * 50))
) = 223
```

Пусть за всю партию:

```text
Правильные цифры          +7300
Строки, блоки и финиш      +1365
Ошибки и помощь             -491
scoreBeforePace             8174
timeRatioPermille = 820     +817
Итог                        8991
```

Изменение рейтинга, например `+12`, показывается отдельно и не превращает
`8991` в `9003`.

### Пример Paper

Семь новых ходов ожидают Check. До Check HUD не раскрывает их правильность.
После Check шесть правильных ходов начисляются хронологически одним пакетом,
один подтверждённый неверный результат создаёт одну ошибку, затем применяется
цена Check. UI показывает одну строку:

> Проверено · +228 · 1 ошибка · серия сброшена

Подробные составляющие доступны только в результате.

## 10. Live Score HUD — «Пульс партии»

HUD занимает отдельную полосу минимальной высотой 44 pt между верхней навигацией
и сеткой. Он не накладывается на клетки и не уменьшает touch targets.

```text
Сложно                              4 280   ×1,5
                                      +120  ━━━○
┌──────────────────────── сетка 9×9 ────────────────────────┐
```

Состав:

- счёт — semibold 17 pt, tabular figures;
- множитель — акцентная капсула примерно 52×28 pt;
- hairline 2 pt под множителем показывает прогресс до следующей ступени, но не
  является таймером;
- единый зарезервированный delta-slot показывает `+120`/`−223` 450–550 мс;
  отдельного второго центра уведомлений над keypad нет;
- при `deferredValidation` рядом появляется компактный индикатор `◌ 5`, где
  число означает количество ожидающих проверки ходов;
- HUD можно скрыть в спокойной практике, расчёт при этом остаётся активным;
- при Accessibility Dynamic Type HUD получает intrinsic height, переносится на
  две строки и никогда не уменьшает шрифт ради фиксированной высоты.

Микрокопи:

- `+120`;
- `Множитель повышен · ×1,5`;
- `−223 · серия сброшена`;
- `−134 · подсказка по технике`;
- `−134 · проверка`;
- `Штрафной остаток −80`;
- `5 ходов ожидают проверки`;
- `Открыта цифра · без рейтинга и рекорда`;
- `Бонус темпа +888` — только в финале.

Пользователь до действия видит спокойную подпись:

- у Check: `Проверка: −134 очка и сброс серии`;
- у Hint sheet: `Название техники: −134 очка и сброс серии`;
- у Reveal: `Открыть цифру · без рейтинга и рекорда`.

Числа в подсказях рассчитываются для текущего puzzle budget, а не зашиваются в
локализацию. Текст счёта, штрафа и служебных подписей имеет contrast ratio не
ниже 4.5:1; progress hairline — не ниже 3:1. Штраф всегда обозначается знаком
`−`, текстом и accessibility value, а не только цветом.

## 11. Анимации и feedback

### Во время партии

| Событие | Анимация |
|---|---|
| Правильная цифра | существующий scale/fade цифры 150–180 мс; numeric transition счёта 220 мс |
| `+points` | fade + подъём на 5 pt возле HUD, 480 мс |
| Рост множителя | `0.98 → 1.035 → 1.0`, 180–220 мс; hairline заполняется |
| Ошибка | `−points`, приглушение капсулы и возврат к локализованному ×1,0; без shake |
| Hint/Check | нейтральный `−points` в том же delta-slot HUD |
| Пакет Paper | один count-up 240–320 мс до конечного значения |

Правила:

- Score-анимация никогда не создаёт частицы;
- она не добавляет отдельный звук;
- следующий ввод доступен немедленно;
- быстрые события за 100 мс объединяются в один visual delta, но Domain хранит
  их отдельно;
- устаревшая animation-команда не ставится в очередь;
- один ход сохраняет общий приоритет
  `puzzleSolved > groupCompleted > error > multiplier > digit`;
- `FeedbackCoordinator` создаёт не более одного sound и haptic на transaction.

Haptics:

- правильный ввод использует уже существующий light impact;
- ход, повышающий tier множителя, использует один `.soft` вместо обычного
  `.light`, но никогда второй импульс;
- ошибка по умолчанию не имеет haptic;
- Hint/Check получают только обычный selection feedback;
- победа использует один success pattern.

### Reduce Motion

- счёт меняется сразу или через fade 100–150 мс;
- нет spring, подъёма `+points`, волн и частиц;
- множитель получает статический контур и новое число;
- итоговое окно появляется fade 150–180 мс с конечными значениями;
- haptics по-прежнему управляются отдельной настройкой.

### VoiceOver

HUD является одним accessibility-элементом. Для immediate validation:

> «Очки 4 280. Множитель 1,5. До следующей ступени два хода».

Для deferred validation:

> «Подтверждённые очки 4 280. Пять ходов ожидают проверки».

Deferred-вариант не озвучивает прогресс неподтверждённых ходов к множителю.

Обычный ввод не озвучивает очки после каждой цифры. Озвучиваются только:

- новый tier множителя;
- применённый штраф;
- переход в тренировочный результат;
- итог партии.

Доступно действие `Озвучить счёт`. Декоративный progress hairline и частицы
скрыты от accessibility tree.

## 12. Итоговое окно

После победной реакции появляется одна карточка. На маленьком iPhone она может
прокручиваться; основной CTA закрепляется в safe-area footer и ничего не
перекрывает. Не требуется одновременно удерживать весь итог и кнопку на экране
при максимальном Dynamic Type.

Начальное компактное состояние:

```text
                    ✓
               Судоку решено

                    Очки
                   8 991
              Личный рекорд

         ×2,0 максимум · 0 ошибок · 12:48

          Сложная задача · без подсказок

Рейтинг ясности                             +12
1 252 → 1 264

              [ Следующая задача ]
         [ Как начислено ]  [ На главную ]
```

После отдельного действия `Как начислено` раскрываются:

```text
Правильные цифры                         +7 300
Строки, блоки и финиш                    +1 365
Ошибки и помощь                            −491
Бонус темпа                                +817
```

Сырая формула, `D`, `F`, permille и basis points в UI не показываются. Каждая
строка breakdown является одним accessibility-элементом.

Варианты:

- Daily: главный CTA `К результатам дня`, под счётом percentile/друзья;
- Reveal/третий `confirmedErrorStrike`:
  `Судоку решено · Тренировка · Не влияет на рейтинг и личный рекорд`,
  `deltaR = 0`;
- подтверждение повышения: после закрытия результата запускается существующий
  переход «Пространства ясности»;
- снижение ранга не получает отрицательную анимацию или звук;
- Perfect failure: `Попытка завершена`, счёт виден как тренировочный и не
  записывается.

### Анимация результата

1. Победная реакция сетки — 450–550 мс.
2. Карточка — fade + подъём 10–12 pt за 240–260 мс.
3. Count-up итоговых очков и rating bar идут параллельно 400–500 мс.
4. Breakdown не анимируется до явного `Как начислено`, затем появляется одним
   fade 160–180 мс.

Финальные accessibility values присутствуют сразу при создании карточки и не
озвучивают промежуточные значения count-up. VoiceOver-фокус ставится на
заголовок и один раз сообщает: «Судоку решено. Очки: 8 991. Рейтинг повышен на
12». Время `12:48` имеет label «12 минут 48 секунд»; rating progress сообщает
процент и оставшееся число. Галочка, разделители и progress graphics скрыты от
accessibility tree.

Кнопки активны с момента появления карточки, имеют отдельные targets минимум
44×44 pt. Tap сразу завершает count-up. Полностью доступное состояние появляется
не позднее 1.35 секунды после победы. Interstitial запрещён до закрытия
результата и возможного rank transition.

## 13. Domain-архитектура

UI не рассчитывает очки. Чистый `SessionScoreReducer` получает
идемпотентные события и возвращает новое состояние плюс семантические эффекты.

```swift
struct GameEventEnvelope: Codable, Sendable {
    let id: UUID
    let commandID: UUID
    let sessionID: UUID
    let sequence: UInt64
    let schemaVersion: UInt16
    let payloadHash: SHA256Digest
    let payload: GameEvent
}

enum GameEvent: Codable, Sendable {
    case sessionStarted(SessionDescriptor)
    case digitCommitted(PlacementCommand)
    case digitRemoved(RemoveCommand)
    case undoApplied(targetCommandID: UUID)
    case validationApplied(ValidationBatch)
    case hintLayerOpened(HintUse)
    case candidateAidEscalated(CandidateAidLevel)
    case timingTransition(TimingTransition)
    case speedEligibilityInvalidated(SpeedIneligibilityReason)
    case puzzleCompleted(CompletionRecord)
}
```

`GameEvent` — единый канонический журнал доски. `SessionScoreReducer` является
его projection, а не владельцем второго отдельного score journal.

```swift
struct ValidationBatch: Codable, Sendable {
    let validationID: UUID
    let kind: ValidationKind
    let policy: ScoreValidationPolicy
    let valueRevision: UInt64
    let boardDigest: SHA256Digest
    let outcomes: [PlacementOutcome] // sorted by commitSequence
    let completedGroups: [GroupID]
}
```

- immediate validation записывает batch из одного размещения;
- deferred validation записывает только текущие неснятые размещения;
- Check cost, outcomes, error penalties и группы применяются одним атомарным
  event;
- `puzzleCompleted` разрешён только после канонической проверки полной доски;
- отдельные публичные `correctPlacementConfirmed`, `groupConfirmed` и
  `validationResolved` запрещены, иначе один факт можно было бы начислить
  дважды;
- `validationRequested` не сохраняется отдельно: приложение сначала вычисляет
  batch, затем атомарно пишет один `validationApplied`, поэтому crash не
  оставляет списанную цену без результата.

Все события одной пользовательской команды имеют общий `commandID` и
сохраняются через `appendTransaction([GameEventEnvelope])`:

- immediate input: `digitCommitted + validationApplied`;
- последний immediate input:
  `digitCommitted + validationApplied + puzzleCompleted`;
- Reveal: `hintLayerOpened(reveal) + digitCommitted(source: .reveal) +
  validationApplied` и, если это последняя клетка, `puzzleCompleted`;
- system fill использует тот же шаблон с `source: .systemFill`;
- deferred Check: `validationApplied` и, если поле решено, `puzzleCompleted`.

Транзакция либо целиком появляется в journal с непрерывными sequence, либо не
появляется вовсе. В `immediateValidated` после commit-транзакции не остаётся
неподтверждённых размещений. Это исключает восстановление доски с цифрой, за
которую ещё не рассчитан score, и решённой, но незапечатанной доски.
Общий инвариант: **любая** command-транзакция, после которой доска канонически
решена, атомарно добавляет `puzzleCompleted` независимо от source.

```swift
struct SessionScoreState: Codable, Sendable {
    var status: SessionScoreStatus
    var sessionID: UUID
    var puzzleID: PuzzleID
    var catalogVersion: String
    var puzzleContentHash: SHA256Digest
    var ruleSetVersion: String
    var ruleSetHash: SHA256Digest
    var validationPolicy: ScoreValidationPolicy

    var scoreBalance: Int64
    var penaltyLedger: Int64
    var streak: Int
    var multiplierPermille: Int
    var maxStreak: Int
    var maxMultiplierPermille: Int

    var valueRevision: UInt64
    var currentPlacementByCell: [CellID: PlacementID]
    var placements: [PlacementID: PlacementRecord]
    var nextAwardOrdinal: UInt8
    var awardOrdinalByCell: [CellID: UInt8]
    var awardedCells: BitSet81
    var awardedGroups: BitSet27
    var nonScoringCells: BitSet81
    var penalizedAttempts: Set<AttemptKey>
    var confirmedErrorStrikeCount: UInt8

    var hintLedger: [HintKey: HintLayer]
    var checkLedger: Set<CheckKey>
    var candidateAidLevel: CandidateAidLevel
    var breakdown: ScoreBreakdown
    var eligibility: ScoreEligibility

    var activeElapsedMs: UInt64
    var challengeElapsedMs: UInt64?
    var expectedActiveMs: UInt64
    var speedIneligibilityReasons: Set<SpeedIneligibilityReason>

    var processedEventHashes: [UUID: SHA256Digest]
    var lastSequence: UInt64
    var sealedCompletionID: UUID?

    var displayScore: Int {
        Int(clamping: min(Int64(999_999), max(0, scoreBalance)))
    }
}
```

`PlacementRecord` имеет lifecycle
`.pending/.superseded/.reversed/.confirmed`. `valueRevision` монотонно
увеличивается при вводе, замене, Erase и Undo и никогда не откатывается. Поэтому
pending-ход, удалённый до Check, не попадает в `ValidationBatch`.

`PlacementCommand.source` равен `.user`, `.reveal` или `.systemFill`.
`nextAwardOrdinal` назначается клетке ровно один раз при её первой терминальной
классификации и сохраняется в `awardOrdinalByCell`; Reveal и system fill также
потребляют ordinal, но добавляют клетку в `nonScoringCells`. Wrong placement
ordinal не потребляет. Snapshot/restore поэтому не может изменить следующую
базовую долю.

`AttemptKey` равен паре `(cellID, digit)`, а не ID визуального нажатия. Поэтому
повторная доставка события и повтор той же уже показанной ошибки не создают
новый штраф; новая неверная цифра в той же клетке остаётся новым подтверждённым
событием.

`CheckKey = (valueRevision, checkKind)`: системная проверка Perfect не делает
ручной Check бесплатным. `HintKey = (valueRevision, logicalStepHash)` стабилен
при повторном открытии шторки и после restart; UI не генерирует новый платный
Hint ID при каждом показе. `candidateAidLevel` монотонно хранит максимальный
фактически использованный слой.

Инварианты reducer:

- сначала проверяются session ID и schema;
- известный event ID с тем же payload hash — no-op;
- тот же ID с другим payload hash — corruption;
- новое событие принимается только при `sequence == lastSequence + 1`;
- неизвестный event type останавливает replay до миграции, а не игнорируется;
- устаревший validation result отбрасывается до записи; уже сохранённый
  `validationApplied` с несовпадающим `valueRevision` считается corruption;
- после `puzzleCompleted` scoring state запечатан;
- множитель всегда 1000...2000 permille;
- `awardedCells.count <= initialEmptyCount`;
- displayScore всегда 0...999999; отрицательный scoreBalance остаётся
  видимым как штрафной остаток и не исчезает;
- расчёт одного журнала на любом устройстве даёт одинаковый результат.

Reducer возвращает только семантические эффекты:

```swift
enum ScoreEffect {
    case pointsAdded(delta: Int, total: Int)
    case multiplierChanged(from: Int, to: Int, streak: Int)
    case penaltyApplied(reason: PenaltyReason, delta: Int, total: Int)
    case paperProgressPending(count: Int)
    case paperBatchResolved(netDelta: Int)
    case resultReady(SessionScoreResult)
}
```

`ScoreAnimationCoordinator @MainActor` может объединить, сократить или полностью
убрать эффекты при Reduce Motion. Это никогда не меняет `SessionScoreState`.

## 14. Persistence, версии и integrity

`SavedGame` использует один append-only `GameEvent` journal для Board и Score.
Event и новый sequence пишутся немедленно одной транзакцией; debounce до 500 мс
разрешён только для snapshot.

`GameCommandApplier` сначала строит полный список событий команды на копии
текущего состояния, проверяет его reducer-ом, затем одной SwiftData/SQLite
транзакцией записывает envelopes и новый `lastSequence`. Частичное применение
массива событий запрещено.

Snapshot содержит:

- `snapshotSequence`;
- `SessionDescriptor`, puzzle/catalog ID и content hash;
- score ruleset ID/hash и validation policy;
- `BoardState`, current placements и `SessionScoreState`;
- rating/daily competition version;
- active/challenge elapsed, expected time, suspend state и speed eligibility.

Снимок создаётся после 10–15 событий и немедленно при
`inactive/background`. После crash приложение воспроизводит хвост единого
журнала; Board и Score не могут восстановиться на разных sequence.

Для обычных режимов сохраняются накопленные monotonic intervals. Для Daily:

- online-старт получает server/start receipt, если backend доступен;
- challenge time продолжает идти во время background;
- offline reboot или clock anomaly не мешает закончить задачу локально, но
  добавляет `clockIntegrityUnknown` и отключает pace/leaderboard;
- UI-таймер никогда не является источником итогового времени.

`NOVEMI_SessionScoreRuleSet_v1.json` является встроенным версионированным
описанием констант, а не resource pack и не удалённым исполняемым кодом:

- активная сессия навсегда фиксирует свою версию;
- `arithmeticVersion = integer-half-up-v1` фиксирует порядок округления;
- `maximumTimeRatioPermille = null` означает последний unbounded tier; unsafe
  integer sentinel не используется;
- Remote Config может выбрать только заранее встроенную и протестированную
  версию для **новой** сессии;
- формула не меняется посреди игры;
- новая формула создаёт новый `scoreRuleSetVersion`, `dailyScoreVersion` и
  leaderboard namespace;
- тема, звук и experience pack не имеют доступа к score rules.

Validator JSON отклоняет неизвестные ключи, floating-point константы там, где
ожидается integer, unsafe JSON integers и несортированные/перекрывающиеся pace
tiers.

Без собственного backend Game Center получает только результат совместимой
версии и базовые integrity-флаги клиента. Если позже появится серверная
соревновательная проверка, он повторно применяет тот же reducer к разрешённому
минимальному журналу; полный журнал ходов нельзя собирать скрыто.

## 15. Аналитика

Добавить события:

- `session_score_started`;
- `session_score_delta_coalesced`;
- `score_multiplier_tier_reached`;
- `score_multiplier_broken`;
- `score_penalty_applied`;
- `paper_score_batch_resolved`;
- `session_score_completed`;
- `session_score_personal_best`;
- `session_score_hud_hidden`.

Параметры — только агрегаты:

- `scoreRuleSetVersion`;
- difficulty tier и bucket `D`;
- итоговый score bucket;
- максимальная серия и множитель;
- число подтверждённых ошибок;
- число Check;
- максимальный Hint layer и candidate aid;
- pace bucket;
- eligibility/result type;
- Reduce Motion используется только как локальный QA-флаг без скрытой отправки
  assistive-technology status.

Не отправлять решение, значения клеток и полный журнал ходов без отдельной
необходимости, privacy review и явного описания.

Первые эксперименты должны менять презентацию, а не математику:

1. HUD всегда видим против возможности свернуть после первого объяснения;
2. progress hairline против только числа множителя;
3. одна строка результата против сразу раскрытых четырёх строк.

Изменение чисел создаёт новую версию алгоритма и несовместимый leaderboard.

Guardrails:

- abandon rate;
- D1/D7 retention;
- доля третьей подтверждённой ошибки;
- использование Hint/Check;
- время до первого скрытия HUD;
- доля пользователей, понимающих разницу между score и rating;
- отсутствие роста accidental taps из-за HUD.

## 16. Тесты

### Unit

- сумма `cellBase` всегда равна `B`;
- `awardOrdinal` распределяет remainder без привязки к CellID;
- nextAwardOrdinal/awardOrdinalByCell сохраняются; Reveal и system fill
  потребляют ordinal один раз и дают 0;
- golden vectors для `roundHalfUp`, difficulty scale, placement/error/check/hint
  и pace совпадают на всех платформах;
- все нормализованные границы multiplier tiers включительны и детерминированы;
- одна клетка и одна группа не награждаются повторно;
- повтор event ID с тем же hash является no-op; тот же ID с другим payload
  обнаруживается как corruption;
- gap/duplicate sequence и неизвестный event type не применяются молча;
- immediate command transaction после crash присутствует целиком или
  отсутствует целиком; pending validation/completion не остаётся;
- последний user/reveal/systemFill command всегда атомарно содержит
  `puzzleCompleted`;
- correct → erase/Undo → correct не фармит очки или streak;
- wrong → Undo → wrong не отменяет и не дублирует штраф;
- batch Check со множеством новых wrong pairs списывает отдельный penalty за
  каждую пару, но создаёт один `confirmedErrorStrike`;
- массовая проверка случайных цифр математически невыгодна;
- pending correct → Undo → Check не начисляет удалённый ход;
- pending wrong → Replace → Check не штрафует superseded ход;
- одинаковый `(valueRevision, checkKind)` бесплатен;
- повышение Hint layer списывает только разницу;
- стабильный HintKey переживает закрытие sheet/restart, новый логический шаг
  получает новую цену;
- Paper не публикует correctness-effects до Check/finish;
- устаревшая validation revision не попадает в journal; несовместимый
  сохранённый batch считается corruption;
- третий `confirmedErrorStrike` переводит результат в practice;
- Reveal даёт клетке 0 очков и unrecorded result;
- Classic всегда получает pace bonus 0;
- Manual Check, любой Hint, candidate aid выше neutral, error и Reveal
  необратимо дают pace bonus 0;
- timeRatio использует ceil-permille; границы 700/850/1000, нулевой expected
  time и overflow проверены golden tests;
- медленный eligible challenge получает 0, не отрицательное число;
- отрицательный penalty debt показывает итог 0; четыре числовые строки сходятся
  через `effectivePenalty`, а remainder остаётся несуммируемой подписью;
- crash не может сохранить Board и Score на разных sequence;
- score и multiplier соблюдают caps.

### Property-based

- случайные допустимые event journals всегда дают одинаковый replay;
- дублирование любого подмножества событий не меняет результат;
- сериализация/snapshot/replay сохраняют точное состояние;
- случайный crash между любыми событиями после replay даёт тот же Board и Score;
- разбиение одной command transaction crash-инъекцией невозможно;
- `awardedCells` всегда является подмножеством исходно пустых клеток;
- более глубокая помощь при одинаковом остальном не увеличивает итог;
- дополнительная подтверждённая ошибка не увеличивает итог;
- более быстрое eligible completion не даёт меньший pace bonus.

### UI и accessibility

- HUD не перекрывает ни одну из 81 клеток на минимальном iPhone;
- быстрый ввод не создаёт очередь устаревших `+points`;
- пакет Paper даёт одну агрегированную анимацию;
- ошибка не трясёт сетку и не воспроизводит громкий звук;
- Reduce Motion убирает подъём, spring и count-up;
- VoiceOver не озвучивает очки после каждой цифры;
- Dynamic Type переводит HUD в две строки;
- результат доступен и кнопки активны до конца анимации;
- Daily/Practice/Reveal/PB имеют правильные заголовки и eligibility;
- четыре строки breakdown сходятся с итогом.

## 17. Критерии готовности

Функция готова к закрытому TestFlight, если:

1. Нет скрытой проверки через HUD в Paper.
2. Ввод подтверждается менее чем за 100 мс; score-animation не блокирует input.
3. Один ход создаёт максимум один sound и haptic.
4. Таймер не уменьшает живой множитель.
5. Медленное прохождение не получает отрицательный штраф.
6. Undo/Erase/повтор Check/повтор Hint layer не позволяют фармить очки.
7. Reveal и третий `confirmedErrorStrike` не попадают в рейтинг, PB или
   leaderboard.
8. Итог после crash/restore совпадает бит-в-бит.
9. Результат содержит максимум четыре строки и отдельный `deltaR`.
10. Reduce Motion, VoiceOver и крупный текст проходят UI-тест.
11. Новая score formula никогда не смешивается со старым Daily leaderboard.
12. Interstitial не появляется до закрытия результата и rank-transition.

## 18. Порядок внедрения

1. Чистый `SessionScoreReducer` + unit/property tests.
2. Immediate policy для Assistant/Flow Scored Challenge.
3. Deferred batch policy для Paper и Focus без проверки решения.
4. HUD без анимаций, затем numeric transition и multiplier hairline.
5. Итоговая карточка и breakdown.
6. Pace bonus в Against PB.
7. Daily leaderboard новой версии.
8. TestFlight telemetry и тест понимания `Счёт партии` против `Рейтинг ясности`.

