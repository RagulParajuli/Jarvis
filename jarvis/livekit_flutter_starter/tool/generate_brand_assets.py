"""Generate every Jarvis brand asset from one drawn master image.

The master is a recreation of the JARVIS HUD mark: a dark holographic disc made
of concentric cyan rings, tick marks and arcs, with the J.A.R.V.I.S. wordmark and
the INITIALIZING... caption in the middle.

Usage
-----
    python tool/generate_brand_assets.py

This refuses nothing and only depends on Pillow. To use the original artwork
instead of the drawn master, overwrite ``assets/jarvis_logo.png`` with your
image and run the script again: every platform icon is regenerated from it.
"""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[1]

# The master is drawn at 2x and downsampled so circles and thin ticks stay
# smooth without shipping a gigantic PNG.
SIZE = 1024
SS = 2
CANVAS = SIZE * SS

BG = (4, 10, 16)
CYAN = (57, 215, 255)
CYAN_SOFT = (24, 120, 160)
WHITE = (236, 253, 255)
AMBER = (255, 186, 64)
DIM = (90, 170, 195)

FONT_BOLD = Path(r"C:\Windows\Fonts\arialbd.ttf")
FONT_REGULAR = Path(r"C:\Windows\Fonts\arial.ttf")
FONT_MONO = Path(r"C:\Windows\Fonts\consola.ttf")


def _font(path: Path, size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    for candidate in (path, FONT_BOLD, FONT_REGULAR):
        if candidate.exists():
            return ImageFont.truetype(str(candidate), size)
    return ImageFont.load_default()


def _text_width(draw: ImageDraw.ImageDraw, text: str, font, tracking: int) -> int:
    widths = [draw.textlength(character, font=font) for character in text]
    return int(sum(widths) + tracking * max(len(text) - 1, 0))


def _tracked_text(
    draw: ImageDraw.ImageDraw,
    center_x: float,
    center_y: float,
    text: str,
    font,
    tracking: int,
    fill,
) -> None:
    width = _text_width(draw, text, font, tracking)
    x = center_x - width / 2
    for character in text:
        draw.text((x, center_y), character, font=font, fill=fill, anchor="lm")
        x += draw.textlength(character, font=font) + tracking


def _arc(draw, radius, start, end, width, fill) -> None:
    box = (CANVAS / 2 - radius, CANVAS / 2 - radius, CANVAS / 2 + radius, CANVAS / 2 + radius)
    draw.arc(box, start=start, end=end, fill=fill, width=width)


def draw_master() -> Image.Image:
    image = Image.new("RGB", (CANVAS, CANVAS), BG)
    draw = ImageDraw.Draw(image)
    center = CANVAS / 2

    # Radial teal haze behind the disc.
    haze = Image.new("RGB", (CANVAS, CANVAS), BG)
    haze_draw = ImageDraw.Draw(haze)
    for step in range(60, 0, -1):
        radius = int(CANVAS * 0.52 * step / 60)
        alpha = int(2 + 30 * (1 - step / 60) ** 2)
        haze_draw.ellipse(
            (center - radius, center - radius, center + radius, center + radius),
            fill=(4 + alpha // 2, 12 + alpha, 15 + alpha),
        )
    image = Image.blend(image, haze, 0.85)
    draw = ImageDraw.Draw(image)

    # Engineering grid, faded towards the corners.
    grid = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    grid_draw = ImageDraw.Draw(grid)
    step = 64 * SS
    for offset in range(0, CANVAS, step):
        grid_draw.line((offset, 0, offset, CANVAS), fill=(0, 140, 190, 16), width=1)
        grid_draw.line((0, offset, CANVAS, offset), fill=(0, 140, 190, 16), width=1)
    image = Image.alpha_composite(image.convert("RGBA"), grid)
    draw = ImageDraw.Draw(image)

    scale = SS

    # Outer hairline rings.
    _arc(draw, 486 * scale, 0, 360, 2 * scale, (30, 110, 140))
    _arc(draw, 470 * scale, 0, 360, 3 * scale, (36, 150, 185))
    _arc(draw, 458 * scale, 0, 360, 8 * scale, (18, 82, 108))

    # Outer tick ring: 96 marks, longer every fifth.
    for index in range(96):
        angle = math.radians(index * 3.75)
        major = index % 5 == 0
        inner = 426 * scale if major else 434 * scale
        outer = 454 * scale
        x1 = center + math.cos(angle) * inner
        y1 = center + math.sin(angle) * inner
        x2 = center + math.cos(angle) * outer
        y2 = center + math.sin(angle) * outer
        color = (60, 200, 235) if major else (26, 118, 148)
        draw.line((x1, y1, x2, y2), fill=color, width=(3 if major else 1) * scale)

    # Inner guide rings.
    _arc(draw, 414 * scale, 0, 360, 2 * scale, (34, 140, 175))
    _arc(draw, 396 * scale, 0, 360, 2 * scale, (20, 88, 115))

    # Wide translucent band with a brighter inner edge.
    _arc(draw, 362 * scale, 0, 360, 26 * scale, (10, 52, 68))
    _arc(draw, 350 * scale, 0, 360, 4 * scale, (40, 176, 210))
    _arc(draw, 376 * scale, 0, 360, 2 * scale, (46, 190, 225))

    # Broken highlight arcs, the asymmetric detail from the reference.
    for start, length, width, color in (
        (-18, 64, 10, (72, 220, 255)),
        (58, 42, 10, (52, 178, 214)),
        (112, 26, 10, (52, 178, 214)),
        (148, 38, 10, (72, 220, 255)),
        (206, 62, 10, (52, 178, 214)),
        (276, 30, 10, (72, 220, 255)),
    ):
        _arc(draw, 369 * scale, start, start + length, width * scale, color)

    # The amber service arc on the left, matching the reference highlight.
    _arc(draw, 369 * scale, 152, 196, 9 * scale, AMBER)
    _arc(draw, 392 * scale, 154, 194, 3 * scale, (255, 214, 130))

    # Gear-like inner ticks.
    for index in range(72):
        angle = math.radians(index * 5)
        inner = 316 * scale if index % 2 else 306 * scale
        outer = 330 * scale
        x1 = center + math.cos(angle) * inner
        y1 = center + math.sin(angle) * inner
        x2 = center + math.cos(angle) * outer
        y2 = center + math.sin(angle) * outer
        draw.line((x1, y1, x2, y2), fill=(24, 110, 140), width=1 * scale)

    _arc(draw, 300 * scale, 0, 360, 3 * scale, (44, 178, 210))
    _arc(draw, 288 * scale, 0, 360, 1 * scale, (24, 104, 130))

    # Dark centre disc.
    radius = 272 * scale
    draw.ellipse((center - radius, center - radius, center + radius, center + radius), fill=(3, 9, 14))
    _arc(draw, 268 * scale, 0, 360, 2 * scale, (28, 120, 150))
    _arc(draw, 252 * scale, 0, 360, 1 * scale, (20, 80, 100))

    # Yellow status dots along the top-right arc.
    for degrees in (-58, -47, -36, -25, -14):
        angle = math.radians(degrees)
        x = center + math.cos(angle) * 334 * scale
        y = center + math.sin(angle) * 334 * scale
        draw.ellipse((x - 5 * scale, y - 5 * scale, x + 5 * scale, y + 5 * scale), fill=(255, 214, 92))

    # Wordmark and caption.
    wordmark = _font(FONT_BOLD, 94 * SS)
    caption = _font(FONT_REGULAR, 34 * SS)

    glow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    _tracked_text(glow_draw, center, center - 8 * scale, "J.A.R.V.I.S.", wordmark, 10 * scale, (90, 225, 255, 210))
    _tracked_text(glow_draw, center, center + 82 * scale, "I N I T I A L I Z I N G . . .", caption, 4 * scale, (140, 220, 240, 150))
    glow = glow.filter(ImageFilter.GaussianBlur(14 * scale))
    image = Image.alpha_composite(image.convert("RGBA"), glow)
    draw = ImageDraw.Draw(image)

    _tracked_text(draw, center, center - 8 * scale, "J.A.R.V.I.S.", wordmark, 10 * scale, WHITE)
    _tracked_text(draw, center, center + 82 * scale, "I N I T I A L I Z I N G . . .", caption, 4 * scale, (176, 232, 246))

    # Fine corner brackets, like the frame around the reference image.
    bracket = ImageDraw.Draw(image)
    inset = 18 * SS
    arm = 54 * SS
    for (x, y, dx, dy) in (
        (inset, inset, 1, 1),
        (CANVAS - inset, inset, -1, 1),
        (inset, CANVAS - inset, 1, -1),
        (CANVAS - inset, CANVAS - inset, -1, -1),
    ):
        bracket.line((x, y, x + arm * dx, y), fill=(38, 160, 195), width=2 * SS)
        bracket.line((x, y, x, y + arm * dy), fill=(38, 160, 195), width=2 * SS)

    return image.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB")


def _save(image: Image.Image, path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    image.resize((size, size), Image.LANCZOS).save(path, optimize=True)


def _maskable(image: Image.Image) -> Image.Image:
    # Maskable icons need breathing room inside the safe zone.
    canvas = Image.new("RGB", image.size, BG)
    inner = image.resize((int(image.width * 0.78), int(image.height * 0.78)), Image.LANCZOS)
    offset = (image.width - inner.width) // 2
    canvas.paste(inner, (offset, offset))
    return canvas


def main() -> None:
    master = draw_master()

    # In-app artwork.
    _save(master, ROOT / "assets" / "jarvis_logo.png", 512)

    # Android launcher icons.
    for folder, size in {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }.items():
        _save(master, ROOT / "android" / "app" / "src" / "main" / "res" / folder / "ic_launcher.png", size)

    # Web / PWA.
    web_icons = ROOT / "web" / "icons"
    _save(master, web_icons / "Icon-192.png", 192)
    _save(master, web_icons / "Icon-512.png", 512)
    _save(_maskable(master), web_icons / "Icon-maskable-192.png", 192)
    _save(_maskable(master), web_icons / "Icon-maskable-512.png", 512)
    _save(master, ROOT / "web" / "favicon.png", 64)

    # README artwork.
    _save(master, ROOT / ".github" / "assets" / "app-icon.png", 256)

    # Next.js frontend (served as app/icon.png and app/favicon.ico).
    _save(master, ROOT.parent / "frontend" / "app" / "icon.png", 512)
    master.save(
        ROOT.parent / "frontend" / "app" / "favicon.ico",
        sizes=[(16, 16), (32, 32), (48, 48)],
    )

    # iOS icon set, one file per entry in Contents.json.
    ios = ROOT / "ios" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    for name, size in {
        "iPhone_Notifications_20_2x 1.png": 40,
        "iPhone_Notifications_20_3x.png": 60,
        "iPad_Settings_29_1x 1.png": 29,
        "iPhone_Settings_29_2x.png": 58,
        "iPhone_Settings_29_3x.png": 87,
        "iPhone_Spotlight_40_2x.png": 80,
        "iPhone_Spotlight_40_3x.png": 120,
        "iPhone_App_60_2x.png": 120,
        "iPhone_App_60_3x.png": 180,
        "iPad_Notifications_20_1x.png": 20,
        "iPhone_Notifications_20_2x.png": 40,
        "iPad_Settings_29_1x.png": 29,
        "iPad_Settings_29_2x.png": 58,
        "iPad_Spotlight_40_1x.png": 40,
        "iPad_Spotlight_40_2x.png": 80,
        "iPad_App_76_1x.png": 76,
        "iPad_App_76_2x.png": 152,
        "iPad_Pro_App_83.5_2x.png": 167,
        "App_store_1024_1x.png": 1024,
    }.items():
        _save(master, ios / name, size)

    # macOS icon set.
    macos = ROOT / "macos" / "Runner" / "Assets.xcassets" / "AppIcon.appiconset"
    for name, size in {
        "16.png": 16,
        "16@2x.png": 32,
        "32.png": 32,
        "32@2x.png": 64,
        "128.png": 128,
        "128@2x.png": 256,
        "256.png": 256,
        "256@2x.png": 512,
        "512.png": 512,
        "512@2x.png": 1024,
    }.items():
        _save(master, macos / name, size)

    # Windows .ico with the usual shell sizes.
    ico = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"
    ico.parent.mkdir(parents=True, exist_ok=True)
    master.save(ico, sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])

    print(f"Wrote brand assets from {SIZE}px master.")


if __name__ == "__main__":
    main()
