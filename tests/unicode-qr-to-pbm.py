#!/usr/bin/env python3

"""Convert qrc's inverted Unicode half-block output to a scaled PBM image."""

import sys


HALVES = {
    " ": (0, 0),
    "▀": (1, 0),
    "▄": (0, 1),
    "█": (1, 1),
}
SCALE = 4


def main() -> None:
    lines = sys.stdin.read().splitlines()
    if not lines:
        raise SystemExit("empty Unicode QR")
    width = max(len(line) for line in lines)
    modules: list[list[int]] = []
    for line in lines:
        line = line.ljust(width)
        upper: list[int] = []
        lower: list[int] = []
        for char in line:
            try:
                top, bottom = HALVES[char]
            except KeyError as exc:
                raise SystemExit(f"unexpected QR character: {char!r}") from exc
            upper.append(top)
            lower.append(bottom)
        modules.extend((upper, lower))

    print("P1")
    print(f"{width * SCALE} {len(modules) * SCALE}")
    for row in modules:
        scaled = " ".join(str(pixel) for pixel in row for _ in range(SCALE))
        for _ in range(SCALE):
            print(scaled)


if __name__ == "__main__":
    main()
