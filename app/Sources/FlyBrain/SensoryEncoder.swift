import Foundation
import FlyCore

/// Tuning of the Percept -> input-current mapping. Currents are in rate units (rMax = 1 by default),
/// so a current of ~1 saturates a node with no recurrent input.
public struct EncoderConfig: Sendable {
    // Loom (LPLC2/LC4)
    /// The pointer is treated as a disc of this radius (points).
    public var objectRadius: Double = 25
    /// Fly-eye scale: effective distance = screen distance * distanceScale (raise to make the fly less jumpy).
    public var distanceScale: Double = 1
    /// η-function η = θ̇ · exp(−α θ) (Gabbiani-style looming detector).
    public var etaAlpha: Double = 0.5
    /// η below this (rad/s) gives no loom drive (ignores slow drift / receding pointer).
    public var etaThreshold: Double = 1.0
    /// Loom current = loomMax · tanh(etaGain · (η − threshold)+).
    public var etaGain: Double = 0.3
    public var loomMax: Float = 3
    /// Lateralisation: w_R = clamp(0.5 − 0.5·k·sin(bearing)), w_L = clamp(0.5 + 0.5·k·sin(bearing)).
    public var lateralSharpness: Double = 1.5

    // Mechanosensation (Johnston's organ / bristles)
    public var mechanoRadius: Double = 40
    public var mechanoMax: Float = 2

    // Visual landing cue (airborne only)
    /// Landing current = landingMax · exp(−minEdgeDistance / landingScale).
    public var landingScale: Double = 120
    public var landingMax: Float = 2
    /// Border anticipation: each screen border is a wide-field looming surface. Per hemifield the
    /// landing current gains landingMax · exp(−τ/edgeTau0) (τ = edge time-to-contact, s).
    public var edgeTau0: Double = 0.4
    /// Avoidance steering: contralateral steer_dn current = edgeSteerMax · exp(−τ/edgeTau0) (an imminent
    /// border on the left drives steer_dn R → turn right, away).
    public var edgeSteerMax: Float = 1.2

    // Idle drives (perched only)
    /// Groom current ramps linearly from 0 at idle = groomDelay to groomMax at groomDelay + groomRamp.
    public var groomDelay: Double = 3
    public var groomRamp: Double = 10
    public var groomMax: Float = 2
    /// Exploratory walking tonic onto walk_dn, scaled by (1 − groom ramp fraction).
    public var walkTonic: Float = 0.6
    /// Restlessness: after a perched bout of `restMin...restMax` seconds (drawn per bout), a ramping
    /// voluntary-takeoff drive onto the non-giant-fiber `escape_dn` types (slow, GF-independent takeoff).
    public var restMin: Double = 8
    public var restMax: Double = 30
    public var restRamp: Double = 2
    public var restDrive: Float = 2.5

    // Flight maintenance (airborne only)
    public var flightWing: Float = 1.0
    public var flightSteer: Float = 0.4

    // v3 natural flight (airborne only)
    /// Body saccades: inter-saccade interval ~ exponential (mean), clipped to min...max (s). The first
    /// saccade after takeoff comes no earlier than `saccadeFirstDelay` + one interval.
    public var saccadeMeanInterval: Double = 1.2
    public var saccadeMinInterval: Double = 0.3
    public var saccadeMaxInterval: Double = 4
    public var saccadeFirstDelay: Double = 0.6
    /// Saccade amplitude range (rad), delivered as a square pulse on steer_dn of the turn side: duration
    /// T grows linearly over saccadePulse with the amplitude (30° → 80 ms, 120° → 120 ms) and strength =
    /// clamp(saccadeDrivePerRadSec · amplitude / T, 0, saccadeDriveMax), so pulse area ∝ amplitude.
    public var saccadeAmplitude: ClosedRange<Double> = (Double.pi / 6)...(2 * Double.pi / 3)
    public var saccadePulse: ClosedRange<Double> = 0.08...0.12
    public var saccadeDrivePerRadSec: Float = 0.028
    public var saccadeDriveMax: Float = 0.6
    /// Collision-avoidance saccade: when a (non-target) border's time-to-contact drops below
    /// `loomSaccadeTau` (s), a saccade of loomSaccadeAmplitude (rad) away from it is triggered at once
    /// (at most one per loomSaccadeRefractory s).
    public var loomSaccadeTau: Double = 1.1
    public var loomSaccadeAmplitude: ClosedRange<Double> = (Double.pi / 3)...(2 * Double.pi / 3)
    public var loomSaccadeRefractory: Double = 0.5
    /// Heading memory (menotaxis-like compass): a leaky integral (τ = headingMemoryTau s) of the fly's
    /// heading change; spontaneous saccades go left with p = 0.5 − headingMemoryBias·tanh(memory/headingMemoryScale),
    /// so sustained rotation one way is countered (no circling).
    public var headingMemoryTau: Double = 10
    public var headingMemoryScale: Double = 1.5
    public var headingMemoryBias: Double = 0.5
    /// A collision-avoidance saccade turns toward the more open hemifield (longer gaze ray), but against
    /// the heading memory when |memory| > loomMemoryThreshold (rad) and the two gaze distances are within
    /// loomTieRatio of each other (head-on or into a corner: either way is open).
    public var loomMemoryThreshold: Double = 2
    public var loomTieRatio: Double = 1.5
    /// With a perch target, a saccade turns toward it with this probability (fixation saccades).
    public var targetSaccadeBias: Double = 0.85
    /// No saccades while the target is closer than this time-to-contact (s) (final approach).
    public var targetSaccadeSuppressTau: Double = 1.2
    /// Heading noise: Ornstein-Uhlenbeck drive asymmetry (+ on steer_dn L, − on R).
    public var headingNoiseTau: Double = 1.0
    public var headingNoiseStd: Double = 0.012
    /// Fixation of the perch target: steer_dn of the target side += fixationGain · sin(bearing)
    /// (full strength when the target is behind).
    public var fixationGain: Float = 0.11
    /// Target landing cue: visual_landing += landingMax · exp(−τ_target / targetTau0).
    public var targetTau0: Double = 0.7

    // v4 flocking (boids; airborne only, onto steer_dn and wing_mn only, never onto loom/mechano)
    /// Flock pull (alignment + cohesion): steer_dn of the flock side += flockGain · strength · sin(bearing)
    /// (±1 when behind). Weaker than target fixation and saccades.
    public var flockGain: Float = 0.07
    /// Separation: steer_dn toward the separation (away) bearing += separationGain · strength · sin(b)
    /// (±1 when the away direction is behind, i.e. the neighbour is ahead).
    public var separationGain: Float = 0.45
    /// With neighbours (flockSpeedRatio > 0) the flight wing drive becomes
    /// clamp(flockWingBase + flockThrustGain·(ratio − 1) − separationThrustGain·sepStrength·max(0, −cos b_sep), flockWingMin, flightWing):
    /// a mid-range thrust (≈ 450 pt/s) so speed can be matched both ways; a neighbour close ahead brakes.
    public var flockWingBase: Float = 0.25
    public var flockThrustGain: Float = 0.5
    public var separationThrustGain: Float = 0.3
    public var flockWingMin: Float = 0.1
    /// A separation strength above this starts an immediate saccade toward the away side
    /// (separationSaccadeAmplitude, rad; at most one per separationSaccadeRefractory s), cancelling a saccade
    /// pulse that turns toward the neighbour.
    public var separationSaccadeThreshold: Double = 0.6
    public var separationSaccadeAmplitude: ClosedRange<Double> = (Double.pi / 6)...(Double.pi / 3)
    public var separationSaccadeRefractory: Double = 0.3
    /// Flocking calms the saccade generator: spontaneous intervals × (1 + flockSaccadeSlowdown · strength),
    /// and a spontaneous saccade turns toward the flock (amplitude ≈ |bearing|) with p = flockSaccadeBias · strength
    /// when |bearing| > 0.35 rad; with a neighbour close (separation > 0.2) it turns away instead.
    public var flockSaccadeSlowdown: Double = 2.0
    public var flockSaccadeBias: Double = 0.8
    /// The spontaneous saccade timer runs (1 + flockSaccadeUrgency · strength · (|bearing| − 0.35)+) times faster.
    public var flockSaccadeUrgency: Double = 4
    /// Pursuit saccade: flock strength ≥ pursuitSaccadeStrength and |flock bearing| > pursuitSaccadeBearing (rad)
    /// start an immediate saccade toward the flock (at most one per pursuitSaccadeRefractory s).
    public var pursuitSaccadeStrength: Double = 0.3
    public var pursuitSaccadeBearing: Double = 0.8
    public var pursuitSaccadeRefractory: Double = 0.4

    // v5 window startle (substrate vibration / nearby window motion), never onto loom
    /// Perched on a window that moved / resized / closed (`Percept.substrateJolt` 0...1): mechano (both sides)
    /// += joltMechano · jolt and voluntary takeoff (escape_dn minus gf) += joltDrive · jolt. Calibrated on the
    /// real circuit like `restDrive` (the voluntary-takeoff channel decodes takeoff from ≈ 0.15–0.2 input):
    /// a full jolt gives takeoff in 1–2 frames, still > threshold at jolt ≈ 0.1 (see WindowPerchTests).
    public var joltMechano: Float = 2
    public var joltDrive: Float = 2.5
    /// A window moved within ~150 pt (`Percept.windowMotionStartle` 0...1): voluntary takeoff += startleDrive ·
    /// startle (weaker than the jolt: on the real circuit only startle ≳ 0.5, i.e. within ≈ 75 pt, reaches the
    /// takeoff threshold), and airborne a loom-free turn away from the moving window: steer_dn on
    /// the side away from `windowMotionBearing` += startleSteer · startle.
    public var startleDrive: Float = 0.4
    public var startleSteer: Float = 0.4
    public init() {}
}

/// Input currents per sensory/drive channel, before they are written onto circuit groups.
public struct SensoryDrive: Sendable, Equatable {
    public var loomL: Float = 0, loomR: Float = 0
    public var mechanoL: Float = 0, mechanoR: Float = 0
    public var landing: Float = 0
    /// Per-side extra landing current from border looming (time-to-contact), added on top of `landing`.
    public var edgeLoomL: Float = 0, edgeLoomR: Float = 0
    public var groom: Float = 0
    public var walk: Float = 0
    public var restless: Float = 0
    public var wing: Float = 0
    public var steerL: Float = 0, steerR: Float = 0
    /// v3 components already included in steerL/R / landing (for inspection): saccade pulse (signed,
    /// + = left), heading noise (signed), fixation (signed), target landing cue.
    public var saccade: Float = 0, headingNoise: Float = 0, fixation: Float = 0, targetLanding: Float = 0
    /// v4 components already included in steerL/R (signed, + = left): flock pull and separation.
    public var flock: Float = 0, separation: Float = 0
    /// v5 window startle onto the voluntary-takeoff neurons (added to `restless` when applied), and its
    /// steering component (signed, + = left, already included in steerL/R).
    public var startle: Float = 0, startleTurn: Float = 0
    public init() {}
}

/// Percept -> input currents on sensor / DN groups. Mapping (all documented in EncoderConfig):
///
/// | source | formula | target group(s) |
/// |---|---|---|
/// | pointer looming | θ = 2·atan(R/d), θ̇ = 2R·(−ḋ)/(d²+R²), η = θ̇e^{−αθ}; I = loomMax·tanh(g(η−η₀)+), split L/R by bearing | `loom` (side L/R; C gets the max) |
/// | pointer < 40 pt | I = mechanoMax·(1 − d/40), split L/R by bearing | `mechano` |
/// | airborne, nearest perch edge | I = landingMax·exp(−min(dL,dR,dB)/landingScale) | `visual_landing` |
/// | airborne, border looming per hemifield (gaze ray ±30°, τ = ray distance ÷ closing speed, incl. Dock top / menu bar) | I_side += landingMax·exp(−τ_side/edgeTau0) | `visual_landing` L/R (C gets the max) |
/// | airborne, border looming, contralateral | I = edgeSteerMax·exp(−τ_L/edgeTau0) on R, ·exp(−τ_R/edgeTau0) on L (turn away; the behaviour layer ignores yaw while landing) | `steer_dn` R/L |
/// | perched idle time | I = groomMax·clamp((idle−delay)/ramp) | `groom_dn` |
/// | perched idle time | I = walkTonic·(1 − groom fraction) | `walk_dn` |
/// | perched idle > bout length (random restMin…restMax per bout) | I = restDrive·clamp((idle−bout)/restRamp) | `escape_dn` minus `gf` |
/// | airborne | I = flightWing; flightSteer each side | `wing_mn`; `steer_dn` L/R |
/// | airborne, saccade generator (interval ~Exp(1.2 s) clipped 0.3–4 s; side random, away from an imminent border, or toward the target) | square pulse, area ∝ amplitude (30–120°), 80–120 ms | `steer_dn` of the turn side |
/// | airborne, border τ < 1.1 s (not the target's border) | immediate collision-avoidance saccade 60–120° toward the longer gaze ray (memory breaks ties) | `steer_dn` contralateral |
/// | airborne, heading memory (leaky ∫ heading change, τ 10 s) | spontaneous saccade side biased against the accumulated turn | — |
/// | airborne, heading noise (OU, τ 1 s) | ±n | `steer_dn` L (+) / R (−) |
/// | airborne, perch target (fixation) | fixationGain·sin(bearing) (±1 when behind) | `steer_dn` of the target side |
/// | airborne, perch target (looming) | landingMax·exp(−τ_target/targetTau0) | `visual_landing` |
/// | border looming on the target's border | no avoidance steering from that hemifield | — |
/// | airborne, flock pull (boids alignment + cohesion, leader ×2.5) | flockGain·strength·sin(b_flock) (±1 behind); weaker than fixation | `steer_dn` of the flock side |
/// | airborne, separation (neighbours within 2.5 body lengths / predicted closest approach) | separationGain·strength·sin(b_sep) (±1 behind) | `steer_dn` of the away side |
/// | airborne, separation strength > 0.35 | immediate saccade 45–90° toward the away side (cancels a saccade turning toward the neighbour) | `steer_dn` of the away side |
/// | airborne, flock strength ≥ 0.3 and |b_flock| > 0.6 rad | immediate pursuit saccade toward the flock, amplitude ≈ |b_flock| | `steer_dn` of the flock side |
/// | airborne, flocking | spontaneous saccade interval × (1 + strength); side toward the flock (p = 0.8·strength) | — |
/// | airborne, speed ratio (neighbours' speed ÷ own, with catch-up) | wing = flockWingBase + flockThrustGain·(ratio−1) − separationThrustGain·sep·(neighbour ahead), replaces flightWing | `wing_mn` |
/// | perched, leader took off nearby (Percept.flockTakeoffDrive) | I = restDrive·drive (max with restlessness) | `escape_dn` minus `gf` |
/// | perched on a window that moved / resized / closed (Percept.substrateJolt, decays over 0.3 s; held while the window is gone) | I = joltMechano·jolt both sides; I = joltDrive·jolt | `mechano` L/R/C; `escape_dn` minus `gf` |
/// | a window moved within ~150 pt (Percept.windowMotionStartle ∝ proximity, decays over 0.3 s) | I = startleDrive·startle | `escape_dn` minus `gf` |
/// | airborne, nearby window motion (bearing Percept.windowMotionBearing) | startleSteer·startle on the side away from the window | `steer_dn` |
/// | window startle (any) | never | `loom` |
/// | neighbours (any) | never | `loom`, `mechano` (no escape from friends) |
///
/// ḋ uses only the pointer velocity projected on the fly→pointer axis (fly self-motion is ignored, so a
/// stationary pointer never looms). Bearing is relative to fly heading; positive = pointer on the left.
public final class SensoryEncoder {
    public var config: EncoderConfig

    // Last computed values, for debugging / overlay.
    public private(set) var theta: Double = 0
    public private(set) var thetaDot: Double = 0
    public private(set) var bearing: Double = 0
    public private(set) var lastDrive = SensoryDrive()

    private let loomL: [Int32], loomR: [Int32], loomC: [Int32]
    private let mechL: [Int32], mechR: [Int32], mechC: [Int32]
    private let landingL: [Int32], landingR: [Int32], landingC: [Int32]
    private let landing: [Int32], groom: [Int32], walk: [Int32], wing: [Int32]
    private let steerL: [Int32], steerR: [Int32], steerC: [Int32]
    private let voluntaryTakeoff: [Int32]
    private var rng: SplitMix64
    private var lastIdle = Double.infinity
    private var boutLength: Double
    // Saccade generator / heading noise state.
    private var wasAirborne = false
    private var saccadeTimer = 0.0
    private var pulseLeft = 0.0
    private var pulseSigned: Float = 0
    private var ou = 0.0
    private var sinceSaccade = 0.0
    private var lastHeading = 0.0
    /// Side (+1 left / −1 right) of the current separation turn (hysteresis for a neighbour dead ahead).
    private var separationSide: Float = 0
    /// Leaky integral of heading change (rad, + = turned left), see `EncoderConfig.headingMemoryTau`.
    public private(set) var headingMemory = 0.0
    /// Number of saccade pulses started, and the last one's commanded amplitude (rad, + = left).
    public private(set) var saccadeCount = 0
    /// Of which collision-avoidance (looming-triggered) saccades.
    public private(set) var loomSaccadeCount = 0
    public private(set) var lastSaccadeAmplitude = 0.0

    public init(circuit: Circuit, config: EncoderConfig = EncoderConfig(), seed: UInt64 = 1) {
        self.config = config
        rng = SplitMix64(seed: seed ^ 0x5EED_0F_F1E5)
        boutLength = config.restMin
        func g(_ name: String, _ s: Side? = nil) -> [Int32] { circuit.group(name, side: s).map { Int32($0) } }
        loomL = g("loom", .L); loomR = g("loom", .R); loomC = g("loom", .C)
        mechL = g("mechano", .L); mechR = g("mechano", .R); mechC = g("mechano", .C)
        landingL = g("visual_landing", .L); landingR = g("visual_landing", .R); landingC = g("visual_landing", .C)
        landing = g("visual_landing"); groom = g("groom_dn"); walk = g("walk_dn"); wing = g("wing_mn")
        steerL = g("steer_dn", .L); steerR = g("steer_dn", .R); steerC = g("steer_dn", .C)
        let gf = Set(g("gf"))
        voluntaryTakeoff = g("escape_dn").filter { !gf.contains($0) }
        boutLength = drawBout()
    }

    /// Restlessness setting: perched-bout length range (s). Takes effect immediately (the current
    /// bout is redrawn from the new range).
    public func setRestBout(_ range: ClosedRange<Double>) {
        config.restMin = max(0, range.lowerBound); config.restMax = max(config.restMin, range.upperBound)
        boutLength = drawBout()
    }

    /// Length (s) of the current perched bout before the voluntary-takeoff drive ramps up.
    public var currentBoutLength: Double { boutLength }

    private func unit() -> Double { Double(rng.next() >> 11) / Double(1 << 53) }

    private func drawBout() -> Double {
        config.restMin + (config.restMax - config.restMin) * unit()
    }

    private func drawInterval() -> Double {
        let c = config
        let x = -c.saccadeMeanInterval * log(max(1 - unit(), 1e-12))
        return min(max(x, c.saccadeMinInterval), max(c.saccadeMinInterval, c.saccadeMaxInterval))
    }

    /// Starts a saccade pulse of signed amplitude `a` (rad, + = left).
    private func startPulse(_ a: Double) {
        let c = config
        let lo = c.saccadeAmplitude.lowerBound, hi = c.saccadeAmplitude.upperBound
        let f = min(max((abs(a) - lo) / max(hi - lo, 1e-6), 0), 1)
        let T = c.saccadePulse.lowerBound + (c.saccadePulse.upperBound - c.saccadePulse.lowerBound) * f
        let s = min(max(c.saccadeDrivePerRadSec * Float(abs(a) / max(T, 1e-3)), 0), c.saccadeDriveMax)
        pulseSigned = a > 0 ? s : -s
        pulseLeft = T
        saccadeCount += 1; lastSaccadeAmplitude = a; sinceSaccade = 0
    }

    private func gauss() -> Double {
        let u1 = max(unit(), 1e-12), u2 = unit()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    /// Decides the next saccade (side and amplitude) from the percept; nil = skip this one.
    private func planSaccade(_ p: Percept) -> Double? {
        let c = config
        let amp = c.saccadeAmplitude.lowerBound + (c.saccadeAmplitude.upperBound - c.saccadeAmplitude.lowerBound) * unit()
        let tL = p.edgeTimeToContactLeft, tR = p.edgeTimeToContactRight
        let hasTarget = p.targetDistance.isFinite
        if hasTarget && p.targetTimeToContact < c.targetSaccadeSuppressTau { return nil }
        // Collision-avoidance saccade: away from an imminent border (not from the target's border).
        let effL = p.edgeIsTargetLeft ? Double.infinity : tL, effR = p.edgeIsTargetRight ? Double.infinity : tR
        if min(effL, effR) < 1.0 { return effL < effR ? -amp : amp }
        if hasTarget {
            let b = p.targetBearing
            if abs(b) < 0.35 { return unit() < 0.8 ? nil : (unit() < 0.5 ? amp : -amp) }
            if unit() < c.targetSaccadeBias {
                let a = min(max(abs(b) * (0.8 + 0.2 * unit()), c.saccadeAmplitude.lowerBound), c.saccadeAmplitude.upperBound)
                return b > 0 ? a : -a
            }
        }
        if p.separationStrength > 0.05 { return sin(p.separationBearing) >= 0 ? amp : -amp }
        if p.flockStrength > 0, p.separationStrength < 0.05, abs(p.flockBearing) > 0.35, unit() < c.flockSaccadeBias * p.flockStrength {
            let b = p.flockBearing
            let a = min(max(abs(b) * (0.8 + 0.2 * unit()), c.saccadeAmplitude.lowerBound), c.saccadeAmplitude.upperBound)
            return b > 0 ? a : -a
        }
        let pLeft = 0.5 - c.headingMemoryBias * tanh(headingMemory / max(c.headingMemoryScale, 1e-6))
        return unit() < pLeft ? amp : -amp
    }

    /// Computes the drive for this frame from the percept (`dt` advances the saccade generator and
    /// heading noise).
    public func drive(for p: Percept, dt: Double = 1.0 / 60) -> SensoryDrive {
        let c = config
        var d = SensoryDrive()
        let dx = Double(p.pointer.x - p.flyPosition.x), dy = Double(p.pointer.y - p.flyPosition.y)
        let dist = max((dx * dx + dy * dy).squareRoot(), 1e-3)
        let ux = dx / dist, uy = dy / dist
        // Radial velocity of the pointer relative to the fly (negative = approaching).
        let radial = Double(p.pointerVelocity.dx) * ux + Double(p.pointerVelocity.dy) * uy
        let deff = max(dist * c.distanceScale, 1)
        let rr = c.objectRadius
        theta = 2 * atan(rr / deff)
        thetaDot = 2 * rr * (-radial * c.distanceScale) / (deff * deff + rr * rr)
        var b = atan2(dy, dx) - p.flyHeading
        b = atan2(sin(b), cos(b))
        bearing = b
        let sb = sin(b) * c.lateralSharpness
        let wL = Float(min(max(0.5 + 0.5 * sb, 0), 1)), wR = Float(min(max(0.5 - 0.5 * sb, 0), 1))

        let eta = thetaDot * exp(-c.etaAlpha * theta)
        let loom = c.loomMax * Float(tanh(c.etaGain * max(eta - c.etaThreshold, 0)))
        if loom.isFinite { d.loomL = loom * wL; d.loomR = loom * wR }

        if dist < c.mechanoRadius {
            let m = c.mechanoMax * Float(1 - dist / c.mechanoRadius)
            d.mechanoL = m * wL; d.mechanoR = m * wR
        }

        if p.airborne {
            let edge = max(min(p.distanceToLeftEdge, p.distanceToRightEdge, p.distanceToBottom), 0)
            let v = c.landingMax * Float(exp(-edge / max(c.landingScale, 1e-6)))
            d.landing = v.isFinite ? v : 0
            d.wing = c.flightWing
            d.steerL = c.flightSteer; d.steerR = c.flightSteer
            let t0 = max(c.edgeTau0, 1e-6)
            func loom(_ tau: Double) -> Float {
                guard tau.isFinite else { return 0 }  // +inf (not closing) or NaN
                return Float(exp(-max(tau, 0) / t0))
            }
            let eL = loom(p.edgeTimeToContactLeft), eR = loom(p.edgeTimeToContactRight)
            d.edgeLoomL = c.landingMax * eL; d.edgeLoomR = c.landingMax * eR
            if !p.edgeIsTargetLeft { d.steerR += c.edgeSteerMax * eL }
            if !p.edgeIsTargetRight { d.steerL += c.edgeSteerMax * eR }

            let h = max(dt, 0)
            if !wasAirborne {
                saccadeTimer = c.saccadeFirstDelay + drawInterval(); pulseLeft = 0; ou = 0
                headingMemory = 0; lastHeading = p.flyHeading
            }
            var dh = (p.flyHeading - lastHeading).truncatingRemainder(dividingBy: 2 * .pi)
            if dh > .pi { dh -= 2 * .pi } else if dh < -.pi { dh += 2 * .pi }
            lastHeading = p.flyHeading
            if dh.isFinite { headingMemory = headingMemory * exp(-h / max(c.headingMemoryTau, 1e-3)) + dh }
            // Heading noise (OU).
            let tn = max(c.headingNoiseTau, 1e-3)
            ou += -ou / tn * h + c.headingNoiseStd * (2 * h / tn).squareRoot() * gauss()
            d.headingNoise = Float(ou)
            // Fixation of the perch target + its looming landing cue.
            if p.targetDistance.isFinite {
                let b = p.targetBearing
                let f = Float(cos(b) >= 0 ? sin(b) : (sin(b) >= 0 ? 1 : -1)) * c.fixationGain
                d.fixation = f
                let tt = p.targetTimeToContact
                if tt.isFinite {
                    let v = c.landingMax * Float(exp(-max(tt, 0) / max(c.targetTau0, 1e-6)))
                    d.targetLanding = v; d.landing += v
                }
            }
            // v4 boids: flock pull and separation onto steer_dn, speed matching onto wing_mn.
            func lateral(_ b: Double) -> Float { Float(cos(b) >= 0 ? sin(b) : (sin(b) >= 0 ? 1 : -1)) }
            if p.flockStrength > 0 { d.flock = c.flockGain * Float(min(p.flockStrength, 1)) * lateral(p.flockBearing) }
            if p.separationStrength > 0 {
                // Neighbour (nearly) dead ahead: the away direction is behind and its side flips; keep the side.
                var side = lateral(p.separationBearing)
                if cos(p.separationBearing) < 0 && abs(sin(p.separationBearing)) < 0.4 && separationSide != 0 { side = separationSide }
                separationSide = side >= 0 ? 1 : -1
                d.separation = c.separationGain * Float(min(p.separationStrength, 1)) * side
            } else { separationSide = 0 }
            if p.flockSpeedRatio > 0 {
                let brake = c.separationThrustGain * Float(min(p.separationStrength, 1) * max(0, -cos(p.separationBearing)))
                let w = c.flockWingBase + c.flockThrustGain * Float(p.flockSpeedRatio - 1) - brake
                d.wing = min(max(w, c.flockWingMin), c.flightWing)
            }
            // Saccade generator.
            sinceSaccade += h
            let effL = p.edgeIsTargetLeft ? Double.infinity : p.edgeTimeToContactLeft
            let effR = p.edgeIsTargetRight ? Double.infinity : p.edgeTimeToContactRight
            // A saccade turning toward a too-close neighbour is cancelled (the separation saccade follows at once).
            if pulseLeft > 0 && p.separationStrength > c.separationSaccadeThreshold
                && pulseSigned * (separationSide != 0 ? separationSide : (sin(p.separationBearing) >= 0 ? 1 : -1)) < 0 {
                pulseLeft = 0; sinceSaccade = .infinity
            }
            if pulseLeft > 0 {
                pulseLeft -= h
            } else if min(effL, effR) < c.loomSaccadeTau && sinceSaccade > c.loomSaccadeRefractory {
                let lo = c.loomSaccadeAmplitude.lowerBound, hi = c.loomSaccadeAmplitude.upperBound
                let amp = lo + (hi - lo) * unit()
                // Turn toward the more open hemifield (longer gaze ray); τ decides when distances are unknown.
                let dL = p.edgeDistanceLeft, dR = p.edgeDistanceRight
                var a: Double
                if dL.isFinite && dR.isFinite && abs(dL - dR) > 1 {
                    a = dL < dR ? -amp : amp
                    let near = min(dL, dR), far = max(dL, dR)
                    if abs(headingMemory) > c.loomMemoryThreshold && far < c.loomTieRatio * max(near, 1) {
                        a = headingMemory > 0 ? -amp : amp
                    }
                } else {
                    a = effL < effR ? -amp : amp
                }
                startPulse(a)
                loomSaccadeCount += 1
                saccadeTimer = drawInterval()
            } else if p.separationStrength > c.separationSaccadeThreshold && sinceSaccade > c.separationSaccadeRefractory {
                // Separation saccade: away from a too-close neighbour (steering only, never loom).
                let lo = c.separationSaccadeAmplitude.lowerBound, hi = c.separationSaccadeAmplitude.upperBound
                let amp = lo + (hi - lo) * unit()
                startPulse((separationSide != 0 ? separationSide > 0 : sin(p.separationBearing) >= 0) ? amp : -amp)
                saccadeTimer = drawInterval() * (1 + c.flockSaccadeSlowdown * min(max(p.flockStrength, 0), 1))
            } else if p.flockStrength >= c.pursuitSaccadeStrength && abs(p.flockBearing) > c.pursuitSaccadeBearing
                        && p.separationStrength < 0.05
                        && sinceSaccade > c.pursuitSaccadeRefractory
                        && !(p.targetDistance.isFinite && p.targetTimeToContact < c.targetSaccadeSuppressTau) {
                // Pursuit (catch-up) saccade toward the flock, amplitude ≈ the flock bearing.
                let b = p.flockBearing
                let amp = min(max(0.8 * abs(b), c.saccadeAmplitude.lowerBound), c.saccadeAmplitude.upperBound)
                startPulse(b > 0 ? amp : -amp)
                saccadeTimer = drawInterval() * (1 + c.flockSaccadeSlowdown * min(p.flockStrength, 1))
            } else {
                // Flocking: a large flock bearing makes the next saccade come sooner (catch-up turns).
                let urge = p.flockStrength > 0 ? c.flockSaccadeUrgency * min(p.flockStrength, 1) * max(0, abs(p.flockBearing) - 0.35) : 0
                saccadeTimer -= h * (1 + urge)
                if saccadeTimer <= 0 {
                    saccadeTimer = drawInterval()
                    if p.flockStrength > 0 { saccadeTimer *= 1 + c.flockSaccadeSlowdown * min(p.flockStrength, 1) }
                    if let a = planSaccade(p) { startPulse(a) }
                }
            }
            if pulseLeft > 0 { d.saccade = pulseSigned }
            // v5: nearby window motion → loom-free turn away from it (+ voluntary takeoff, below).
            if p.windowMotionStartle > 0 {
                let away: Float = sin(p.windowMotionBearing) >= 0 ? -1 : 1
                d.startleTurn = away * c.startleSteer * Float(min(p.windowMotionStartle, 1))
            }
            let asym = d.saccade + d.headingNoise + d.fixation + d.flock + d.separation + d.startleTurn
            if asym > 0 { d.steerL += asym } else { d.steerR -= asym }
            d.steerL = max(d.steerL, 0); d.steerR = max(d.steerR, 0)
        } else {
            let idle = p.idleTime.isFinite ? max(p.idleTime, 0) : 0
            let frac = Float(min(max((idle - c.groomDelay) / max(c.groomRamp, 1e-6), 0), 1))
            d.groom = c.groomMax * frac
            d.walk = c.walkTonic * (1 - frac)
            if idle < lastIdle { boutLength = drawBout() }  // a new perched bout started
            let r = Float(min(max((idle - boutLength) / max(c.restRamp, 1e-6), 0), 1))
            d.restless = c.restDrive * r
            // v4 social takeoff (leader took off nearby): same voluntary-takeoff channel, never loom.
            if p.flockTakeoffDrive > 0 { d.restless = max(d.restless, c.restDrive * Float(min(p.flockTakeoffDrive, 1))) }
            // v5 substrate jolt (the window under the feet moved / closed): mechanosensory + voluntary takeoff.
            if p.substrateJolt > 0 {
                let j = Float(min(p.substrateJolt, 1))
                d.mechanoL += c.joltMechano * j; d.mechanoR += c.joltMechano * j
                d.startle += c.joltDrive * j
            }
        }
        // v5 nearby window motion: weaker voluntary-takeoff drive (perched or airborne).
        if p.windowMotionStartle > 0 { d.startle += c.startleDrive * Float(min(p.windowMotionStartle, 1)) }
        wasAirborne = p.airborne
        lastIdle = p.airborne ? .infinity : (p.idleTime.isFinite ? p.idleTime : 0)
        lastDrive = d
        return d
    }

    /// Writes a drive onto the network's input buffer (zeroing everything else first).
    public func apply(_ d: SensoryDrive, to net: RateNetwork) {
        net.input.withUnsafeMutableBufferPointer { inp in
            for i in 0..<inp.count { inp[i] = 0 }
            func add(_ idx: [Int32], _ v: Float) { if v != 0 { for i in idx { inp[Int(i)] += v } } }
            add(loomL, d.loomL); add(loomR, d.loomR); add(loomC, max(d.loomL, d.loomR))
            add(mechL, d.mechanoL); add(mechR, d.mechanoR); add(mechC, max(d.mechanoL, d.mechanoR))
            add(landing, d.landing); add(landingL, d.edgeLoomL); add(landingR, d.edgeLoomR)
            add(landingC, max(d.edgeLoomL, d.edgeLoomR)); add(groom, d.groom); add(walk, d.walk); add(wing, d.wing)
            add(voluntaryTakeoff, d.restless + d.startle)
            add(steerL, d.steerL); add(steerR, d.steerR); add(steerC, max(d.steerL, d.steerR))
        }
    }
}
