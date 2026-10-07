#!/usr/bin/env python3
"""Generate lossless 1x/2x/3x Settings icons from the checked-in 720px master.
Requires Pillow only when regenerating: python3 build_brand_icons.py
Never upscale the old 29px icon. The crop was made from the user's 1080px photo.
"""
from pathlib import Path
from PIL import Image, ImageFilter
root = Path(__file__).resolve().parent
crop = Image.open(root / 'assets/lingdong-icon-master.png').convert('RGB')
assert crop.width == crop.height and crop.width >= 512
for folder, base, ext in [(root / 'sbcpuprefs/Resources', 'icon', 'PNG'),
                          (root / 'ControlCenter/resources', 'SettingsIcon', 'png')]:
    for scale in (1, 2, 3):
        image = crop.resize((29 * scale, 29 * scale), Image.Resampling.LANCZOS)
        image = image.filter(ImageFilter.UnsharpMask(radius=0.45, percent=60, threshold=3))
        suffix = '' if scale == 1 else '@%dx' % scale
        image.save(folder / ('%s%s.%s' % (base, suffix, ext)), optimize=True)
crop.resize((256, 256), Image.Resampling.LANCZOS).save(root / 'assets/lingdong-icon-preview.png', optimize=True)
print('Generated 29/58/87px icons from a %dpx lossless master' % crop.width)
