"""Build "Dewey", a procedurally modelled, rigged Drosophila melanogaster (male), in Blender.

Run (Blender 5.x, headless) from anywhere:

    blender -b -P pipeline/blender/build_dewey.py -- [--no-render] [--samples=64] [--no-usd] [--blend=out.blend]

What it does
------------
* Reads flybody's rig (`app/Sources/FlyApp/Resources/fly/body.json`, TuragaLab/flybody, Apache-2.0):
  body names, hierarchy, body frames, joints (names/axes/ranges/springrefs). These are copied
  unchanged, so `FlyRig` + `JointAnimator` drive Dewey exactly like flybody.
* Models every body procedurally in the zero-joint pose (world = thorax frame, 1 Blender unit = 1 mm):
  - thorax / abdomen segments: "lathe fits" (rings x sectors ray-cast onto flybody's decimated mesh,
    which is used only as a proportion guide), Taubin-smoothed; colour regions (notum stripes,
    pleura, tergite bands, dark male tip, pale sternites) follow the ring/sector grid so the
    boundaries are clean;
  - head capsule, coxae, proboscis, halteres, antennae: quad-sphere star fits;
  - compound eyes: a Goldberg (hexagonal) facet shell — one domed lens per ommatidium (~700/eye) —
    projected onto flybody's eye outline;
  - legs: tapered tubes whose axis and radius profile follow flybody's segments, with distal hairs,
    tibial spurs, a male sex comb on the T1 basitarsus, 5th tarsomere, paired claws and pulvilli;
  - wings: membrane outline fitted to flybody's wing, Drosophila venation (C, L1-L6, humeral, ACV, PCV)
    as thin vein tubes plus a baked RGBA vein texture;
  - macrochaetae (thorax, scutellum, head), microchaetae, abdominal bristle rows, ocelli, plumose aristae.
* Builds an Armature with one bone per flybody body (bone frame == body frame, so joint axes are
  bone-local axes; joints are stored as the custom property "joints" on each bone), a single skinned
  mesh (rigid region weights: every vertex weight 1 to the body it belongs to), Blender materials,
  and exports `Resources/dewey/Dewey.usdz`.
* Writes the runtime format: per-body rigid OBJ pieces (one per body x material, vertices in the body
  frame in cm, with vt/vn, `mtllib dewey.mtl`) and a `body.json` in the exact schema of
  `Resources/fly/body.json` (plus an ignored "textures" map for a texture-aware loader).
* Bakes two small textures: `ommatidium.png` (Cycles EMIT bake of a procedural lens shader, mapped
  per facet) and `wing_albedo.png` (RGBA venation, rasterised from the same vein table).
* Renders `renders/v2/E_blender.png` (Cycles, 3/4 view, rest pose = spring-reference wings + standing legs).
"""
from __future__ import annotations

import json
import math
import random
import sys
from pathlib import Path

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Quaternion, Vector
from mathutils.bvhtree import BVHTree

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
FLY = ROOT / "app/Sources/FlyApp/Resources/fly"
OUT = ROOT / "app/Sources/FlyApp/Resources/dewey"
RENDERS = ROOT / "renders/v2"
ARGV = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
DO_RENDER = "--no-render" not in ARGV
DO_USD = "--no-usd" not in ARGV
SAMPLES = int(next((a.split("=")[1] for a in ARGV if a.startswith("--samples=")), 64))
S = 10.0  # Blender units (mm) per body.json unit (cm)
rng = random.Random(1709)

# Runtime materials (sRGB, alpha). Names are free-form for FlyRig; "wing" and "eye" get special shading there.
MATERIALS = {
    "body":    [0.58, 0.40, 0.22, 1.0],   # thorax cuticle, tan-brown
    "stripe":  [0.36, 0.23, 0.12, 1.0],   # darker notum stripes
    "pleura":  [0.62, 0.45, 0.27, 1.0],   # thorax sides
    "lower":   [0.84, 0.70, 0.48, 1.0],   # pale sternites, proboscis, halteres
    "frons":   [0.80, 0.50, 0.22, 1.0],   # orange frons / head top
    "tergum":  [0.80, 0.63, 0.34, 1.0],   # pale-yellow abdominal tergites
    "tergite": [0.20, 0.12, 0.07, 1.0],   # dark tergite bands / male tip
    "leg":     [0.76, 0.57, 0.33, 1.0],
    "dark":    [0.09, 0.06, 0.04, 1.0],   # bristles, claws, aristae
    "eye":     [0.74, 0.05, 0.03, 1.0],
    "ocelli":  [0.55, 0.30, 0.08, 1.0],
    "vein":    [0.45, 0.32, 0.18, 1.0],
    "wing":    [0.86, 0.88, 0.90, 0.22],
}
TEXTURES = {"wing": {"diffuse": "wing_albedo.png"}, "eye": {"diffuse": "ommatidium.png"}}

# ----------------------------------------------------------------------------------------------
# flybody rig
# ----------------------------------------------------------------------------------------------
FLYDOC = json.loads((FLY / "body.json").read_text())
BODIES = FLYDOC["bodies"]
BY_NAME = {b["name"]: b for b in BODIES}
W: dict[str, Matrix] = {}
for b in BODIES:
    local = Matrix.Translation(Vector(b["pos"]) * S) @ Quaternion(b["quat"]).to_matrix().to_4x4()
    W[b["name"]] = (W[b["parent"]] @ local) if b["parent"] else local
CHILDREN: dict[str, list[str]] = {}
for b in BODIES:
    if b["parent"]:
        CHILDREN.setdefault(b["parent"], []).append(b["name"])


def origin(name: str) -> Vector:
    return W[name].translation.copy()


def axis_of(name: str, i: int) -> Vector:
    return W[name].col[i].xyz.normalized()


_ref_cache: dict = {}


def ref(body: str, mats=("body", "lower")):
    """flybody's decimated mesh(es) for `body`, in world mm (zero pose): (verts, faces)."""
    key = (body, tuple(mats))
    if key in _ref_cache:
        return _ref_cache[key]
    vs, fs = [], []
    for mat in mats:
        p = FLY / f"{body}_{mat}.obj"
        if not p.exists():
            continue
        base = len(vs)
        for line in p.read_text().splitlines():
            if line.startswith("v "):
                vs.append(W[body] @ (Vector([float(x) for x in line.split()[1:4]]) * S))
            elif line.startswith("f "):
                idx = [int(t.split("/")[0]) - 1 + base for t in line.split()[1:]]
                for k in range(1, len(idx) - 1):
                    fs.append((idx[0], idx[k], idx[k + 1]))
    _ref_cache[key] = (vs, fs) if vs else None
    return _ref_cache[key]


def bvh_of(vs, fs):
    return BVHTree.FromPolygons(vs, fs)


# ----------------------------------------------------------------------------------------------
# geometry container
# ----------------------------------------------------------------------------------------------
class Part:
    __slots__ = ("body", "mat", "v", "f", "vn", "cn", "cuv")

    def __init__(self, body, mat, v, f, vn=None, cn=None, cuv=None):
        self.body, self.mat, self.v, self.f, self.vn, self.cn, self.cuv = body, mat, v, f, vn, cn, cuv


PARTS: list[Part] = []


def vertex_normals(v, f):
    n = [Vector((0, 0, 0)) for _ in v]
    for face in f:
        p0 = v[face[0]]
        for k in range(1, len(face) - 1):
            c = (v[face[k]] - p0).cross(v[face[k + 1]] - p0)
            for i in (face[0], face[k], face[k + 1]):
                n[i] += c
    return [x.normalized() if x.length > 1e-14 else Vector((0, 0, 1)) for x in n]


def add(body, mat, v, f, vn=None, cn=None, cuv=None):
    if not f:
        return
    PARTS.append(Part(body, mat, v, f, vn if vn is not None or cn is not None else vertex_normals(v, f), cn, cuv))


def add_classified(body, v, f, classify, info=None):
    """Adds one smooth mesh split into materials; normals are shared so seams stay smooth."""
    vn = vertex_normals(v, f)
    groups: dict[str, list] = {}
    for k, face in enumerate(f):
        cen = sum((v[i] for i in face), Vector()) / len(face)
        nrm = sum((vn[i] for i in face), Vector()).normalized()
        groups.setdefault(classify(cen, nrm, info[k] if info else None), []).append(face)
    for mat, faces in groups.items():
        PARTS.append(Part(body, mat, v, faces, vn))


def adjacency(nv, f):
    nb = [set() for _ in range(nv)]
    for face in f:
        for k in range(len(face)):
            a, b = face[k], face[(k + 1) % len(face)]
            nb[a].add(b)
            nb[b].add(a)
    return [list(s) for s in nb]


def taubin(v, f, iters=3, lam=0.5, mu=-0.53, pinned=()):
    nb = adjacency(len(v), f)
    pinned = set(pinned)
    for _ in range(iters):
        for fac in (lam, mu):
            new = []
            for i, p in enumerate(v):
                if i in pinned or not nb[i]:
                    new.append(p)
                    continue
                avg = sum((v[j] for j in nb[i]), Vector()) / len(nb[i])
                new.append(p + fac * (avg - p))
            v[:] = new


def pca(points):
    P = np.array([tuple(p) for p in points])
    m = P.mean(0)
    X = P - m
    w, V = np.linalg.eigh(X.T @ X / len(P))
    V = V[:, w.argsort()[::-1]]
    if np.linalg.det(V) < 0:
        V[:, 2] *= -1
    Q = X @ V
    lo, hi = Q.min(0), Q.max(0)
    c = m + V @ ((lo + hi) / 2)
    return Vector(c), Matrix(V.tolist()), (hi - lo) / 2


def quad_sphere(n):
    verts, index, faces = [], {}, []
    X, Y, Z = Vector((1, 0, 0)), Vector((0, 1, 0)), Vector((0, 0, 1))
    sides = [(X, Y, Z), (-X, Z, Y), (Y, Z, X), (-Y, X, Z), (Z, X, Y), (-Z, Y, X)]

    def vid(p):
        key = (round(p.x, 5), round(p.y, 5), round(p.z, 5))
        if key not in index:
            index[key] = len(verts)
            verts.append(p)
        return index[key]

    for N, U, V in sides:
        grid = [[vid((N + U * math.tan((-1 + 2 * i / n) * math.pi / 4) + V * math.tan((-1 + 2 * j / n) * math.pi / 4)).normalized())
                 for j in range(n + 1)] for i in range(n + 1)]
        for i in range(n):
            for j in range(n):
                faces.append((grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]))
    return verts, faces


def star_fit(refm, n=8, smooth=3, scale=(1, 1, 1), inflate=0.0):
    """Quad sphere ray-cast (from outside, towards the PCA centre) onto a reference mesh."""
    vs, fs = refm
    bvh = bvh_of(vs, fs)
    c, R, radii = pca(vs)
    sv, sf = quad_sphere(n)
    big = 4 * float(max(radii))
    out = []
    for d in sv:
        e = c + R @ Vector((d.x * radii[0] * scale[0], d.y * radii[1] * scale[1], d.z * radii[2] * scale[2]))
        dv = (e - c)
        dl = dv.length
        dv.normalize()
        hit = bvh.ray_cast(c + dv * big, -dv, 2 * big)
        if hit[0] is not None and (hit[0] - c).length < 1.6 * dl + 1e-9:
            out.append(hit[0])
        else:
            out.append(e)
    taubin(out, sf, smooth)
    if inflate:
        vn = vertex_normals(out, sf)
        out = [p + nn * inflate for p, nn in zip(out, vn)]
    return out, sf


def lathe_fit(refm, a, up, nr, ns, smooth=2, end_pull=1.0):
    """Rings (along axis a) x sectors (angle from `up` about a) ray-cast onto a reference mesh.

    Returns verts, faces, info where info[k] = (ring fraction 0..1 along +a, sector angle in (-pi, pi]).
    """
    vs, fs = refm
    bvh = bvh_of(vs, fs)
    a = a.normalized()
    u = (up - a * up.dot(a)).normalized()
    w = a.cross(u)
    P = np.array([tuple(p) for p in vs])
    o = Vector(P.mean(0))
    A = np.array(tuple(a))
    t = (P - np.array(tuple(o))) @ A
    tmin, tmax = float(t.min()), float(t.max())
    L = tmax - tmin
    big = 4 * float(np.linalg.norm(P.max(0) - P.min(0)))
    rings_t = [tmin + L * (1 - math.cos(math.pi * (i + 0.5) / nr)) / 2 for i in range(nr)]
    centres = []
    for ti in rings_t:
        mask = np.abs(t - ti) < max(L / nr, 1e-6) * 0.9
        if mask.sum() < 3:
            mask = np.abs(t - ti) < L / 4
        cc = Vector(P[mask].mean(0))
        cc = cc + a * (ti - (cc - o).dot(a))
        centres.append(cc)
    for _ in range(2):
        centres = [centres[0]] + [(centres[i - 1] + 2 * centres[i] + centres[i + 1]) / 4
                                  for i in range(1, nr - 1)] + [centres[-1]]
    v, f, info = [], [], []
    for i, cc in enumerate(centres):
        for j in range(ns):
            th = 2 * math.pi * j / ns
            r = u * math.cos(th) + w * math.sin(th)
            hit = bvh.ray_cast(cc + r * big, -r, big)
            v.append(hit[0] if hit[0] is not None else bvh.find_nearest(cc + r * 1e-3)[0])
    s_hit = bvh.ray_cast(centres[0] - a * big, a, 2 * big)[0] or (centres[0] - a * 0.05)
    e_hit = bvh.ray_cast(centres[-1] + a * big, -a, 2 * big)[0] or (centres[-1] + a * 0.05)
    s_apex = centres[0] + (s_hit - centres[0]) * end_pull
    e_apex = centres[-1] + (e_hit - centres[-1]) * end_pull
    si = len(v)
    v.append(s_apex)
    ei = len(v)
    v.append(e_apex)

    def ang(j):
        th = 2 * math.pi * (j + 0.5) / ns
        return th if th <= math.pi else th - 2 * math.pi

    for i in range(nr - 1):
        for j in range(ns):
            j2 = (j + 1) % ns
            f.append((i * ns + j, i * ns + j2, (i + 1) * ns + j2, (i + 1) * ns + j))
            info.append(((i + 1) / nr, ang(j)))
    for j in range(ns):
        j2 = (j + 1) % ns
        f.append((j2, j, si))
        info.append((0.0, ang(j)))
        f.append(((nr - 1) * ns + j, (nr - 1) * ns + j2, ei))
        info.append((1.0, ang(j)))
    taubin(v, f, smooth)
    return v, f, info


def tube(path, radii, sides=8, cap0=True, cap1=True, tip0=0.6, tip1=0.6, twist=0.0):
    """Generalised cylinder with parallel-transport frames; caps are short cones (rounded look)."""
    n = len(path)
    tang = []
    for i in range(n):
        d = path[min(i + 1, n - 1)] - path[max(i - 1, 0)]
        tang.append(d.normalized())
    ref_up = Vector((0, 0, 1)) if abs(tang[0].z) < 0.9 else Vector((1, 0, 0))
    nrm = (ref_up - tang[0] * ref_up.dot(tang[0])).normalized()
    frames = []
    for i in range(n):
        if i:
            nrm = (nrm - tang[i] * nrm.dot(tang[i])).normalized()
        frames.append((nrm.copy(), tang[i].cross(nrm)))
    v, f = [], []
    for i in range(n):
        N, B = frames[i]
        for k in range(sides):
            th = 2 * math.pi * k / sides + twist
            v.append(path[i] + (N * math.cos(th) + B * math.sin(th)) * radii[i])
    for i in range(n - 1):
        for k in range(sides):
            k2 = (k + 1) % sides
            f.append((i * sides + k, i * sides + k2, (i + 1) * sides + k2, (i + 1) * sides + k))
    if cap0 and radii[0] > 0:
        a = len(v)
        v.append(path[0] - tang[0] * radii[0] * tip0)
        for k in range(sides):
            f.append(((k + 1) % sides, k, a))
    if cap1:
        a = len(v)
        v.append(path[-1] + tang[-1] * radii[-1] * tip1)
        for k in range(sides):
            last = (n - 1) * sides
            f.append((last + k, last + (k + 1) % sides, a))
    return v, f


def bristle(body, base, direction, length, radius, bend=None, segs=3, sides=3, mat="dark"):
    d = direction.normalized()
    if segs == 1:
        a = (Z - d * Z.dot(d))
        a = a.normalized() if a.length > 1e-6 else (X - d * X.dot(d)).normalized()
        b = d.cross(a)
        base0 = base - d * radius
        v = [base0 + (a * math.cos(2 * math.pi * k / 3) + b * math.sin(2 * math.pi * k / 3)) * radius for k in range(3)]
        v.append(base + d * length)
        add(body, mat, v, [(0, 1, 3), (1, 2, 3), (2, 0, 3)])
        return
    bend = bend if bend is not None else Vector((0, 0, 0))
    path = [base - d * radius * 1.5]
    for s in range(1, segs + 1):
        x = s / segs
        path.append(base + d * length * x + bend * length * x * x)
    radii = [radius] + [radius * (1 - s / (segs + 0.6)) for s in range(1, segs + 1)]
    v, f = tube(path, radii, sides=sides, cap0=False, cap1=True, tip1=2.5)
    add(body, mat, v, f)


def surface_hit(bvh, origin_pt, direction):
    hit = bvh.ray_cast(origin_pt, direction, 100.0)
    return (hit[0], hit[1]) if hit[0] is not None else (None, None)


def bbox(points):
    P = np.array([tuple(p) for p in points])
    return P.min(0), P.max(0)


# ----------------------------------------------------------------------------------------------
# thorax
# ----------------------------------------------------------------------------------------------
X, Y, Z = Vector((1, 0, 0)), Vector((0, 1, 0)), Vector((0, 0, 1))
STRIPE_DEG = [(9, 17), (30, 38)]  # notum stripe angle bands (deg from dorsal midline)


def build_thorax():
    r = ref("thorax", ("body",))
    v, f, info = lathe_fit(r, X, Z, nr=30, ns=56, smooth=3)
    lo, hi = bbox(v)

    def cls(c, n, inf):
        tf, th = inf
        d = abs(math.degrees(th))
        if d < 62:
            if 0.30 < tf < 0.93 and any(a <= d <= b for a, b in STRIPE_DEG):
                return "stripe"
            return "body"
        if d < 128:
            return "pleura"
        return "lower"

    add_classified("thorax", v, f, cls, info)
    bvh = bvh_of(v, f)

    def top(fx, fy):
        x = lo[0] + fx * (hi[0] - lo[0])
        y = (lo[1] + hi[1]) / 2 + fy * (hi[1] - lo[1]) / 2
        return surface_hit(bvh, Vector((x, y, hi[2] + 1)), -Z)

    L = hi[0] - lo[0]
    # Macrochaetae (fx from posterior=0 to anterior=1, fy lateral fraction), per side.
    macro = [  # (fx, fy, length/L, lateral splay)
        (0.42, 0.30, 0.34, 0.05), (0.62, 0.30, 0.30, 0.05),   # dorsocentrals (posterior, anterior)
        (0.40, 0.58, 0.30, 0.25), (0.28, 0.62, 0.30, 0.30),   # supra-alar / postalar
        (0.70, 0.74, 0.26, 0.45), (0.86, 0.66, 0.24, 0.45),   # notopleural / humeral
        (0.55, 0.70, 0.24, 0.40),
    ]
    for side in (1, -1):
        for fx, fy, ln, splay in macro:
            p, n = top(fx, side * fy)
            if p is None:
                continue
            d = -X + n * 0.55 + Y * side * splay
            bristle("thorax", p, d, ln * L, 0.0085, bend=-n * 0.25, segs=4, sides=4)
        # scutellar bristles: apical pair long, crossing over the midline; basal pair shorter
        for fx, fy, ln, cross in ((0.06, 0.16, 0.44, 0.35), (0.14, 0.34, 0.32, -0.05)):
            p, n = top(fx, side * fy)
            if p is None:
                continue
            d = -X + n * 0.35 - Y * side * cross
            bristle("thorax", p, d, ln * L, 0.009, bend=-n * 0.2, segs=4, sides=4)
    # Microchaetae in loose rows on the scutum.
    for k in range(150):
        fx = rng.uniform(0.28, 0.92)
        fy = rng.uniform(-0.62, 0.62) * math.sqrt(max(0.0, 1 - ((fx - 0.6) / 0.42) ** 2))
        p, n = top(fx, fy)
        if p is None:
            continue
        d = -X + n * 0.5 + Y * fy * 0.3
        bristle("thorax", p, d, rng.uniform(0.045, 0.06) * L / 1.0, 0.0042, segs=1, sides=3)


# ----------------------------------------------------------------------------------------------
# head, eyes, ocelli, antennae, proboscis
# ----------------------------------------------------------------------------------------------
def goldberg_dirs(subdiv):
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdiv, radius=1.0)
    bm.faces.ensure_lookup_table()
    fc = [f.calc_center_median().normalized() for f in bm.faces]
    cells = []
    for v in bm.verts:
        n = v.co.normalized()
        ring = [fc[f.index] for f in v.link_faces]
        u = (ring[0] - n * ring[0].dot(n)).normalized()
        w = n.cross(u)
        ring.sort(key=lambda r: math.atan2(r.dot(w), r.dot(u)))
        cells.append((n, ring))
    bm.free()
    return cells


EYE_CELLS = None
EYE_BULGE = 1.05
EYE_EXPAND = 1.18


def eye_facets(eye_pts, target_bvh, E, rot, expand):
    """Goldberg cells whose centre direction (from E) lies inside flybody's eye outline, widened by
    `expand` (per-azimuth angular profile); every cell vertex is ray-cast onto `target_bvh`."""
    A = (sum(eye_pts, Vector()) / len(eye_pts) - E).normalized()
    u = (Z - A * Z.dot(A)).normalized()
    w = A.cross(u)
    NBIN = 24

    def polar(d):
        return math.acos(max(-1.0, min(1.0, d.dot(A)))), math.atan2(d.dot(w), d.dot(u))

    prof = [0.0] * NBIN
    for p in eye_pts:
        th, az = polar((p - E).normalized())
        b = int((az + math.pi) / (2 * math.pi) * NBIN) % NBIN
        prof[b] = max(prof[b], th)
    for b in range(NBIN):
        if prof[b] == 0.0:
            prof[b] = max(prof)
    prof = [(prof[b - 1] + 2 * prof[b] + prof[(b + 1) % NBIN]) / 4 for b in range(NBIN)]
    big = 5.0
    cache = {}

    def proj(d):
        key = (round(d.x, 6), round(d.y, 6), round(d.z, 6))
        if key not in cache:
            dd = rot @ d
            h = target_bvh.ray_cast(E + dd * big, -dd, big)
            cache[key] = (h[0], h[1]) if h[0] is not None else (None, None)
        return cache[key]

    facets = []
    for n, ring in EYE_CELLS:
        th, az = polar(rot @ n)
        x = (az + math.pi) / (2 * math.pi) * NBIN - 0.5
        b0 = int(math.floor(x)) % NBIN
        fr = x - math.floor(x)
        lim = prof[b0] * (1 - fr) + prof[(b0 + 1) % NBIN] * fr
        if th > lim * expand:
            continue
        pc, nc = proj(n)
        if pc is None:
            continue
        pr = [proj(r)[0] for r in ring]
        if any(p is None for p in pr):
            continue
        facets.append((pc, nc, pr))
    return facets


def build_head():
    cap_ref = ref("head", ("body", "eye"))
    v, f = star_fit(cap_ref, n=13, smooth=3)
    # Pull the face back between the eyes (flybody's face protrudes; real eyes dominate the front view).
    xf = max(p.x for p in ref("head", ("eye",))[0])
    v = [Vector((xf + (p.x - xf) * 0.55, p.y, p.z)) if p.x > xf else p for p in v]
    lo, hi = bbox(v)
    cx = (lo[0] + hi[0]) / 2

    def cls(c, n, _):
        if n.z < -0.35:
            return "lower"
        if c.x > cx + 0.05 * (hi[0] - lo[0]) and n.x > 0.2:
            return "frons"
        return "body" if n.z < 0.45 else "frons"

    add_classified("head", v, f, cls)
    head_bvh = bvh_of(v, f)
    hc = Vector(((lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2))

    # Compound eyes.
    er = ref("head", ("eye",))
    for side in (1, -1):
        idx = [i for i, p in enumerate(er[0]) if p.y * side > 0]
        keep = set(idx)
        remap = {i: k for k, i in enumerate(idx)}
        evs = [er[0][i] for i in idx]
        efs = [tuple(remap[i] for i in fc) for fc in er[1] if all(i in keep for i in fc)]
        ec = sum(evs, Vector()) / len(evs)
        best = None
        rot = Matrix.Rotation(0.37 * side, 3, "Z")
        for alpha in (0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0, 1.1):
            centre = ec + (hc - ec) * alpha
            fac = eye_facets(evs, head_bvh, centre, rot, EYE_EXPAND)
            score = abs(len(fac) - 760)
            if best is None or score < best[0]:
                best = (score, fac, alpha)
        facets = best[1]
        print(f"eye side={side} facets={len(facets)} alpha={best[2]}")
        E = ec + (hc - ec) * best[2]
        ev, ef, ecn, euv = [], [], [], []
        for pc, nc, pr in facets:
            pc = E + (pc - E) * EYE_BULGE
            pr = [E + (p - E) * EYE_BULGE for p in pr]
            outward = (pc - hc).normalized()
            if nc.dot(outward) < 0:
                nc = -nc
            rad = sum(((p - pc).length for p in pr)) / len(pr)
            lift = nc * 0.004
            apex = pc + nc * rad * 0.28 + lift
            base = len(ev)
            ev.append(apex)
            m = len(pr)
            for k, p in enumerate(pr):
                ev.append(p + lift)
            for k in range(m):
                k2 = (k + 1) % m
                ef.append((base + 1 + k, base + 1 + k2, base))
                rk, rk2 = (pr[k] - pc).normalized(), (pr[k2] - pc).normalized()
                ecn.append(((nc + rk * 0.75).normalized(), (nc + rk2 * 0.75).normalized(), nc))
                a1, a2 = 2 * math.pi * k / m, 2 * math.pi * k2 / m
                euv.append(((0.5 + 0.5 * math.cos(a1), 0.5 + 0.5 * math.sin(a1)),
                            (0.5 + 0.5 * math.cos(a2), 0.5 + 0.5 * math.sin(a2)), (0.5, 0.5)))
        # make sure faces wind outward
        for k, fc in enumerate(ef):
            a, b, c = (ev[i] for i in fc)
            if (b - a).cross(c - a).dot(ecn[k][2]) < 0:
                ef[k] = (fc[1], fc[0], fc[2])
                ecn[k] = (ecn[k][1], ecn[k][0], ecn[k][2])
                euv[k] = (euv[k][1], euv[k][0], euv[k][2])
        add("head", "eye", ev, ef, cn=ecn, cuv=euv)

    L = hi[0] - lo[0]

    def top(fx, fy):
        x = lo[0] + fx * (hi[0] - lo[0])
        y = (lo[1] + hi[1]) / 2 + fy * (hi[1] - lo[1]) / 2
        return surface_hit(head_bvh, Vector((x, y, hi[2] + 1)), -Z)

    # Ocelli: triangle on the vertex.
    for fx, fy, rr in ((0.42, 0.0, 0.034), (0.30, 0.13, 0.03), (0.30, -0.13, 0.03)):
        p, n = top(fx, fy)
        if p is None:
            continue
        sv, sf = quad_sphere(3)
        u = (X - n * X.dot(n)).normalized()
        w = n.cross(u)
        ov = [p + (u * q.x + w * q.y) * rr + n * (q.z * rr * 0.55) for q in sv]
        add("head", "ocelli", ov, sf)
    # Head macrochaetae: (fx, fy, length/L, direction)
    for side in (1, -1):
        for fx, fy, ln, d in (
            (0.36, 0.07, 0.42, X * 0.6 + Y * side * 0.5 + Z * 0.6),        # ocellar
            (0.14, 0.40, 0.48, -X * 0.7 + Y * side * 0.1 + Z * 0.5),       # inner vertical
            (0.12, 0.62, 0.44, -X * 0.5 + Y * side * 0.7 + Z * 0.4),       # outer vertical
            (0.05, 0.12, 0.30, -X * 0.9 - Y * side * 0.3 + Z * 0.3),       # postvertical (crossing)
            (0.52, 0.50, 0.38, -X * 0.6 + Z * 0.7 + Y * side * 0.1),       # orbitals
            (0.66, 0.48, 0.30, X * 0.5 + Z * 0.6 + Y * side * 0.2),
            (0.76, 0.46, 0.28, -X * 0.4 + Z * 0.7),
        ):
            p, n = top(fx, side * fy)
            if p is None:
                continue
            bristle("head", p, d, ln * L, 0.0075, bend=-n * 0.2, segs=3, sides=4)
        for k in range(8):  # postocular row
            p, n = top(rng.uniform(0.04, 0.2), side * rng.uniform(0.55, 0.85))
            if p is not None:
                bristle("head", p, -X + n * 0.6, 0.12 * L, 0.004, segs=1, sides=3)


def build_antennae():
    for side, sname in ((1, "left"), (-1, "right")):
        body = f"antenna_{sname}"
        r = ref(body, ("body",))
        c, R, radii = pca(r[0])
        o = origin(body)
        c = o + (c - o) * 0.55  # tuck the funiculus towards the antennal socket (face midline)
        pv, pf = quad_sphere(3)  # pedicel
        add(body, "frons", [o + (c - o) * 0.15 + q * 0.035 for q in pv], pf)
        sv, f = quad_sphere(5)
        k = (0.62, 0.45, 0.45)
        v = [c + R @ Vector((q.x * radii[0] * k[0], q.y * radii[1] * k[1], q.z * radii[2] * k[2])) for q in sv]
        add(body, "frons", v, f)
        bvh = bvh_of(v, f)
        # Arista: from the dorsolateral base of the 3rd segment, forward/outward/up, plumose.
        out = Y * side
        d0 = (X * 0.9 + out * 0.55 + Z * 0.55).normalized()
        p, n = surface_hit(bvh, c + (out * 0.6 + Z) * 0.5, -(out * 0.6 + Z).normalized())
        if p is None:
            p = c
        L = 0.30
        bend = (-out * 0.15 + Z * 0.05)
        path = [p + d0 * L * s / 8 + bend * L * (s / 8) ** 2 for s in range(9)]
        radii_ = [0.010 * (1 - 0.85 * s / 8) for s in range(9)]
        av, af = tube(path, radii_, sides=4, cap0=True, cap1=True)
        add(body, "dark", av, af)
        # branches: dorsal (longer) and ventral rays in the plane spanned by the shaft and Z
        for k in range(2, 9):
            base = path[k]
            tdir = (path[min(k + 1, 8)] - path[k - 1]).normalized()
            up = (Z - tdir * Z.dot(tdir)).normalized()
            for sgn, ln in ((1, 0.075), (-1, 0.05)):
                if sgn < 0 and k % 2:
                    continue
                bl = ln * (1 - 0.5 * (k - 2) / 7)
                bristle(body, base, tdir * 0.55 + up * sgn, bl, 0.0028, segs=1, sides=3)


def build_proboscis():
    for body, mat, n in (("rostrum", "lower", 6), ("haustellum", "body", 6),
                         ("labrum_left", "lower", 5), ("labrum_right", "lower", 5)):
        mats = ("body", "lower")
        r = ref(body, mats)
        if r is None:
            continue
        v, f = star_fit(r, n=n, smooth=2)
        add(body, mat, v, f)


# ----------------------------------------------------------------------------------------------
# abdomen
# ----------------------------------------------------------------------------------------------
ABD = ["abdomen", "abdomen_2", "abdomen_3", "abdomen_4", "abdomen_5", "abdomen_6", "abdomen_7"]


def build_abdomen():
    for k, body in enumerate(ABD):
        r = ref(body, ("body", "lower"))
        a = axis_of(body, 1)  # local +y points posteriorly along the abdomen chain
        nr, ns = (8, 30) if k < 6 else (7, 26)
        v, f, info = lathe_fit(r, a, Z, nr=nr, ns=ns, smooth=2, end_pull=0.85)
        male_dark = body in ("abdomen_5", "abdomen_6", "abdomen_7")

        def cls(c, n, inf, k=k, male_dark=male_dark):
            tf, th = inf
            d = abs(math.degrees(th))
            if d > 118:
                return "lower"
            if male_dark and d < 105:
                return "tergite"
            if k >= 1 and tf > 0.62 and d < 100:
                return "tergite"
            if k == 0 and tf > 0.75 and d < 60:
                return "tergite"
            return "tergum"

        add_classified(body, v, f, cls, info)
        # posterior-margin bristle row
        if 1 <= k <= 6:
            bvh = bvh_of(v, f)
            P = np.array([tuple(p) for p in v])
            t = P @ np.array(tuple(a))
            tq = t.min() + 0.8 * (t.max() - t.min())
            cc = Vector(P[np.abs(t - tq) < (t.max() - t.min()) * 0.15].mean(0))
            u = (Z - a * Z.dot(a)).normalized()
            w = a.cross(u)
            for j in range(-6, 7):
                th = math.radians(j * 13 + rng.uniform(-3, 3))
                rd = u * math.cos(th) + w * math.sin(th)
                p, n = surface_hit(bvh, cc + rd * 3, -rd)
                if p is None:
                    continue
                bristle(body, p, a + n * 0.45, 0.075 if k < 5 else 0.06, 0.005, segs=2, sides=3)


# ----------------------------------------------------------------------------------------------
# legs
# ----------------------------------------------------------------------------------------------
LEGS = [f"T{i}_{s}" for s in ("left", "right") for i in (1, 2, 3)]
CHAIN = ["femur", "tibia", "tarsus", "tarsus2", "tarsus3", "tarsus4"]


def seg_profile(body, p0, p1, nb):
    r = ref(body, ("body", "lower", "dark"))
    a = (p1 - p0)
    L = a.length
    a = a / L
    if r is None:
        return [p0, p1], [0.02, 0.02], a
    P = np.array([tuple(p) for p in r[0]])
    t = (P - np.array(tuple(p0))) @ np.array(tuple(a))
    lo_, hi_ = np.percentile(t, 1), np.percentile(t, 99)
    lo_, hi_ = max(lo_, -0.25 * L), min(hi_, 1.25 * L)
    edges = np.linspace(lo_, hi_, nb + 1)
    cs, rs = [], []
    for i in range(nb):
        m = (t >= edges[i]) & (t <= edges[i + 1])
        if m.sum() < 3:
            tc = (edges[i] + edges[i + 1]) / 2
            cs.append(p0 + a * tc)
            rs.append(rs[-1] if rs else 0.02)
            continue
        cc = Vector(P[m].mean(0))
        Q = P[m] - np.array(tuple(cc))
        Q = Q - np.outer(Q @ np.array(tuple(a)), np.array(tuple(a)))
        cs.append(cc)
        rs.append(float(np.linalg.norm(Q, axis=1).mean()) * 1.02)
    for _ in range(2):
        cs = [cs[0]] + [(cs[i - 1] + 2 * cs[i] + cs[i + 1]) / 4 for i in range(1, nb - 1)] + [cs[-1]]
        rs = [rs[0]] + [(rs[i - 1] + 2 * rs[i] + rs[i + 1]) / 4 for i in range(1, nb - 1)] + [rs[-1]]
    half = (edges[1] - edges[0]) / 2
    path = [cs[0] - a * half] + cs + [cs[-1] + a * half]
    radii = [rs[0] * 0.92] + rs + [rs[-1] * 0.92]
    return path, radii, a


def hairs_along(body, path, radii, count, length, radius=0.0038, mat="dark", ventral_only=False, t0=0.1, t1=0.95):
    n = len(path)
    for _ in range(count):
        s = rng.uniform(t0, t1) * (n - 1)
        i = min(int(s), n - 2)
        fr = s - i
        c = path[i].lerp(path[i + 1], fr)
        rr = radii[i] + (radii[i + 1] - radii[i]) * fr
        a = (path[i + 1] - path[i]).normalized()
        up = (Z - a * Z.dot(a))
        up = up.normalized() if up.length > 1e-6 else X
        w = a.cross(up)
        th = rng.uniform(math.pi * 0.6, math.pi * 1.4) if ventral_only else rng.uniform(0, 2 * math.pi)
        rd = up * math.cos(th) + w * math.sin(th)
        base = c + rd * rr * 0.9
        bristle(body, base, a * 0.8 + rd * 0.55, length, radius, segs=1, sides=3, mat=mat)


def build_legs():
    for leg in LEGS:
        # coxa
        cb = f"coxa_{leg}"
        r = ref(cb, ("body",))
        v, f = star_fit(r, n=5, smooth=3)
        add(cb, "leg", v, f)
        for k, part in enumerate(CHAIN):
            body = f"{part}_{leg}"
            nxt = f"{CHAIN[k + 1]}_{leg}" if k + 1 < len(CHAIN) else f"claw_{leg}"
            p0, p1 = origin(body), origin(nxt)
            nb = 8 if part in ("femur", "tibia") else 4
            path, radii, a = seg_profile(body, p0, p1, nb)
            sides = 10 if part in ("femur", "tibia") else 7
            mat = "leg"
            v, f = tube(path, radii, sides=sides, tip0=0.5, tip1=0.5)
            add(body, mat, v, f)
            L = (p1 - p0).length
            if part == "femur":
                hairs_along(body, path, radii, 26, 0.06)
            elif part == "tibia":
                hairs_along(body, path, radii, 26, 0.055)
                # apical spurs
                for s in (1, -1):
                    bristle(body, path[-2] + (Z * -0.6 + Y * s * 0.3).normalized() * radii[-2],
                            a + Z * -0.4, 0.07, 0.006, segs=2, sides=3)
            else:
                hairs_along(body, path, radii, 8, 0.04, ventral_only=True)
            if part == "tarsus" and leg.startswith("T1"):
                # male sex comb: a transverse row of ~10 dark, blunt teeth on the basitarsus
                c = path[1].lerp(path[2], 0.3)
                up = (Z - a * Z.dot(a)).normalized()
                w = a.cross(up)
                for j in range(10):
                    th = math.pi * (0.55 + 0.9 * j / 9)
                    rd = up * math.cos(th) + w * math.sin(th)
                    bristle(body, c + rd * radii[1] * 0.9 + a * 0.004 * (j - 4.5), a * 0.6 + rd * 0.8,
                            0.035, 0.0055, segs=1, sides=3)
        # claw body = 5th tarsomere + claws + pulvilli
        body = f"claw_{leg}"
        p0 = origin(body)
        d = (p0 - origin(f"tarsus4_{leg}")).normalized()
        L5 = (p0 - origin(f"tarsus4_{leg}")).length * 1.05
        r4 = 0.016
        prof = seg_profile(f"tarsus4_{leg}", origin(f"tarsus4_{leg}"), p0, 4)
        if prof:
            r4 = prof[1][-2]
        path = [p0 - d * 0.01, p0 + d * L5 * 0.5, p0 + d * L5]
        v, f = tube(path, [r4 * 0.95, r4 * 1.0, r4 * 0.9], sides=7, tip0=0.4, tip1=0.4)
        add(body, "leg", v, f)
        tip = p0 + d * L5
        side = d.cross(Z).normalized()
        for s in (1, -1):
            bristle(body, tip - d * 0.005, d * 0.7 + side * s * 0.45 + Z * 0.15, 0.05, 0.0065,
                    bend=-Z * 0.9, segs=3, sides=4)
        sv, sf = quad_sphere(2)
        pv = [tip + d * 0.004 - Z * 0.006 + d * q.x * 0.018 + side * q.y * 0.016 + Z * q.z * 0.006 for q in sv]
        add(body, "lower", pv, sf)
        hairs_along(body, path, [r4] * 3, 4, 0.035, ventral_only=True)


# ----------------------------------------------------------------------------------------------
# halteres
# ----------------------------------------------------------------------------------------------
def build_halteres():
    for s in ("left", "right"):
        body = f"haltere_{s}"
        r = ref(body, ("body",))
        v, f = star_fit(r, n=6, smooth=2)
        add(body, "lower", v, f)


# ----------------------------------------------------------------------------------------------
# wings
# ----------------------------------------------------------------------------------------------
VEINS = {  # (u along span 0=hinge..1=tip, w across chord 0=posterior..1=anterior margin), radius mm
    "C":  ([(0.02, 0.93), (0.15, 0.985), (0.45, 0.995), (0.75, 0.99), (0.9, 0.96), (0.975, 0.8), (0.995, 0.55)], 0.013),
    "L1": ([(0.03, 0.80), (0.15, 0.88), (0.30, 0.95), (0.42, 0.99)], 0.010),
    "L2": ([(0.05, 0.70), (0.25, 0.78), (0.50, 0.85), (0.68, 0.92), (0.80, 0.99)], 0.0095),
    "L3": ([(0.05, 0.62), (0.30, 0.64), (0.60, 0.66), (0.85, 0.65), (0.995, 0.57)], 0.0095),
    "L4": ([(0.06, 0.52), (0.30, 0.46), (0.60, 0.38), (0.85, 0.30), (0.985, 0.20)], 0.0095),
    "L5": ([(0.07, 0.42), (0.30, 0.30), (0.55, 0.16), (0.70, 0.06), (0.76, 0.0)], 0.009),
    "L6": ([(0.06, 0.34), (0.18, 0.18), (0.28, 0.03)], 0.008),
    "M":  ([(0.1, 0.01), (0.3, 0.004), (0.6, 0.004), (0.85, 0.01), (0.95, 0.06), (0.99, 0.25), (0.998, 0.5)], 0.0045),
}


def vein_at(name, u):
    pts = VEINS[name][0]
    for (u0, w0), (u1, w1) in zip(pts, pts[1:]):
        if u0 <= u <= u1:
            return w0 + (w1 - w0) * (u - u0) / (u1 - u0)
    return pts[-1][1]


def cross_veins():
    return {
        "hcv": ([(0.07, vein_at("C", 0.07)), (0.08, vein_at("L1", 0.08))], 0.007),
        "acv": ([(0.43, vein_at("L3", 0.43)), (0.44, vein_at("L4", 0.44))], 0.0075),
        "pcv": ([(0.65, vein_at("L4", 0.65)), (0.61, vein_at("L5", 0.61))], 0.0075),
    }


def build_wings():
    for s in ("left", "right"):
        body = f"wing_{s}"
        r = ref(body, ("wing",))
        hinge = origin(body)
        c, R, radii = pca(r[0])
        e1 = R.col[0].normalized()
        if (c - hinge).dot(e1) < 0:
            e1 = -e1
        e2 = R.col[1].normalized()
        e2 = (e2 - e1 * e2.dot(e1)).normalized()
        if e2.dot(X) < 0:
            e2 = -e2
        P = np.array([tuple(p - hinge) for p in r[0]])
        sp = P @ np.array(tuple(e1))
        ch = P @ np.array(tuple(e2))
        smin, smax = float(sp.min()), float(sp.max())
        # Analytic Drosophila wing outline (span-normalised u, chord in units of the max chord Wc,
        # + = anterior), scaled to flybody's wing span/chord and centred on its mid-span chord.
        smin = max(smin, 0.0)
        Lw = smax - smin
        Wc = float(ch.max() - ch.min())
        if not 0.35 * Lw < Wc < 0.55 * Lw:
            Wc = 0.45 * Lw
        ANT = [(0.0, 0.05), (0.06, 0.10), (0.2, 0.17), (0.4, 0.23), (0.6, 0.27), (0.75, 0.28), (0.86, 0.25),
               (0.93, 0.19), (0.97, 0.12), (0.99, 0.05), (1.0, -0.06)]
        POS = [(0.0, -0.05), (0.04, -0.12), (0.08, -0.24), (0.11, -0.26), (0.14, -0.33), (0.25, -0.50),
               (0.4, -0.62), (0.55, -0.68), (0.7, -0.67), (0.82, -0.58), (0.9, -0.47), (0.95, -0.36),
               (0.98, -0.24), (0.995, -0.14), (1.0, -0.06)]
        mid = (sp > smin + 0.4 * Lw) & (sp < smin + 0.6 * Lw)
        coff = float(np.median(ch[mid])) if mid.sum() else 0.0
        coff -= Wc * (0.25 - 0.67) / 2

        def chord(u):
            pp = float(np.interp(u, [q[0] for q in POS], [q[1] for q in POS]))
            aa = float(np.interp(u, [q[0] for q in ANT], [q[1] for q in ANT]))
            return coff + pp * Wc, coff + aa * Wc

        def P3(u, w):
            pp, aa = chord(u)
            return hinge + e1 * (smin + u * Lw) + e2 * (pp + w * (aa - pp))

        # membrane
        us = [0.0] + [0.02 + 0.98 * (1 - math.cos(math.pi * k / 26)) / 2 for k in range(27)]
        us = sorted(set(round(x, 5) for x in us))
        ws = [k / 8 for k in range(9)]
        mv, mf, muv = [], [], []
        for u in us:
            for w in ws:
                mv.append(P3(u, w))
        nwv = len(ws)
        for i in range(len(us) - 1):
            for j in range(nwv - 1):
                a_, b_, c_, d_ = i * nwv + j, (i + 1) * nwv + j, (i + 1) * nwv + j + 1, i * nwv + j + 1
                mf.append((a_, b_, c_, d_))
                muv.append(((us[i], ws[j]), (us[i + 1], ws[j]), (us[i + 1], ws[j + 1]), (us[i], ws[j + 1])))
        add(body, "wing", mv, mf, cuv=muv)
        # veins
        allv = dict(VEINS)
        allv.update(cross_veins())
        for name, (pts, rad) in allv.items():
            dense = []
            for (u0, w0), (u1, w1) in zip(pts, pts[1:]):
                nseg = max(2, int(abs(u1 - u0) * 16) + 1)
                for k in range(nseg):
                    t = k / nseg
                    dense.append((u0 + (u1 - u0) * t, w0 + (w1 - w0) * t))
            dense.append(pts[-1])
            path = [P3(u, w) for u, w in dense]
            taper = [rad * (1.0 - 0.45 * (u)) for u, _ in dense]
            v, f = tube(path, taper, sides=4, tip0=0.8, tip1=0.8, twist=math.pi / 4)
            add(body, "vein", v, f)
        # costal bristles along the anterior margin
        for k in range(26):
            u = 0.05 + 0.85 * k / 25
            p = P3(u, 0.99)
            n = e1.cross(e2)
            bristle(body, p, e1 * 0.7 + e2 * 0.5 + n * (0.2 if k % 2 else -0.2), 0.025, 0.004, segs=1, sides=3)


# ----------------------------------------------------------------------------------------------
# textures
# ----------------------------------------------------------------------------------------------
def srgb_to_lin(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def make_wing_texture(path: Path, w=512, h=256):
    U, Wc = np.meshgrid((np.arange(w) + 0.5) / w, (np.arange(h) + 0.5) / h)
    img = np.zeros((h, w, 4), dtype=np.float32)
    mem = np.array([0.80, 0.82, 0.84])
    img[..., :3] = mem
    img[..., 3] = 0.36
    # faint iridescent tint bands across the membrane
    tint = 0.04 * np.sin(Wc * 9 + U * 5)
    img[..., 0] += tint
    img[..., 2] -= tint
    allv = dict(VEINS)
    allv.update(cross_veins())
    vein = np.array(MATERIALS["vein"][:3])
    for name, (pts, rad) in allv.items():
        dmin = np.full((h, w), 1e9)
        for (u0, w0), (u1, w1) in zip(pts, pts[1:]):
            ax, ay = u0 * w, w0 * h
            bx, by = u1 * w, w1 * h
            px, py = U * w, Wc * h
            vx, vy = bx - ax, by - ay
            t = np.clip(((px - ax) * vx + (py - ay) * vy) / max(vx * vx + vy * vy, 1e-9), 0, 1)
            d = np.hypot(px - (ax + t * vx), py - (ay + t * vy))
            dmin = np.minimum(dmin, d)
        width = 1.4 + rad * 120
        a = np.clip(width - dmin, 0, 1)
        img[..., :3] = img[..., :3] * (1 - a[..., None]) + vein * a[..., None]
        img[..., 3] = np.maximum(img[..., 3], a * 0.95)
    img = np.clip(img, 0, 1)
    lin = np.where(img[..., :3] <= 0.04045, img[..., :3] / 12.92, ((img[..., :3] + 0.055) / 1.055) ** 2.4)
    im = bpy.data.images.new("wing_albedo", w, h, alpha=True)
    px = np.concatenate([img[..., :3], img[..., 3:]], axis=2)  # PNG save writes display (sRGB) values
    im.pixels.foreach_set(px.ravel())
    im.filepath_raw = str(path)
    im.file_format = "PNG"
    im.save()
    _ = lin
    return im


def bake_ommatidium(path: Path, size=128):
    """Cycles EMIT bake of a procedural lens shader (radial gradient -> colour ramp) onto a UV plane."""
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 4
    me = bpy.data.meshes.new("bakeplane")
    me.from_pydata([(-1, -1, 0), (1, -1, 0), (1, 1, 0), (-1, 1, 0)], [], [(0, 1, 2, 3)])
    uv = me.uv_layers.new(name="UVMap")
    for li, (x, y) in enumerate([(0, 0), (1, 0), (1, 1), (0, 1)]):
        uv.data[li].uv = (x, y)
    ob = bpy.data.objects.new("bakeplane", me)
    scene.collection.objects.link(ob)
    mat = bpy.data.materials.new("bake_omm")
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sub = nt.nodes.new("ShaderNodeVectorMath")
    sub.operation = "DISTANCE"
    sub.inputs[1].default_value = (0.5, 0.5, 0.0)
    nt.links.new(tc.outputs["UV"], sub.inputs[0])
    vor = nt.nodes.new("ShaderNodeTexVoronoi")  # fine speckle inside the lens
    vor.inputs["Scale"].default_value = 18.0
    nt.links.new(tc.outputs["UV"], vor.inputs["Vector"])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    cr = ramp.color_ramp
    cr.elements[0].position = 0.0
    cr.elements[0].color = (srgb_to_lin(0.98), srgb_to_lin(0.30), srgb_to_lin(0.18), 1)
    cr.elements[1].position = 0.42
    cr.elements[1].color = (srgb_to_lin(0.72), srgb_to_lin(0.05), srgb_to_lin(0.03), 1)
    e = cr.elements.new(0.50)
    e.color = (srgb_to_lin(0.32), srgb_to_lin(0.02), srgb_to_lin(0.02), 1)
    e = cr.elements.new(0.20)
    e.color = (srgb_to_lin(0.86), srgb_to_lin(0.12), srgb_to_lin(0.06), 1)
    nt.links.new(sub.outputs["Value"], ramp.inputs["Fac"])
    mix = nt.nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    mix.blend_type = "MULTIPLY"
    mix.inputs["Factor"].default_value = 0.12
    nt.links.new(ramp.outputs["Color"], mix.inputs[6])
    nt.links.new(vor.outputs["Color"], mix.inputs[7])
    em = nt.nodes.new("ShaderNodeEmission")
    nt.links.new(mix.outputs[2], em.inputs["Color"])
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(em.outputs[0], out.inputs["Surface"])
    img = bpy.data.images.new("ommatidium", size, size)
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    nt.nodes.active = tex
    me.materials.append(mat)
    for o in bpy.context.scene.objects:
        o.select_set(False)
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob
    bpy.ops.object.bake(type="EMIT")
    img.filepath_raw = str(path)
    img.file_format = "PNG"
    img.save()
    bpy.data.objects.remove(ob)
    return img


# ----------------------------------------------------------------------------------------------
# exports
# ----------------------------------------------------------------------------------------------
def tri_count(f):
    return sum(len(x) - 2 for x in f)


def write_runtime(out: Path):
    out.mkdir(parents=True, exist_ok=True)
    for p in out.glob("*.obj"):
        p.unlink()
    groups: dict[tuple[str, str], list[Part]] = {}
    for p in PARTS:
        groups.setdefault((p.body, p.mat), []).append(p)
    meshes_by_body: dict[str, list] = {}
    total = 0
    for (body, mat), parts in groups.items():
        Minv = W[body].inverted()
        R = Minv.to_3x3()
        vlines, vtlines, vnlines, flines = [], [], [], []
        vt_index, vn_index = {}, {}
        ntri = 0

        def vt_id(uv):
            key = (round(uv[0], 4), round(uv[1], 4))
            if key not in vt_index:
                vt_index[key] = len(vt_index) + 1
                vtlines.append(f"vt {key[0]:.4f} {key[1]:.4f}")
            return vt_index[key]

        def vn_id(n):
            n = (R @ n).normalized()
            key = (round(n.x, 3), round(n.y, 3), round(n.z, 3))
            if key not in vn_index:
                vn_index[key] = len(vn_index) + 1
                vnlines.append(f"vn {key[0]:.3f} {key[1]:.3f} {key[2]:.3f}")
            return vn_index[key]

        vbase = 0
        for part in parts:
            used = sorted({i for fc in part.f for i in fc})
            remap = {}
            for i in used:
                q = (Minv @ part.v[i]) / S
                vlines.append(f"v {q.x:.5f} {q.y:.5f} {q.z:.5f}")
                remap[i] = vbase + len(remap) + 1
            vbase += len(remap)
            for k, fc in enumerate(part.f):
                corners = []
                for c, i in enumerate(fc):
                    n = part.cn[k][c] if part.cn is not None else part.vn[i]
                    uv = part.cuv[k][c] if part.cuv is not None else (0.0, 0.0)
                    corners.append(f"{remap[i]}/{vt_id(uv)}/{vn_id(n)}")
                for t in range(1, len(corners) - 1):
                    flines.append(f"f {corners[0]} {corners[t]} {corners[t + 1]}")
                    ntri += 1
        fname = f"{body}_{mat}.obj"
        (out / fname).write_text("\n".join(
            [f"# Dewey (procedural, Blender) {body}/{mat}: body frame, cm, {ntri} triangles",
             "mtllib dewey.mtl"] + vlines + vtlines + vnlines + [f"usemtl {mat}"] + flines) + "\n")
        total += ntri
        meshes_by_body.setdefault(body, []).append(
            {"file": fname, "pos": [0, 0, 0], "quat": [1, 0, 0, 0], "material": mat, "triangles": ntri})
    primary = {"thorax": "body", "head": "frons", "abdomen_7": "tergite"}
    bodies = []
    for b in BODIES:
        nb = json.loads(json.dumps(b))
        ms = meshes_by_body.get(b["name"], [])
        pm = primary.get(b["name"])
        ms.sort(key=lambda m: (0 if m["material"] == pm else 1, -m["triangles"]))
        nb["meshes"] = ms
        bodies.append(nb)
    doc = {
        "version": 1,
        "source": "Dewey: procedural Blender model (pipeline/blender/build_dewey.py); rig, body frames and "
                  "joints from TuragaLab/flybody fruitfly.xml (Apache-2.0)",
        "units": "cm", "up": "z", "forward": "x",
        "triangles": total,
        "bodies": bodies,
        "materials": MATERIALS,
        "textures": TEXTURES,
    }
    (out / "body.json").write_text(json.dumps(doc, indent=1))
    mtl = ["# Dewey materials (Kd sRGB); texture maps are optional extras"]
    for name, c in MATERIALS.items():
        mtl += [f"newmtl {name}", f"Kd {c[0]:.3f} {c[1]:.3f} {c[2]:.3f}", f"d {c[3]:.2f}", "Ks 0.25 0.25 0.25", "Ns 40"]
        if name in TEXTURES:
            mtl.append(f"map_Kd {TEXTURES[name]['diffuse']}")
            if name == "wing":
                mtl.append(f"map_d {TEXTURES[name]['diffuse']}")
        mtl.append("")
    (out / "dewey.mtl").write_text("\n".join(mtl))
    return total


def build_blender_scene(images):
    scene = bpy.context.scene
    arm_data = bpy.data.armatures.new("DeweyRig")
    arm = bpy.data.objects.new("DeweyRig", arm_data)
    scene.collection.objects.link(arm)
    for o in bpy.context.scene.objects:
        if o is not None:
            o.select_set(False)
    bpy.context.view_layer.objects.active = arm
    bpy.ops.object.mode_set(mode="EDIT")
    for b in BODIES:
        name = b["name"]
        eb = arm_data.edit_bones.new(name)
        M = W[name]
        head = M.translation
        kids = CHILDREN.get(name, [])
        ln = max(((origin(k) - head).length for k in kids), default=0.15)
        ln = max(ln, 0.06)
        eb.head = head
        eb.tail = head + M.col[1].xyz.normalized() * ln
        eb.align_roll(M.col[2].xyz.normalized())
        if b["parent"]:
            eb.parent = arm_data.edit_bones[b["parent"]]
    bpy.ops.object.mode_set(mode="OBJECT")
    for b in BODIES:
        pb = arm.pose.bones[b["name"]]
        pb["joints"] = json.dumps(b["joints"])
        arm_data.bones[b["name"]]["joints"] = json.dumps(b["joints"])

    # materials
    mats = {}
    for name, c in MATERIALS.items():
        m = bpy.data.materials.new(name)
        m.use_nodes = True
        p = m.node_tree.nodes.get("Principled BSDF")
        lin = [srgb_to_lin(x) for x in c[:3]]
        p.inputs["Base Color"].default_value = (*lin, 1)
        p.inputs["Roughness"].default_value = 0.42
        if name in ("body", "stripe", "pleura", "frons", "tergum", "tergite", "leg", "lower"):
            p.inputs["Subsurface Weight"].default_value = 0.25
            p.inputs["Subsurface Radius"].default_value = (1.0, 0.45, 0.2)
            p.inputs["Subsurface Scale"].default_value = 0.04
            p.inputs["Coat Weight"].default_value = 0.35
            p.inputs["Coat Roughness"].default_value = 0.3
        if name == "eye":
            tex = m.node_tree.nodes.new("ShaderNodeTexImage")
            tex.image = images["ommatidium"]
            m.node_tree.links.new(tex.outputs["Color"], p.inputs["Base Color"])
            p.inputs["Roughness"].default_value = 0.28
            p.inputs["Coat Weight"].default_value = 0.7
            p.inputs["Coat Roughness"].default_value = 0.08
        if name == "ocelli":
            p.inputs["Roughness"].default_value = 0.1
            p.inputs["Coat Weight"].default_value = 1.0
        if name == "wing":
            tex = m.node_tree.nodes.new("ShaderNodeTexImage")
            tex.image = images["wing"]
            m.node_tree.links.new(tex.outputs["Color"], p.inputs["Base Color"])
            m.node_tree.links.new(tex.outputs["Alpha"], p.inputs["Alpha"])
            p.inputs["Roughness"].default_value = 0.12
            p.inputs["Thin Film Thickness"].default_value = 420.0
            p.inputs["Thin Film IOR"].default_value = 1.45
            try:
                m.surface_render_method = "BLENDED"
            except Exception:
                pass
        if name == "dark":
            p.inputs["Roughness"].default_value = 0.35
        mats[name] = m
    mat_index = {n: i for i, n in enumerate(MATERIALS)}

    verts, faces, fmat, groups, loop_n, loop_uv = [], [], [], [], [], []
    for part in PARTS:
        used = sorted({i for fc in part.f for i in fc})
        remap = {i: len(verts) + k for k, i in enumerate(used)}
        for i in used:
            verts.append(tuple(part.v[i]))
            groups.append(part.body)
        for k, fc in enumerate(part.f):
            faces.append(tuple(remap[i] for i in fc))
            fmat.append(mat_index[part.mat])
            for c, i in enumerate(fc):
                loop_n.append(tuple(part.cn[k][c] if part.cn is not None else part.vn[i]))
                loop_uv.append(part.cuv[k][c] if part.cuv is not None else (0.0, 0.0))
    me = bpy.data.meshes.new("Dewey")
    me.from_pydata(verts, [], faces)
    for m in mats.values():
        me.materials.append(m)
    me.polygons.foreach_set("material_index", fmat)
    me.shade_smooth()
    uvl = me.uv_layers.new(name="UVMap")
    uvl.data.foreach_set("uv", [x for uv in loop_uv for x in uv])
    me.normals_split_custom_set(loop_n)
    me.validate(clean_customdata=False)
    ob = bpy.data.objects.new("Dewey", me)
    scene.collection.objects.link(ob)
    vg = {}
    for b in BODIES:
        vg[b["name"]] = ob.vertex_groups.new(name=b["name"])
    by_body: dict[str, list[int]] = {}
    for i, g in enumerate(groups):
        by_body.setdefault(g, []).append(i)
    for g, ids in by_body.items():
        vg[g].add(ids, 1.0, "REPLACE")
    ob.parent = arm
    mod = ob.modifiers.new("Armature", "ARMATURE")
    mod.object = arm
    return arm, ob


def pose_rest(arm):
    """flybody spring-reference pose for wings (folded) and legs at 0 (standing), like JointAnimator(.rest)."""
    for b in BODIES:
        pb = arm.pose.bones[b["name"]]
        pb.rotation_mode = "QUATERNION"
        q = Quaternion()
        for j in b["joints"]:
            ang = j.get("springref", 0.0)
            if "_T" in j["name"] or "tarsus" in j["name"]:
                ang = 0.0
            q = q @ Quaternion(Vector(j["axis"]).normalized(), ang)
        pb.rotation_quaternion = q


def render(arm, ob, path: Path):
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    try:
        prefs = bpy.context.preferences.addons["cycles"].preferences
        prefs.compute_device_type = "METAL"
        prefs.get_devices()
        for d in prefs.devices:
            d.use = True
        scene.cycles.device = "GPU"
    except Exception as e:  # CPU fallback
        print("GPU unavailable:", e)
    scene.cycles.samples = SAMPLES
    scene.cycles.use_denoising = True
    scene.render.resolution_x = 1200
    scene.render.resolution_y = 900
    scene.render.film_transparent = False
    scene.view_settings.view_transform = "AgX"
    scene.view_settings.look = "AgX - Medium High Contrast"
    world = bpy.data.worlds.new("w")
    scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    bg.inputs["Color"].default_value = (0.62, 0.66, 0.70, 1)
    bg.inputs["Strength"].default_value = 0.6
    # ground (a pale surface under the claws)
    zmin = min(v.co.z for v in ob.evaluated_get(bpy.context.evaluated_depsgraph_get()).data.vertices)
    gm = bpy.data.meshes.new("ground")
    s = 40
    gm.from_pydata([(-s, -s, zmin), (s, -s, zmin), (s, s, zmin), (-s, s, zmin)], [], [(0, 1, 2, 3)])
    g = bpy.data.objects.new("ground", gm)
    scene.collection.objects.link(g)
    gmat = bpy.data.materials.new("ground")
    gmat.use_nodes = True
    gmat.node_tree.nodes.get("Principled BSDF").inputs["Base Color"].default_value = (0.75, 0.76, 0.78, 1)
    gmat.node_tree.nodes.get("Principled BSDF").inputs["Roughness"].default_value = 0.6
    gm.materials.append(gmat)
    target = Vector((-0.55, 0, 0.25))

    def light(name, kind, loc, energy, size, color=(1, 1, 1)):
        ld = bpy.data.lights.new(name, kind)
        ld.energy = energy
        ld.color = color
        if kind == "AREA":
            ld.size = size
        lo = bpy.data.objects.new(name, ld)
        lo.location = loc
        d = (target - Vector(loc)).normalized()
        lo.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()
        scene.collection.objects.link(lo)

    light("key", "AREA", (6, -8, 12), 1500, 8, (1.0, 0.96, 0.9))
    light("fill", "AREA", (-10, 6, 6), 500, 10, (0.85, 0.9, 1.0))
    light("rim", "AREA", (-8, -2, 9), 900, 5)
    cam_d = bpy.data.cameras.new("cam")
    cam_d.lens = 85
    cam_d.clip_start = 0.05
    cam_d.clip_end = 200
    cam = bpy.data.objects.new("cam", cam_d)
    cam.location = target + Vector((7.5, -9.0, 6.0)) * 0.86
    cam.rotation_euler = (target - cam.location).to_track_quat("-Z", "Y").to_euler()
    scene.collection.objects.link(cam)
    scene.camera = cam
    scene.render.filepath = str(path)
    scene.render.image_settings.file_format = "PNG"
    path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.render.render(write_still=True)


def debug_views(prefix):
    """Extra close-up views for development (top, side, head, wing)."""
    scene = bpy.context.scene
    scene.cycles.samples = max(8, SAMPLES // 4)
    scene.render.resolution_x, scene.render.resolution_y = 900, 700
    cam = scene.camera
    views = {"top": ((-0.4, 0, 16), (-0.4, 0, 0), "X"), "side": ((-0.3, -15, 0.3), (-0.3, 0, 0.3), "Z"),
             "head": ((4.2, -3.2, 2.2), (0.85, 0, 0.15), "Z"), "front": ((9, 0, 1.0), (0.5, 0, 0.1), "Z")}
    for k, (loc, tgt, up) in views.items():
        cam.location = Vector(loc)
        cam.rotation_euler = (Vector(tgt) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
        if k == "top":
            cam.rotation_euler = (0, 0, -math.pi / 2)
        scene.render.filepath = f"{prefix}_{k}.png"
        bpy.ops.render.render(write_still=True)
    arm = bpy.data.objects["DeweyRig"]
    for s in ("left", "right"):
        arm.pose.bones[f"wing_{s}"].rotation_quaternion = Quaternion()
    cam.location = Vector((-0.4, 0, 16))
    cam.rotation_euler = (0, 0, -math.pi / 2)
    cam.data.lens = 50
    scene.render.filepath = f"{prefix}_spread.png"
    bpy.ops.render.render(write_still=True)
    cam.data.lens = 85
    pose_rest(arm)


def export_usd(arm, ob, path: Path):
    for o in bpy.context.scene.objects:
        o.select_set(o in (arm, ob))
    bpy.context.view_layer.objects.active = arm
    kw = dict(filepath=str(path), selected_objects_only=True, export_armatures=True, export_materials=True,
              export_uvmaps=True, export_normals=True, generate_preview_surface=True, root_prim_path="/Dewey",
              export_custom_properties=True, triangulate_meshes=True)
    try:
        bpy.ops.wm.usd_export(**kw, convert_scene_units="CUSTOM", meters_per_unit=0.001)
    except TypeError:
        bpy.ops.wm.usd_export(**kw)


def main():
    global EYE_CELLS
    bpy.ops.wm.read_factory_settings(use_empty=True)
    EYE_CELLS = goldberg_dirs(5)
    build_thorax()
    build_head()
    build_antennae()
    build_proboscis()
    build_abdomen()
    build_legs()
    build_halteres()
    build_wings()
    OUT.mkdir(parents=True, exist_ok=True)
    images = {"wing": make_wing_texture(OUT / "wing_albedo.png"),
              "ommatidium": bake_ommatidium(OUT / "ommatidium.png")}
    total = write_runtime(OUT)
    by_mat: dict[str, int] = {}
    for p in PARTS:
        by_mat[p.mat] = by_mat.get(p.mat, 0) + tri_count(p.f)
    print("triangles by material:", dict(sorted(by_mat.items(), key=lambda kv: -kv[1])))
    print(f"TOTAL triangles = {total}")
    arm, ob = build_blender_scene(images)
    pose_rest(arm)
    if DO_USD:
        export_usd(arm, ob, OUT / "Dewey.usdz")
    if DO_RENDER:
        render(arm, ob, RENDERS / "E_blender.png")
        views = next((a.split("=", 1)[1] for a in ARGV if a.startswith("--views=")), None)
        if views:
            debug_views(views)
    blend = next((a.split("=", 1)[1] for a in ARGV if a.startswith("--blend=")), None)
    if blend:
        bpy.ops.wm.save_as_mainfile(filepath=blend, check_existing=False)
    size = sum(p.stat().st_size for p in OUT.iterdir() if p.is_file())
    print(f"dewey folder size = {size / 1e6:.2f} MB")


main()
