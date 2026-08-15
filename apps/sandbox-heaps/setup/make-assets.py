#!/usr/bin/env python3
"""Writes the sandbox's shared resource images.

The app ships a small `res/` folder so the example projects have something real to load through
`hxd.Res`, rather than demonstrating an asset pipeline with no assets in it. These are generated
rather than drawn so the repository carries a script instead of binaries nobody can edit, and so
nothing here is anyone else's artwork.

    python setup/make-assets.py

Writes into `assets/res/`. Rerun after editing; the files are small and deterministic, so a rerun
that changes nothing leaves the tree clean.
"""

import struct
import zlib
from pathlib import Path

SIZE = 64


def png(path, pixels):
    """Writes RGBA pixels as a PNG. No third-party imaging library, because one image format
    written by hand is cheaper than a dependency the next person has to install."""
    raw = b"".join(b"\x00" + bytes(row) for row in pixels)

    def chunk(tag, body):
        head = tag + body
        return struct.pack(">I", len(body)) + head + struct.pack(">I", zlib.crc32(head))

    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 6, 0, 0, 0)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def gem():
    """A soft diamond that fades out at its points, so a ring of them reads as one shape rather
    than as sixteen squares. Alpha does the shaping; additive blending does the rest."""
    rows = []
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            dx = abs(x - SIZE / 2 + 0.5) / (SIZE / 2)
            dy = abs(y - SIZE / 2 + 0.5) / (SIZE / 2)
            d = dx + dy
            a = max(0.0, 1.0 - d)
            row += [
                int(255 * (0.55 + 0.45 * a)),
                int(255 * (0.35 + 0.55 * a)),
                int(255 * (0.85 + 0.15 * a)),
                int(255 * (a ** 1.6)),
            ]
        rows.append(row)
    return rows


def panel():
    """A bevelled plate, opaque and tiling, for a cube to wear. Flat colour on a cube shows only
    the lighting; something with edges in it shows the UVs as well, which is the half a texture
    is there to prove."""
    rows = []
    for y in range(SIZE):
        row = []
        for x in range(SIZE):
            edge = min(x, y, SIZE - 1 - x, SIZE - 1 - y)
            if edge < 3:
                r, g, b = 38, 44, 62
            elif edge < 6:
                r, g, b = 96, 116, 158
            else:
                rivet = (x % 24 < 3 and y % 24 < 3)
                shade = 1.0 - (y / SIZE) * 0.28
                base = (150, 108, 74) if rivet else (74, 88, 120)
                r, g, b = (int(c * shade) for c in base)
            row += [r, g, b, 255]
        rows.append(row)
    return rows


def main():
    out = Path(__file__).resolve().parent.parent / "assets" / "res"
    out.mkdir(parents=True, exist_ok=True)

    png(out / "gem.png", gem())
    png(out / "panel.png", panel())

    for name in ("gem.png", "panel.png"):
        print("wrote", (out / name).relative_to(out.parent.parent))


if __name__ == "__main__":
    main()
