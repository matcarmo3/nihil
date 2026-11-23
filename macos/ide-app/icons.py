# macos/ide-app/icons.py — remakes the IDE's icons from assets/avatar.png, small (64 colors):
#   python3 macos/ide-app/icons.py   (needs Pillow; macOS for iconutil)
# writes ide/static/icon-192.png, ide/static/icon-512.png and macos/ide-app/nihil.icns
import os, subprocess, tempfile
from PIL import Image

os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
src = Image.open("assets/avatar.png").convert("RGBA")

def icon(size, path):
    im = src.resize((size, size), Image.LANCZOS)
    im.quantize(colors=64, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE).save(path, optimize=True)

icon(192, "ide/static/icon-192.png")
icon(512, "ide/static/icon-512.png")
with tempfile.TemporaryDirectory() as work:
    iconset = os.path.join(work, "nihil.iconset")
    os.mkdir(iconset)
    # the source is 640x640: no 512@2x (1024), it would only be larger
    for size, name in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
                       (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512")]:
        icon(size, os.path.join(iconset, f"icon_{name}.png"))
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", "macos/ide-app/nihil.icns"], check=True)
