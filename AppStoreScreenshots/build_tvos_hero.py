"""
AI CONTEXT — tvOS App Store hero artwork

PURPOSE: Produce the 1920×1080 Autohop tvOS brand hero using the canonical
repository app icon and exact reviewer-approved slogan.

INVARIANTS: Never regenerate or redraw the Autohop logo; scale it uniformly.
Keep the output exactly 1920×1080 and preserve the slogan verbatim.
"""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT / "tvOS-Hero" / "Autohop-Your-Podcasts-Deserve-The-Big-Screen.png"
BACKGROUND = ROOT / "tvOS-1.6" / "autohop-tvos-brand-background.png"
ICON = ROOT.parent / "Assets.xcassets" / "AppIcon.appiconset" / "AutohopAppIcon-1024.png"
FONT = "/System/Library/Fonts/SFNS.ttf"


def main() -> None:
    canvas = Image.open(BACKGROUND).convert("RGB").resize((1920, 1080), Image.Resampling.LANCZOS)

    icon_size = 440
    icon = Image.open(ICON).convert("RGBA").resize((icon_size, icon_size), Image.Resampling.LANCZOS)
    icon_mask = Image.new("L", (icon_size, icon_size), 0)
    ImageDraw.Draw(icon_mask).rounded_rectangle((0, 0, icon_size - 1, icon_size - 1), radius=96, fill=255)

    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle((154, 334, 634, 814), radius=112, fill=(0, 0, 0, 185))
    shadow = shadow.filter(ImageFilter.GaussianBlur(30))
    composed = Image.alpha_composite(canvas.convert("RGBA"), shadow)
    composed.paste(icon, (170, 310), icon_mask)

    draw = ImageDraw.Draw(composed)
    name_font = ImageFont.truetype(FONT, 84)
    slogan_font = ImageFont.truetype(FONT, 76)
    draw.text((700, 328), "Autohop", font=name_font, fill=(169, 151, 255))
    draw.text((700, 452), "Your Podcasts Deserve", font=slogan_font, fill=(255, 255, 255))
    draw.text((700, 544), "The Big Screen", font=slogan_font, fill=(255, 255, 255))

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    composed.convert("RGB").save(OUTPUT, "PNG", optimize=True)


if __name__ == "__main__":
    main()
