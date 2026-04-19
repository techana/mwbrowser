from PIL import Image, ImageDraw, ImageFont

W, H = 512, 212
SCALE = 3

# Palette (user's 4-color choice for Screen 6):
C_WHITE      = (255, 255, 255)  # 0 - content
C_BLACK      = (0, 0, 0)         # 1 - text
C_LIGHT_GRAY = (192, 192, 192)   # 2 - chrome
C_DARK_GRAY  = (96, 96, 96)      # 3 - accents, scrollbar

img = Image.new('RGB', (W, H), C_WHITE)
d = ImageDraw.Draw(img)

try:
    font = ImageFont.truetype("/System/Library/Fonts/Monaco.ttf", 9)
except:
    font = ImageFont.load_default()

# Titlebar (y=0..9, 10px): light-gray bg + dark-gray 1px separator
d.rectangle([0, 0, W-1, 9], fill=C_LIGHT_GRAY)
d.line([(0, 9), (W-1, 9)], fill=C_DARK_GRAY)

# Toolbar (y=10..28, 19px)
d.rectangle([0, 10, W-1, 28], fill=C_LIGHT_GRAY)
d.line([(0, 28), (W-1, 28)], fill=C_DARK_GRAY)

# Three buttons, 60x15 at y=12..26
def button(x, label, focused=False):
    d.rectangle([x, 12, x+59, 26], fill=C_LIGHT_GRAY, outline=C_BLACK)
    if focused:
        d.rectangle([x-1, 11, x+60, 27], outline=C_DARK_GRAY)
    # center-ish text
    d.text((x+6, 13), label, fill=C_BLACK, font=font)

button(2,   "< Back")
button(64,  "Refresh")          # (Stop when busy)
button(126, "Fwd >")

# Address bar (x=190..497)
d.rectangle([190, 12, 497, 26], fill=C_WHITE, outline=C_BLACK)
d.text((194, 13), "a:\\test.html", fill=C_BLACK, font=font)

# Content area is already white. Draw frame boundaries lightly.

# Scrollbar track (x=500..511, y=29..211)
d.rectangle([500, 29, 511, 211], fill=C_LIGHT_GRAY, outline=C_DARK_GRAY)
# Up arrow
d.rectangle([500, 29, 511, 40], outline=C_BLACK, fill=C_LIGHT_GRAY)
d.polygon([(505, 32), (509, 37), (501, 37)], fill=C_BLACK)
# Down arrow
d.rectangle([500, 200, 511, 211], outline=C_BLACK, fill=C_LIGHT_GRAY)
d.polygon([(501, 203), (509, 203), (505, 208)], fill=C_BLACK)
# Thumb (full because no content in Step 1)
d.rectangle([502, 42, 509, 198], fill=C_DARK_GRAY)

# Titlebar text: "(page title) - AraDigit Viewer"
d.text((4, -1), "My Page - AraDigit Viewer", fill=C_BLACK, font=font)

out_dir = "/Users/mans/Workarea/msx html viewer"
img.save(f"{out_dir}/mockup.png")
img_big = img.resize((W*SCALE, H*SCALE), Image.NEAREST)
img_big.save(f"{out_dir}/mockup_3x.png")

# Annotated version: canvas with mockup + legend
PAD = 20
LEGEND_W = 240
ANNO_W = W*SCALE + PAD*2 + LEGEND_W
ANNO_H = H*SCALE + PAD*2

anno = Image.new('RGB', (ANNO_W, ANNO_H), (40, 40, 40))
anno.paste(img_big, (PAD, PAD))
ad = ImageDraw.Draw(anno)

try:
    fbig = ImageFont.truetype("/System/Library/Fonts/Monaco.ttf", 14)
except:
    fbig = ImageFont.load_default()

legend_x = W*SCALE + PAD*2
y = PAD
for label, col in [
    ("Colour 0 - white",      C_WHITE),
    ("Colour 1 - black",      C_BLACK),
    ("Colour 2 - light gray", C_LIGHT_GRAY),
    ("Colour 3 - dark gray",  C_DARK_GRAY),
]:
    ad.rectangle([legend_x, y, legend_x+20, y+20], fill=col, outline=(255,255,255))
    ad.text((legend_x+28, y+2), label, fill=(255,255,255), font=fbig)
    y += 28

y += 14
for line in [
    "Resolution: 512x212",
    "(image shown at 3x)",
    "",
    "Titlebar: y=0..9  (10px)",
    "Toolbar:  y=10..28 (19px)",
    "Content:  y=29..211",
    "Scrollbar: x=500..511",
    "",
    "Buttons: 60x15px,",
    "  gap=3px",
    "Address: x=190..497",
    "",
    "Label 'Refresh' toggles",
    "to 'Stop' while busy.",
]:
    ad.text((legend_x, y), line, fill=(200,200,200), font=fbig)
    y += 18

anno.save(f"{out_dir}/mockup_annotated.png")
print("Wrote mockup.png, mockup_3x.png, mockup_annotated.png")
