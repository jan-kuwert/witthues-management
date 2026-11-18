# Builds Witthues/Resources/AppIcon.svg from the Witthüs logo's W mark.
# Usage: python3 Resources/make_icon.py <Witthüs-Logo.svg> Resources/AppIcon.svg 4.6   (add "preview" to simulate the macOS mask)
import re, sys
src = open(sys.argv[1]).read()
polys = re.findall(r'<polygon class="cls-2" points="([^"]+)"/>', src)
s = float(sys.argv[3])
cx, cy = 122.2, 131.0  # centre of the W mark in logo units
# Outline of the W mark, pulled slightly inward so its edge stays hidden under the white shapes;
# grey shows only through the cuts between them.
outline = [(32.75, 25.09), (205.75, 40.38), (222.08, 231.78), (22.29, 236.96), (26.68, 31.66)]
hull = " ".join(f"{cx + (x - cx) * 0.99:.2f} {cy + (y - cy) * 0.99:.2f}" for x, y in outline)
shapes = "".join(f'<polygon points="{p}"/>' for p in polys)
clip = '<clipPath id="m"><rect width="1024" height="1024" rx="230"/></clipPath>' if len(sys.argv) > 4 else ""
svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<defs>{clip}
<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#e9ebee"/></linearGradient>
<linearGradient id="cut" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#b9bcc1"/><stop offset="1" stop-color="#8f9297"/></linearGradient>
<linearGradient id="mark" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="#e9ebee"/></linearGradient>
<linearGradient id="shade" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#3a3d42" stop-opacity="0.10"/></linearGradient>
<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0.6"/><stop offset="0.45" stop-color="#fff" stop-opacity="0"/></linearGradient>
</defs>
<!-- Full-bleed: macOS masks the square to its squircle. The white W mark is scaled past the edges so it fills the shape and the grey cuts draw the W. -->
<g {'clip-path="url(#m)"' if clip else ''}>
<rect width="1024" height="1024" fill="#f5f6f8"/>
<g transform="translate(512 512) scale({s}) translate({-cx} {-cy})">
<polygon fill="url(#cut)" points="{hull}"/>
<g fill="#f5f6f8">{shapes}</g>
</g>
<rect width="1024" height="1024" fill="url(#shade)"/>
<rect width="1024" height="1024" fill="url(#sheen)"/>
</g>
</svg>'''
open(sys.argv[2], 'w').write(svg)
