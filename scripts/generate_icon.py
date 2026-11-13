"""Original geometric SimpleMusic icon. Standard library only; no external assets."""
import json
import math
from pathlib import Path
import struct
import zlib

SIZE = 1024
ASSETS = Path("SimpleMusic/Assets.xcassets")
ICON = ASSETS / "AppIcon.appiconset"


def glyph(x, y):
    left = 419 <= x <= 469 and 310 <= y <= 655
    right = 655 <= x <= 705 and 250 <= y <= 595
    beam_y = 310 - (x - 419) * 60 / 286
    beam = 419 <= x <= 705 and beam_y <= y <= beam_y + 65
    note_a = ((x - 392) / 77) ** 2 + ((y - 653) / 61) ** 2 <= 1
    note_b = ((x - 628) / 77) ** 2 + ((y - 594) / 61) ** 2 <= 1
    return left or right or beam or note_a or note_b


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)


def main():
    ICON.mkdir(parents=True, exist_ok=True)
    ASSETS.joinpath("Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}))
    ICON.joinpath("Contents.json").write_text(json.dumps({
        "images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
        "info": {"author": "xcode", "version": 1}
    }, indent=2))
    pixels = bytearray()
    for y in range(SIZE):
        pixels.append(0)  # PNG filter none
        for x in range(SIZE):
            t = (x + y) / (2 * SIZE)
            glow = math.exp(-(((x - 710) / 460) ** 2 + ((y - 250) / 520) ** 2))
            background = (11 + 14 * t, 20 + 33 * t + 32 * glow, 48 + 70 * t + 35 * glow)
            coverage = 0
            if 310 <= x <= 707 and 248 <= y <= 716:
                coverage = sum(glyph(x + dx, y + dy) for dx, dy in ((.25, .25), (.75, .25), (.25, .75), (.75, .75))) / 4
            shade = min(max((y - 250) / 465, 0), 1)
            foreground = (248 - 101 * shade, 254 - 12 * shade, 255)
            pixels.extend(round(a * (1 - coverage) + b * coverage) for a, b in zip(background, foreground))
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(pixels), 9)) + chunk(b"IEND", b"")
    ICON.joinpath("AppIcon.png").write_bytes(png)
    assert png[25] == 2  # RGB, no alpha channel. iOS supplies the corner mask.
    print("Original opaque 1024x1024 AppIcon generated:", len(png), "bytes")


if __name__ == "__main__":
    main()
