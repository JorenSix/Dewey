# Interface contracts

These are the shared contracts between the parallel modules. If you change one, update this file **and** `app/Sources/FlyCore`.

## Module graph (SwiftPM, `app/`)

```
FlyCore      pure Swift + CoreGraphics; shared value types (Percept, MotorCommand, BodyPose, FlyState)
FlyBrain     -> FlyCore            circuit loader, RateNetwork, SensoryEncoder, MotorDecoder, ConnectomeBrain: Brain
FlyBehavior  -> FlyCore            World (screen/dock/perches), kinematics, state machine -> Percept, FlyFrame
FlyBody      -> FlyCore, SceneKit  FlyRig (SCNNode tree from body.json), JointAnimator(BodyPose)
FlyApp       -> all                NSStatusItem, overlay NSPanel + SCNView, 60 Hz loop
```

Coordinates: **AppKit global screen points, origin bottom-left, y up**. Angles in radians, and a positive angle is counter-clockwise (to the left). Time is in seconds.

## `app/Sources/FlyApp/Resources/circuit.json` (written by `pipeline/build_circuit.py`)

```jsonc
{
  "version": 1,
  "source": "FlyEM male-cns v1.0 flat-connectome minconf-0.5",
  "citation": "Berg et al. 2025 bioRxiv 10.1101/2025.10.09.680999 (CC-BY 4.0)",
  "nodes": [
    { "id": 0,                 // == index in array
      "name": "LPLC2_R",       // type + "_" + side
      "type": "LPLC2", "side": "R",        // side: "L" | "R" | "C" (center/unknown)
      "class": "...", "superclass": "...",  // raw annotation strings, may be ""
      "nt": "acetylcholine",                // predicted transmitter, may be "unknown"
      "role": "sensor",                     // sensor | inter | dn | an | mn
      "n": 80,                              // neurons collapsed into this node
      "tau": 0.02 }                         // seconds
  ],
  "edges": { "pre": [0, ...], "post": [5, ...], "w": [0.12, ...] },
  // w = sign(nt of pre) * synapses(pre->post) / total_input_synapses(post), so |sum w into a node| <= 1.
  // sign: acetylcholine +1; gaba, glutamate -1; anything else +1 (and it is listed in the build report).
  "groups": {           // node ids; a group can be empty, but the key must be present
    "loom": [], "mechano": [], "visual_landing": [],
    "gf": [], "escape_dn": [], "landing_dn": [], "steer_dn": [], "walk_dn": [],
    "backward_dn": [], "freeze_dn": [], "groom_dn": [],
    "wing_mn": [], "haltere_mn": [], "leg_mn": []
  }
}
```
Lateralised behaviour (steering, a loom coming from one side) uses the `side` field of the nodes in a group.

## `app/Sources/FlyApp/Resources/fly/body.json` (written by `pipeline/export_body.py`)

```jsonc
{
  "version": 1, "source": "TuragaLab/flybody fruitfly.xml (Apache-2.0)",
  "units": "cm", "up": "z", "forward": "x",          // MuJoCo frame; FlyRig converts to SceneKit y-up
  "bodies": [
    { "name": "thorax", "parent": null,               // parents come before children
      "pos": [0,0,0], "quat": [1,0,0,0],              // MuJoCo order w,x,y,z, relative to parent
      "meshes": [ { "file": "thorax.obj", "pos": [0,0,0], "quat": [1,0,0,0], "material": "body" } ],
      "joints": [ { "name": "...", "type": "hinge",   // hinge | ball | slide
                    "pos": [0,0,0], "axis": [0,1,0], "range": [-0.5, 0.5] } ] }
  ],
  "materials": { "body": [0.55,0.38,0.22,1], "wing": [0.85,0.9,0.95,0.35], "eye": [0.7,0.05,0.05,1] }
}
```

## Swift types (`FlyCore`): see the source, summarised here

- `Percept`: what the fly senses each frame. It holds the fly position, heading and whether it is airborne; the pointer position and velocity; the distances to the left, right and bottom perches; the idle time; and the screen size. It is built by FlyBehavior and consumed by `Brain`.
- `MotorCommand`: the brain's output, decoded from DN/MN activity. All fields are 0…1 except `yawRate` (rad/s, positive = left).
- `protocol Brain: AnyObject { func step(_ p: Percept, dt: Double) -> MotorCommand; var activity: [String: Float] { get } }`
- `FlyState`: `perched, walking, grooming, takingOff, flying, escaping, landing`.
- `BodyPose`: the animation parameters FlyBehavior hands to FlyBody (wing stroke, phases, gait, groom, head yaw).
- `FlyFrame`: the per-frame output of FlyBehavior for rendering. It holds the position, heading, altitude scale, state, pose, and the `Perch` surface the fly sits on (if any).

## v2 additions (Dewey)

- `FlyFrame.roll` / `pitch`: set by FlyBehavior (banking, takeoff/landing pitch, three-quarter tilt when perched) and applied by the overlay. These replace `FlyController.bodyRoll`.
- `Percept.edgeTimeToContactLeft/Right` and `edgeClosingSpeed`: border anticipation, encoded by `SensoryEncoder` onto `visual_landing` and `steer_dn` (L/R).
- `DeweySettings`: size in points, restlessness 0…1 (mapped to a perched-bout range by `restBout`), visible. Persisted by FlyApp in UserDefaults.
- `RestlessnessTunable.setRestBout(_:)`: implemented by `ConnectomeBrain` and `ScriptedBrain`.
- `OverlayController.setFlySize(_:)`: the size setting; `show()` / `hide()` handle visibility.
- `Resources/dewey/`: the Blender-built model, in the same `body.json` + OBJ format as `Resources/fly/` (flybody). `FLY_MODEL=flybody` selects the old model.

## v3 additions (multi-screen, large screens)

- `ScreenInfo {id, frame, visibleFrame}` and `PerchSite {screenID, side, a, b}` live in `FlyBehavior/Screens.swift`, together with the full `World` multi-screen API that module I implements. The single-screen `World(screenFrame:visibleFrame:)` stays as a convenience.
- Perch sites are screen edges plus Dock tops, minus every segment shared with an adjacent screen (two screen frames touching along an edge, overlap > 1 pt). The menu-bar top edge is never a perch.
- Bundle id `be.0110.dewey`. Settings migrate once from `be.ugent.ghentcdh.dewey` (copied, never deleted).
- J's additions (FlyCore, additive with defaults):
  - `Percept.targetBearing`, `targetDistance`, `targetTimeToContact`, `edgeIsTargetLeft/Right`, `edgeDistanceLeft/Right`, which describe the chosen perch target and the borders.
  - `DeweySettings.flightBout` (calm 15–45 s, restless 4–12 s), applied to `FlyController.flightBoutRange` along with `restBout`.
  - Edge τ is perpendicular distance ÷ closing speed.
- Distribution: `scripts/package-dmg.sh` produces the single artifact `build/Dewey.dmg` (app plus an Applications shortcut, signed ad hoc).

## v4 additions (friends / boids)

- `DeweySettings.friends` (0…5) and `friendSizeFactor` 0.85…0.90.
- `Percept.flockBearing/flockStrength/separationBearing/separationStrength/flockSpeedRatio`: boids inputs, encoded onto `steer_dn` and thrust only, never onto loom.
- `FlockNeighbor`: what one fly sees of another. `FlyController.neighbors: [FlockNeighbor]` (module L adds this) is set every frame by the flock coordinator (module M) before `update`. `FlyController.isLeader` / `id` / `size` identify the fly.
- Rendering: one `FlyActor` per fly (controller + brain + renderable + small SCNView); `OverlayController.setFriends(_:)` adds or removes friends live.
- `Percept.flockTakeoffDrive` (L): social takeoff drive onto the voluntary-takeoff neurons (`escape_dn` minus `gf`) when the leader takes off nearby.
- Kinematic separation backstop in FlyController (user-approved exception): within 1.2 body lengths and closing, the fly brakes and turns away to keep at least 1.0 body length. Activations are counted in `separationSafeguards`.

## v5 additions (window perches)

- `WindowInfo {id, frame (AppKit global), ownerPID}`, ordered front to back.
- `World.windows`, `World.withWindows(_:)` and `qualifyingWindowIDs`. Window sites (top, left, right edges, visible parts only, windows inset at least 10% from every side of their screen, at least 200×120 pt) appear in `perchSites` with `PerchSite.windowID`.
- `Percept.substrateJolt` and `windowMotionStartle`: startle inputs, encoded onto the mechano and voluntary-takeoff neurons.
- `FlyController.windowsChanged(moved: Set<Int>, removed: Set<Int>)` (module Q) is called by the app's WindowTracker (module P) after the World has been updated.
- v5: a window qualifies only if at least 70% of its area is visible, not behind windows in front (`World.minVisibleFraction`).
