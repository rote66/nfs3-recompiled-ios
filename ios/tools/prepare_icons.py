from pathlib import Path
import sys

from PIL import Image, ImageChops


source = Image.open(sys.argv[1]).convert("RGBA")
artwork = ImageChops.difference(source.convert("RGB"), Image.new("RGB", source.size, "white")).getbbox()
if artwork:
    source = source.crop(artwork)
background = Image.new("RGB", source.size, "black")
background.paste(source, mask=source.getchannel("A"))
destination = Path(__file__).resolve().parents[1] / "Resources"
for name, size in {
    "AppIcon60x60@2x.png": 120,
    "AppIcon60x60@3x.png": 180,
    "AppIcon76x76.png": 76,
    "AppIcon76x76@2x.png": 152,
    "AppIcon83.5x83.5@2x.png": 167,
    "AppIcon1024.png": 1024,
}.items():
    background.resize((size, size), Image.Resampling.LANCZOS).save(destination / name)
