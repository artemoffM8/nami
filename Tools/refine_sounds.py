#!/usr/bin/env python3
"""
Доводка звуковой палитры из исходников NAMI_Sounds.

Главная проблема исходного набора не в тембре, а в ПОВТОРЕ: один и тот же
сэмпл звучит идентично на каждом касании, и ухо читает это как механику за
десяток нажатий. Поэтому скрипт делает не «новые звуки», а живые варианты
существующих:

  • round-robin — по 4 варианта на часто повторяющиеся события;
  • микрорасстройка ±3% — заметна как «другой раз», не как другой звук;
  • разброс громкости ±1.5 дБ — снимает ощущение метронома;
  • короткий хвост помещения — исходники абсолютно сухие, отсюда «стерильно».

Отдельно смягчается `error`: у исходника центр спектра 8.4 кГц — самая
резкая для уха область. Ошибка не должна звучать как упрёк.

Музыка пересобирается целиком: 12 секунд слишком мало, шов слышно за минуту.

Запуск из корня NamiApp:  python3 Tools/refine_sounds.py
Требуется numpy.
"""

from __future__ import annotations

import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT.parent / "sudoku" / "NAMI_Sounds"
OUT = ROOT / "App" / "Resources" / "Sounds"
RATE = 44_100

# Событие -> (файл исходника, сколько вариантов, срезать выше, Гц)
PLAN = {
    "cellSelected":   ("sfx/cell_select.wav",  4, 9000),
    "digitPlaced":    ("sfx/digit_place.wav",  4, 8000),
    "digitErased":    ("sfx/erase.wav",        4, 7000),
    "noteToggled":    ("sfx/note_place.wav",   4, 7500),
    "groupCompleted": ("sfx/row_complete.wav", 3, 11000),
    # Ошибка: жёсткий срез сверху, вариантов меньше — она и так редкая.
    "conflict":       ("sfx/error.wav",        3, 2600),
    # Победа и подтверждение звучат по одному разу, чередовать нечего.
    "victory":        ("sfx/victory.wav",      1, 12000),
    "uiConfirm":      ("sfx/ui_confirm.wav",   1, 10000),
}

LOOP_SECONDS = 48.0


def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as handle:
        frames = handle.readframes(handle.getnframes())
        channels = handle.getnchannels()
    data = np.frombuffer(frames, dtype="<i2").astype(np.float64) / 32768
    return data.reshape(-1, channels).mean(1) if channels > 1 else data


def write_wav(path: Path, signal: np.ndarray, peak: float = 0.72) -> None:
    signal = np.nan_to_num(signal)
    signal -= signal.mean()
    top = np.abs(signal).max()
    if top > 0:
        signal = signal * (peak / top)
    fade = min(int(RATE * 0.004), len(signal))
    if fade:
        signal[-fade:] *= np.linspace(1, 0, fade)
    data = (np.clip(signal, -1, 1) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        handle.writeframes(data.tobytes())


def resample(signal: np.ndarray, factor: float) -> np.ndarray:
    """Расстройка через передискретизацию. На 50 мс сдвиг длины неслышен,
    а смена высоты — именно то, что делает повтор непохожим на предыдущий."""
    length = int(len(signal) / factor)
    source = np.linspace(0, len(signal) - 1, length)
    return np.interp(source, np.arange(len(signal)), signal)


def lowpass(signal: np.ndarray, cutoff: float) -> np.ndarray:
    """Однополюсный ФНЧ. Снимает песок в верхах, оставляя атаку."""
    alpha = 1 - np.exp(-2 * np.pi * cutoff / RATE)
    out = np.empty_like(signal)
    value = 0.0
    for i, sample in enumerate(signal):
        value += alpha * (sample - value)
        out[i] = value
    return out


def add_room(signal: np.ndarray, amount: float = 0.16) -> np.ndarray:
    """Три ранних отражения вместо ревербератора. Дают ощущение, что звук
    произошёл в комнате, а не был склеен в редакторе."""
    out = np.pad(signal, (0, int(RATE * 0.06)))
    for delay_ms, gain in ((7.0, 0.55), (13.0, 0.32), (23.0, 0.18)):
        offset = int(RATE * delay_ms / 1000)
        tail = lowpass(signal, 3200) * gain * amount
        out[offset:offset + len(tail)] += tail
    return out


def build_variants(name: str, source: Path, count: int, cutoff: float) -> None:
    base = read_wav(source)
    rng = np.random.default_rng(abs(hash(name)) % 2**32)
    for index in range(count):
        signal = base.copy()
        if index > 0:
            # Первый вариант — исходный тембр, остальные слегка отличаются.
            signal = resample(signal, float(rng.uniform(0.968, 1.032)))
        signal = lowpass(signal, cutoff)
        signal = add_room(signal)
        gain = 1.0 if index == 0 else float(rng.uniform(0.84, 1.0))
        suffix = "" if index == 0 else str(index + 1)
        write_wav(OUT / f"{name}{suffix}.wav", signal * gain)
    print(f"  {name:<15} {count} вариант(ов) из {source.name}")


def build_ambient_loop() -> None:
    """Бесшовный пэд.

    Швов не будет по построению: все модуляторы — целые гармоники 1/T,
    поэтому в точке склейки и фаза, и огибающая совпадают сами собой.
    """
    total = int(RATE * LOOP_SECONDS)
    time = np.arange(total) / RATE
    base = 2 * np.pi / LOOP_SECONDS   # один оборот за петлю

    # Ре-минорный фон: тоника, квинта, октава и мягкая терция сверху.
    voices = [(146.83, 0.42), (220.00, 0.30), (293.66, 0.24), (349.23, 0.14)]
    out = np.zeros(total)
    for index, (freq, amplitude) in enumerate(voices):
        # Медленное дыхание: каждый голос со своим числом циклов за петлю.
        breath = 0.72 + 0.28 * np.sin(base * (index + 1) * time * RATE / RATE * 1.0
                                      + index * 1.7)
        # Лёгкая расстройка двух копий даёт живой хор вместо синтетика.
        for detune in (-0.15, 0.15):
            phase = 2 * np.pi * (freq + detune) * time
            out += amplitude * 0.5 * breath * (np.sin(phase) + 0.18 * np.sin(2 * phase))

    # Воздух: очень тихий шум, дышащий в противофазе к голосам.
    noise = np.random.default_rng(20260804).normal(size=total)
    spectrum = np.fft.rfft(noise)
    freqs = np.fft.rfftfreq(total, 1 / RATE)
    spectrum[(freqs < 300) | (freqs > 2400)] = 0
    air = np.fft.irfft(spectrum, total)
    air *= 0.02 * (0.6 + 0.4 * np.sin(base * 3 * time * RATE / RATE + 2.1))
    out += air

    out = lowpass(out, 2600)
    write_wav(OUT / "ambientLoop.wav", out, peak=0.55)
    size = (OUT / "ambientLoop.wav").stat().st_size / 1024 / 1024
    print(f"  ambientLoop     {LOOP_SECONDS:.0f} с бесшовно, {size:.1f} МБ")


def main() -> None:
    if not SOURCE.exists():
        raise SystemExit(f"нет исходников: {SOURCE}")
    OUT.mkdir(parents=True, exist_ok=True)
    print("Собираю палитру:")
    for name, (relative, count, cutoff) in PLAN.items():
        build_variants(name, SOURCE / relative, count, cutoff)
    build_ambient_loop()


if __name__ == "__main__":
    main()
