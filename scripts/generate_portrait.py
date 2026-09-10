#!/usr/bin/env python3
"""Encode the original grayscale portrait as terminal Braille (build-time only).

Requires Pillow. The checked-in UTF-8 assets are embedded by Zig; the installed
CLI has no Python, image decoder, network, or terminal image-protocol dependency.
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
DOTS = ((0, 0, 0), (0, 1, 1), (0, 2, 2), (1, 0, 3),
        (1, 1, 4), (1, 2, 5), (0, 3, 6), (1, 3, 7))


def encode(source: Image.Image, columns: int) -> str:
    # 2x4 dots per character; square dots assume conventional 1:2 terminal cells.
    size = columns * 2
    gray = source.convert("L").resize((size, size), Image.Resampling.LANCZOS)
    # Keep highlights clean while retaining the hair's fine tonal structure.
    gray = gray.point(lambda value: 255 - int(((255 - value) / 255) ** 1.15 * 245))
    bitmap = gray.convert("1", dither=Image.Dither.FLOYDSTEINBERG)
    lines = []
    for y in range(0, size, 4):
        line = []
        for x in range(0, size, 2):
            mask = sum(1 << bit for dx, dy, bit in DOTS if not bitmap.getpixel((x + dx, y + dy)))
            line.append(chr(0x2800 + mask) if mask else " ")
        lines.append("".join(line).rstrip())
    return "\n".join(lines) + "\n"


if __name__ == "__main__":
    with Image.open(ROOT / "docs/assets/portrait-source.png") as source:
        for columns in (20, 32, 40, 48, 56, 64):
            target = ROOT / f"src/assets/portrait-{columns}.txt"
            target.write_text(encode(source, columns), encoding="utf-8")
            print(target.relative_to(ROOT))
