"""Build the reduced fly circuit (circuit.json) from the FlyEM male-CNS v1.0 flat connectome.

Usage (from repo root):
    uv run --project pipeline python -I pipeline/build_circuit.py [--raw data/raw] [--out app/Sources/FlyApp/Resources/circuit.json]

Steps
1. Load body annotations + neurotransmitter predictions; print the actual column names.
2. Select seed neurons (by type, case-insensitive; also matched against instance/synonyms/flywireType/mancType).
3. Pass 1 over the weights file (streamed per record batch, column-projected): keep edges touching a seed.
4. Collapse to (type, side) nodes; expand with the top-k strongest partners of each seed node and with
   the interneurons on two-step paths loom -> X -> GF and GF -> X -> MN.
5. Pass 2: keep edges with both ends in the final body set, and total input synapses of each final
   post-synaptic body over ALL presynaptic partners in the full connectome.
6. w = sign(nt of pre node) * syn(pre node -> post node) / total_input_syn(post node); write compact JSON.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
import pandas as pd
import pyarrow as pa
import pyarrow.compute as pc
import pyarrow.feather as pf
import pyarrow.ipc as ipc

ROOT = Path(__file__).resolve().parent.parent
ANN = "body-annotations-male-cns-v1.0-minconf-0.5.feather"
NT = "body-neurotransmitters-male-cns-v1.0.feather"
W = "connectome-weights-male-cns-v1.0-minconf-0.5.feather"

GROUP_KEYS = [
    "loom", "mechano", "visual_landing",
    "gf", "escape_dn", "landing_dn", "steer_dn", "walk_dn",
    "backward_dn", "freeze_dn", "groom_dn",
    "wing_mn", "haltere_mn", "leg_mn",
]

# Seed cell types per group. Matched case-insensitively as full type names; entries ending in '*' are prefixes.
SEED_TYPES = {
    "loom": ["LPLC2", "LC4", "LPLC1", "LC6"],
    "gf": ["DNp01"],
    "escape_dn": ["DNp02", "DNp04", "DNp06", "DNp11"],
    "landing_dn": ["DNp07", "DNp10"],
    "steer_dn": ["DNa01", "DNa02", "DNb05", "DNb06"],
    # Not in the brief's seed list; added so walk_dn is not empty: BDN2 (DNg100) and oDN1 (DNg97), Sapkal 2024.
    "walk_dn": ["DNg100", "DNg97"],
    "backward_dn": ["MDN", "DNa_MDN"],
    "freeze_dn": ["DNp09"],
    # DNg12 does not exist as a bare type in male-CNS v1.0; it is split into DNg12_a..h.
    "groom_dn": ["DNg11", "DNg12", "DNg12_*"],
    "mechano": ["JO-*"],
}
SIGN = {"acetylcholine": 1.0, "gaba": -1.0, "glutamate": -1.0}

# vnc_motor `subclass` codes (MANC convention): wm wing, hm haltere, fl/ml/hl front/middle/hind leg.
WING_SUB, HALTERE_SUB, LEG_SUB = {"wm"}, {"hm"}, {"fl", "ml", "hl"}
# TTMn (tergotrochanteral = jump muscle, GF target) is annotated "wm" but drives the mesothoracic leg.
FORCE_LEG = {"TTMn"}

K_SEED = 8         # top-k upstream and downstream partner nodes per core seed node
K_MN = 3           # top-k upstream partner nodes per MN node
K_MECHANO = 2      # top-k downstream partner nodes per mechanosensory node
K_PATH = 12        # interneurons kept per two-step-path family
N_VISUAL_LANDING = 4

TAU_DEFAULT, TAU_GF, TAU_MN = 0.02, 0.005, 0.05


def log(*a):
    print(*a, file=sys.stderr)


def side_of(row) -> str:
    for c in ("somaSide", "rootSide"):
        v = row.get(c)
        if isinstance(v, str) and v in ("L", "R"):
            return v
    inst = row.get("instance")
    if isinstance(inst, str):
        m = re.search(r"_([LR])$", inst)
        if m:
            return m.group(1)
    return "C"


def load_annotations(raw: Path) -> pd.DataFrame:
    tab = pf.read_table(raw / ANN)
    log("annotation columns:", tab.column_names)
    cols = ["bodyId", "type", "instance", "somaSide", "rootSide", "superclass", "class", "subclass",
            "synonyms", "flywireType", "mancType", "status"]
    a = tab.select(cols).to_pandas()
    a = a[a["type"].notna() & (a["type"] != "")].copy()
    sides = np.full(len(a), "C", dtype=object)
    for c in ("rootSide", "somaSide"):  # somaSide wins
        v = a[c].astype(object).values
        ok = np.isin(v, ["L", "R"])
        sides[ok] = v[ok]
    inst_side = a["instance"].fillna("").str.extract(r"_([LR])$")[0].values
    fill = (sides == "C") & pd.notna(inst_side)
    sides[fill] = inst_side[fill]
    a["side"] = sides
    a["node"] = a["type"] + "_" + a["side"]
    return a


def load_nt(raw: Path, bodies: np.ndarray) -> pd.DataFrame:
    tab = pf.read_table(raw / NT)
    log("neurotransmitter columns:", tab.column_names)
    tab = tab.select(["body", "predicted_nt", "celltype_predicted_nt", "consensus_nt"])
    tab = tab.filter(pc.is_in(tab["body"], value_set=pa.array(bodies)))
    return tab.to_pandas().set_index("body")


def match_types(a: pd.DataFrame, patterns: list[str]) -> set[str]:
    types = set()
    alt_cols = ["type", "instance", "synonyms", "flywireType", "mancType"]
    for p in patterns:
        if p.endswith("*"):
            m = a["type"].str.lower().str.startswith(p[:-1].lower())
        else:
            m = a["type"].str.lower() == p.lower()
            if not m.any():  # fall back to synonym/instance/etc. columns (token match)
                rx = rf"(?i)(?:^|[^A-Za-z0-9]){re.escape(p)}(?:$|[^A-Za-z0-9])"
                m = np.zeros(len(a), bool)
                for c in alt_cols:
                    m |= a[c].fillna("").str.contains(rx, regex=True).values
        types |= set(a.loc[m, "type"])
    return types


def iter_weights(raw: Path):
    reader = ipc.open_file(raw / W)
    log("weights columns:", reader.schema.names, "batches:", reader.num_record_batches)
    for i in range(reader.num_record_batches):
        yield reader.get_batch(i)


def main(argv=None) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", default=str(ROOT / "data" / "raw"))
    ap.add_argument("--out", default=str(ROOT / "app" / "Sources" / "FlyApp" / "Resources" / "circuit.json"))
    ap.add_argument("--report", default=str(Path(__file__).resolve().parent / "build_report.json"))
    args = ap.parse_args(argv)
    raw = Path(args.raw)

    a = load_annotations(raw)
    body_node = dict(zip(a["bodyId"].values, a["node"].values))

    # ---- seeds ---------------------------------------------------------------------------------
    report: dict = {"seeds": {}, "not_found": [], "substitutions": {}}
    group_types: dict[str, set[str]] = {}
    for g, pats in SEED_TYPES.items():
        found = match_types(a, pats)
        group_types[g] = found
        for p in pats:
            hit = match_types(a, [p])
            report["seeds"][p] = sorted(hit)
            if not hit:
                report["not_found"].append(p)
    report["substitutions"]["DNg12"] = sorted(group_types["groom_dn"] - {"DNg11"})

    mn = a[a["superclass"] == "vnc_motor"]
    sub_types = mn.groupby("subclass")["type"].apply(set).to_dict()
    group_types["wing_mn"] = set().union(*[sub_types.get(s, set()) for s in WING_SUB]) - FORCE_LEG
    group_types["haltere_mn"] = set().union(*[sub_types.get(s, set()) for s in HALTERE_SUB])
    group_types["leg_mn"] = set().union(*[sub_types.get(s, set()) for s in LEG_SUB]) | (FORCE_LEG & set(mn["type"]))
    group_types["haltere_mn"] -= group_types["leg_mn"]
    group_types["wing_mn"] -= group_types["leg_mn"] | group_types["haltere_mn"]

    bristle = a[a["subclass"].fillna("").str.contains("mechanosensory bristle")]
    group_types["mechano"] |= set(bristle["type"])
    report["mechano_bristle_types"] = sorted(set(bristle["type"]))

    seed_types = set().union(*group_types.values())
    seed_bodies = a.loc[a["type"].isin(seed_types), "bodyId"].values
    log(f"seed types: {len(seed_types)}, seed bodies: {len(seed_bodies)}")

    # ---- pass 1: edges touching seeds ---------------------------------------------------------
    seed_vs = pa.array(np.unique(seed_bodies))
    parts = []
    for b in iter_weights(raw):
        m = pc.or_(pc.is_in(b.column(0), value_set=seed_vs), pc.is_in(b.column(1), value_set=seed_vs))
        if pc.any(m).as_py():
            parts.append(b.filter(m))
    e1 = pa.Table.from_batches(parts).to_pandas()
    del parts
    e1["pre_n"] = e1["body_pre"].map(body_node)
    e1["post_n"] = e1["body_post"].map(body_node)
    e1 = e1.dropna(subset=["pre_n", "post_n"])
    n1 = e1.groupby(["pre_n", "post_n"], as_index=False)["weight"].sum()
    log(f"pass 1: {len(e1)} body edges touching seeds -> {len(n1)} node edges")

    node_type = a.drop_duplicates("node").set_index("node")["type"].to_dict()

    def nodes_of(types: set[str]) -> set[str]:
        return {n for n, t in node_type.items() if t in types}

    group_nodes = {g: nodes_of(t) for g, t in group_types.items()}

    # visual_landing: strongest visual_projection inputs to landing DNs (excluding loom types)
    vp_types = set(a.loc[a["superclass"] == "visual_projection", "type"])
    up_land = n1[n1["post_n"].isin(group_nodes["landing_dn"])].copy()
    up_land["ptype"] = up_land["pre_n"].map(node_type)
    up_land = up_land[up_land["ptype"].isin(vp_types - group_types["loom"])]
    vl = up_land.groupby("ptype")["weight"].sum().sort_values(ascending=False)
    group_types["visual_landing"] = set(vl.index[:N_VISUAL_LANDING])
    group_nodes["visual_landing"] = nodes_of(group_types["visual_landing"])
    report["visual_landing"] = {k: int(v) for k, v in vl.head(N_VISUAL_LANDING).items()}

    mn_nodes = group_nodes["wing_mn"] | group_nodes["haltere_mn"] | group_nodes["leg_mn"]
    core = set().union(*[group_nodes[g] for g in GROUP_KEYS if g not in ("wing_mn", "haltere_mn", "leg_mn", "mechano")])
    keep = set().union(*group_nodes.values())

    def topk(df, key, other, nodes, k):
        sub = df[df[key].isin(nodes) & ~df[other].isin(nodes)]
        sub = sub.sort_values("weight", ascending=False).groupby(key).head(k)
        return set(sub[other])

    keep |= topk(n1, "post_n", "pre_n", core, K_SEED)   # upstream partners of core seeds
    keep |= topk(n1, "pre_n", "post_n", core, K_SEED)   # downstream partners of core seeds
    keep |= topk(n1, "post_n", "pre_n", mn_nodes, K_MN)
    keep |= topk(n1, "pre_n", "post_n", group_nodes["mechano"], K_MECHANO)

    # two-step path interneurons: loom -> X -> GF and GF -> X -> MN (bottleneck = min of the two legs)
    def bridges(src: set[str], dst: set[str]) -> list[tuple[str, int]]:
        out = n1[n1["pre_n"].isin(src)].groupby("post_n")["weight"].sum()
        inn = n1[n1["post_n"].isin(dst)].groupby("pre_n")["weight"].sum()
        both = out.index.intersection(inn.index).difference(src | dst)
        s = pd.Series({x: min(out[x], inn[x]) for x in both}, dtype=float).sort_values(ascending=False)
        return [(x, int(v)) for x, v in s.head(K_PATH).items()]

    loom_gf = set(nodes_of({"LPLC2", "LC4"}))
    b1 = bridges(loom_gf, group_nodes["gf"])
    b2 = bridges(group_nodes["gf"], mn_nodes)
    gf_path_nodes = {x for x, _ in b1 + b2}
    keep |= gf_path_nodes
    report["bridges_loom_gf"] = b1
    report["bridges_gf_mn"] = b2
    keep = sorted(keep)
    log(f"final node count: {len(keep)}")

    # ---- pass 2: edges among final bodies + total input per final post body --------------------
    final_bodies = a.loc[a["node"].isin(keep), "bodyId"].values
    fvs = pa.array(np.unique(final_bodies))
    parts, tot_parts = [], []
    for b in iter_weights(raw):
        mpost = pc.is_in(b.column(1), value_set=fvs)
        if not pc.any(mpost).as_py():
            continue
        bp = b.filter(mpost)
        tot_parts.append(bp.select([1, 2]))
        mpre = pc.is_in(bp.column(0), value_set=fvs)
        parts.append(bp.filter(mpre))
    tot = pa.Table.from_batches(tot_parts).to_pandas().groupby("body_post")["weight"].sum()
    e2 = pa.Table.from_batches(parts).to_pandas()
    del parts, tot_parts
    e2["pre_n"] = e2["body_pre"].map(body_node)
    e2["post_n"] = e2["body_post"].map(body_node)
    n2 = e2.groupby(["pre_n", "post_n"], as_index=False)["weight"].sum()
    tot_node = tot.groupby(tot.index.map(body_node)).sum()

    # ---- nodes ---------------------------------------------------------------------------------
    fa = a[a["node"].isin(keep)]
    ntdf = load_nt(raw, fa["bodyId"].values)
    node_meta = {}
    for node, grp in fa.groupby("node"):
        def mode(col: str, g=grp) -> str:
            vals = [str(v) for v in g[col].dropna() if str(v) not in ("", "nan")]
            return Counter(vals).most_common(1)[0][0] if vals else ""
        nts = ntdf.reindex(grp["bodyId"].values)
        cand = [v for v in nts["celltype_predicted_nt"].dropna() if v != "unclear"]
        if not cand:
            cand = [v for v in nts["predicted_nt"].dropna() if v != "unclear"]
        nt = Counter(cand).most_common(1)[0][0] if cand else "unknown"
        node_meta[node] = dict(type=grp["type"].iloc[0], side=grp["side"].iloc[0],
                               cls=mode("class"), superclass=mode("superclass"), nt=nt, n=int(len(grp)))

    idx = {n: i for i, n in enumerate(keep)}
    sensor_groups = group_nodes["loom"] | group_nodes["mechano"] | group_nodes["visual_landing"]
    nodes = []
    role_count = Counter()
    for n in keep:
        m = node_meta[n]
        sc = m["superclass"]
        if n in mn_nodes or "motor" in sc:
            role, tau = "mn", TAU_MN
        elif "descending" in sc:
            role, tau = "dn", TAU_DEFAULT
        elif "ascending" in sc and "sensory" not in sc:
            role, tau = "an", TAU_DEFAULT
        elif "sensory" in sc or n in sensor_groups:
            role, tau = "sensor", TAU_DEFAULT
        else:
            role, tau = "inter", TAU_DEFAULT
        if n in group_nodes["gf"] or n in gf_path_nodes:
            tau = TAU_GF if role != "mn" else TAU_MN
        role_count[role] += 1
        nodes.append({"id": idx[n], "name": n, "type": m["type"], "side": m["side"], "class": m["cls"],
                      "superclass": sc, "nt": m["nt"], "role": role, "n": m["n"], "tau": tau})

    # ---- edges ---------------------------------------------------------------------------------
    other_nts = Counter()
    pre_sign = {}
    for n in keep:
        nt = node_meta[n]["nt"]
        pre_sign[n] = SIGN.get(nt, 1.0)
        if nt not in SIGN:
            other_nts[nt] += 1
    n2["w"] = [pre_sign[p] * w / tot_node[q] for p, q, w in zip(n2["pre_n"], n2["post_n"], n2["weight"])]
    n2["w"] = n2["w"].round(4)
    n2 = n2[n2["w"].abs() >= 1e-3].sort_values(["post_n", "pre_n"])
    edges = {"pre": [idx[p] for p in n2["pre_n"]], "post": [idx[q] for q in n2["post_n"]],
             "w": [float(x) for x in n2["w"]]}

    groups = {g: sorted(idx[n] for n in group_nodes.get(g, set()) if n in idx) for g in GROUP_KEYS}
    circuit = {
        "version": 1,
        "source": "FlyEM male-cns v1.0 flat-connectome minconf-0.5",
        "citation": "Berg et al. 2025 bioRxiv 10.1101/2025.10.09.680999 (CC-BY 4.0)",
        "nodes": nodes,
        "edges": edges,
        "groups": groups,
    }
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(circuit, separators=(",", ":")))

    report.update({
        "nodes": len(nodes), "edges": len(edges["w"]), "roles": dict(role_count),
        "group_sizes": {g: len(v) for g, v in groups.items()},
        "nt_signed_plus_one_other": dict(other_nts),
        "bytes": out.stat().st_size,
    })
    Path(args.report).write_text(json.dumps(report, indent=1) + "\n")
    print(json.dumps({k: report[k] for k in ("nodes", "edges", "roles", "group_sizes", "not_found",
                                             "nt_signed_plus_one_other", "bytes")}, indent=1))


if __name__ == "__main__":
    main()
