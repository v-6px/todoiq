"""Generates the Google Play store graphics for ToDoIQ.

Run from the project root:

    python tool/generate_store_assets.py

Writes:
  assets/store/icon_512.png         512x512 app icon
  assets/store/feature_1024x500.png 1024x500 feature graphic

Both are saved as 24-bit RGB PNGs with no alpha channel: Play requires that
for the feature graphic, and it keeps the icon from rendering differently on
light and dark store pages.
"""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

BACKGROUND = "#121212"
BLUE = "#2979FF"
RED = "#F44336"

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "assets" / "store"

# Bold geometric sans, closest to the wordmark among the fonts Windows ships.
FONT_CANDIDATES = [
    Path("C:/Windows/Fonts/segoeuib.ttf"),
    Path("C:/Windows/Fonts/arialbd.ttf"),
]


def load_font(size: int) -> ImageFont.FreeTypeFont:
    for candidate in FONT_CANDIDATES:
        if candidate.exists():
            return ImageFont.truetype(str(candidate), size)
    raise SystemExit("No bold font found; add one to FONT_CANDIDATES.")


def fit_font(text: str, max_width: int, max_height: int) -> ImageFont.FreeTypeFont:
    """The largest font size at which [text] fits inside the box."""
    size = 10
    while True:
        font = load_font(size + 2)
        left, top, right, bottom = font.getbbox(text)
        if right - left > max_width or bottom - top > max_height:
            return load_font(size)
        size += 2


def draw_wordmark(
    image: Image.Image,
    max_width: int,
    max_height: int,
) -> None:
    """Draws "ToDo" in blue and "IQ" in red, centred as one word."""
    draw = ImageDraw.Draw(image)
    word = "ToDoIQ"
    font = fit_font(word, max_width, max_height)

    # Centre on the ink of the whole word, not the font's line box, so the
    # visible letters sit in the true middle.
    left, top, right, bottom = draw.textbbox((0, 0), word, font=font)
    x = (image.width - (right - left)) / 2 - left
    y = (image.height - (bottom - top)) / 2 - top

    # "IQ" starts exactly where "ToDo" advances to, so the kerning matches
    # the word drawn in one piece.
    draw.text((x, y), "ToDo", font=font, fill=BLUE)
    draw.text((x + font.getlength("ToDo"), y), "IQ", font=font, fill=RED)


def make_icon() -> Path:
    image = Image.new("RGB", (512, 512), BACKGROUND)
    # A generous margin: Play masks the icon with rounded corners.
    draw_wordmark(image, max_width=400, max_height=400)
    path = OUT_DIR / "icon_512.png"
    image.save(path, "PNG", optimize=True)
    return path


def make_feature_graphic() -> Path:
    image = Image.new("RGB", (1024, 500), BACKGROUND)
    # Kept well inside the frame: Play may crop or overlay the edges.
    draw_wordmark(image, max_width=640, max_height=220)
    path = OUT_DIR / "feature_1024x500.png"
    image.save(path, "PNG", optimize=True)
    return path


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for path in (make_icon(), make_feature_graphic()):
        with Image.open(path) as saved:
            print(f"{path}  {saved.size[0]}x{saved.size[1]} {saved.mode} "
                  f"{path.stat().st_size // 1024} KB")


if __name__ == "__main__":
    main()
