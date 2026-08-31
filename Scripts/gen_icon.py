#!/usr/bin/env python3
"""Renders the Bifold app icon: an open DS clamshell on deep slate.

    python Scripts/gen_icon.py

Writes Bifold/Resources/Assets.xcassets/AppIcon.appiconset/bifold-icon-1024.png
using nothing but the standard library (SDF shapes + zlib PNG writer).
"""
import math
import os
import struct
import zlib

SIZE = 1024
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'Bifold', 'Resources', 'Assets.xcassets', 'AppIcon.appiconset', 'bifold-icon-1024.png')


def rounded_rect(px, py, cx, cy, hw, hh, r):
    """Signed distance to a rounded rectangle centred at (cx, cy)."""
    dx = abs(px - cx) - (hw - r)
    dy = abs(py - cy) - (hh - r)
    ax = max(dx, 0.0)
    ay = max(dy, 0.0)
    return math.hypot(ax, ay) + min(max(dx, dy), 0.0) - r


def circle(px, py, cx, cy, radius):
    return math.hypot(px - cx, py - cy) - radius


def coverage(d):
    """Anti-aliased coverage from a signed distance (1 inside, 0 outside)."""
    if d <= -1.0:
        return 1.0
    if d >= 1.0:
        return 0.0
    return 0.5 - d * 0.5


def lerp(a, b, t):
    return a + (b - a) * t


def blend(base, color, alpha):
    return (lerp(base[0], color[0], alpha),
            lerp(base[1], color[1], alpha),
            lerp(base[2], color[2], alpha))


# Palette (Slate theme family).
BG_TOP = (18, 22, 32)
BG_BOTTOM = (9, 12, 18)
BEZEL = (30, 38, 52)
BEZEL_EDGE = (52, 64, 84)
HINGE = (44, 54, 70)
HINGE_DARK = (24, 30, 42)
SCREEN_TOP_A = (129, 190, 255)     # top screen glow, upper left
SCREEN_TOP_B = (38, 92, 168)       # top screen glow, lower right
SCREEN_BOT_A = (28, 40, 60)        # bottom (touch) screen, subtle
SCREEN_BOT_B = (16, 24, 38)
DOT = (95, 168, 245)
LED = (88, 204, 82)

# Geometry (icon canvas 1024×1024).
CX = 512.0
TOP_CY, BOT_CY = 330.0, 700.0
SHELL_HW, SHELL_HH, SHELL_R = 250.0, 172.0, 46.0
SCREEN_HW, SCREEN_HH, SCREEN_R = 208.0, 132.0, 24.0
HINGE_CY = 515.0
HINGE_HW, HINGE_HH, HINGE_R = 210.0, 26.0, 22.0
LED_X, LED_Y, LED_R = 512.0 + 170.0, 515.0, 11.0

rows = []
for y in range(SIZE):
    row = bytearray()
    ty = y / (SIZE - 1)
    for x in range(SIZE):
        px, py = float(x), float(y)
        # Background: vertical gradient with a faint radial lift behind the shell.
        c = blend(BG_TOP, BG_BOTTOM, ty)
        glow = max(0.0, 1.0 - math.hypot(px - CX, py - 500.0) / 620.0)
        c = blend(c, (24, 32, 48), glow * glow * 0.55)

        # Halves of the shell (bezels).
        for cy in (TOP_CY, BOT_CY):
            d = rounded_rect(px, py, CX, cy, SHELL_HW, SHELL_HH, SHELL_R)
            a = coverage(d)
            if a > 0:
                shade = blend(BEZEL, HINGE_DARK, (py - (cy - SHELL_HH)) / (2 * SHELL_HH) * 0.5)
                c = blend(c, shade, a)
                edge = coverage(abs(d + 3.0) - 3.0) * 0.35
                c = blend(c, BEZEL_EDGE, edge * a)

        # Hinge bar joining the halves.
        d = rounded_rect(px, py, CX, HINGE_CY, HINGE_HW, HINGE_HH, HINGE_R)
        a = coverage(d)
        if a > 0:
            shade = blend(HINGE, HINGE_DARK, abs(py - HINGE_CY) / HINGE_HH)
            c = blend(c, shade, a)
            # Two darker hinge notches.
            for nx in (CX - 120.0, CX + 120.0):
                dn = rounded_rect(px, py, nx, HINGE_CY, 26.0, HINGE_HH - 6.0, 10.0)
                c = blend(c, HINGE_DARK, coverage(dn) * a * 0.9)

        # Top screen: lit, diagonal glacier gradient plus a soft highlight.
        d = rounded_rect(px, py, CX, TOP_CY, SCREEN_HW, SCREEN_HH, SCREEN_R)
        a = coverage(d)
        if a > 0:
            t = ((px - (CX - SCREEN_HW)) / (2 * SCREEN_HW) + (py - (TOP_CY - SCREEN_HH)) / (2 * SCREEN_HH)) / 2
            sc = blend(SCREEN_TOP_A, SCREEN_TOP_B, min(1.0, max(0.0, t)))
            hl = max(0.0, 1.0 - ((px - (CX - SCREEN_HW)) + (py - (TOP_CY - SCREEN_HH))) / 260.0)
            sc = blend(sc, (225, 240, 255), hl * hl * 0.5)
            c = blend(c, sc, a)

        # Bottom screen: dark touch glass with a small accent dot matrix.
        d = rounded_rect(px, py, CX, BOT_CY, SCREEN_HW, SCREEN_HH, SCREEN_R)
        a = coverage(d)
        if a > 0:
            t = (py - (BOT_CY - SCREEN_HH)) / (2 * SCREEN_HH)
            sc = blend(SCREEN_BOT_A, SCREEN_BOT_B, min(1.0, max(0.0, t)))
            c = blend(c, sc, a)
            for iy in range(3):
                for ix in range(3):
                    dotx = CX + (ix - 1) * 64.0
                    doty = BOT_CY + (iy - 1) * 64.0
                    dd = circle(px, py, dotx, doty, 7.0)
                    c = blend(c, DOT, coverage(dd) * a * (0.85 if (ix, iy) == (1, 1) else 0.35))

        # Power LED on the hinge's right shoulder, with a soft glow.
        glow = max(0.0, 1.0 - math.hypot(px - LED_X, py - LED_Y) / (LED_R * 3.4))
        if glow > 0:
            c = blend(c, LED, glow * glow * 0.5)
        c = blend(c, (200, 255, 190), coverage(circle(px, py, LED_X, LED_Y, LED_R)) * 0.95)

        row += bytes((int(round(c[0])), int(round(c[1])), int(round(c[2]))))
    rows.append(bytes(row))


def write_png(path, width, height, rgb_rows):
    raw = b''.join(b'\x00' + r for r in rgb_rows)

    def chunk(tag, data):
        payload = tag + data
        return struct.pack('>I', len(data)) + payload + struct.pack('>I', zlib.crc32(payload) & 0xFFFFFFFF)

    header = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', header)
           + chunk(b'IDAT', zlib.compress(raw, 9))
           + chunk(b'IEND', b''))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(png)


write_png(OUT, SIZE, SIZE, rows)
print(f'Wrote {OUT}')
