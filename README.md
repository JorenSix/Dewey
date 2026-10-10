# Dewey — a connectome-driven fruit fly for your menu bar

**Dewey** is a native macOS menu-bar fruit fly. Click the menu-bar icon to release it. It flies around your screen, escapes when the mouse pointer looms at it, and perches on screen edges, on top of the Dock, and on application windows. There it walks, grooms, and takes off again when it gets restless.

<div align="center">

https://github.com/user-attachments/assets/4d364fd8-83cd-4a01-b3e9-cf91a9bd4522

<em>Dewey and friends exploring the desktop and perching on windows (35 seconds).</em>

</div>

Its behaviour runs on a **reduced circuit from the Janelia FlyEM male CNS connectome (v1.0)**:
- 1,339 cell-type nodes and 30,655 signed, weighted edges, simulated as a rate network at 60 Hz.
- Pointer looming drives LPLC2/LC4, which drive the giant fiber (DNp01) and the escape descending neurons, which in turn drive takeoff.
- Nearby screen edges drive visual landing inputs and the landing DNs (DNp07/DNp10).
- Idle time drives the grooming DNs.

## Download

[Download Dewey for macOS](https://github.com/JorenSix/Dewey/releases/latest) (Apple silicon, macOS 14 or later).

Open the DMG and drag Dewey into Applications, then launch it from there. Dewey appears in the menu bar. The app is ad-hoc signed and is not notarized by Apple, so macOS may require you to allow it in System Settings → Privacy & Security after the first launch attempt.

Alternatively, after copying Dewey into Applications, run this in Terminal to remove its quarantine flag and launch it:

```sh
xattr -dr com.apple.quarantine "/Applications/Dewey.app"
open "/Applications/Dewey.app"
```

## Menu

Click the fly icon in the menu bar to open the menu:
- **Show / Hide Dewey** (⌘D)
- **Size** slider (20–120 pt)
- **Restlessness** slider (Calm…Restless), which sets how long Dewey stays perched before taking off on its own
- **Friends** slider (0–5): adds companion flies
- **About Dewey**
- **Quit**

Settings persist in `UserDefaults` (`defaults read be.0110.dewey settings`).

## What Dewey does

- Flies with a figure-eight wingbeat, drawn with faded in-between wings so the beat reads as motion blur.
- Banks into turns, pitches up on takeoff and flares before landing. A soft drop shadow grows with altitude.
- Sees screen borders approaching (time-to-contact in each visual hemifield, fed to the connectome's landing and steering inputs). It slows and lands on the left edge, right edge or top of the Dock, or turns away.
- Stands *on* the edge in a three-quarter view, feet touching the border.
- While perched it walks, then grooms in the order flies do: head → front legs → abdomen → wings. It gets restless and takes off again.
- Escapes when the pointer looms at it (LPLC2/LC4 → giant fiber → takeoff).
- Lands on the visible top, left, and right edges of application windows. Windows must be at least 200×120 pt and sit at least 10% of the screen dimensions inside the usable screen edges; maximised and edge-docked windows are ignored.
- Takes off when its window moves, resizes, or closes. Nearby window movement can also startle it. Window tracking uses window bounds without reading titles or capturing the screen.

## Friends

The Friends slider adds up to 5 companion flies, each randomly 10–15% smaller than Dewey.
- Each runs its own connectome brain and the same behaviour code as Dewey.
- In flight they flock with Dewey using **boids** (separation, alignment, cohesion). The boids rules enter each fly's brain as steering and thrust inputs, never as escape inputs, and friends weight Dewey 2.5×, so the flock follows him.
- When Dewey lands, friends perch near him, spaced out along the edge. When he takes off, they follow.
- A small kinematic safeguard keeps flies at least a body length apart in the air.

## Build & run

Requirements: macOS 14+, Swift 6 Command Line Tools (Xcode is not needed), and `uv` for the Python pipeline.

```sh
scripts/bundle.sh            # swift build -c release -> build/Dewey.app (LSUIElement, ad-hoc signed)
open build/Dewey.app        # menu-bar icon -> "Release fly"
```

Tests:

```sh
cd app && swift test                 # debug
cd app && swift test -c release      # includes the 0.5 ms brain-step benchmark
cd pipeline && uv run pytest         # circuit sanity checks
```

### Debug environment variables

| Variable | Effect |
|---|---|
| `FLY_AUTORELEASE=1` | Release the fly at launch. |
| `FLY_START_STATE=flying\|perched` | State the fly starts in. |
| `FLY_SEED=<n>` | Deterministic seed for the brain and the behaviour. |
| `FLY_BRAIN=scripted` | Use the hand-written stand-in brain instead of the connectome. |
| `FLY_PLACEHOLDER=1` | Draw a simple placeholder instead of the flybody mesh. |
| `FLY_SNAPSHOT_DIR=<dir>` | Save up to 6 renders of the overlay scene, one every 2 s. This works without Screen Recording permission. |
| `FLY_FPS=<n>` | Display-link frame-rate cap. |
| `FLY_MODEL=flybody` | Use the original flybody mesh instead of the Dewey model. |
| `FLY_SIZE=<pt>` | Starting size. |
| `FLY_FRIENDS=<n>` | Starting number of friends (overrides the setting). |
| `FLY_FORCE_STATE=flying\|banking\|perched_left\|perched_bottom\|takeoff` | Stage a pose for snapshots (with `FLY_SNAPSHOT_DIR`, `FLY_SNAPSHOT_EXIT=1`). |

Pass them to a bundle with `open --env FLY_AUTORELEASE=1 build/Dewey.app`.

## Architecture

```
pipeline/            Python (uv), run once, offline
  download.py        fetches 3 flat-connectome feather files (~1.1 GB) into data/raw, records hashes
  build_circuit.py   seeds -> 1-hop expansion -> (type, side) nodes -> signed normalised weights -> circuit.json
  export_body.py     flybody MJCF + meshes -> decimated OBJ + body.json
  blender/build_dewey.py  procedural Dewey model + armature (bones = flybody joints) -> per-bone OBJ + body.json + Dewey.usdz
app/                 SwiftPM package (no Xcode project)
  FlyCore            shared value types: Percept, MotorCommand, BodyPose, FlyFrame, Brain protocol
  FlyBrain           Circuit (CSR), RateNetwork, SensoryEncoder, MotorDecoder, ConnectomeBrain
  FlyBehavior        World (screen, Dock, perches), FlyController state machine + kinematics, ScriptedBrain
  FlyBody            FlyRig (SceneKit node tree from body.json), JointAnimator, FlySnapshot
  FlyApp             status item, transparent click-through overlay above the Dock, display-link loop
docs/contracts.md    circuit.json / body.json schemas and module contracts
scripts/bundle.sh    builds and signs the .app
```

The interfaces between modules are documented in `docs/contracts.md`. Column names, seed cell types and substitutions are in `pipeline/README.md` and `pipeline/build_report.json`.

To rebuild the circuit (this needs about 1.2 GB of free disk temporarily, and `data/raw` is deleted afterwards):

```sh
cd pipeline && uv run python download.py && uv run python build_circuit.py && uv run pytest && rm -rf ../data/raw
```

The Dewey model is rebuilt with `blender -b -P pipeline/blender/build_dewey.py` (Blender 5.2, about 20 s). Its style is modelled on a realistic rigged Drosophila; no third-party model files are used.

## Credits & licences

- **Connectome data:** FlyEM male CNS v1.0, CC-BY 4.0. Berg S, Beckett I, Costa M, Schlegel P, … Rubin G, Jefferis G. *Sexual dimorphism in the complete connectome of the Drosophila male central nervous system.* bioRxiv 2025, doi:10.1101/2025.10.09.680999. https://male-cns.janelia.org
- **Fly body proportions and joints:** flybody (TuragaLab, HHMI Janelia / Google DeepMind), Apache-2.0. Vaxenburg et al., *Nature* 2025. The licence is in `LICENSES/flybody-Apache-2.0.txt`.
- **Caveat:** the behaviour is shaped by real circuit topology and weights. It is not a validated biophysical model: the decoder thresholds, the sensory encoding and some sign assignments (neurons with no predicted transmitter count as excitatory) are approximations.
