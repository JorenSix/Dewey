import FlyCore
import Foundation
import simd

/// Grooming sub-behaviour, in the fly's anterior-to-posterior order (Seeds et al. 2014).
public enum GroomStage: Int, CaseIterable, Sendable {
    case head, frontLegs, abdomen, wingLeft, wingRight

    /// Length of each stage in groom cycles (one cycle = `groomPhase` advancing by 2π; at
    /// FlyController's 3 Hz: head 3 s, front legs 2.3 s, abdomen 3 s, each wing 3 s; 14.3 s total).
    public static let cycles: [Double] = [9, 7, 9, 9, 9]
    public static var sequenceCycles: Double { cycles.reduce(0, +) }

    /// Stage at `cycle` (groom cycles since the bout started; the sequence loops), the progress through
    /// it (0..<1) and the cross-fade weight of the stage (the previous stage has weight 1 − fade).
    public static func at(cycle: Double) -> (stage: GroomStage, progress: Double, fade: Double) {
        var c = cycle.truncatingRemainder(dividingBy: sequenceCycles)
        if c < 0 { c += sequenceCycles }
        for (i, len) in cycles.enumerated() {
            if c < len || i == cycles.count - 1 {
                return (GroomStage(rawValue: i)!, min(c / len, 0.9999), smoothstep(0, 1, c))
            }
            c -= len
        }
        return (.head, 0, 1)
    }

    var previous: GroomStage { GroomStage(rawValue: (rawValue + GroomStage.allCases.count - 1) % GroomStage.allCases.count)! }
}

/// Maps a `BodyPose` onto the flybody joints of a `FlyRig`.
///
/// Joint semantics (determined from renders; left/right are mirrored so the same sign means the same
/// motion on both sides):
/// - Wings `wing_{yaw,roll,pitch}_{left,right}`: 0/0/0 = wing spread laterally in the horizontal plane.
///   yaw + sweeps the wing backward (spring ref 1.5 = folded over the abdomen), roll + tilts it down,
///   pitch rotates about the span (angle of attack). Spring refs (1.5, 0.7, -1) = folded rest.
/// - Legs `coxa_{abduct,twist}_T{1,2,3}_{side}`, `coxa_T*_{side}` (+ = protract / swing forward),
///   `femur_twist_T*`, `femur_T*` (- = lift/flex), `tibia_T*` (- = flex), `tarsus{,2..5}_T*`.
///   All 0 = flybody's standing pose (all six tarsi on one ground plane); spring refs = legs retracted
///   for flight.
/// - Head `head_abduct` (yaw, about the head z axis), `head_twist` (roll), `head` (pitch).
/// - Halteres `haltere_{left,right}` beat in anti-phase with the wings.
/// - Abdomen `abdomen{,_2.._7}` / `abdomen_abduct*` stay at rest.
///
/// Flight uses a figure-eight wing stroke (see `WingStroke`) plus `WingGhosts` (in-between wing copies
/// and a stroke-plane blur disc). Grooming runs the anterior→posterior sequence of `GroomStage`.
public final class JointAnimator {
    public let rig: FlyRig

    public static let legs = ["T1_left", "T2_left", "T3_left", "T1_right", "T2_right", "T3_right"]
    /// Tripod A swings together, tripod B half a cycle later.
    public static let tripodA: Set<String> = ["T1_left", "T2_right", "T3_left"]
    static let legJoints = ["coxa_abduct", "coxa_twist", "coxa", "femur_twist", "femur", "tibia",
                            "tarsus", "tarsus2", "tarsus3", "tarsus4", "tarsus5"]

    /// Ghost wings + blur disc (shared by all animators of the same rig).
    public let wingGhosts: WingGhosts
    /// Show ghost wings / blur disc while flying.
    public var ghostsEnabled = true {
        didSet { if !ghostsEnabled { wingGhosts.hide() } }
    }

    /// Current grooming sub-behaviour (meaningful while `groomAmount` > 0).
    public private(set) var groomStage: GroomStage = .head
    /// Groom cycles since the current grooming bout started (unwrapped `groomPhase` / 2π).
    public private(set) var groomCycles: Double = 0
    private var lastGroomPhase: Double?

    public init(rig: FlyRig) {
        self.rig = rig
        if let g = rig.wingGhosts {
            wingGhosts = g
        } else {
            wingGhosts = WingGhosts(rig: rig)
            rig.wingGhosts = wingGhosts
        }
    }

    public func apply(_ pose: BodyPose) {
        advanceGroom(pose)
        applyWings(pose)
        applyLegs(pose)
        applyGroomExtras(pose)
        let haltere = 0.18 * min(1, pose.wingStroke) * sin(pose.wingPhase + .pi)
        rig.setAngle("haltere_left", haltere)
        rig.setAngle("haltere_right", haltere)
    }

    // MARK: wings

    /// Figure-eight wingbeat parameters (radians). Phase 0 = mid downstroke (wing lateral, moving
    /// forward), π/2 = ventral (front) reversal, π = mid upstroke, 3π/2 = dorsal (back) reversal.
    public enum WingStroke {
        /// Stroke angle (wing_yaw): mean slightly behind lateral, ±69° fore/aft.
        public static let yawMean = 0.15, yawAmplitude = 1.2
        /// Deviation (wing_roll) at twice the beat frequency: tip path crosses itself mid-stroke.
        public static let rollMean = 0.0, rollAmplitude = 0.18
        /// Rotation (wing_pitch): ±0.8 rad (≈ 92° flip) that switches sign at the stroke reversals
        /// (supination at the ventral reversal, pronation at the dorsal one), squared off by tanh.
        public static let pitchMean = 0.0, pitchAmplitude = 0.8, pitchSharpness = 3.0

        /// Unclamped flight angles (yaw, roll, pitch) at full stroke amplitude `amp`.
        public static func angles(phase ph: Double, amp: Double = 1) -> SIMD3<Double> {
            let yaw = yawMean - yawAmplitude * amp * sin(ph)
            let roll = rollMean + rollAmplitude * amp * sin(2 * ph)
            let pitch = pitchMean + pitchAmplitude * amp * tanh(pitchSharpness * cos(ph)) / tanh(pitchSharpness)
            return SIMD3(yaw, roll, pitch)
        }
    }

    /// Wing joint angles (yaw, roll, pitch) for one side, blended from the folded rest pose.
    func wingAngles(side: String, stroke: Double, phase: Double) -> SIMD3<Double> {
        let s = clamp01(stroke)
        let unfold = smoothstep(0, 0.25, s)   // any flight drive spreads the wings
        let f = WingStroke.angles(phase: phase, amp: s)
        let names = ["wing_yaw_\(side)", "wing_roll_\(side)", "wing_pitch_\(side)"]
        var out = SIMD3<Double>()
        for i in 0..<3 {
            var a = mix(rest(names[i]), f[i], unfold)
            if let r = rig.joint(named: names[i])?.range { a = min(max(a, r.lowerBound), r.upperBound) }
            out[i] = a
        }
        return out
    }

    func applyWings(_ pose: BodyPose) {
        for side in ["left", "right"] {
            let a = wingAngles(side: side, stroke: pose.wingStroke, phase: pose.wingPhase)
            rig.setAngle("wing_yaw_\(side)", a.x)
            rig.setAngle("wing_roll_\(side)", a.y)
            rig.setAngle("wing_pitch_\(side)", a.z)
        }
        if ghostsEnabled {
            wingGhosts.update(stroke: pose.wingStroke, phase: pose.wingPhase) { side, ph in
                self.wingAngles(side: side, stroke: pose.wingStroke, phase: ph)
            }
        }
    }

    // MARK: grooming sequence

    func advanceGroom(_ pose: BodyPose) {
        guard pose.groomAmount > 0.02 else {
            groomCycles = 0; lastGroomPhase = nil; groomStage = .head
            return
        }
        if let last = lastGroomPhase {
            groomCycles += max(0, remainder(pose.groomPhase - last, 2 * .pi)) / (2 * .pi)
        } else {
            groomCycles = pose.groomPhase / (2 * .pi) // a continuous (unwrapped) phase selects the stage directly
        }
        lastGroomPhase = pose.groomPhase
        groomStage = GroomStage.at(cycle: groomCycles).stage
    }

    /// Weight of each stage right now (cross-faded over the first cycle of a stage).
    func groomWeights(_ amount: Double) -> [GroomStage: Double] {
        let (stage, _, fade) = GroomStage.at(cycle: groomCycles)
        var w: [GroomStage: Double] = [stage: amount * fade]
        if fade < 1 { w[stage.previous, default: 0] += amount * (1 - fade) }
        return w
    }

    // Leg keyframes (coxa_abduct, coxa_twist, coxa, femur_twist, femur, tibia), solved by IK on the
    // flybody rig. Wing cleaning: hind-leg claw on the dorsal surface of the lowered wing at 50, 60 …
    // 90 % span, and 0.06 above it for the return stroke.
    static let wingSweepContact: [[Double]] = [[0.25, -0.08, 1.3, 0.34, -0.39, -1.15],
                                               [0.21, -0.15, 1.25, 0.3, 0.06, -0.87],
                                               [0.12, -0.15, 0.85, 0.37, -0.01, -0.51],
                                               [-0.32, -0.15, 0.85, 0.58, 0.2, -0.14],
                                               [-0.62, -0.15, 0.81, 0.68, 0.41, 0.34]]
    static let wingSweepLifted: [[Double]] = [[0.19, -0.15, 1.3, 0.39, -0.41, -1.03],
                                              [0.15, -0.15, 1.25, 0.4, -0.02, -0.79],
                                              [-0.22, -0.15, 1.24, 0.53, 0.21, -0.48],
                                              [-0.9, -0.12, 1.25, 0.67, 0.26, -0.08],
                                              [-0.9, -0.15, 1.1, 0.65, 0.47, 0.37]]
    /// Head sweeps: front-leg tibia tip over the top / front / underside of the compound eye.
    static let headSweep: [[Double]] = [[-0.7, 0.09, 0.8, -0.62, -0.15, 0.16],
                                        [-0.71, -0.02, 0.64, -1.0, 0.07, -0.06],
                                        [-0.72, -0.07, 0.47, -0.73, -0.15, -0.39]]
    static let ikJoints = ["coxa_abduct", "coxa_twist", "coxa", "femur_twist", "femur", "tibia"]
    /// Wing pose while it is being cleaned: lowered (roll +) and abducted (yaw − from folded 1.5).
    static let groomWingYaw = 1.15, groomWingRoll = 1.0

    /// Piecewise-linear interpolation through keyframes, u in 0...1.
    static func lerpKeys(_ keys: [[Double]], _ u: Double) -> [Double] {
        let x = clamp01(u) * Double(keys.count - 1)
        let i = min(Int(x), keys.count - 2), t = x - Double(i)
        return zip(keys[i], keys[i + 1]).map { mix($0, $1, t) }
    }

    /// Sweep position along the wing (0 = base … 1 = tip) and lift (0 = pressing, 1 = return stroke)
    /// at a groom phase: power stroke base→tip over 60 % of the cycle, lifted return over 40 %.
    public static func wingSweep(phase: Double) -> (u: Double, lift: Double) {
        var c = (phase / (2 * .pi)).truncatingRemainder(dividingBy: 1)
        if c < 0 { c += 1 }
        if c < 0.6 { return (smoothstep(0, 1, c / 0.6), 0) }
        let r = (c - 0.6) / 0.4
        return (1 - smoothstep(0, 1, r), sin(.pi * r))
    }

    // MARK: legs

    func applyLegs(_ pose: BodyPose) {
        let walk = clamp01(pose.walkAmount)
        let tuck = clamp01(pose.legTuck)
        let w = groomWeights(clamp01(pose.groomAmount))
        let gp = pose.groomPhase
        let sweep = Self.wingSweep(phase: gp)

        for leg in Self.legs {
            var a: [String: Double] = [:]
            for j in Self.legJoints { a[j] = 0 } // standing pose

            // Tripod gait: swing (lifted, moving forward) for sin(phase) > 0, stance otherwise.
            let ph = pose.walkPhase + (Self.tripodA.contains(leg) ? 0 : .pi)
            let lift = max(0, sin(ph))
            a["coxa"]! += walk * -0.6 * cos(ph)
            a["femur"]! += walk * -0.75 * lift
            a["tibia"]! += walk * (-0.35 * lift + 0.15 * cos(ph))

            let isFront = leg.hasPrefix("T1"), isHind = leg.hasPrefix("T3")
            let isLeft = leg.hasSuffix("left")
            let mirror = isLeft ? 1.0 : -1.0
            func add(_ keys: [Double], _ weight: Double) {
                for (j, v) in zip(Self.ikJoints, keys) { a[j]! += weight * v }
            }
            if isFront, let hw = w[.head], hw > 0 {
                // Both front legs sweep top → front → underside of the eyes, then back.
                add(Self.lerpKeys(Self.headSweep, 0.5 - 0.5 * cos(gp)), hw)
            }
            if isFront, let fw = w[.frontLegs], fw > 0 {
                // Front legs raised in front of the head, rubbing against each other.
                let r = sin(gp * 2 + (mirror > 0 ? 0 : .pi))
                a["coxa"]! += fw * (0.9 + 0.15 * r)
                a["coxa_twist"]! += fw * 0.25 * r
                a["femur"]! += fw * -0.7
                a["tibia"]! += fw * (-0.8 + 0.35 * r)
            }
            if isHind, let bw = w[.abdomen], bw > 0 {
                // Hind legs lifted and swept backward along the sides of the abdomen.
                let r = sin(gp * 1.5 + (mirror > 0 ? 0 : .pi * 0.5))
                a["coxa"]! += bw * (-0.2 + 0.3 * r)
                a["coxa_abduct"]! += bw * -0.4
                a["femur"]! += bw * (-0.9 + 0.3 * r)
                a["tibia"]! += bw * (0.4 - 0.4 * r)
            }
            if isHind, let ww = w[isLeft ? .wingLeft : .wingRight], ww > 0 {
                // Hind leg of that side sweeps over the dorsal wing surface, base → tip.
                let keys = zip(Self.lerpKeys(Self.wingSweepContact, sweep.u),
                               Self.lerpKeys(Self.wingSweepLifted, sweep.u)).map { mix($0, $1, sweep.lift) }
                add(keys, ww)
            }

            for (j, v) in a {
                let name = "\(j)_\(leg)"
                rig.setAngle(name, mix(v, rest(name), tuck))
            }
        }
    }

    /// Head tilt during eye cleaning and the lowered wing during wing cleaning.
    func applyGroomExtras(_ pose: BodyPose) {
        let amount = clamp01(pose.groomAmount)
        let w = groomWeights(amount)
        let gp = pose.groomPhase
        // head_abduct is yaw (+ = left, CCW from above); its MJCF range is ±0.2, allow ±0.5 for visibility.
        let hw = w[.head] ?? 0
        rig.setAngle("head_abduct", min(max(pose.headYaw * (1 - hw), -0.5), 0.5), clamp: false)
        rig.setAngle("head", hw * (0.15 + 0.1 * sin(gp)))          // nods into the sweeping legs
        rig.setAngle("head_twist", hw * 0.12 * sin(gp * 0.5))

        guard amount > 0 else { return }
        let fold = 1 - smoothstep(0, 0.25, clamp01(pose.wingStroke))
        let sweep = Self.wingSweep(phase: gp)
        for (side, stage) in [("left", GroomStage.wingLeft), ("right", .wingRight)] {
            let ww = (w[stage] ?? 0) * fold
            guard ww > 0 else { continue }
            // The wing yields a little under the pressing leg (mid-sweep) and springs back on the return.
            let press = 0.04 * sin(.pi * sweep.u) * (1 - sweep.lift) - 0.03 * sweep.lift
            let yaw = mix(rig.joint(named: "wing_yaw_\(side)")?.angle ?? 0, Self.groomWingYaw, ww)
            let roll = mix(rig.joint(named: "wing_roll_\(side)")?.angle ?? 0, Self.groomWingRoll + press, ww)
            rig.setAngle("wing_yaw_\(side)", yaw)
            rig.setAngle("wing_roll_\(side)", roll)
        }
    }

    // MARK: standing stance / contact

    /// Ventral distance (rig units, +y = dorsal) from the body origin (thorax centre) to the lowest
    /// tarsus / claw point in the standing stance. Place the body this far from the surface it stands on.
    public var footContactOffset: Float { stanceMetrics.footContactOffset }
    /// Half the lateral (z) width of the body proper (head, thorax, abdomen), rig units.
    public var bodyHalfWidth: Float { stanceMetrics.bodyHalfWidth }
    /// Half the lateral (z) span of the tarsi in the standing stance, rig units.
    public var stanceHalfWidth: Float { stanceMetrics.stanceHalfWidth }

    var stanceMetrics: FlyRig.StanceMetrics {
        if let m = rig.stanceMetrics { return m }
        let m = measureStance()
        rig.stanceMetrics = m
        return m
    }

    /// Poses the standing stance (all leg joints 0), measures it and restores the current pose.
    func measureStance() -> FlyRig.StanceMetrics {
        let saved = rig.joints.mapValues(\.angle)
        defer { for (n, v) in saved { rig.setAngle(n, v, clamp: false) } }
        for leg in Self.legs { for j in Self.legJoints { rig.setAngle("\(j)_\(leg)", 0) } }
        let tarsi = rig.vertices(ofBodies: Self.legs.flatMap { rig.tarsalBodies(leg: $0) })
        let core = rig.vertices(ofBodies: rig.bodyNames.filter {
            $0 == "thorax" || $0 == "head" || $0.hasPrefix("abdomen")
        })
        return FlyRig.StanceMetrics(
            footContactOffset: -(tarsi.map(\.y).min() ?? 0),
            bodyHalfWidth: core.map { abs($0.z) }.max() ?? 0,
            stanceHalfWidth: tarsi.map { abs($0.z) }.max() ?? 0)
    }

    // MARK: helpers

    func rest(_ name: String) -> Double { rig.joint(named: name)?.restAngle ?? 0 }
}

@inline(__always) func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
@inline(__always) func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
@inline(__always) func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
    let t = clamp01((x - e0) / (e1 - e0))
    return t * t * (3 - 2 * t)
}
