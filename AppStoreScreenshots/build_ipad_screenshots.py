"""
AI CONTEXT — iPad App Store screenshot compositor

PURPOSE: Build the Version 1.6 iPad marketing campaign from the supplied,
pixel-faithful iPad captures. Each feature is exported in Apple's 12.9-inch
iPad portrait (2048×2732) and landscape (2732×2048) submission sizes.

DESIGN: Match the established iPhone/tvOS campaign: Autohop's purple-to-blue
brand field, a small platform eyebrow, a short white editorial headline, and a
single untouched device capture presented with restrained depth and border.

INVARIANTS: Never redraw, retouch, crop, or fabricate product UI. Scale every
capture uniformly, preserve its complete device frame, and export only exact
App Store dimensions. Update FEATURES rather than layout code when revising
campaign copy or source captures.
"""

from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT / "iPadOS-1.6"
BACKGROUND = ROOT / "tvOS-1.6" / "autohop-tvos-brand-background.png"
DOWNLOADS = Path("/Users/kevinperry/Downloads")
FONT = "/System/Library/Fonts/SFNS.ttf"


FEATURES = [
    {
        "slug": "podcasts-beautifully-focused",
        "headline": "Your podcasts. Beautifully focused.",
        "portrait": "CleanShot 2026-08-30 at 19.59.39@2x.jpg",
        "landscape": "CleanShot 2026-08-30 at 19.59.49@2x.jpg",
    },
    {
        "slug": "see-every-minute",
        "headline": "See where every minute goes.",
        "portrait": "CleanShot 2026-08-30 at 19.58.26@2x.jpg",
        "landscape": "CleanShot 2026-08-30 at 19.58.13@2x.jpg",
    },
    {
        "slug": "find-your-next-favourite",
        "headline": "Find your next favourite.",
        "portrait": "CleanShot 2026-08-30 at 19.57.07@2x.jpg",
        "landscape": "CleanShot 2026-08-30 at 19.57.23@2x.jpg",
    },
    {
        "slug": "shows-ordered-your-way",
        "headline": "Your shows. Ordered your way.",
        "portrait": "CleanShot 2026-08-30 at 19.56.52@2x.jpg",
        "landscape": "CleanShot 2026-08-30 at 19.56.43@2x.jpg",
    },
    {
        "slug": "video-built-right-in",
        "headline": "Video podcasts. Built right in.",
        "portrait": "CleanShot 2026-08-30 at 19.56.07@2x.jpg",
        "landscape": "CleanShot 2026-08-30 at 19.56.25@2x.jpg",
    },
]


FORMATS = {
    "portrait": {
        "size": (2048, 2732),
        "eyebrow": (150, 126),
        "headline": (150, 202),
        "headline_max_width": 1748,
        "headline_start": 112,
        "frame_bounds": (1710, 2090),
        "frame_top": 500,
        "radius": 50,
    },
    "landscape": {
        "size": (2732, 2048),
        "eyebrow": (210, 105),
        "headline": (210, 174),
        "headline_max_width": 2312,
        "headline_start": 108,
        "frame_bounds": (2310, 1510),
        "frame_top": 430,
        "radius": 52,
    },
}


def fit_font(draw: ImageDraw.ImageDraw, text: str, max_width: int, start: int) -> ImageFont.FreeTypeFont:
    size = start
    while size >= 64:
        font = ImageFont.truetype(FONT, size)
        box = draw.textbbox((0, 0), text, font=font)
        if box[2] - box[0] <= max_width:
            return font
        size -= 2
    return ImageFont.truetype(FONT, size)


def aspect_fit(source_size: tuple[int, int], bounds: tuple[int, int]) -> tuple[int, int]:
    scale = min(bounds[0] / source_size[0], bounds[1] / source_size[1])
    return round(source_size[0] * scale), round(source_size[1] * scale)


def campaign_background(size: tuple[int, int]) -> Image.Image:
    source = Image.open(BACKGROUND).convert("RGB")
    scale = max(size[0] / source.width, size[1] / source.height)
    rendered = source.resize(
        (round(source.width * scale), round(source.height * scale)),
        Image.Resampling.LANCZOS,
    )
    left = (rendered.width - size[0]) // 2
    top = (rendered.height - size[1]) // 2
    return rendered.crop((left, top, left + size[0], top + size[1]))


def framed_capture(source: Image.Image, bounds: tuple[int, int], radius: int) -> Image.Image:
    size = aspect_fit(source.size, bounds)
    capture = source.convert("RGB").resize(size, Image.Resampling.LANCZOS)
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255
    )
    framed = Image.new("RGBA", size, (0, 0, 0, 0))
    framed.paste(capture, (0, 0), mask)
    return framed


def build_slide(index: int, feature: dict[str, str], orientation: str) -> Path:
    config = FORMATS[orientation]
    width, height = config["size"]
    canvas = campaign_background((width, height)).convert("RGBA")
    draw = ImageDraw.Draw(canvas)

    eyebrow_font = ImageFont.truetype(FONT, 37 if orientation == "portrait" else 35)
    headline_font = fit_font(
        draw,
        feature["headline"],
        config["headline_max_width"],
        config["headline_start"],
    )
    draw.text(config["eyebrow"], "AUTOHOP FOR IPAD", font=eyebrow_font, fill=(167, 151, 255))
    draw.text(config["headline"], feature["headline"], font=headline_font, fill=(255, 255, 255))

    source_path = DOWNLOADS / feature[orientation]
    if not source_path.is_file():
        raise FileNotFoundError(f"Missing supplied capture: {source_path}")
    capture = framed_capture(Image.open(source_path), config["frame_bounds"], config["radius"])
    frame_x = (width - capture.width) // 2
    frame_y = config["frame_top"]

    shadow = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (
            frame_x - 22,
            frame_y + 20,
            frame_x + capture.width + 22,
            frame_y + capture.height + 44,
        ),
        radius=config["radius"] + 22,
        fill=(0, 0, 0, 205),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(34))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.alpha_composite(capture, (frame_x, frame_y))

    border = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle(
        (frame_x, frame_y, frame_x + capture.width - 1, frame_y + capture.height - 1),
        radius=config["radius"],
        outline=(255, 255, 255, 60),
        width=3,
    )
    canvas = Image.alpha_composite(canvas, border)

    output = OUTPUT / orientation / f"{index:02d}-{feature['slug']}.png"
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(output, "PNG", optimize=True)
    return output


def package(outputs: list[Path]) -> None:
    archive = ROOT / "Autohop-iPad-App-Store-Screenshots-1.6.zip"
    with ZipFile(archive, "w", ZIP_DEFLATED) as zip_file:
        for output in outputs:
            zip_file.write(output, output.relative_to(OUTPUT.parent))


def main() -> None:
    outputs = []
    for index, feature in enumerate(FEATURES, start=1):
        for orientation in FORMATS:
            outputs.append(build_slide(index, feature, orientation))
    package(outputs)


if __name__ == "__main__":
    main()
