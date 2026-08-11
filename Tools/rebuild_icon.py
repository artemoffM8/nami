#!/usr/bin/env python3
"""
Пересборка иконки из исходника.

iOS сама скругляет углы по суперэллипсу, поэтому в бандл обязана попасть
картинка БЕЗ собственного скругления и без полей. Исходник прислан со
скруглённой плиткой на тёмном фоне — скрипт находит плитку и растягивает
её на весь кадр, чтобы маска системы резала по живому изображению.

Запуск из корня NamiApp:  python3 Tools/rebuild_icon.py
Требуется Pillow:         pip install pillow
"""

from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Design" / "icon-source-1024.png"
TARGET = ROOT / "App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
LUMINANCE_THRESHOLD = 320   # ниже — фон, выше — стекло плитки


def main() -> None:
    image = Image.open(SOURCE).convert("RGB")
    mask = np.asarray(image).astype(int).sum(2) > LUMINANCE_THRESHOLD
    ys, xs = np.where(mask)
    if not len(xs):
        raise SystemExit("не нашёл плитку: подберите LUMINANCE_THRESHOLD")

    center_x = (xs.min() + xs.max()) / 2
    center_y = (ys.min() + ys.max()) / 2
    half = max(xs.max() - xs.min(), ys.max() - ys.min()) / 2
    box = (round(center_x - half), round(center_y - half),
           round(center_x + half), round(center_y + half))

    icon = image.crop(box).resize((1024, 1024), Image.LANCZOS)
    # Альфа-канал в иконке App Store запрещён, поэтому режим строго RGB.
    icon.save(TARGET, "PNG", optimize=True)
    print(f"{TARGET.name}: плитка {box} -> 1024x1024 RGB")


if __name__ == "__main__":
    main()
