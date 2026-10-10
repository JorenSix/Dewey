# /// script
# requires-python = ">=3.11"
# dependencies = ["trimesh>=4.4", "numpy>=1.26", "fast-simplification>=0.1.7"]
# ///
"""Export the flybody fruit fly (TuragaLab/flybody, Apache-2.0) for the SceneKit app.

Reads data/flybody/flybody/fruitfly/assets/fruitfly.xml (MuJoCo MJCF), resolves the
<default> class hierarchy, keeps only the visual mesh geoms (group 1; collision
primitives live in group 4/5 and are skipped), decimates the meshes to ~20k triangles
in total, merges the geoms of each body per material into one OBJ (vertices expressed in
the body frame), and writes app/Sources/FlyApp/Resources/fly/{body.json,*.obj}.

Run from the repo root:  uv run --script pipeline/export_body.py
"""
from __future__ import annotations

import json
import math
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import numpy as np
import trimesh

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "data/flybody/flybody/fruitfly/assets"
OUT = ROOT / "app/Sources/FlyApp/Resources/fly"
TRIANGLE_BUDGET = 20_000

# MJCF material -> app material. The contract requires body/wing/eye; dark and lower are extras.
MATERIAL_MAP = {
    "body": "body", "lower": "lower", "membrane": "wing", "red": "eye",
    "black": "dark", "brown": "dark", "bristle-brown": "dark", "ocelli": "dark",
}
MATERIALS = {
    "body": [0.62, 0.42, 0.22, 1.0],    # tan/brown cuticle
    "lower": [0.80, 0.63, 0.40, 1.0],   # pale ventral sclerites
    "dark": [0.16, 0.09, 0.05, 1.0],    # bristles, claws, veins, ocelli
    "eye": [0.72, 0.06, 0.04, 1.0],     # red compound eyes
    "wing": [0.85, 0.90, 0.95, 0.35],   # translucent membrane
}
# Parts too small to matter at menu-bar scale (or wing veins), dropped to save triangles.
SKIP_GEOMS = {"rostrum_bristle-brown", "head_black", "haustellum_black",
              "wing_left_brown", "wing_right_brown"}  # vein tubes do not decimate below ~1.6k tris each


def floats(s: str | None, default):
    return [float(x) for x in s.split()] if s else list(default)


def quat_mul(a, b):
    aw, ax, ay, az = a
    bw, bx, by, bz = b
    return [aw * bw - ax * bx - ay * by - az * bz,
            aw * bx + ax * bw + ay * bz - az * by,
            aw * by - ax * bz + ay * bw + az * bx,
            aw * bz + ax * by - ay * bx + az * bw]


def euler_to_quat(e, seq="xyz"):
    # MuJoCo default eulerseq="xyz" (intrinsic, lowercase = moving axes).
    q = [1.0, 0.0, 0.0, 0.0]
    for angle, axis in zip(e, seq):
        h = angle / 2
        v = {"x": [1, 0, 0], "y": [0, 1, 0], "z": [0, 0, 1]}[axis.lower()]
        q = quat_mul(q, [math.cos(h), *(math.sin(h) * c for c in v)])
    return q


def frame(el) -> tuple[list[float], list[float]]:
    pos = floats(el.get("pos"), [0, 0, 0])
    if el.get("quat"):
        q = floats(el.get("quat"), [1, 0, 0, 0])
    elif el.get("euler"):
        q = euler_to_quat(floats(el.get("euler"), [0, 0, 0]))
    elif el.get("axisangle"):
        x, y, z, a = floats(el.get("axisangle"), [0, 0, 1, 0])
        n = math.sqrt(x * x + y * y + z * z) or 1.0
        q = [math.cos(a / 2), *(math.sin(a / 2) * c / n for c in (x, y, z))]
    else:
        q = [1.0, 0.0, 0.0, 0.0]
    n = math.sqrt(sum(c * c for c in q))
    return pos, [c / n for c in q]


def quat_to_mat(q):
    w, x, y, z = q
    return np.array([
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
    ])


class Defaults:
    """Resolves MJCF <default> classes: class name -> {tag: attrs}, with inheritance."""

    def __init__(self, root_default):
        self.classes: dict[str, dict[str, dict[str, str]]] = {}
        self._walk(root_default, "main", {})

    def _walk(self, el, name, inherited):
        mine = {tag: dict(attrs) for tag, attrs in inherited.items()}
        for child in el:
            if child.tag == "default":
                continue
            mine.setdefault(child.tag, {}).update(child.attrib)
        self.classes[name] = mine
        for child in el:
            if child.tag == "default":
                self._walk(child, child.get("class"), mine)

    def resolve(self, el, childclass: str) -> dict[str, str]:
        cls = el.get("class") or childclass
        attrs = dict(self.classes[cls].get(el.tag, {}))
        attrs.update(el.attrib)
        return attrs


def load_mesh(path: Path, scale) -> trimesh.Trimesh:
    # Minimal OBJ reader (positions + faces only; the flybody OBJs reference textures we ignore).
    verts, faces = [], []
    for line in path.read_text().splitlines():
        if line.startswith("v "):
            verts.append([float(x) for x in line.split()[1:4]])
        elif line.startswith("f "):
            idx = [int(tok.split("/")[0]) for tok in line.split()[1:]]
            idx = [i - 1 if i > 0 else len(verts) + i for i in idx]
            for k in range(1, len(idx) - 1):  # fan-triangulate polygons
                faces.append([idx[0], idx[k], idx[k + 1]])
    m = trimesh.Trimesh(vertices=np.asarray(verts) * np.asarray(scale), faces=np.asarray(faces), process=True)
    m.merge_vertices()
    return m


def decimate(m: trimesh.Trimesh, target: int) -> trimesh.Trimesh:
    if len(m.faces) <= target:
        return m
    try:
        d = m.simplify_quadric_decimation(face_count=target)
    except TypeError:  # older trimesh signature
        d = m.simplify_quadric_decimation(target)
    return d if len(d.faces) > 0 else m


def write_obj(path: Path, m: trimesh.Trimesh):
    v = m.vertices
    n = m.vertex_normals
    lines = [f"# flybody (Apache-2.0) decimated, units cm, {len(m.faces)} triangles"]
    lines += [f"v {x:.5f} {y:.5f} {z:.5f}" for x, y, z in v]
    lines += [f"vn {x:.3f} {y:.3f} {z:.3f}" for x, y, z in n]
    lines += [f"f {a}//{a} {b}//{b} {c}//{c}" for a, b, c in (m.faces + 1)]
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    xml = ASSETS / "fruitfly.xml"
    root = ET.parse(xml).getroot()
    defaults = Defaults(root.find("default"))
    mesh_scale = floats(defaults.classes["main"].get("mesh", {}).get("scale"), [1, 1, 1])
    mesh_files = {}
    for m in root.find("asset").iter("mesh"):
        mesh_files[m.get("name")] = (m.get("file"), floats(m.get("scale"), mesh_scale))

    bodies = []
    geoms = []  # (body_name, app_material, mesh_name, pos, quat)

    def walk(body_el, parent, childclass):
        cc = body_el.get("childclass") or childclass
        name = body_el.get("name")
        pos, quat = frame(body_el)
        joints = []
        for j in body_el.findall("joint"):
            a = defaults.resolve(j, cc)
            if a.get("type", "hinge") == "free":
                continue
            jd = {"name": a["name"], "type": a.get("type", "hinge"),
                  "pos": floats(a.get("pos"), [0, 0, 0]), "axis": floats(a.get("axis"), [0, 0, 1])}
            if "range" in a:
                jd["range"] = floats(a["range"], [])
            if "springref" in a:  # flybody's spring rest pose; used by JointAnimator as the neutral pose
                jd["springref"] = float(a["springref"])
            joints.append(jd)
        for g in body_el.findall("geom"):
            a = defaults.resolve(g, cc)
            if a.get("type", "sphere") != "mesh" or a.get("group", "0") != "1":
                continue
            if a.get("name") in SKIP_GEOMS or a.get("mesh") in SKIP_GEOMS:
                continue
            gpos, gquat = frame(g)
            mat = MATERIAL_MAP.get(a.get("material", "body"), "body")
            geoms.append((name, mat, a["mesh"], gpos, gquat))
        bodies.append({"name": name, "parent": parent, "pos": pos, "quat": quat,
                       "meshes": [], "joints": joints})
        for child in body_el.findall("body"):
            walk(child, name, cc)

    for b in root.find("worldbody").findall("body"):
        walk(b, None, "main")

    # Load meshes and transform into body frames.
    loaded = []
    for body, mat, mesh_name, gpos, gquat in geoms:
        file, scale = mesh_files[mesh_name]
        m = load_mesh(ASSETS / file, scale)
        T = np.eye(4)
        T[:3, :3] = quat_to_mat(gquat)
        T[:3, 3] = gpos
        m.apply_transform(T)
        loaded.append((body, mat, mesh_name, m))

    # Triangle budget ~ sqrt(original faces); wings are flat and kept extra simple.
    weights = []
    for body, mat, name, m in loaded:
        w = math.sqrt(len(m.faces))
        if "wing" in name:
            w *= 0.5
        if mat == "eye":
            w *= 1.5
        weights.append(w)
    scale = TRIANGLE_BUDGET / sum(weights)
    merged: dict[tuple[str, str], list[trimesh.Trimesh]] = {}
    report = []
    for (body, mat, name, m), w in zip(loaded, weights):
        target = max(24, int(w * scale))
        d = decimate(m, target)
        merged.setdefault((body, mat), []).append(d)
        report.append((name, len(m.faces), len(d.faces)))

    OUT.mkdir(parents=True, exist_ok=True)
    for f in OUT.glob("*.obj"):
        f.unlink()
    keep = OUT / ".keep"
    if keep.exists():
        keep.unlink()

    by_name = {b["name"]: b for b in bodies}
    total = 0
    files = []
    for (body, mat), parts in merged.items():
        m = trimesh.util.concatenate(parts)
        fname = f"{body}_{mat}.obj"
        write_obj(OUT / fname, m)
        total += len(m.faces)
        files.append((fname, len(m.faces)))
        by_name[body]["meshes"].append({"file": fname, "pos": [0, 0, 0], "quat": [1, 0, 0, 0],
                                        "material": mat, "triangles": int(len(m.faces))})

    doc = {
        "version": 1,
        "source": "TuragaLab/flybody fruitfly.xml (Apache-2.0)",
        "units": "cm", "up": "z", "forward": "x",
        "triangles": total,
        "bodies": bodies,
        "materials": MATERIALS,
    }
    (OUT / "body.json").write_text(json.dumps(doc, indent=1))
    size = sum(p.stat().st_size for p in OUT.iterdir())
    for fname, n in sorted(files):
        print(f"{fname:40s} {n:6d}")
    print(f"bodies={len(bodies)} joints={sum(len(b['joints']) for b in bodies)} "
          f"files={len(files)} triangles={total} size={size/1e6:.2f} MB")
    return 0 if size < 3e6 else 1


if __name__ == "__main__":
    sys.exit(main())
