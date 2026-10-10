import CoreGraphics
import FlyCore

/// Boids parameters (v4 friends). Distances in points, angles in radians.
public struct BoidsConfig: Sendable {
    /// Only airborne neighbours closer than this are seen.
    public var visualRadius = 400.0
    /// Half-angle of the forward-biased field of view (150° = 300° FOV, a 60° blind sector behind).
    public var fovHalfAngle = 150.0 * Double.pi / 180
    /// Separation zone = this many own body lengths (inverse-distance repulsion inside it).
    public var separationBodyLengths = 2.5
    /// Predictive separation: a neighbour whose straight-line closest approach within this horizon (s)
    /// falls inside the separation zone also repels (away from the closest-approach point).
    public var separationHorizon = 0.6
    /// Leader (Dewey) weight in cohesion and alignment.
    public var leaderWeight = 2.5
    /// Weights of the alignment (mean unit heading) and cohesion (unit vector to the centroid) terms.
    public var alignmentWeight = 0.8
    public var cohesionWeight = 1.0
    /// Cohesion is 0 within `cohesionDeadZone` of the weighted centroid and saturates at `cohesionSaturation`.
    public var cohesionDeadZone = 130.0
    public var cohesionSaturation = 350.0
    /// Speed matching: desired speed = weighted neighbour mean speed · (1 + catchUpGain · forward cohesion).
    public var catchUpGain = 1.0
    /// The leader follows the flock only this much (strengths and speed deviation scaled).
    public var leaderResponse = 1.0
    /// Short visual memory (s): a neighbour that leaves the field of view or the visual radius keeps pulling
    /// (cohesion / alignment only, dead-reckoned, weight fading to 0) for this long.
    public var memoryDuration = 3.0
    public init() {}
}

/// What the boids rules produce for one fly, all relative to its own heading (positive = left).
public struct BoidsOutput: Sendable, Equatable {
    public var flockBearing = 0.0
    public var flockStrength = 0.0
    public var separationBearing = 0.0
    public var separationStrength = 0.0
    /// Desired ÷ own speed (1 = matched, 0 = no neighbours seen).
    public var speedRatio = 0.0
    /// Number of neighbours seen.
    public var seen = 0
    public init() {}
}

/// Pure boids computation (separation, alignment, cohesion) for one fly from its neighbours.
public enum Boids {
    /// Whether `me` sees `n` now: airborne, within the visual radius and the field of view.
    public static func sees(_ me: FlockNeighbor, _ n: FlockNeighbor, config c: BoidsConfig = BoidsConfig()) -> Bool {
        guard n.id != me.id, n.airborne else { return false }
        let dx = Double(n.position.x - me.position.x), dy = Double(n.position.y - me.position.y)
        let d = hypot(dx, dy)
        return d < c.visualRadius && d > 1e-6 && abs(angleDiff(atan2(dy, dx), me.heading)) <= c.fovHalfAngle
    }

    /// `remembered`: neighbours recently seen but not visible now, as (dead-reckoned state, weight 0...1);
    /// they count in cohesion, alignment and speed matching only.
    public static func compute(self me: FlockNeighbor, neighbors: [FlockNeighbor],
                               remembered: [(FlockNeighbor, Double)] = [],
                               config c: BoidsConfig = BoidsConfig()) -> BoidsOutput {
        var out = BoidsOutput()
        guard me.airborne else { return out }
        let px = Double(me.position.x), py = Double(me.position.y)
        let vx = Double(me.velocity.dx), vy = Double(me.velocity.dy)
        let ownSpeed = hypot(vx, vy)
        let sepR = c.separationBodyLengths * me.size
        var wSum = 0.0, ax = 0.0, ay = 0.0, cx = 0.0, cy = 0.0, sSum = 0.0
        var sepX = 0.0, sepY = 0.0
        for (n, fade) in remembered where n.id != me.id && fade > 0 {
            let w = (n.isLeader ? c.leaderWeight : 1) * min(fade, 1)
            wSum += w
            ax += w * cos(n.heading); ay += w * sin(n.heading)
            cx += w * Double(n.position.x); cy += w * Double(n.position.y)
            sSum += w * hypot(Double(n.velocity.dx), Double(n.velocity.dy))
        }
        for n in neighbors where sees(me, n, config: c) {
            let dx = Double(n.position.x) - px, dy = Double(n.position.y) - py
            let d = hypot(dx, dy)
            out.seen += 1
            let w = n.isLeader ? c.leaderWeight : 1
            wSum += w
            let nvx = Double(n.velocity.dx), nvy = Double(n.velocity.dy)
            let ns = hypot(nvx, nvy)
            ax += w * cos(n.heading); ay += w * sin(n.heading)
            cx += w * Double(n.position.x); cy += w * Double(n.position.y)
            sSum += w * ns
            // Separation, proximity: inverse-distance repulsion inside the zone (1 at half the zone).
            if d < sepR {
                let k = min(3, sepR / d - 1)
                sepX -= k * dx / d; sepY -= k * dy / d
            }
            // Separation, predictive: closest approach of the relative straight-line motion.
            let rvx = nvx - vx, rvy = nvy - vy
            let rv2 = rvx * rvx + rvy * rvy
            if rv2 > 1e-6 {
                let t = -(dx * rvx + dy * rvy) / rv2
                if t > 0 && t < c.separationHorizon {
                    let mx = dx + rvx * t, my = dy + rvy * t
                    let m = hypot(mx, my)
                    if m < sepR {
                        let k = 2 * (1 - m / sepR) * (1 - t / c.separationHorizon).squareRoot()
                        var ux: Double, uy: Double
                        if m > 1e-3 { ux = -mx / m; uy = -my / m } else {
                            // Dead-on: sidestep perpendicular to the relative velocity (to the left).
                            let r = rv2.squareRoot(); ux = -rvy / r; uy = rvx / r
                        }
                        sepX += k * ux; sepY += k * uy
                    }
                }
            }
        }
        guard wSum > 0 else { return out }
        let lead = me.isLeader ? c.leaderResponse : 1
        // Alignment: weighted mean unit heading; cohesion: toward the weighted centroid.
        ax /= wSum; ay /= wSum
        let ox = cx / wSum - px, oy = cy / wSum - py
        let od = hypot(ox, oy)
        let cs = min(1, max(0, (od - c.cohesionDeadZone) / max(c.cohesionSaturation - c.cohesionDeadZone, 1)))
        var fx = c.alignmentWeight * ax, fy = c.alignmentWeight * ay
        if od > 1e-6 { fx += c.cohesionWeight * cs * ox / od; fy += c.cohesionWeight * cs * oy / od }
        let fm = hypot(fx, fy)
        if fm > 1e-9 {
            out.flockBearing = angleDiff(atan2(fy, fx), me.heading)
            out.flockStrength = min(1, fm) * lead
        }
        let sm = hypot(sepX, sepY)
        if sm > 1e-9 {
            out.separationBearing = angleDiff(atan2(sepY, sepX), me.heading)
            out.separationStrength = min(1, sm)
        }
        // Speed matching with catch-up: the centroid ahead (beyond the dead zone) raises the desired speed.
        let fwd = od > 1e-6 ? cs * (ox * cos(me.heading) + oy * sin(me.heading)) / od : 0
        let desired = sSum / wSum * (1 + c.catchUpGain * fwd)
        var ratio = desired / max(ownSpeed, 50)
        ratio = 1 + (ratio - 1) * lead
        out.speedRatio = min(2.5, max(0.2, ratio))
        return out
    }
}

/// Test / utility harness: steps N `FlyController`s (each with its own brain) together on one World,
/// building every fly's neighbour list from the others' state at the start of the frame.
public final class FlockSimulation {
    public var world: World {
        didSet { for c in flies { c.world = world } }
    }
    public private(set) var flies: [FlyController]
    public private(set) var time = 0.0

    /// `flies[0]` is conventionally the leader; ids and leadership are taken from the controllers.
    public init(world: World, flies: [FlyController]) {
        self.world = world
        self.flies = flies
    }

    /// Builds a flock: fly 0 is the leader (Dewey, `leaderSize`), the others get `sizes` (default
    /// 0.85–0.90 × leaderSize). Airborne starts are spread on a ring of `spawnRadius` around the screen centre.
    public static func make(world: World, count: Int, leaderSize: Double = 40, sizes: [Double]? = nil,
                            seed: UInt64 = 1, startState: FlyState = .flying, spawnRadius: Double = 160,
                            brain: (Int, UInt64) -> Brain) -> FlockSimulation {
        var rng = SeededRandom(seed: seed &* 7919 &+ 17)
        var flies: [FlyController] = []
        let centre = CGPoint(x: world.screenFrame.midX, y: world.screenFrame.midY)
        for i in 0..<count {
            let s = seed &* 1000 &+ UInt64(i)
            let c = FlyController(world: world, brain: brain(i, s), seed: s, startState: startState)
            c.flockID = i
            c.isLeader = i == 0
            if i == 0 { c.bodySize = leaderSize } else {
                c.bodySize = sizes.map { $0[(i - 1) % max($0.count, 1)] }
                    ?? leaderSize * rng.uniform(DeweySettings.friendSizeFactor.lowerBound, DeweySettings.friendSizeFactor.upperBound)
            }
            if c.isAirborne && i > 0 {
                let a = 2 * Double.pi * Double(i) / Double(max(count - 1, 1))
                c.place(at: CGPoint(x: Double(centre.x) + spawnRadius * cos(a), y: Double(centre.y) + spawnRadius * sin(a)),
                        heading: flies[0].heading)
            }
            flies.append(c)
        }
        return FlockSimulation(world: world, flies: flies)
    }

    /// Each fly's view of the others (state at the start of the frame).
    public func neighborLists() -> [[FlockNeighbor]] {
        let selves = flies.map(\.flockSelf)
        return flies.indices.map { i in selves.enumerated().filter { $0.offset != i }.map(\.element) }
    }

    /// Advances every fly by `dt` with the same pointer.
    @discardableResult
    public func step(pointer: CGPoint, dt: Double) -> [FlyFrame] {
        let lists = neighborLists()
        for (c, n) in zip(flies, lists) { c.neighbors = n }
        time += dt
        return flies.map { $0.update(pointer: pointer, dt: dt) }
    }

    public func setFlocking(_ on: Bool) { for c in flies { c.flockingEnabled = on } }

    /// |mean unit heading| over the given flies (0 when fewer than 2).
    public static func orderParameter(_ flies: [FlyController]) -> Double {
        guard flies.count >= 2 else { return 0 }
        let x = flies.map { cos($0.heading) }.reduce(0, +), y = flies.map { sin($0.heading) }.reduce(0, +)
        return hypot(x, y) / Double(flies.count)
    }
}
