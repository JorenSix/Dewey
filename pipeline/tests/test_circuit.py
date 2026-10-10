"""Validate app/Sources/FlyApp/Resources/circuit.json against docs/contracts.md."""
from __future__ import annotations

import json
from collections import deque
from pathlib import Path

import pytest

CIRCUIT = Path(__file__).resolve().parents[2] / "app" / "Sources" / "FlyApp" / "Resources" / "circuit.json"
GROUP_KEYS = ["loom", "mechano", "visual_landing", "gf", "escape_dn", "landing_dn", "steer_dn", "walk_dn",
              "backward_dn", "freeze_dn", "groom_dn", "wing_mn", "haltere_mn", "leg_mn"]
NONEMPTY = ["loom", "gf", "escape_dn", "landing_dn", "steer_dn", "wing_mn", "leg_mn"]
ROLES = {"sensor", "inter", "dn", "an", "mn"}
NODE_KEYS = {"id": int, "name": str, "type": str, "side": str, "class": str, "superclass": str,
             "nt": str, "role": str, "n": int, "tau": float}


@pytest.fixture(scope="module")
def c():
    return json.loads(CIRCUIT.read_text())


def test_file_size():
    assert CIRCUIT.stat().st_size < 5 * 1024 * 1024


def test_top_level(c):
    assert c["version"] == 1
    assert isinstance(c["source"], str) and c["source"]
    assert isinstance(c["citation"], str) and "Berg" in c["citation"]
    assert set(c) >= {"version", "source", "citation", "nodes", "edges", "groups"}


def test_nodes(c):
    nodes = c["nodes"]
    assert 300 <= len(nodes) <= 3000
    names = set()
    for i, n in enumerate(nodes):
        assert n["id"] == i
        for k, t in NODE_KEYS.items():
            assert isinstance(n[k], t), (k, n)
        assert n["side"] in ("L", "R", "C")
        assert n["role"] in ROLES
        assert n["n"] >= 1 and n["tau"] > 0
        assert n["name"] == f'{n["type"]}_{n["side"]}'
        names.add(n["name"])
    assert len(names) == len(nodes)


def test_edges(c):
    e, n = c["edges"], len(c["nodes"])
    assert len(e["pre"]) == len(e["post"]) == len(e["w"]) > 0
    assert all(isinstance(x, int) and 0 <= x < n for x in e["pre"] + e["post"])
    assert all(1e-3 <= abs(w) <= 1 for w in e["w"])
    into = [0.0] * n
    for q, w in zip(e["post"], e["w"]):
        into[q] += abs(w)
    assert max(into) <= 1.0 + 1e-3


def test_groups(c):
    g, n = c["groups"], len(c["nodes"])
    for k in GROUP_KEYS:
        assert k in g, k
        assert all(isinstance(i, int) and 0 <= i < n for i in g[k])
    for k in NONEMPTY:
        assert g[k], k
    types = lambda k: {c["nodes"][i]["type"] for i in g[k]}
    assert {"LPLC2", "LC4"} <= types("loom")
    assert types("gf") == {"DNp01"}
    assert all(c["nodes"][i]["role"] == "mn" for k in ("wing_mn", "haltere_mn", "leg_mn") for i in g[k])
    assert "TTMn" in types("leg_mn")


def _reach(c, src, dst, max_hops):
    adj = {}
    for p, q, w in zip(c["edges"]["pre"], c["edges"]["post"], c["edges"]["w"]):
        adj.setdefault(p, []).append((q, w))
    dst = set(dst)
    seen = {s: (None, 0.0) for s in src}
    frontier, hops = deque((s, 0) for s in src), {}
    while frontier:
        u, d = frontier.popleft()
        if u in dst and u not in src:
            path = [u]
            while seen[path[-1]][0] is not None:
                path.append(seen[path[-1]][0])
            return path[::-1]
        if d >= max_hops:
            continue
        for v, w in adj.get(u, []):
            if v not in seen:
                seen[v] = (u, w)
                frontier.append((v, d + 1))
    return None


def test_loom_to_gf_path(c):
    g = c["groups"]
    loom = [i for i in g["loom"] if c["nodes"][i]["type"] in ("LPLC2", "LC4")]
    assert _reach(c, loom, g["gf"], 3) is not None


def test_gf_to_mn_path(c):
    g = c["groups"]
    assert _reach(c, g["gf"], g["wing_mn"] + g["leg_mn"], 3) is not None
    # the classic GF -> TTMn connection is direct and excitatory
    ttmn = {i for i in g["leg_mn"] if c["nodes"][i]["type"] == "TTMn"}
    direct = [w for p, q, w in zip(c["edges"]["pre"], c["edges"]["post"], c["edges"]["w"])
              if p in g["gf"] and q in ttmn]
    assert direct and all(w > 0 for w in direct)


def test_loom_drives_gf_excitatory(c):
    g = c["groups"]
    loom = {i for i in g["loom"] if c["nodes"][i]["type"] in ("LPLC2", "LC4")}
    ws = [w for p, q, w in zip(c["edges"]["pre"], c["edges"]["post"], c["edges"]["w"])
          if p in loom and q in g["gf"]]
    assert ws and max(ws) > 0.05
