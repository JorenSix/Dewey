# Connectome pipeline

This pipeline builds `app/Sources/FlyApp/Resources/circuit.json`, a reduced circuit at the level of cell type and side, from the Janelia FlyEM **male-CNS v1.0** flat connectome. The data comes from Berg et al. 2025, bioRxiv 10.1101/2025.10.09.680999, CC-BY 4.0. The schema is defined in `docs/contracts.md`.

```bash
uv run --project pipeline python -I pipeline/download.py        # -> data/raw/, records sha256+size in data_manifest.json
uv run --project pipeline python -I pipeline/build_circuit.py   # -> circuit.json + pipeline/build_report.json
cd pipeline && uv run pytest
rm -rf data/raw                                                  # raw data is not kept; hashes stay in data_manifest.json
```

The build takes about 10 s and peaks at about 0.9 GB RSS. The weights file has 151.9 M rows, so it is streamed one record batch at a time in two passes and is never loaded whole.

## Input files and their actual columns

| file | columns |
|---|---|
| `body-annotations-male-cns-v1.0-minconf-0.5.feather` (211,577 rows) | assignedOlHex1, assignedOlHex2, bodyId, flywireType, group, instance, somaSide, statusLabel, superclass, type, vfbId, hemibrainType, itoleeHl, supertype, birthtime, mancBodyid, mancGroup, mancType, subclass, synonyms, class, rootSide, somaNeuromere, trumanHl, dimorphism, matchingNotes, entryNerve, mancSerial, mcnsSerial, serialMotif, fruDsx, exitNerve, receptorType, somaLocation, tosomaLocation, status |
| `body-neurotransmitters-male-cns-v1.0.feather` (1,835,518 rows) | body, cell_type, total_nt_predictions, predicted_nt_confidence, predicted_nt, ground_truth, celltype_total_nt_predictions, celltype_predicted_nt, celltype_predicted_nt_confidence, consensus_nt |
| `connectome-weights-male-cns-v1.0-minconf-0.5.feather` (151,856,684 rows) | body_pre, body_post, weight |

Notes:
- Motor neurons have `superclass == "vnc_motor"`.
- The motor neuron `subclass` codes are: `wm` wing, `hm` haltere, `fl`/`ml`/`hl` front, middle and hind leg, `ad` abdominal, `nm` neck, `xm` other.
- Neurotransmitter values are acetylcholine, gaba, glutamate, histamine, dopamine, octopamine, serotonin and `unclear`.

## Method

1. **Nodes.** Every neuron with a non-empty `type` is collapsed into the node `type_side`.
   - The side is taken from `somaSide`, then `rootSide`, then the `_L`/`_R` suffix of `instance`.
   - If none of these gives a side, it is `C`.
2. **Seeds.** Seeds are matched on the full type name, case-insensitively. If a name doesn't match, the pipeline falls back to `instance`, `synonyms`, `flywireType` and `mancType`. The seeds are:
   - the types listed in `SEED_TYPES`
   - every `vnc_motor` neuron in subclass wm, hm, fl, ml or hl
   - every `JO-*` type, plus every type whose subclass is "mechanosensory bristle"
3. **visual_landing.** These are the 4 strongest `visual_projection` input types to DNp07 and DNp10, excluding the loom types.
4. **Expansion.** The node set is grown from the seeds as follows:
   - Each core seed node (loom, the DNs and visual_landing) adds its top 8 upstream and top 8 downstream partner nodes.
   - Each motor neuron node adds its top 3 upstream partners.
   - Each mechano node adds its top 2 downstream partners.
   - The top 12 bridge nodes X on the paths LPLC2/LC4 → X → GF and GF → X → MN are added. They are ranked by the weaker of the two links.
5. **Weights.** `w = sign(nt_pre) * syn(pre→post) / total_input_syn(post)`.
   - `total_input_syn` sums the post node's bodies over all presynaptic bodies in the full connectome, typed or not.
   - Weights are rounded to 4 decimals, and any weight with |w| < 1e-3 is dropped.
6. **Signs.** Acetylcholine is +1, and GABA and glutamate are −1. Anything else counts as +1: histamine, dopamine, octopamine, serotonin, and `unknown`.
   - A node's transmitter is the most common `celltype_predicted_nt` across its bodies, falling back to `predicted_nt`, and ignoring `unclear`.
   - Most VNC neurons and motor neurons have no prediction, so they come out as `unknown` and get +1. This includes many VNC interneurons that may really be inhibitory.
7. **Time constants.** tau is 0.02 s by default, 0.005 s for DNp01 and the GF bridge nodes, and 0.05 s for motor neurons.

## Substitutions and additions

- **DNg12** is not a type in v1.0. It is split into `DNg12_a` through `DNg12_h`, and all eight are used in `groom_dn`.
- **MDN** exists as type `MDN`. `DNa_MDN` does not exist.
- **TTMn** is annotated subclass `wm`, but it is placed in `leg_mn`. It is the jump (tergotrochanteral) motor neuron that GF targets.
- **walk_dn** was not in the brief. It holds DNg100 (BDN2) and DNg97 (oDN1), from Sapkal 2024.

The full record of seeds, bridges and counts is in `pipeline/build_report.json`.
