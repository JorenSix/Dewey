import CoreGraphics
import FlyCore

/// Hand-written stand-in for the connectome brain. Deterministic for a given seed.
///
/// - takeoff/escape when the pointer is within ~120 pt and approaching, or approaches fast (>800 pt/s) within 300 pt
/// - in flight: steers toward the perch target in the percept (v3, picked by FlyController after a flight
///   bout) and emits a land drive when close; without a target, wanders with a mild edge attraction
/// - wanders (random yaw rate) in flight; with neighbours (v4) follows the boids percept fields
/// - while perched: bouts of idling, walking and grooming, then a spontaneous takeoff after a while
/// - v5: takes off at once on a substrate jolt (perched window moved / closed) or a close window-motion startle
public final class ScriptedBrain: Brain, RestlessnessTunable {
    private var rng: SeededRandom

    // Flight
    private var flightTime = 0.0
    private var landAfter = 0.0
    private var wanderYaw = 0.0
    private var wanderTimer = 0.0

    // Perch
    private var perchTime = 0.0
    private var perchStay = 0.0
    private var bout: Bout = .idle
    private var boutTimer = 0.0
    private var walkDir = 1.0

    // Threat
    private var threatHold = 0.0

    private var lastCommand = MotorCommand.idle

    private enum Bout { case idle, walk, groom }

    /// Distance and approach-speed thresholds (exposed for tuning/tests).
    public var threatRadius = 120.0
    public var fastApproachRadius = 300.0
    public var fastApproachSpeed = 800.0
    /// Perched-bout length range (s) before a spontaneous takeoff (restlessness setting).
    public private(set) var perchStayRange: ClosedRange<Double> = 6...20

    public func setRestBout(_ range: ClosedRange<Double>) {
        let lo = max(0, range.lowerBound)
        perchStayRange = lo...max(lo, range.upperBound)
        perchStay = rng.uniform(perchStayRange.lowerBound, perchStayRange.upperBound)
    }

    public init(seed: UInt64 = 1) {
        rng = SeededRandom(seed: seed)
        landAfter = rng.uniform(4, 14)
        perchStay = rng.uniform(perchStayRange.lowerBound, perchStayRange.upperBound)
    }

    public var activity: [String: Float] {
        ["takeoff": Float(lastCommand.takeoff), "land": Float(lastCommand.land),
         "groom": Float(lastCommand.groom), "walk": Float(lastCommand.walkSpeed),
         "yaw": Float(lastCommand.yawRate), "freeze": Float(lastCommand.freeze)]
    }

    public func step(_ p: Percept, dt: Double) -> MotorCommand {
        var cmd = MotorCommand()

        // --- Threat detection -------------------------------------------------------------
        let dx = Double(p.pointer.x - p.flyPosition.x), dy = Double(p.pointer.y - p.flyPosition.y)
        let dist = max(1, hypot(dx, dy))
        let vx = Double(p.pointerVelocity.dx), vy = Double(p.pointerVelocity.dy)
        let approach = -(vx * dx + vy * dy) / dist // > 0 when the pointer moves toward the fly
        let threat = (dist < threatRadius && approach > 40)
            || (dist < fastApproachRadius && approach > fastApproachSpeed)
            || dist < 35
        if threat { threatHold = 0.35 } else { threatHold = max(0, threatHold - dt) }

        if threatHold > 0 {
            cmd.takeoff = 1
            cmd.thrust = 1
            // Turn away from the pointer.
            let away = atan2(-dy, -dx)
            cmd.yawRate = max(-12, min(12, 8 * angleDiff(away, p.flyHeading)))
            perchTime = 0; flightTime = 0
            landAfter = rng.uniform(5, 15)
            perchStay = rng.uniform(perchStayRange.lowerBound, perchStayRange.upperBound)
            lastCommand = cmd
            return cmd
        }

        if p.airborne {
            perchTime = 0
            flightTime += dt
            // Wander.
            wanderTimer -= dt
            if wanderTimer <= 0 {
                wanderTimer = rng.uniform(0.4, 1.6)
                wanderYaw = rng.uniform(-2.8, 2.8)
            }
            cmd.yawRate = wanderYaw
            cmd.thrust = 0.4 + 0.3 * sin(flightTime * 0.7)
            // v4 boids (percept is zero when alone): flock pull, stronger separation, speed matching.
            if p.flockStrength > 0 || p.separationStrength > 0 {
                cmd.yawRate = 0.3 * wanderYaw + 2 * p.flockStrength * sin(p.flockBearing)
                    + 5 * p.separationStrength * sin(p.separationBearing)
            }
            if p.flockSpeedRatio > 0 { cmd.thrust = min(1, max(0, 0.5 + 0.8 * (p.flockSpeedRatio - 1))) }

            if p.targetDistance.isFinite {
                // Perch target from FlyBehavior: fixate it and land when close.
                cmd.yawRate += 3 * p.targetBearing
                cmd.thrust = 0.3
                if p.targetDistance < 260 { cmd.land = 1 }
                lastCommand = cmd
                return cmd
            }
            let dl = p.distanceToLeftEdge, dr = p.distanceToRightEdge, db = p.distanceToBottom
            let nearest = min(dl, dr, db)
            // Mild attraction toward the edges/Dock all the time, strong once ready to land.
            let target: Double
            if nearest == dl { target = .pi } else if nearest == dr { target = 0 } else { target = -.pi / 2 }
            // v3: landing is driven by the controller's perch target (above); without one, only a mild
            // attraction toward the nearest edge.
            let ready = false
            let gain = ready ? 3.0 : 0.25
            cmd.yawRate += gain * angleDiff(target, p.flyHeading)
            if ready {
                cmd.thrust = 0.3
                if nearest < 260 { cmd.land = 1 }
            }
        } else {
            flightTime = 0
            perchTime += dt
            boutTimer -= dt
            if boutTimer <= 0 {
                let r = rng.uniform(0, 1)
                bout = r < 0.4 ? .idle : (r < 0.7 ? .walk : .groom)
                boutTimer = bout == .walk ? rng.uniform(0.8, 2.5) : rng.uniform(1.5, 4)
                if rng.chance(0.5) { walkDir = -walkDir }
            }
            switch bout {
            case .idle: break
            case .walk:
                cmd.walkSpeed = 0.6
                cmd.backward = walkDir < 0 ? 1 : 0
            case .groom:
                cmd.groom = 1
            }
            // v5: the window underfoot moved / closed (substrate jolt) or one moved close by → takeoff.
            if p.substrateJolt > 0.2 || p.windowMotionStartle > 0.5 { perchTime = perchStay + 1 }
            if perchTime > perchStay {
                cmd.takeoff = 1
                cmd.thrust = 0.6
                perchTime = 0
                perchStay = rng.uniform(perchStayRange.lowerBound, perchStayRange.upperBound)
                landAfter = rng.uniform(4, 14)
            }
        }
        lastCommand = cmd
        return cmd
    }
}
