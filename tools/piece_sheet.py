#!/usr/bin/env python3
"""
tools/piece_sheet.py
Renders the six generated meshes side by side on a neutral backdrop — a quick QA
sheet for tuning proportions (and a nice asset catalogue for the docs).

Usage: python3 tools/piece_sheet.py [out.png]
"""

import os
import sys

import numpy as np
from PIL import Image, ImageDraw

import render as R  # reuse the software renderer's maths and shading

ROOT = R.ROOT
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "renders", "06_piece_sheet.png")

W, H = 1600, 620
SS = 2
ORDER = ["P", "R", "N", "B", "Q", "K"]
LABELS = {"P": "pawn", "R": "rook", "N": "knight", "B": "bishop", "Q": "queen", "K": "king"}


def main():
    cam = R.Camera(eye=(0, 3.6, 16.5), focus=(0, 1.5, 0), fov=30, x_shift=0, width=W * SS, height=H * SS)
    cam.focal = (H * SS / 2.0) / np.tan(np.radians(cam.fov) / 2.0)
    cam.x_shift = 0

    img = Image.new("RGB", (W * SS, H * SS), (26, 25, 23))
    draw = ImageDraw.Draw(img)

    # floor plate
    plate = np.array([[-12, 0, -8], [12, 0, -8], [12, 0, 12], [-12, 0, 12]])
    screen, _ = cam.project(plate)
    draw.polygon([tuple(p) for p in screen], fill=(34, 32, 30))

    # spacing across the sheet
    spacing = 2.9
    start = -spacing * (len(ORDER) - 1) / 2

    polys = []
    for i, ptype in enumerate(ORDER):
        x = start + i * spacing
        base_color = R.P["white_piece"] if i % 2 == 0 else R.P["black_piece"]
        # a soft contact shadow
        shadow = R.circle_poly((x - 0.1, 0.01, 0.1), 0.52, 20)
        sscreen, _ = cam.project(shadow)
        layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
        ImageDraw.Draw(layer).polygon([tuple(p) for p in sscreen], fill=(0, 0, 0, 110))
        img = Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")
        draw = ImageDraw.Draw(img)

        for poly, normal in R.piece_geometry(ptype):
            world = poly + np.array([x, 0.0, 0.0])
            centroid = world.mean(axis=0)
            depth = float(((centroid - cam.eye) @ cam.R.T)[2])
            polys.append((depth, world, normal, centroid, base_color))

    polys.sort(key=lambda item: -item[0])
    for depth, world, normal, centroid, base_color in polys:
        view = R.norm(cam.eye - centroid)
        if float(np.dot(R.norm(np.asarray(normal)), view)) <= 0:
            continue  # backface cull
        dark = base_color is R.P["black_piece"]
        col = R.shade(base_color, normal, view,
                      spec_strength=0.34 if dark else 0.22,
                      rim_strength=0.46 if dark else 0.26)
        screen, z = cam.project(world)
        if np.any(z <= 0.2):
            continue
        draw.polygon([tuple(p) for p in screen], fill=col)

    # labels
    for i, ptype in enumerate(ORDER):
        x = start + i * spacing
        screen, _ = cam.project(np.array([[x, 0.02, 1.5]]))
        if screen[0][1] < H * SS:
            draw.text((screen[0][0], H * SS - 26 * SS), LABELS[ptype],
                      font=R.font(15, "bold"), fill=(150, 148, 144), anchor="mm")

    img = img.resize((W, H), Image.LANCZOS)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    img.save(OUT, quality=95)
    print("wrote", OUT, img.size)


if __name__ == "__main__":
    main()
