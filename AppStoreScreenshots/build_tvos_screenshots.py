"""
AI CONTEXT — tvOS App Store screenshot compositor

PURPOSE: Rebuild the 1920×1080 tvOS 1.6 marketing set from pixel-faithful
Apple TV captures and the Autohop brand background. Headlines, order and source
filenames live in SLIDES so future models can revise copy without altering UI.

INVARIANTS: Never redraw, fabricate or retouch product UI. Preserve each source
capture's 16:9 content, add only the outer campaign frame/caption, and keep all
exports exactly 1920×1080. The ZIP contains only numbered submission images.
"""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT / "tvOS-1.6-v2"
BACKGROUND = OUTPUT / "autohop-tvos-brand-background.png"
DESKTOP = Path("/Users/kevinperry/Desktop")

WIDTH, HEIGHT = 1920, 1080
FONT_BOLD = "/System/Library/Fonts/SFNS.ttf"


SLIDES = [
    ("01-your-queue-already-handled.png", "Your queue. Already handled.", "Home Screen - Up Next queue.png"),
    ("02-video-chapter-by-chapter.png", "Video podcasts. Chapter by chapter.", "Chapter Selector Video Playback.png"),
    ("03-next-up-on-top-shelf.png", "Your next episode. Right on Top Shelf.", "Top Rail.png"),
    ("04-find-your-next-favourite.png", "Find your next favourite show.", "Discover Page.png"),
    ("05-watch-at-your-pace.png", "Watch at your pace.", "Speed Control settings.png"),
    ("06-audio-controls-on-screen.png", "Audio controls. Right on screen.", "Audio Settings.png"),
    ("07-every-episode-full-story.png", "Every episode. The full story.", "Episode Description page.png"),
]


def fit_font(draw: ImageDraw.ImageDraw, text: str, max_width: int, start: int = 72) -> ImageFont.FreeTypeFont:
    size = start
    while size > 42:
        font = ImageFont.truetype(FONT_BOLD, size)
        box = draw.textbbox((0, 0), text, font=font)
        if box[2] - box[0] <= max_width:
            return font
        size -= 2
    return ImageFont.truetype(FONT_BOLD, size)


def aspect_fit(source_size: tuple[int, int], bounds: tuple[int, int]) -> tuple[int, int]:
    source_width, source_height = source_size
    bound_width, bound_height = bounds
    scale = min(bound_width / source_width, bound_height / source_height)
    return round(source_width * scale), round(source_height * scale)


def rounded_screenshot(source: Image.Image, bounds: tuple[int, int], radius: int = 34) -> Image.Image:
    size = aspect_fit(source.size, bounds)
    source_ratio = source.width / source.height
    rendered_ratio = size[0] / size[1]
    assert abs(source_ratio - rendered_ratio) < 0.002, "Screenshot aspect ratio changed"
    shot = source.convert("RGB").resize(size, Image.Resampling.LANCZOS)
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    result = Image.new("RGBA", size, (0, 0, 0, 0))
    result.paste(shot, (0, 0), mask)
    return result


def build_slide(filename: str, headline: str, source_name: str) -> None:
    base = Image.open(BACKGROUND).convert("RGB").resize((WIDTH, HEIGHT), Image.Resampling.LANCZOS)
    draw = ImageDraw.Draw(base)

    eyebrow_font = ImageFont.truetype(FONT_BOLD, 25)
    headline_font = fit_font(draw, headline, 1640)
    draw.text((150, 67), "AUTOHOP FOR APPLE TV", font=eyebrow_font, fill=(160, 144, 255))
    draw.text((150, 112), headline, font=headline_font, fill=(255, 255, 255))

    frame_y = 250
    screenshot = rounded_screenshot(Image.open(DESKTOP / source_name), (1360, 765))
    frame_w, frame_h = screenshot.size
    frame_x = (WIDTH - frame_w) // 2

    shadow = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_draw.rounded_rectangle(
        (frame_x - 14, frame_y + 10, frame_x + frame_w + 14, frame_y + frame_h + 28),
        radius=48,
        fill=(0, 0, 0, 190),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(22))
    base = Image.alpha_composite(base.convert("RGBA"), shadow)

    base.alpha_composite(screenshot, (frame_x, frame_y))

    border = Image.new("RGBA", (WIDTH, HEIGHT), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle(
        (frame_x, frame_y, frame_x + frame_w - 1, frame_y + frame_h - 1),
        radius=34,
        outline=(255, 255, 255, 55),
        width=2,
    )
    base = Image.alpha_composite(base, border)
    base.convert("RGB").save(OUTPUT / filename, "PNG", optimize=True)


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for filename, headline, source_name in SLIDES:
        build_slide(filename, headline, source_name)


if __name__ == "__main__":
    main()
