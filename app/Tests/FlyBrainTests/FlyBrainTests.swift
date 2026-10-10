import CoreGraphics
import Foundation
import FlyBrain
import FlyCore
import Testing

// Non-@testable import so the suite also runs under `swift test -c release` (benchmark).

let synthetic = SyntheticCircuit.make()
let frameDT = 1.0 / 60

struct LoomResult {
    var maxTakeoff = 0.0
    var takeoffTime: Double? = nil
    var yawAtTakeoff = 0.0
    var maxYaw = 0.0
}

/// Fly perched at (700, 450) facing +x; pointer starts 400 pt to its right (−y) and rushes at it at 2000 pt/s.
/// Reports takeoff timing and yaw within the first 0.3 s of the approach.
func runLoom(_ brain: ConnectomeBrain) -> LoomResult {
    let fly = CGPoint(x: 700, y: 450)
    var p = Percept(flyPosition: fly, flyHeading: 0, airborne: false,
                    pointer: CGPoint(x: 700, y: 50), pointerVelocity: .zero,
                    distanceToLeftEdge: 700, distanceToRightEdge: 740, distanceToBottom: 450, idleTime: 0)
    for _ in 0..<60 { _ = brain.step(p, dt: frameDT) } // settle 1 s
    var res = LoomResult()
    let speed = 2000.0
    for f in 1...18 { // 0.3 s
        let t = Double(f) * frameDT
        p.pointer = CGPoint(x: 700, y: 50 + speed * t)
        p.pointerVelocity = CGVector(dx: 0, dy: speed)
        let m = brain.step(p, dt: frameDT)
        res.maxTakeoff = max(res.maxTakeoff, m.takeoff)
        res.maxYaw = max(res.maxYaw, m.yawRate)
        if res.takeoffTime == nil, m.takeoff > 0.5 { res.takeoffTime = t; res.yawAtTakeoff = m.yawRate }
    }
    return res
}

@Test func loomFromRightTriggersTakeoffAndLeftTurn() {
    let brain = ConnectomeBrain(circuit: synthetic, seed: 7)
    let r = runLoom(brain)
    print("loom(synthetic): maxTakeoff=\(r.maxTakeoff) t=\(r.takeoffTime ?? -1) yaw@takeoff=\(r.yawAtTakeoff)")
    #expect(r.maxTakeoff > 0.5)
    #expect(r.takeoffTime != nil && r.takeoffTime! <= 0.3)
    #expect(r.yawAtTakeoff > 0, "loom on the right must turn the fly left (positive yaw)")
}

@Test func loomFromLeftTurnsRight() {
    let brain = ConnectomeBrain(circuit: synthetic, seed: 7)
    var p = Percept(flyPosition: CGPoint(x: 700, y: 450), flyHeading: 0, pointer: CGPoint(x: 700, y: 850))
    for _ in 0..<60 { _ = brain.step(p, dt: frameDT) }
    var minYaw = 0.0
    for f in 1...18 {
        p.pointer = CGPoint(x: 700, y: 850 - 2000 * Double(f) * frameDT)
        p.pointerVelocity = CGVector(dx: 0, dy: -2000)
        minYaw = min(minYaw, brain.step(p, dt: frameDT).yawRate)
    }
    #expect(minYaw < -1)
}

@Test func slowOrRecedingPointerDoesNotTriggerTakeoff() {
    let brain = ConnectomeBrain(circuit: synthetic, seed: 3)
    var p = Percept(flyPosition: CGPoint(x: 700, y: 450), pointer: CGPoint(x: 700, y: 150))
    var maxT = 0.0
    for f in 0..<120 { // slow approach 60 pt/s, never closer than 180 pt
        p.pointer = CGPoint(x: 700, y: 150 + 60 * Double(f) * frameDT)
        p.pointerVelocity = CGVector(dx: 0, dy: 60)
        maxT = max(maxT, brain.step(p, dt: frameDT).takeoff)
    }
    #expect(maxT < 0.2)
}

@Test func idleLeadsToGroomingWithoutTakeoff() {
    var cfg = BrainConfig()
    cfg.encoder.restMin = 1e9; cfg.encoder.restMax = 1e9  // restlessness off: grooming only
    let brain = ConnectomeBrain(circuit: synthetic, config: cfg, seed: 11)
    var p = Percept(flyPosition: CGPoint(x: 0, y: 450), flyHeading: .pi / 2, pointer: CGPoint(x: 1200, y: 800),
                    distanceToLeftEdge: 0, distanceToRightEdge: 1440, distanceToBottom: 450)
    var maxGroom = 0.0, maxTakeoff = 0.0, walkEarly = 0.0
    for f in 0..<(30 * 60) {
        p.idleTime = Double(f) * frameDT
        let m = brain.step(p, dt: frameDT)
        maxGroom = max(maxGroom, m.groom); maxTakeoff = max(maxTakeoff, m.takeoff)
        if f == 60 { walkEarly = m.walkSpeed }
    }
    print("idle: maxGroom=\(maxGroom) maxTakeoff=\(maxTakeoff) walk@1s=\(walkEarly) final=\(brain.lastCommand)")
    #expect(maxGroom > 0.5)
    #expect(maxTakeoff < 0.2)
    #expect(walkEarly > 0.5, "exploratory walking tonic early in the idle period")
    #expect(brain.lastCommand.walkSpeed < 0.5, "walking gives way to grooming")
}

@Test func restlessnessEventuallyTriggersVoluntaryTakeoff() {
    let brain = ConnectomeBrain(circuit: synthetic, seed: 11)
    var p = Percept(flyPosition: CGPoint(x: 0, y: 450), flyHeading: .pi / 2, pointer: CGPoint(x: 1200, y: 800),
                    distanceToLeftEdge: 0, distanceToRightEdge: 1440, distanceToBottom: 450)
    var firstTakeoff: Double?
    for f in 0..<(40 * 60) {
        p.idleTime = Double(f) * frameDT
        if brain.step(p, dt: frameDT).takeoff > 0.5 { firstTakeoff = p.idleTime; break }
    }
    print("restless: first voluntary takeoff at idle=\(firstTakeoff ?? -1) s")
    let t = try! #require(firstTakeoff)
    #expect(t >= 8 && t <= 33, "takeoff only after a perched bout of restMin...restMax (+ramp)")
}

@Test func ratesStayBoundedUnderRandomInput() {
    let brain = ConnectomeBrain(circuit: synthetic, seed: 5)
    var rng = SplitMix64(seed: 99)
    func u() -> Double { Double(rng.nextUnit()) }
    var p = Percept()
    for f in 0..<(60 * 60) {
        if f % 60 == 0 { p.airborne = u() < 0.5; p.idleTime = 30 * u() }
        p.flyPosition = CGPoint(x: 1440 * u(), y: 900 * u())
        p.flyHeading = 2 * .pi * u()
        p.pointer = CGPoint(x: 1440 * u(), y: 900 * u())
        p.pointerVelocity = CGVector(dx: 6000 * (u() - 0.5), dy: 6000 * (u() - 0.5))
        p.distanceToLeftEdge = 1440 * u(); p.distanceToRightEdge = 1440 * u(); p.distanceToBottom = 900 * u()
        let m = brain.step(p, dt: frameDT)
        for v in [m.takeoff, m.thrust, m.yawRate, m.land, m.walkSpeed, m.backward, m.freeze, m.groom] {
            #expect(v.isFinite)
        }
        if f % 30 == 0 {
            let r = brain.network.rates
            #expect(r.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= brain.network.rMax })
        }
    }
    // Direct abuse of the network: huge random currents on every node.
    let net = RateNetwork(circuit: synthetic, seed: 1)
    for _ in 0..<600 {
        for i in 0..<net.n { net.input[i] = 50 * (rng.nextUnit() - 0.5) }
        net.step(dt: frameDT)
    }
    #expect(net.rates.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= net.rMax })
    #expect(net.gain * synthetic.csr().maxRowAbsSum < 1)
}

@Test func airborneNearEdgeRaisesLanding() {
    func land(edge: Double) -> Double {
        let brain = ConnectomeBrain(circuit: synthetic, seed: 13)
        let p = Percept(flyPosition: CGPoint(x: edge, y: 500), airborne: true, pointer: CGPoint(x: 1300, y: 100),
                        distanceToLeftEdge: edge, distanceToRightEdge: 1440 - edge, distanceToBottom: 500)
        var m = MotorCommand()
        for _ in 0..<90 { m = brain.step(p, dt: frameDT) }
        #expect(m.thrust > 0.5, "flight tonic sustains wing MN drive")
        return m.land
    }
    let near = land(edge: 10), far = land(edge: 700)
    print("landing: near=\(near) far=\(far)")
    #expect(near > 0.5)
    #expect(far < 0.2)
}

@Test func jsonRoundTripLoad() throws {
    let json = """
    {"version":1,"source":"tiny","citation":"t",
     "nodes":[
      {"id":0,"name":"LPLC2_R","type":"LPLC2","side":"R","class":"","superclass":"","nt":"acetylcholine","role":"sensor","n":80,"tau":0.02},
      {"id":1,"name":"DNp01_R","type":"DNp01","side":"R","class":"","superclass":"","nt":"acetylcholine","role":"dn","n":1,"tau":0.005},
      {"id":2,"name":"DLMn_C","type":"DLMn","side":"C","class":"","superclass":"","nt":"unknown","role":"mn","n":5,"tau":0.02}],
     "edges":{"pre":[0,1,2],"post":[1,2,1],"w":[0.6,0.8,-0.2]},
     "groups":{"loom":[0],"mechano":[],"visual_landing":[],"gf":[1],"escape_dn":[],"landing_dn":[],"steer_dn":[],
               "walk_dn":[],"backward_dn":[],"freeze_dn":[],"groom_dn":[],"wing_mn":[2],"haltere_mn":[],"leg_mn":[]}}
    """
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flybrain-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("circuit.json")
    try json.write(to: url, atomically: true, encoding: .utf8)
    let c = try Circuit.load(url: url)
    #expect(c.nodeCount == 3 && c.edgeCount == 3)
    #expect(c.nodes[1].side == .R && c.nodes[2].side == .C && c.nodes[0].n == 80)
    #expect(c.group("loom", side: .R) == [0] && c.group("loom", side: .L).isEmpty)
    #expect(c.missingGroups.isEmpty)
    let m = c.csr()
    #expect(m.rowPtr == [0, 0, 2, 3])
    #expect(Set(m.col[0..<2]) == [0, 2])
    #expect(abs(m.maxRowAbsSum - 0.8) < 1e-6)
    // Re-encode and decode again.
    let again = try JSONDecoder().decode(Circuit.self, from: JSONEncoder().encode(c))
    #expect(again.edges.w == c.edges.w && again.nodes.map(\.name) == c.nodes.map(\.name))
    // Bad file is rejected.
    let bad = url.deletingLastPathComponent().appendingPathComponent("bad.json")
    try json.replacingOccurrences(of: "\"post\":[1,2,1]", with: "\"post\":[1,9,1]").write(to: bad, atomically: true, encoding: .utf8)
    #expect(throws: CircuitError.self) { try Circuit.load(url: bad) }
    // Brain runs on it (tau 0.005 → substeps).
    let brain = ConnectomeBrain(circuit: c)
    #expect(brain.network.substeps(for: frameDT) == 7)
    _ = brain.step(Percept(), dt: frameDT)
}

@Test func benchmarkFrameStep() {
    let brain = ConnectomeBrain(circuit: synthetic, seed: 1)
    var p = Percept(flyPosition: CGPoint(x: 700, y: 450), pointer: CGPoint(x: 900, y: 450),
                    pointerVelocity: CGVector(dx: -300, dy: 0), idleTime: 5)
    for _ in 0..<60 { _ = brain.step(p, dt: frameDT) }
    var times: [Double] = []
    times.reserveCapacity(500)
    let clock = ContinuousClock()
    for i in 0..<500 {
        p.airborne = (i / 100) % 2 == 1
        let d = clock.measure { _ = brain.step(p, dt: frameDT) }
        times.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1e3)
    }
    times.sort()
    let median = times[times.count / 2]
    let c = synthetic
    #if DEBUG
    let mode = "debug"
    #else
    let mode = "release"
    #endif
    print(String(format: "BENCH [%@] nodes=%d edges=%d substeps=%d median=%.4f ms p90=%.4f ms",
                 mode, c.nodeCount, c.edgeCount, brain.network.substeps(for: frameDT), median, times[450]))
    #if DEBUG
    // Unoptimised builds are not representative; the 0.5 ms budget is asserted with `swift test -c release`.
    #expect(median < 50)
    #else
    #expect(median < 0.5)
    #endif
}

// MARK: - Integration test against the real circuit (module A output)
// INTEGRATION: runs the loom test on app/Sources/FlyApp/Resources/circuit.json when that file exists;
// it is reported as *skipped* (not failed) while the file is absent.

let realCircuitURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/FlyApp/Resources/circuit.json")

@Test("INTEGRATION: real circuit.json loom → takeoff",
      .enabled(if: FileManager.default.fileExists(atPath: realCircuitURL.path), "circuit.json not present yet"))
func realCircuitLoom() throws {
    let c = try Circuit.load(url: realCircuitURL)
    print("real circuit: nodes=\(c.nodeCount) edges=\(c.edgeCount) missingGroups=\(c.missingGroups)")
    let brain = ConnectomeBrain(circuit: c, seed: 7)
    print("gain=\(brain.network.gain) substeps=\(brain.network.substeps(for: frameDT))\n\(brain.calibrationReport)")
    let r = runLoom(brain)
    print("loom(real): maxTakeoff=\(r.maxTakeoff) t=\(r.takeoffTime ?? -1) yaw@takeoff=\(r.yawAtTakeoff)")
    #expect(r.maxTakeoff > 0.5)
    #expect(r.takeoffTime != nil && r.takeoffTime! <= 0.3)
    #expect(r.yawAtTakeoff > 0)
    var rng = SplitMix64(seed: 1)
    for _ in 0..<600 {
        for i in 0..<brain.network.n { brain.network.input[i] = 10 * rng.nextUnit() }
        brain.network.step(dt: frameDT)
    }
    #expect(brain.network.rates.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= brain.network.rMax })
}

// MARK: - v2 border anticipation and restlessness

@Test func edgeTimeToContactDrivesLandingAndSteersAway() {
    let enc = SensoryEncoder(circuit: synthetic)
    var p = Percept(flyPosition: CGPoint(x: 700, y: 450), airborne: true, pointer: CGPoint(x: 5000, y: 5000),
                    distanceToLeftEdge: 700, distanceToRightEdge: 740, distanceToBottom: 450)
    let far = enc.drive(for: p)
    #expect(far.edgeLoomL == 0 && far.edgeLoomR == 0)
    p.edgeTimeToContactLeft = 0.2; p.edgeTimeToContactRight = 2
    let near = enc.drive(for: p)
    let lm = enc.config.landingMax
    #expect(abs(near.edgeLoomL - lm * Float(exp(-0.2 / 0.4))) < 1e-4)
    #expect(near.edgeLoomL > near.edgeLoomR)
    #expect(near.steerR > near.steerL, "border imminent on the left → steer_dn R (turn right, away)")
    // Monotonic in τ.
    var last: Float = .infinity
    for tau in stride(from: 0.05, through: 2.0, by: 0.15) {
        p.edgeTimeToContactLeft = tau; p.edgeTimeToContactRight = tau
        let v = enc.drive(for: p).edgeLoomL
        #expect(v < last); last = v
    }
    // Not airborne → nothing.
    p.airborne = false
    #expect(enc.drive(for: p).edgeLoomL == 0)
}

@Test func imminentBorderOnLeftTurnsBrainRight() {
    let brain = ConnectomeBrain(circuit: synthetic, seed: 3)
    var p = Percept(flyPosition: CGPoint(x: 700, y: 450), airborne: true, pointer: CGPoint(x: 5000, y: 5000),
                    distanceToLeftEdge: 700, distanceToRightEdge: 740, distanceToBottom: 450)
    p.edgeTimeToContactLeft = 0.15
    var m = MotorCommand()
    for _ in 0..<30 { m = brain.step(p, dt: frameDT) }
    #expect(m.yawRate < 0, "yaw=\(m.yawRate)")
}

@Test func setRestBoutMapsToEncoderLive() {
    let brain = ConnectomeBrain(circuit: synthetic, seed: 4)
    brain.setRestBout(DeweySettings(restlessness: 1).restBout)
    #expect(brain.encoder.config.restMin == 3 && brain.encoder.config.restMax == 10)
    #expect((3...10).contains(brain.encoder.currentBoutLength))
    brain.setRestBout(DeweySettings(restlessness: 0).restBout)
    #expect(brain.encoder.config.restMin == 30 && brain.encoder.config.restMax == 90)
    #expect((30...90).contains(brain.encoder.currentBoutLength))
    let tunable: RestlessnessTunable = brain
    tunable.setRestBout(5...6)
    #expect(brain.encoder.config.restMax == 6)
}

// MARK: - v4 flocking (boids) encoder

@Test func flockPerceptSteersAndNeverLooms() {
    let enc = SensoryEncoder(circuit: synthetic)
    enc.config.headingNoiseStd = 0
    enc.config.saccadeFirstDelay = 100   // no spontaneous saccades in this test
    var p = Percept(flyPosition: CGPoint(x: 700, y: 450), airborne: true, pointer: CGPoint(x: 5000, y: 5000),
                    distanceToLeftEdge: 700, distanceToRightEdge: 740, distanceToBottom: 450)
    let alone = enc.drive(for: p)
    #expect(alone.flock == 0 && alone.separation == 0 && alone.wing == enc.config.flightWing)
    // Flock on the left → steer_dn L; weaker than full target fixation.
    p.flockBearing = 1.0; p.flockStrength = 0.2; p.flockSpeedRatio = 1
    let left = enc.drive(for: p)
    #expect(left.flock > 0 && left.flock < enc.config.fixationGain)
    #expect(left.steerL > left.steerR)
    #expect(abs(left.wing - enc.config.flockWingBase) < 1e-5, "matched speed → mid-range wing drive")
    // Separation away to the right is stronger than the flock pull; a neighbour ahead brakes.
    p.separationBearing = -2.0; p.separationStrength = 0.3
    let sep = enc.drive(for: p)
    #expect(sep.separation < 0 && abs(sep.separation) > abs(sep.flock))
    #expect(sep.steerR > sep.steerL)
    #expect(sep.wing < left.wing)
    // Speed ratio > 1 → more thrust.
    p.separationStrength = 0; p.flockSpeedRatio = 1.5
    #expect(enc.drive(for: p).wing > left.wing)
    // Never onto loom / mechano, however strong.
    p.separationStrength = 1; p.flockStrength = 1
    let strong = enc.drive(for: p)
    #expect(strong.loomL == 0 && strong.loomR == 0 && strong.mechanoL == 0 && strong.mechanoR == 0)
    // Perched: flock fields are ignored.
    p.airborne = false
    let perched = enc.drive(for: p)
    #expect(perched.flock == 0 && perched.separation == 0 && perched.steerL == 0 && perched.steerR == 0)
}

@Test func strongSeparationTriggersSaccadeAway() {
    let enc = SensoryEncoder(circuit: synthetic)
    enc.config.headingNoiseStd = 0
    enc.config.saccadeFirstDelay = 100   // no spontaneous saccades in this test
    var p = Percept(flyPosition: CGPoint(x: 700, y: 450), airborne: true, pointer: CGPoint(x: 5000, y: 5000),
                    distanceToLeftEdge: 700, distanceToRightEdge: 740, distanceToBottom: 450)
    _ = enc.drive(for: p)   // takeoff frame
    for _ in 0..<60 { _ = enc.drive(for: p) }   // past the refractory
    let before = enc.saccadeCount
    p.separationBearing = 1.2; p.separationStrength = 0.9
    let d = enc.drive(for: p)
    #expect(enc.saccadeCount == before + 1)
    #expect(enc.lastSaccadeAmplitude > 0 && d.saccade > 0, "saccade to the left, away from the neighbour")
}

@Test func socialTakeoffDrivesVoluntaryTakeoffOnly() {
    let enc = SensoryEncoder(circuit: synthetic)
    var p = Percept(flyPosition: CGPoint(x: 700, y: 20), airborne: false, pointer: CGPoint(x: 5000, y: 5000), idleTime: 0.5)
    #expect(enc.drive(for: p).restless == 0)
    p.flockTakeoffDrive = 1
    let d = enc.drive(for: p)
    #expect(d.restless == enc.config.restDrive && d.loomL == 0 && d.loomR == 0)
}

@Test func windowStartleDrivesMechanoAndVoluntaryTakeoffNeverLoom() {
    let enc = SensoryEncoder(circuit: synthetic)
    var p = Percept(flyPosition: CGPoint(x: 700, y: 20), airborne: false, pointer: CGPoint(x: 5000, y: 5000), idleTime: 0.5)
    let base = enc.drive(for: p)
    #expect(base.startle == 0 && base.mechanoL == 0)
    p.substrateJolt = 1
    let j = enc.drive(for: p)
    #expect(j.startle == enc.config.joltDrive && j.mechanoL == enc.config.joltMechano && j.mechanoR == enc.config.joltMechano)
    #expect(j.loomL == 0 && j.loomR == 0)
    p.substrateJolt = 0; p.windowMotionStartle = 1
    let s = enc.drive(for: p)
    #expect(s.startle == enc.config.startleDrive && s.startle < j.startle && s.mechanoL == 0 && s.loomL == 0)
    // Airborne: a moving window on the left → turn right (steer_dn R), plus the voluntary-takeoff drive.
    enc.config.saccadeFirstDelay = 100; enc.config.headingNoiseStd = 0
    var a = Percept(flyPosition: CGPoint(x: 700, y: 450), airborne: true, pointer: CGPoint(x: 5000, y: 5000),
                    distanceToLeftEdge: 700, distanceToRightEdge: 740, distanceToBottom: 450)
    a.windowMotionStartle = 1; a.windowMotionBearing = 1.0
    let f = enc.drive(for: a)
    #expect(f.startleTurn < 0 && f.steerR > f.steerL && f.loomL == 0 && f.loomR == 0)
}

@Test func substrateJoltTriggersTakeoffWithinAFewFrames() {
    let brain = ConnectomeBrain(circuit: synthetic, seed: 4)
    var p = Percept(flyPosition: CGPoint(x: 700, y: 20), airborne: false, pointer: CGPoint(x: 5000, y: 5000),
                    distanceToLeftEdge: 700, distanceToRightEdge: 740, distanceToBottom: 10, idleTime: 0)
    for f in 0..<60 { p.idleTime = Double(f) * frameDT; #expect(brain.step(p, dt: frameDT).takeoff < 0.5) }
    var t: Double?
    for f in 0..<18 {
        p.substrateJolt = max(0, 1 - Double(f) * frameDT / 0.3)
        if brain.step(p, dt: frameDT).takeoff > 0.5 { t = Double(f + 1) * frameDT; break }
    }
    print("synthetic circuit: jolt takeoff after \(t ?? -1) s")
    #expect(t != nil)
}
