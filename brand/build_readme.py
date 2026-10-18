"""Build the README banner from the existing wordmark.

Run: uv run --with pillow python brand/build_readme.py
"""

from pathlib import Path
import math

from PIL import Image, ImageChops, ImageDraw


ROOT = Path(__file__).resolve().parent
OUT = ROOT / "readme"
OUT.mkdir(exist_ok=True)

PAPER = (246, 247, 251)
logo = Image.open(ROOT / "logo/png/viddeo-logo-2400.png").convert("RGBA")
logo.thumbnail((744, 157), Image.Resampling.LANCZOS)

# Isolate the existing record dot; preserve the wordmark's original geometry.
red = logo.getchannel("R").point(lambda value: 255 if value > 200 else 0)
low_green = logo.getchannel("G").point(lambda value: 255 if value < 130 else 0)
record_mask = ImageChops.multiply(ImageChops.multiply(red, low_green), logo.getchannel("A"))
position = ((1200 - logo.width) // 2, (360 - logo.height) // 2)


def banner(record_opacity=1.0):
    canvas = Image.new("RGB", (1200, 360), PAPER)
    ImageDraw.Draw(canvas).rounded_rectangle(
        (1, 1, 1198, 358), radius=24, outline=(227, 230, 239), width=2
    )
    mark = logo.copy()
    if record_opacity < 1:
        reduction = record_mask.point(lambda value: round(value * (1 - record_opacity)))
        mark.putalpha(ImageChops.subtract(mark.getchannel("A"), reduction))
    canvas.paste(mark, position, mark)
    return canvas


still = banner()
still.save(OUT / "banner.png", optimize=True)
# A quiet loop, with a fully visible wordmark as the first frame.
# Use one palette throughout to keep the flat brand colors stable.
swatches = Image.new("RGB", (1200, 360 * 5))
for index in range(5):
    swatches.paste(banner(1 - index / 8), (0, 360 * index))
palette = swatches.quantize(colors=128)
frames = []
for index in range(64):
    phase = index / 64
    opacity = 1 - 0.5 * math.sin(math.pi * phase) ** 4
    frames.append(banner(opacity).quantize(palette=palette, dither=Image.Dither.NONE))
frames[0].save(
    OUT / "banner.gif", save_all=True, append_images=frames[1:],
    duration=60, loop=0, optimize=True, disposal=1,
)
print(f"Built {OUT / 'banner.png'} and {OUT / 'banner.gif'}")
