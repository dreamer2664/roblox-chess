#!/usr/bin/env python3
"""
tools/make_pieces.py
Generates the chess piece meshes used by the prototype.

Output: assets/pieces/{pawn,rook,knight,bishop,queen,king}.obj  (+ manifest.json)

Why generated rather than downloaded: every CC0 set I found is 45k-60k triangles
per piece with PBR textures. Roblox needs 32 pieces in one place, so that is
~1.8M triangles of geometry the client would choke on. These meshes are turned
surfaces (plus a swept knight) at 32-40 radial segments: 2-4k triangles each,
smooth normals, no textures at all (colour comes from the part's Color).

Round-trip:
  python3 tools/make_pieces.py            # writes assets/pieces/*.obj
  # in Roblox Studio: Asset Manager -> Import 3D, pick the six .obj files,
  # then paste the resulting mesh ids into src/shared/Config.lua (Meshes table)
  python3 tools/render.py                 # previews use the same .obj files

Everything here is original work, MIT licensed with the rest of the repo.
"""

import json
import math
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "assets", "pieces")

TAU = math.pi * 2


# ------------------------------------------------------------------ helpers
def catmull_rom(points, samples_per_segment=8):
    """Smooth a polyline of (r, y) control points into a dense profile."""
    pts = [points[0]] + list(points) + [points[-1]]
    out = []
    for i in range(1, len(pts) - 2):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[i + 1], pts[i + 2]
        for s in range(samples_per_segment):
            t = s / samples_per_segment
            t2, t3 = t * t, t * t * t
            r = 0.5 * ((2 * p1[0]) + (-p0[0] + p2[0]) * t
                       + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2
                       + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3)
            y = 0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * t
                       + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2
                       + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)
            out.append((max(0.0, r), y))
    out.append(points[-1])
    return out


class Mesh:
    """Tiny vertex/face soup with automatic smooth normals."""

    def __init__(self):
        self.verts = []
        self.faces = []  # list of tuples of indices, CCW outward

    def add_vert(self, x, y, z):
        self.verts.append((x, y, z))
        return len(self.verts) - 1

    def add_face(self, *idx):
        if len(set(idx)) >= 3:
            self.faces.append(tuple(idx))

    def merge(self, other):
        offset = len(self.verts)
        self.verts.extend(other.verts)
        for face in other.faces:
            self.faces.append(tuple(i + offset for i in face))

    def transform(self, fn):
        self.verts = [fn(v) for v in self.verts]

    def scaled(self, k):
        m = Mesh()
        m.verts = [(v[0] * k, v[1] * k, v[2] * k) for v in self.verts]
        m.faces = list(self.faces)
        return m

    def normals(self):
        acc = [[0.0, 0.0, 0.0] for _ in self.verts]
        for face in self.faces:
            a = face[0]
            va = self.verts[a]
            # fan-triangulate the polygon and accumulate its area-weighted normal
            for k in range(1, len(face) - 1):
                b, c = face[k], face[k + 1]
                vb, vc = self.verts[b], self.verts[c]
                e1 = (vb[0] - va[0], vb[1] - va[1], vb[2] - va[2])
                e2 = (vc[0] - va[0], vc[1] - va[1], vc[2] - va[2])
                n = (e1[1] * e2[2] - e1[2] * e2[1],
                     e1[2] * e2[0] - e1[0] * e2[2],
                     e1[0] * e2[1] - e1[1] * e2[0])
                for i in (a, b, c):
                    acc[i][0] += n[0]
                    acc[i][1] += n[1]
                    acc[i][2] += n[2]
        out = []
        for nx, ny, nz in acc:
            length = math.sqrt(nx * nx + ny * ny + nz * nz) or 1.0
            out.append((nx / length, ny / length, nz / length))
        return out


# ------------------------------------------------------------------ primitives
def revolve(profile, segments=40, cap_bottom=True, cap_top=True):
    """Surface of revolution around +Y from a (radius, y) profile."""
    mesh = Mesh()
    rings = []
    for r, y in profile:
        ring = []
        for s in range(segments):
            a = TAU * s / segments
            ring.append(mesh.add_vert(r * math.cos(a), y, r * math.sin(a)))
        rings.append(ring)

    for i in range(len(rings) - 1):
        r0, r1 = profile[i], profile[i + 1]
        for s in range(segments):
            s2 = (s + 1) % segments
            a, b = rings[i][s], rings[i][s2]
            c, d = rings[i + 1][s2], rings[i + 1][s]
            if r0[0] < 1e-6 and r1[0] < 1e-6:
                continue
            if r0[0] < 1e-6:
                mesh.add_face(a, d, c)
            elif r1[0] < 1e-6:
                mesh.add_face(a, c, b)
            else:
                mesh.add_face(a, d, c, b)

    if cap_bottom and profile[0][0] > 1e-6:
        centre = mesh.add_vert(0, profile[0][1], 0)
        for s in range(segments):
            mesh.add_face(centre, rings[0][s], rings[0][(s + 1) % segments])
    if cap_top and profile[-1][0] > 1e-6:
        centre = mesh.add_vert(0, profile[-1][1], 0)
        for s in range(segments):
            mesh.add_face(centre, rings[-1][(s + 1) % segments], rings[-1][s])
    return mesh


def sphere(radius, centre, segments=24, rings=14):
    mesh = Mesh()
    grid = []
    for j in range(rings + 1):
        t = math.pi * j / rings
        row = []
        for s in range(segments):
            a = TAU * s / segments
            row.append(mesh.add_vert(
                centre[0] + radius * math.sin(t) * math.cos(a),
                centre[1] + radius * math.cos(t),
                centre[2] + radius * math.sin(t) * math.sin(a),
            ))
        grid.append(row)
    for j in range(rings):
        for s in range(segments):
            s2 = (s + 1) % segments
            a, b = grid[j][s], grid[j][s2]
            c, d = grid[j + 1][s2], grid[j + 1][s]
            mesh.add_face(a, b, c, d)
    return mesh


def box(size, centre, rot_x=0.0, rot_y=0.0):
    """Flat-shaded box (duplicated verts so normals stay crisp)."""
    mesh = Mesh()
    hx, hy, hz = size[0] / 2, size[1] / 2, size[2] / 2
    corners = [(-hx, -hy, -hz), (hx, -hy, -hz), (hx, hy, -hz), (-hx, hy, -hz),
               (-hx, -hy, hz), (hx, -hy, hz), (hx, hy, hz), (-hx, hy, hz)]
    cx, sx = math.cos(rot_x), math.sin(rot_x)
    cy, sy = math.cos(rot_y), math.sin(rot_y)
    rotated = []
    for x, y, z in corners:
        y, z = y * cx - z * sx, y * sx + z * cx
        x, z = x * cy + z * sy, -x * sy + z * cy
        rotated.append((x + centre[0], y + centre[1], z + centre[2]))
    quads = [(3, 2, 1, 0), (4, 5, 6, 7), (0, 1, 5, 4), (2, 3, 7, 6), (1, 2, 6, 5), (3, 0, 4, 7)]
    for quad in quads:
        idx = [mesh.add_vert(*rotated[i]) for i in quad]
        mesh.add_face(*idx)
    return mesh


def ring_teeth(count, radius, y, tooth_h, tooth_w, tooth_d, ring_r):
    """Crenellations: little boxes distributed on a circle (rooks, queens, kings)."""
    mesh = Mesh()
    for i in range(count):
        a = TAU * i / count
        m = box((tooth_w, tooth_h, tooth_d),
                (ring_r * math.cos(a), y + tooth_h / 2, ring_r * math.sin(a)),
                rot_y=-a)
        mesh.merge(m)
    return mesh


def sweep_knight(slices=30, segments=20):
    """
    The knight is the one piece that is not a turned solid, so it is swept along a
    hand-authored spine: the neck rises with a slight backward lean, then the head
    cranes forward and dips, ending in a narrow muzzle. Cross sections are ellipses
    that grow longer in the direction of travel as the head flattens out.
    """
    # (z forward, y, radius, depth-elongation)
    spine = [
        (0.00, 0.30, 0.295, 1.00),
        (-0.02, 0.65, 0.275, 1.00),
        (-0.02, 1.00, 0.255, 1.02),
        (0.00, 1.30, 0.245, 1.10),
        (0.04, 1.52, 0.235, 1.20),
        (0.18, 1.63, 0.215, 1.38),
        (0.36, 1.66, 0.19, 1.42),
        (0.52, 1.63, 0.145, 1.30),
        (0.64, 1.57, 0.095, 1.00),
        (0.71, 1.52, 0.040, 0.70),
    ]
    dense = []
    for i in range(len(spine) - 1):
        a, b = spine[i], spine[i + 1]
        for k in range(4):
            t = k / 4
            dense.append(tuple(a[j] + (b[j] - a[j]) * t for j in range(4)))
    dense.append(spine[-1])

    mesh = Mesh()
    rings = []
    for idx, (cz, cy, radius, elong) in enumerate(dense):
        nxt = dense[min(idx + 1, len(dense) - 1)]
        prv = dense[max(idx - 1, 0)]
        tz, ty = nxt[0] - prv[0], nxt[1] - prv[1]
        length = math.hypot(tz, ty) or 1.0
        tz, ty = tz / length, ty / length
        # in-plane perpendicular to the spine
        pz, py = -ty, tz
        ring = []
        for s_i in range(segments):
            a = TAU * s_i / segments
            x = radius * math.cos(a)
            d = radius * elong * math.sin(a)
            ring.append(mesh.add_vert(x, cy + d * py, cz + d * pz))
        rings.append(ring)

    for i in range(len(rings) - 1):
        for s_i in range(segments):
            s2 = (s_i + 1) % segments
            mesh.add_face(rings[i][s_i], rings[i + 1][s_i], rings[i + 1][s2], rings[i][s2])

    # caps
    for ring, flip in ((rings[0], True), (rings[-1], False)):
        pts = [mesh.verts[i] for i in ring]
        c = (sum(v[0] for v in pts) / len(pts),
             sum(v[1] for v in pts) / len(pts),
             sum(v[2] for v in pts) / len(pts))
        ci = mesh.add_vert(*c)
        for s_i in range(segments):
            s2 = (s_i + 1) % segments
            if flip:
                mesh.add_face(ci, ring[s_i], ring[s2])
            else:
                mesh.add_face(ci, ring[s2], ring[s_i])

    # ears: two small cones on the crown of the head
    for side in (-1, 1):
        ear = revolve([(0.0, 0.0), (0.08, 0.03), (0.05, 0.15), (0.0, 0.20)], segments=10)
        ear.transform(lambda v, s=side: (v[0] + s * 0.095, v[1] + 1.70, v[2] + 0.02))
        mesh.merge(ear)

    return mesh


# ------------------------------------------------------------------ pieces
# Hand-authored Staunton profiles: (radius, height). The base flares, the stem
# waists, the collar steps out, and the head sits on top. Catmull-Rom smooths
# between control points, so duplicate points are used to keep collars crisp.
PAWN = [(0.00, 0.00), (0.40, 0.00), (0.42, 0.03), (0.40, 0.07), (0.33, 0.10),
        (0.30, 0.13), (0.22, 0.17), (0.19, 0.24), (0.175, 0.50), (0.185, 0.56),
        (0.235, 0.60), (0.235, 0.64), (0.20, 0.67), (0.175, 0.70), (0.19, 0.74),
        (0.215, 0.80), (0.225, 0.86), (0.21, 0.92), (0.16, 0.98), (0.08, 1.02),
        (0.00, 1.03)]

ROOK = [(0.00, 0.00), (0.44, 0.00), (0.46, 0.03), (0.44, 0.08), (0.36, 0.11),
        (0.33, 0.15), (0.29, 0.20), (0.275, 0.30), (0.275, 0.55), (0.285, 0.62),
        (0.32, 0.66), (0.33, 0.70), (0.34, 0.78), (0.34, 0.88), (0.31, 0.90),
        (0.00, 0.905)]

BISHOP = [(0.00, 0.00), (0.42, 0.00), (0.44, 0.03), (0.42, 0.08), (0.34, 0.11),
          (0.31, 0.15), (0.23, 0.20), (0.19, 0.27), (0.165, 0.55), (0.175, 0.62),
          (0.235, 0.66), (0.235, 0.71), (0.185, 0.74), (0.15, 0.78), (0.175, 0.84),
          (0.205, 0.92), (0.215, 1.02), (0.205, 1.14), (0.185, 1.26), (0.155, 1.38),
          (0.11, 1.50), (0.06, 1.60), (0.045, 1.66), (0.00, 1.68)]

QUEEN = [(0.00, 0.00), (0.46, 0.00), (0.48, 0.03), (0.46, 0.08), (0.36, 0.11),
         (0.32, 0.15), (0.24, 0.21), (0.205, 0.28), (0.19, 0.60), (0.20, 0.66),
         (0.26, 0.70), (0.26, 0.74), (0.215, 0.77), (0.19, 0.80), (0.215, 0.85),
         (0.25, 0.90), (0.27, 0.96), (0.275, 1.02), (0.24, 1.05), (0.20, 1.08),
         (0.215, 1.11), (0.00, 1.12)]

KING = [(0.00, 0.00), (0.48, 0.00), (0.50, 0.03), (0.48, 0.08), (0.38, 0.11),
        (0.34, 0.15), (0.25, 0.21), (0.215, 0.28), (0.20, 0.62), (0.21, 0.68),
        (0.27, 0.72), (0.27, 0.76), (0.225, 0.79), (0.20, 0.82), (0.225, 0.87),
        (0.26, 0.92), (0.28, 0.98), (0.285, 1.04), (0.25, 1.07), (0.21, 1.10),
        (0.225, 1.13), (0.00, 1.14)]

KNIGHT_BASE = [(0.00, 0.00), (0.44, 0.00), (0.46, 0.03), (0.44, 0.08), (0.36, 0.11),
               (0.33, 0.15), (0.29, 0.20), (0.27, 0.26), (0.28, 0.30), (0.00, 0.31)]


def build_pawn():
    return revolve(catmull_rom(PAWN, 3), 28)


def build_rook():
    m = revolve(catmull_rom(ROOK, 3), 28)
    m.merge(ring_teeth(6, 0.30, 0.88, 0.20, 0.19, 0.17, 0.295))
    return m


def build_bishop():
    m = revolve(catmull_rom(BISHOP, 3), 28)
    m.merge(sphere(0.068, (0.0, 1.71, 0.0), 18, 12))
    return m


def build_queen():
    m = revolve(catmull_rom(QUEEN, 3), 28)
    m.merge(ring_teeth(9, 0.24, 1.10, 0.11, 0.075, 0.075, 0.235))
    m.merge(sphere(0.072, (0.0, 1.20, 0.0), 20, 14))
    return m


def build_king():
    m = revolve(catmull_rom(KING, 3), 28)
    base_y = 1.12
    m.merge(box((0.075, 0.34, 0.075), (0.0, base_y + 0.15, 0.0)))
    m.merge(box((0.235, 0.075, 0.075), (0.0, base_y + 0.20, 0.0)))
    return m


def build_knight():
    m = revolve(catmull_rom(KNIGHT_BASE, 3), 28)
    m.merge(sweep_knight(30, 22))
    return m


BUILDERS = {
    "pawn": build_pawn,
    "rook": build_rook,
    "knight": build_knight,
    "bishop": build_bishop,
    "queen": build_queen,
    "king": build_king,
}

# Sizes follow a real tournament Staunton set (king 95 mm, pawn 45 mm, base
# 38-42 mm) against a 57 mm square, scaled so that one square = 4 studs
# (Config.TileSize). A king therefore stands 6.67 studs tall on a 4-stud tile,
# and every base is 60-74% of the square, like a real board.
TARGET_HEIGHT = {
    "pawn": 3.16, "rook": 4.35, "knight": 4.77,
    "bishop": 4.91, "queen": 5.75, "king": 6.67,
}

# Base *radius* in studs (diameters 2.39-2.95 on a 4-stud square). Real sets keep
# base diameters close across the family, so height scaling alone is not enough.
TARGET_BASE = {
    "pawn": 1.20, "rook": 1.27, "knight": 1.30,
    "bishop": 1.34, "queen": 1.41, "king": 1.48,
}


def obj_text(mesh, name):
    normals = mesh.normals()
    lines = [
        "# %s — generated by tools/make_pieces.py (MIT, same licence as the repo)" % name,
        "# %d vertices, %d faces, units = studs, +Y up, origin at the base" % (
            len(mesh.verts), len(mesh.faces)),
        "o %s" % name,
    ]
    for x, y, z in mesh.verts:
        lines.append("v %.5f %.5f %.5f" % (x, y, z))
    for nx, ny, nz in normals:
        lines.append("vn %.4f %.4f %.4f" % (nx, ny, nz))
    for face in mesh.faces:
        lines.append("f " + " ".join("%d//%d" % (i + 1, i + 1) for i in face))
    return "\n".join(lines) + "\n"


def write_obj(path, mesh, name):
    with open(path, "w") as fh:
        fh.write(obj_text(mesh, name))


CHECK_ONLY = False
stale = []


def main():
    global CHECK_ONLY
    if "--check" in os.sys.argv[1:]:
        CHECK_ONLY = True
    os.makedirs(OUT_DIR, exist_ok=True)
    manifest = {}
    for name, builder in BUILDERS.items():
        mesh = builder()
        # normalise: scale so the mesh is exactly TARGET_HEIGHT studs tall,
        # and recentre so the base sits at y = 0
        ys = [v[1] for v in mesh.verts]
        low, height = min(ys), max(ys) - min(ys)
        k = TARGET_HEIGHT[name] / height
        # measure the base radius (bottom 12% of the mesh) before scaling
        base_r = max(math.hypot(v[0], v[2]) for v in mesh.verts if v[1] < low + height * 0.12) or 1.0
        kr = TARGET_BASE[name] / (base_r * k)
        mesh.transform(lambda v: (v[0] * k * kr, (v[1] - low) * k, v[2] * k * kr))
        path = os.path.join(OUT_DIR, name + ".obj")
        if CHECK_ONLY:
            existing = ""
            if os.path.exists(path):
                with open(path) as fh:
                    existing = fh.read()
            fresh = obj_text(mesh, name)
            if existing != fresh:
                stale.append(name)
            continue
        write_obj(path, mesh, name)
        tris = sum(len(f) - 2 for f in mesh.faces)
        xs = [v[0] for v in mesh.verts]
        ys2 = [v[1] for v in mesh.verts]
        zs = [v[2] for v in mesh.verts]
        manifest[name] = {
            "file": name + ".obj",
            "triangles": tris,
            "vertices": len(mesh.verts),
            "height_studs": round(TARGET_HEIGHT[name], 3),
            "bbox_studs": [round(max(xs) - min(xs), 4),
                           round(max(ys2) - min(ys2), 4),
                           round(max(zs) - min(zs), 4)],
            "yaw_degrees": 180 if name == "knight" else 0,
        }
        print("%-7s %5d tris  %5d verts  -> %s" % (name, tris, len(mesh.verts), path))

    if CHECK_ONLY:
        # --check must never touch the working tree
        if stale:
            print("mesh files are out of date, re-run tools/make_pieces.py: " + ", ".join(stale))
            raise SystemExit(1)
        print("piece meshes are up to date")
        return

    total = sum(m["triangles"] for m in manifest.values())
    with open(os.path.join(OUT_DIR, "manifest.json"), "w") as fh:
        json.dump({"generatedBy": "tools/make_pieces.py", "pieces": manifest,
                   "totalTrianglesPerSet": total}, fh, indent=2)

    print("\n%d triangles per full set of 32 pieces (all six meshes, one colour each)"
          % (total * 2))


if __name__ == "__main__":
    import sys
    CHECK_ONLY = "--check" in sys.argv[1:]
    main()
