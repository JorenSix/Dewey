import CoreGraphics
import FlyCore

/// Runs the fly: builds a `Percept`, asks the `Brain` for a `MotorCommand`, and turns that into
/// a state machine plus kinematics. Call `update(pointer:dt:)` once per display frame.
public final class FlyController {
    public var world: World {
        didSet { worldChanged(old: oldValue) }
    }
    public let brain: Brain

    public private(set) var position: CGPoint
    public private(set) var heading: Double
    public private(set) var speed: Double = 0
    public private(set) var state: FlyState
    public private(set) var perch: Perch?
    /// The perch site (multi-screen edge segment) the fly sits on, if any.
    public private(set) var perchSite: PerchSite?
    /// Roll about the body's long axis in radians (= `FlyFrame.roll`): perched, ±pi/2 = side view with
    /// the feet toward the perch edge; airborne, banking into turns (−k·yawRate·speed, clamped ±0.6).
    /// Positive = right side down. Smoothed.
    public private(set) var bodyRoll: Double = 0
    /// Body pitch (= `FlyFrame.pitch`), positive = nose up: takeoff/climb, pre-landing flare. Smoothed.
    public private(set) var bodyPitch: Double = 0
    /// Number of frames in which the fly's position had to be clamped to the flight bounds
    /// (should stay 0: the look-ahead turns or slows the fly before it reaches a border).
    public private(set) var borderClamps = 0
    /// Speed (pt/s) at the last touchdown.
    public private(set) var lastContactSpeed: Double = 0
    public private(set) var lastCommand = MotorCommand.idle
    public private(set) var pointerVelocity = CGVector.zero
    public private(set) var idleTime = 0.0
    public private(set) var pose = BodyPose.rest
    public private(set) var altitudeScale = 1.0
    /// Number of completed landings (for tests and debugging).
    public private(set) var landings = 0
    /// Landings on the picked perch target's site (subset of `landings`).
    public private(set) var targetLandings = 0
    /// Number of body saccades executed (for tests and debugging).
    public private(set) var saccades = 0
    public private(set) var inSaccade = false

    /// A perch site picked after a flight bout, and the point on it the fly heads for.
    public struct PerchTarget: Sendable, Equatable {
        public var site: PerchSite
        public var point: CGPoint
    }
    public private(set) var target: PerchTarget?

    // v4 friends (boids)
    /// The other flies as this fly sees them; set every frame by the flock coordinator before `update`.
    public var neighbors: [FlockNeighbor] = []
    /// Dewey: friends weight the leader `boids.leaderWeight`× and bias their perch choice toward it.
    public var isLeader = false
    public var flockID = 0
    /// Body length on screen (pt): separation zone and perch spacing scale with it.
    public var bodySize = 40.0
    /// false = ignore neighbours for steering/thrust and perch choice (perch spacing still applies).
    public var flockingEnabled = true
    public var boids = BoidsConfig()
    /// Friends pick perch points within this distance (pt) of the leader's perch / perch target point…
    public var leaderPerchRadius = 300.0
    /// …with this probability per perch-target choice.
    public var leaderPerchBias = 0.9
    /// Perch points keep at least this many body lengths (max of the two flies) from other flies' perch points.
    public var perchSpacingBodyLengths = 2.5
    /// Friends whose leader settles (perched, landing or with a perch target) pick their own perch target within
    /// this delay (s) (unless already seeking); while following a flying, unsettled leader they do not seek a perch.
    public var leaderPerchedLandDelay: ClosedRange<Double> = 1.5...6
    /// Last boids result written into the percept (zero when perched, alone or flocking is off).
    public private(set) var lastBoids = BoidsOutput()
    /// Number of escape manoeuvres started (escape takeoffs and in-flight escapes).
    public private(set) var escapes = 0
    /// Whether the current perch target was picked near the leader.
    public private(set) var targetIsSocial = false
    private var leaderWasPerched = false
    /// Neighbours seen recently but not visible now: last state and age (s), see `BoidsConfig.memoryDuration`.
    private var neighborMemory: [Int: (n: FlockNeighbor, age: Double)] = [:]
    private var lastSeen: [Int: FlockNeighbor] = [:]
    /// Social takeoff: a perched friend follows its leader's takeoff (within `socialTakeoffRadius` pt)
    /// after a reaction delay drawn from `socialTakeoffDelay` (s), via `Percept.flockTakeoffDrive`.
    public var socialTakeoffRadius = 700.0
    public var socialTakeoffDelay: ClosedRange<Double> = 0.15...0.9
    private var leaderWasAirborne = false
    /// Kinematic separation backstop (like the border look-ahead safety, not brain-routed; flocking only):
    /// another airborne fly within `safeguardBodyLengths` (larger body) and closing → brake, yaw away at up to
    /// `safeguardYawRate` rad/s, and never closer than `safeguardMinBodyLengths` to its predicted position.
    public var safeguardBodyLengths = 1.2
    public var safeguardMinBodyLengths = 1.0
    public var safeguardYawRate = 8.0
    /// Number of safeguard engagements (episodes).
    public private(set) var separationSafeguards = 0
    private var safeguardActive = false
    /// A landing approach aborts when the boids separation strength exceeds this (another fly in the way).
    public var landingAbortSeparation = 0.5
    private var socialTakeoffTimer = -1.0
    private var socialTakeoffHold = 0.0

    // v5 window perches and startle
    /// Substrate jolt (0...1) fed to the brain while perched (`Percept.substrateJolt`): set to 1 when the
    /// window the fly stands on moves / resizes / closes, decays linearly over `startleDecay` s; held at 1 while
    /// the fly still stands on a window that no longer exists.
    public private(set) var substrateJolt = 0.0
    /// Visual window-motion startle (0...1, `Percept.windowMotionStartle`): 1 − d/`startleRadius` for a window
    /// that moved or closed within `startleRadius` pt of the fly (edges, old or new frame); decays like the jolt.
    public private(set) var windowMotionStartle = 0.0
    public var startleDecay = 0.3
    public var startleRadius = 150.0
    /// A perch target / landing on a window that moved or closed is dropped and a new one picked after this delay (s).
    public var windowRetargetDelay: ClosedRange<Double> = 0.4...1.2
    /// Window approach: waypoints sit this far (pt) outside the window corners, so the final approach to a
    /// window edge comes from its open side, never through the window.
    public var windowApproachMargin = 60.0
    /// Window sites weigh this many times more than screen edges in the random perch-target choice
    /// (weight ∝ length / (1 + d/1500), as `World.randomPerchSite`), so the fly visibly uses windows.
    public var windowSiteWeight = 2.5
    /// Landing approaches aborted (back to flight), for tests: all sites / window sites.
    public private(set) var landingAborts = 0
    public private(set) var windowLandingAborts = 0
    /// Called on every touchdown with the site landed on (the app logs it, see `landingDescription`).
    public var onLanded: ((PerchSite) -> Void)?
    /// A landing on a window site starts only from at least this far (pt) outside the window.
    public var windowLandingClearance = 20.0
    /// Landings on window sites (subset of `landings`).
    public private(set) var windowLandings = 0
    /// Total displacement (pt) applied by riding a moving window while perched (kinematic attachment).
    public private(set) var windowCarry = CGVector.zero
    /// Frame of the window the fly is perched on, as last seen (to follow its moves).
    private var perchWindowFrame: CGRect?
    /// Frames windows had before the latest World update(s), consumed by `windowsChanged`.
    private var previousWindowFrames: [Int: CGRect] = [:]
    /// Nearest point of the window whose motion startled the fly (escape / steering away from it).
    private var startleSource: CGPoint?

    // Tunables
    public var cruiseSpeedRange: ClosedRange<Double> = 300...700
    public var escapeSpeed = 950.0
    public var walkSpeedMax = 45.0
    public var maxTurnRate = 5.0          // rad/s while cruising
    public var flyingAltitudeScale = 1.3
    /// Wing-beat phase rate in cycles per second. At 60 fps 27 Hz advances ~0.45 cycle per frame,
    /// which aliases into a fast flicker (buzzy look) rather than a smooth slow flap.
    public var wingBeatHz = 27.0
    public var gaitHz = 8.0
    public var groomHz = 3.0

    // Border anticipation (look-ahead)
    /// Gaze-ray half-angle (rad) of the left/right hemifield border sensing.
    public var edgeRayAngle = Double.pi / 6
    /// Avoidance turn starts when the border time-to-contact drops below this (s) and the land drive is low.
    public var avoidTau = 0.9
    /// Full-strength avoidance at/below this time-to-contact (s).
    public var avoidTauHard = 0.35
    /// Peak avoidance yaw rate (rad/s).
    public var avoidYawMax = 9.0
    /// Keep the body centre this far (pt) from the visual borders when braking.
    public var borderMargin = 24.0
    /// Safety look-ahead also turns away when the room (beyond borderMargin) to a border being closed on
    /// drops below this (pt), whatever τ (full strength at 10 pt).
    public var proximityRoom = 40.0
    /// Banking: roll = −bankGain·yawRate·speed, clamped to ±maxBank.
    public var bankGain = 0.0004
    public var maxBank = 0.6
    public var takeoffPitch = 0.45
    public var flarePitch = 0.4

    // v3 natural flight / perch seeking
    /// Flight-bout length range (s) before a perch target is picked (`DeweySettings.flightBout`). Before
    /// the bout is over the fly does not land (except escape ends nothing); afterwards it lands on its
    /// target or, opportunistically, on any site within the landing gate.
    public var flightBoutRange: ClosedRange<Double> = 9...28
    /// Give up a target not reached within this time (s) and pick again.
    public var targetTimeout = 25.0
    /// Landing gate: land (when the brain's land drive is high) on a perch site reachable within this
    /// time at the current speed: distance < max(landGateMin, speed · landGateTau).
    public var landGateTau = 1.0
    public var landGateMin = 160.0
    /// Gaze rays ending within this distance (pt) of the target site count as seeing the target border.
    public var targetRayTolerance = 40.0
    /// Below this time-to-contact (s) even the target border triggers the safety avoidance.
    public var targetSafetyTau = 0.25
    /// Saccade kinematics: a decoded yaw above `saccadeOnsetYaw` (rad/s) starts a body saccade, during
    /// which the heading turns at saccadeGain × decoded yaw (no smoothing, ≤ saccadeMaxRate) until the
    /// yaw falls below `saccadeOffsetYaw` (or saccadeMaxDuration). The trigger and size come from the brain.
    public var saccadeOnsetYaw = 1.0
    public var saccadeOffsetYaw = 0.5
    public var saccadeGain = 3.8
    public var saccadeMaxRate = 30.0
    public var saccadeMaxDuration = 0.3
    public var saccadeRefractory = 0.15
    /// Only a fast rise counts: the decoded yaw must have been below `saccadeOffsetYaw` within this time (s).
    public var saccadeRiseTime = 0.12
    /// A saccade ends once it has turned this far (rad).
    public var saccadeMaxAmplitude = 2.4

    private var rng: SeededRandom
    private var stateTime = 0.0
    private var lastPointer: CGPoint?
    private var landingTarget: CGPoint?
    private var landingSite: PerchSite?
    private var flightTime = 0.0
    private var flightBout = 15.0
    private var targetTime = 0.0
    private var saccadeTime = 0.0
    private var saccadeCooldown = 0.0
    private var sinceLowYaw = 0.0
    private var saccadeTurn = 0.0
    private var takeoffDir = CGVector(dx: 0, dy: 1)
    private var escapeFrom = CGPoint.zero
    private var yawSmoothed = 0.0
    private var landCooldown = 0.0
    private var avoidDir = 0.0
    /// Landing approach: target speed = clamp(d·landingDecel, landingMinSpeed, …).
    public var landingDecel = 2.0
    public var landingMinSpeed = 35.0

    public init(world: World, brain: Brain, seed: UInt64 = 1, startState: FlyState = .perched) {
        self.world = world
        self.brain = brain
        self.rng = SeededRandom(seed: seed)
        let start = FlyController.startSite(world)
        if let site = start, startState == .perched || startState == .walking || startState == .grooming {
            let p = world.perchPoint(on: site, near: CGPoint(x: world.screenFrame.midX, y: world.screenFrame.midY))
            position = p
            heading = world.alignedHeading(site.side, closestTo: 0)
            state = .perched
            perch = site.side
            perchSite = site
            bodyRoll = FlyController.targetRoll(perch: site.side, heading: heading, world: world)
        } else {
            position = world.clampToFlightRegion(CGPoint(x: world.screenFrame.midX, y: world.screenFrame.midY))
            heading = rng.uniform(-.pi, .pi)
            speed = cruiseSpeedRange.lowerBound
            state = .flying
            perch = nil
            altitudeScale = flyingAltitudeScale
        }
        flightBout = rng.uniform(flightBoutRange.lowerBound, flightBoutRange.upperBound)
    }

    /// The bottom site of the primary screen nearest its centre, else any site.
    private static func startSite(_ world: World) -> PerchSite? {
        let c = CGPoint(x: world.screenFrame.midX, y: world.screenFrame.minY)
        let bottoms = world.perchSites.filter { $0.side == .bottom && $0.screenID == world.screens[0].id && $0.windowID == nil }
        func d(_ s: PerchSite) -> CGFloat { let q = world.perchPoint(on: s, near: c); return hypot(q.x - c.x, q.y - c.y) }
        return bottoms.min { d($0) < d($1) } ?? world.perchSites.first
    }

    public var isPerched: Bool { state == .perched || state == .walking || state == .grooming }
    public var isAirborne: Bool { !isPerched }

    /// Velocity (pt/s) along the heading.
    public var velocity: CGVector { CGVector(dx: cos(heading) * speed, dy: sin(heading) * speed) }

    /// Where this fly sits (perched), is about to land, or is heading to perch (target), if anywhere.
    public var perchPoint: CGPoint? {
        if isPerched { return position }
        if state == .landing, let l = landingTarget { return l }
        return target?.point
    }

    /// This fly as its neighbours see it (for building their `neighbors`).
    public var flockSelf: FlockNeighbor {
        FlockNeighbor(id: flockID, position: position, velocity: velocity, heading: heading, airborne: isAirborne,
                      isLeader: isLeader, size: bodySize, perchPoint: perchPoint)
    }

    /// Moves an airborne fly (e.g. a friend spawned near Dewey); ignored while perched.
    public func place(at p: CGPoint, heading h: Double? = nil) {
        guard isAirborne else { return }
        position = world.clampToFlightRegion(p)
        if let h { heading = angleDiff(h, 0) }
    }

    /// Puts the fly perched on `site` at the point nearest `p` (tests, staged snapshots); clears any flight state.
    public func forcePerch(on site: PerchSite, near p: CGPoint) {
        position = world.perchPoint(on: site, near: p)
        heading = world.alignedHeading(site.side, closestTo: heading)
        perch = site.side
        perchSite = site
        perchWindowFrame = site.windowID.flatMap { id in world.windows.first { $0.id == id }?.frame }
        target = nil; landingTarget = nil; landingSite = nil
        speed = 0; altitudeScale = 1; idleTime = 0
        substrateJolt = 0; windowMotionStartle = 0
        bodyRoll = FlyController.targetRoll(perch: site.side, heading: heading, world: world)
        set(.perched)
    }

    public var frame: FlyFrame {
        FlyFrame(position: position, heading: heading, altitudeScale: altitudeScale,
                 state: state, perch: perch, pose: pose, roll: bodyRoll, pitch: bodyPitch)
    }

    /// Distance (pt) to the nearest perch site of each side (+infinity when there is none).
    private func perchDistances() -> (left: Double, right: Double, bottom: Double) {
        var l = Double.infinity, r = Double.infinity, b = Double.infinity
        for s in world.perchSites {
            let q = world.perchPoint(on: s, near: position)
            let d = Double(hypot(q.x - position.x, q.y - position.y))
            switch s.side {
            case .left: l = min(l, d)
            case .right: r = min(r, d)
            case .bottom: b = min(b, d)
            }
        }
        return (l, r, b)
    }

    public func makePercept(pointer: CGPoint) -> Percept {
        let pd = perchDistances()
        var p = Percept(flyPosition: position, flyHeading: heading, airborne: isAirborne,
                        pointer: pointer, pointerVelocity: pointerVelocity,
                        distanceToLeftEdge: pd.left, distanceToRightEdge: pd.right, distanceToBottom: pd.bottom,
                        idleTime: idleTime, screenSize: world.nearestScreen(to: position).frame.size)
        let e = edgeSense()
        p.edgeTimeToContactLeft = e.tauL
        p.edgeTimeToContactRight = e.tauR
        p.edgeClosingSpeed = e.closing
        p.edgeDistanceLeft = e.distL
        p.edgeDistanceRight = e.distR
        if let t = target, state == .flying {
            let aim = targetAim(t)
            let dx = Double(aim.point.x - position.x), dy = Double(aim.point.y - position.y)
            let d = hypot(dx, dy)
            let b = angleDiff(atan2(dy, dx), heading)
            p.targetBearing = b
            if aim.visible {
                p.targetDistance = d
                let closing = speed * cos(b)
                p.targetTimeToContact = closing > 1e-6 ? d / closing : .infinity
                p.edgeIsTargetLeft = e.targetL
                p.edgeIsTargetRight = e.targetR
            } else {
                // Behind a border (another screen): fixate the waypoint; no landing looming yet.
                p.targetDistance = d + Double(hypot(t.point.x - aim.point.x, t.point.y - aim.point.y))
            }
        }
        // v4 boids: airborne only, zero when perched / alone / flocking off.
        lastBoids = BoidsOutput()
        if flockingEnabled && isAirborne && !neighbors.isEmpty {
            let mem = neighborMemory.values.map { m -> (FlockNeighbor, Double) in
                var n = m.n
                n.position = CGPoint(x: Double(n.position.x) + Double(n.velocity.dx) * m.age,
                                     y: Double(n.position.y) + Double(n.velocity.dy) * m.age)
                return (n, 1 - m.age / max(boids.memoryDuration, 1e-6))
            }
            lastBoids = Boids.compute(self: flockSelf, neighbors: neighbors, remembered: mem, config: boids)
            p.flockBearing = lastBoids.flockBearing
            p.flockStrength = lastBoids.flockStrength
            p.separationBearing = lastBoids.separationBearing
            p.separationStrength = lastBoids.separationStrength
            p.flockSpeedRatio = lastBoids.speedRatio
        }
        return p
    }

    /// Border looming as the fly sees it (airborne only; see `Percept.edgeTimeToContactLeft`).
    public struct EdgeSense: Sendable {
        /// Time-to-contact (s) along the left (+edgeRayAngle) / right (−edgeRayAngle) gaze ray and straight ahead.
        public var tauL = Double.infinity, tauR = Double.infinity, tauAhead = Double.infinity
        /// Closing speed (pt/s) on the border hit straight ahead (0 when receding / parallel).
        public var closing = 0.0
        /// Distance (pt) along the left / right gaze ray to the border (whether closing or not).
        public var distL = Double.infinity, distR = Double.infinity
        /// Whether the left / right / ahead gaze ray ends on the current perch target's site.
        public var targetL = false, targetR = false, targetAhead = false
        public var minTau: Double { min(tauL, tauR, tauAhead) }
        /// Smallest τ over rays that do not end on the target site (the target border counts only below
        /// `safety`).
        public func avoidanceTau(safety: Double) -> Double {
            func f(_ t: Double, _ isTarget: Bool) -> Double { isTarget && t >= safety ? .infinity : t }
            return min(f(tauL, targetL), f(tauR, targetR), f(tauAhead, targetAhead))
        }
    }

    /// Gaze ray to the visual border: the outer border of the union of screens (shared edges are
    /// transparent) or a perch line seen from its open side (e.g. the Dock top), whichever is nearer.
    /// Returns the distance along the ray and the inward unit normal of the border hit.
    public func gazeRay(from p: CGPoint, angle: Double) -> (distance: Double, normal: CGVector) {
        var best = world.castRegionRay(from: p, angle: angle)
        let ux = cos(angle), uy = sin(angle)
        for s in world.perchSites {
            let n = world.normal(of: s.side)
            let side = Double(p.x - s.a.x) * Double(n.dx) + Double(p.y - s.a.y) * Double(n.dy)
            let un = ux * Double(n.dx) + uy * Double(n.dy)
            guard side > 0, un < -1e-9 else { continue }
            let t = side / -un
            guard t < best.distance else { continue }
            let hx = Double(p.x) + ux * t, hy = Double(p.y) + uy * t
            let along = s.side == .bottom ? hx : hy
            let (c0, c1) = s.side == .bottom ? (Double(s.a.x), Double(s.b.x)) : (Double(s.a.y), Double(s.b.y))
            let l0 = min(c0, c1), l1 = max(c0, c1)
            if along >= l0 - 1 && along <= l1 + 1 { best = (t, n) }
        }
        return best
    }

    /// Whether `q` can be reached in a straight line from the fly without leaving the flight region.
    public func isVisible(_ q: CGPoint) -> Bool {
        let dx = Double(q.x - position.x), dy = Double(q.y - position.y)
        let d = hypot(dx, dy)
        guard d > 1 else { return true }
        return world.castRegionRay(from: position, angle: atan2(dy, dx)).distance >= d - 2
    }

    /// A straight landing approach to `q` stays inside the flight region with half a body width to spare on
    /// either side (rejects paths grazing a screen corner, e.g. next to a shared edge).
    /// v5: for a window site (`site`) the straight path must also stay off the window (approach from the open side).
    public func hasLandingPath(to q: CGPoint, site: PerchSite? = nil) -> Bool {
        guard isVisible(q) else { return false }
        if let r = site.flatMap(windowFrame(of:)) {
            // Not from just over the window (e.g. right after crossing its top edge from inside) …
            if state != .landing && r.insetBy(dx: -windowLandingClearance, dy: -windowLandingClearance).contains(position) { return false }
            // … and never through it.
            if FlyController.segment(position, q, intersects: r.insetBy(dx: -2, dy: -2)) { return false }
        }
        let dx = Double(q.x - position.x), dy = Double(q.y - position.y)
        let d = hypot(dx, dy)
        guard d > 1 else { return true }
        let px = -dy / d * 8, py = dx / d * 8
        for f in [0.25, 0.5, 0.75, 0.9] {
            let cx = Double(position.x) + dx * f, cy = Double(position.y) + dy * f
            for s in [-1.0, 1.0] where !world.flightRegionContains(CGPoint(x: cx + s * px, y: cy + s * py)) {
                return false
            }
        }
        return true
    }

    /// Where to steer for the target: the target point when visible; otherwise (another screen, around a
    /// corner) the middle of the border shared with the target's screen, or the centre of the fly's screen.
    public func targetAim(_ t: PerchTarget) -> (point: CGPoint, visible: Bool) {
        // v5: a window site is approached from its open side: route around the window via waypoints outside its
        // corners while the straight line would cross it.
        if let r = windowFrame(of: t.site), let w = windowWaypoint(to: t.point, around: r), isVisible(w) { return (w, false) }
        if isVisible(t.point) { return (t.point, true) }
        let fs = world.nearestScreen(to: position), ts = world.nearestScreen(to: t.point)
        if fs.id != ts.id {
            let r = fs.frame.insetBy(dx: -1, dy: -1).intersection(ts.frame.insetBy(dx: -1, dy: -1))
            if !r.isNull {
                let m = world.clampToFlightRegion(CGPoint(x: r.midX, y: r.midY))
                if isVisible(m) { return (m, false) }
            }
        }
        return (world.clampToFlightRegion(CGPoint(x: fs.frame.midX, y: fs.frame.midY)), false)
    }

    /// Whether a point lies within `targetRayTolerance` of the current target's site segment.
    private func nearTargetSite(_ h: CGPoint) -> Bool {
        guard let t = target else { return false }
        return FlyController.distance(h, toSegment: t.site.a, t.site.b) < targetRayTolerance
    }

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let l2 = dx * dx + dy * dy
        var t = l2 > 0 ? (Double(p.x - a.x) * dx + Double(p.y - a.y) * dy) / l2 : 0
        t = min(max(t, 0), 1)
        return hypot(Double(p.x) - (Double(a.x) + t * dx), Double(p.y) - (Double(a.y) + t * dy))
    }

    /// τ per gaze ray = perpendicular distance to the border that ray hits ÷ the fly's closing speed on
    /// that border, counted only when the fly is actually closing on it (+inf otherwise).
    public func edgeSense() -> EdgeSense {
        var e = EdgeSense()
        guard isAirborne, speed > 1 else { return e }
        let vx = cos(heading) * speed, vy = sin(heading) * speed
        func ray(_ a: Double) -> (tau: Double, closing: Double, dist: Double, target: Bool) {
            let r = gazeRay(from: position, angle: heading + a)
            let h = CGPoint(x: Double(position.x) + cos(heading + a) * r.distance,
                            y: Double(position.y) + sin(heading + a) * r.distance)
            let tgt = nearTargetSite(h)
            let closing = -(vx * Double(r.normal.dx) + vy * Double(r.normal.dy))
            guard closing > 1e-6 else { return (.infinity, 0, r.distance, tgt) }
            // True time-to-contact with the border this ray sees: perpendicular distance ÷ closing speed
            // (a ray along the heading gives distance ÷ speed; flying parallel to a border gives +inf).
            let perp = r.distance * -(cos(heading + a) * Double(r.normal.dx) + sin(heading + a) * Double(r.normal.dy))
            return (max(perp, 0) / closing, closing, r.distance, tgt)
        }
        let l = ray(edgeRayAngle), r = ray(-edgeRayAngle)
        e.tauL = l.tau; e.distL = l.dist; e.targetL = l.target
        e.tauR = r.tau; e.distR = r.dist; e.targetR = r.target
        let ahead = ray(0)
        e.tauAhead = ahead.tau; e.closing = ahead.closing; e.targetAhead = ahead.target
        return e
    }

    @discardableResult
    public func update(pointer: CGPoint, dt rawDt: Double) -> FlyFrame {
        let dt = min(max(rawDt, 0), 0.1)
        guard dt > 0 else { return frame }

        // Pointer velocity (lightly smoothed).
        if let last = lastPointer {
            let vx = Double(pointer.x - last.x) / dt, vy = Double(pointer.y - last.y) / dt
            let a = 0.6
            pointerVelocity = CGVector(dx: a * vx + (1 - a) * Double(pointerVelocity.dx),
                                       dy: a * vy + (1 - a) * Double(pointerVelocity.dy))
        }
        lastPointer = pointer

        updateTarget(dt: dt)
        updateSocialTakeoff(dt: dt)
        updateNeighborMemory(dt: dt)
        var percept = makePercept(pointer: pointer)
        if isPerched && socialTakeoffHold > 0 { percept.flockTakeoffDrive = 1 }
        // v5: the window under the feet is gone (closed) → the jolt is held until the fly lifts off.
        if isPerched, let wid = perchSite?.windowID, !world.windows.contains(where: { $0.id == wid }) { substrateJolt = 1 }
        percept.substrateJolt = isPerched ? substrateJolt : 0
        percept.windowMotionStartle = windowMotionStartle
        if windowMotionStartle > 0, let src = startleSource {
            percept.windowMotionBearing = angleDiff(atan2(Double(src.y - position.y), Double(src.x - position.x)), heading)
        }
        let cmd = brain.step(percept, dt: dt)
        substrateJolt = max(0, substrateJolt - dt / max(startleDecay, 1e-3))
        windowMotionStartle = max(0, windowMotionStartle - dt / max(startleDecay, 1e-3))
        lastCommand = cmd
        stateTime += dt
        idleTime += dt
        landCooldown = max(0, landCooldown - dt)
        saccadeCooldown = max(0, saccadeCooldown - dt)

        switch state {
        case .perched, .walking, .grooming: updatePerched(cmd, pointer: pointer, dt: dt)
        case .takingOff: updateTakingOff(cmd, pointer: pointer, dt: dt)
        case .flying: updateFlying(cmd, pointer: pointer, dt: dt)
        case .escaping: updateEscaping(cmd, pointer: pointer, dt: dt)
        case .landing: updateLanding(cmd, pointer: pointer, dt: dt)
        }

        separationSafeguard(dt: dt)
        if isAirborne { clampCounting(position) }
        updateRoll(dt: dt)
        updatePitch(dt: dt)
        updatePose(cmd, dt: dt)
        return frame
    }

    // MARK: - States

    private func set(_ s: FlyState) {
        if s == .escaping && state != .escaping { escapes += 1 }
        if s != state { state = s; stateTime = 0 }
        if s != .flying { inSaccade = false }
    }

    /// Perch seeking: after a flight bout pick a target site (weighted by distance and randomness) and a
    /// point on it; drop it after `targetTimeout` or when its site disappears.
    private func updateTarget(dt: Double) {
        let leader = flockingEnabled && !isLeader ? neighbors.first(where: \.isLeader) : nil
        // The leader is settling when it is perched, landing or has picked a perch target.
        let leaderSettling = leader.map { $0.perchPoint != nil } ?? false
        defer { leaderWasPerched = leaderSettling }
        guard isAirborne, state != .landing else { return }
        if let l = leader {
            if leaderSettling && !leaderWasPerched && target == nil {
                // Friends whose leader settles tend to land soon too (near it, see socialPerchTarget).
                flightBout = min(flightBout, flightTime + rng.uniform(leaderPerchedLandDelay.lowerBound,
                                                                      leaderPerchedLandDelay.upperBound))
            } else if !leaderSettling && l.airborne && (lastSeen[l.id] != nil || neighborMemory[l.id] != nil) {
                // Following a flying leader: no perch seeking of its own; a social target is dropped when
                // the leader takes off again.
                if targetIsSocial && target != nil { target = nil; targetIsSocial = false }
                if target == nil { flightBout = max(flightBout, flightTime + 1) }
            }
        }
        flightTime += dt
        if let t = target {
            targetTime += dt
            if targetTime > targetTimeout || !world.perchSites.contains(t.site) {
                target = nil
                flightBout = flightTime + rng.uniform(2, 6)
            }
            return
        }
        guard state == .flying, flightTime >= flightBout else { return }
        // Friends: a site near the leader's perch (or perch target) point, spaced from the other flies.
        if let lp = leader?.perchPoint, rng.chance(leaderPerchBias),
           let social = socialPerchTarget(near: lp) {
            target = social
            targetIsSocial = true
            targetTime = 0
            return
        }
        guard let site = randomPerchSite() else { return }
        var point = world.perchPoint(on: site, near: position)
        for _ in 0..<4 {
            let u = rng.uniform(0, 1)
            let foot = CGPoint(x: site.a.x + (site.b.x - site.a.x) * u, y: site.a.y + (site.b.y - site.a.y) * u)
            point = world.perchPoint(on: site, near: foot)
            if hypot(point.x - position.x, point.y - position.y) > 200 { break }
        }
        if !neighbors.isEmpty { point = spacedPerchPoint(on: site, near: point) ?? point }
        target = PerchTarget(site: site, point: point)
        targetIsSocial = false
        targetTime = 0
    }

    /// Perch target for a friend: the nearest site to the leader's point `lp` (within leaderPerchRadius)
    /// that has room at the required spacing; nil when none has.
    private func socialPerchTarget(near lp: CGPoint) -> PerchTarget? {
        let r = leaderPerchRadius
        let sites = world.perchSites
            .map { ($0, world.perchPoint(on: $0, near: lp)) }
            .filter { Double(hypot($0.1.x - lp.x, $0.1.y - lp.y)) <= r }
            .sorted { hypot($0.1.x - lp.x, $0.1.y - lp.y) < hypot($1.1.x - lp.x, $1.1.y - lp.y) }
        for (site, _) in sites {
            if let q = spacedPerchPoint(on: site, near: lp, within: (lp, r)) { return PerchTarget(site: site, point: q) }
        }
        return nil
    }

    /// Minimum distance (pt) between this fly's perch point and a neighbour's.
    private func perchSpacing(_ n: FlockNeighbor) -> Double { perchSpacingBodyLengths * max(bodySize, n.size) }

    /// Whether `q` keeps the perch spacing from every other fly's perch point.
    private func perchPointIsFree(_ q: CGPoint) -> Bool {
        neighbors.allSatisfy { n in
            guard let pp = n.perchPoint else { return true }
            return Double(hypot(q.x - pp.x, q.y - pp.y)) >= perchSpacing(n)
        }
    }

    /// The perch point on `site` nearest to `p` that keeps the spacing from the other flies' perch points
    /// (shifted along the segment in 8-pt steps), optionally within `within.radius` of `within.center`;
    /// nil when there is no room.
    public func spacedPerchPoint(on site: PerchSite, near p: CGPoint,
                                 within: (center: CGPoint, radius: Double)? = nil) -> CGPoint? {
        func ok(_ q: CGPoint) -> Bool {
            if let w = within, Double(hypot(q.x - w.center.x, q.y - w.center.y)) > w.radius { return false }
            return perchPointIsFree(q)
        }
        let base = world.perchPoint(on: site, near: p)
        if ok(base) { return base }
        let len = Double(site.length)
        guard len > 1 else { return nil }
        let ux = Double(site.b.x - site.a.x) / len, uy = Double(site.b.y - site.a.y) / len
        let step = 8.0
        var k = 1
        while Double(k) * step <= len {
            for sgn in [1.0, -1.0] {
                let off = sgn * Double(k) * step
                let q = world.perchPoint(on: site, near: CGPoint(x: Double(base.x) + ux * off, y: Double(base.y) + uy * off))
                if ok(q) { return q }
            }
            k += 1
        }
        return nil
    }

    private func separationSafeguard(dt: Double) {
        guard flockingEnabled, isAirborne, !neighbors.isEmpty else { safeguardActive = false; return }
        var engaged = false
        let v = velocity
        for n in neighbors where n.airborne && n.id != flockID {
            let L = max(bodySize, n.size)
            let qx = Double(n.position.x) + Double(n.velocity.dx) * dt, qy = Double(n.position.y) + Double(n.velocity.dy) * dt
            let dx = Double(position.x) - qx, dy = Double(position.y) - qy
            let d = hypot(dx, dy)
            guard d < safeguardBodyLengths * L else { continue }
            var ux = -sin(heading), uy = cos(heading)
            if d > 1e-6 { ux = dx / d; uy = dy / d }
            let closing = -((Double(v.dx) - Double(n.velocity.dx)) * ux + (Double(v.dy) - Double(n.velocity.dy)) * uy)
            let minD = safeguardMinBodyLengths * L
            if closing <= 0 && d >= minD { continue }
            engaged = true
            // Never toward a border (the border look-ahead keeps priority).
            let turn = max(-safeguardYawRate * dt, min(safeguardYawRate * dt, angleDiff(atan2(uy, ux), heading)))
            if world.castRegionRay(from: position, angle: heading + turn).distance > borderMargin + proximityRoom + speed * 0.2 {
                heading = angleDiff(heading + turn, 0)
            }
            if state == .flying || state == .escaping { speed = max(150, speed * (1 - 3 * dt)) }
            if d < minD, world.castRegionRay(from: position, angle: atan2(uy, ux)).distance > minD - d + borderMargin {
                position = CGPoint(x: Double(position.x) + ux * (minD - d), y: Double(position.y) + uy * (minD - d))
            }
        }
        if engaged && !safeguardActive { separationSafeguards += 1 }
        safeguardActive = engaged
    }

    /// Visible neighbours refresh the memory; invisible ones age out after `boids.memoryDuration` (or on landing).
    private func updateNeighborMemory(dt: Double) {
        guard flockingEnabled, isAirborne else { neighborMemory.removeAll(); lastSeen.removeAll(); return }
        let me = flockSelf
        var visible: [Int: FlockNeighbor] = [:]
        for n in neighbors where Boids.sees(me, n, config: boids) { visible[n.id] = n }
        var next: [Int: (n: FlockNeighbor, age: Double)] = [:]
        for n in neighbors where n.airborne && visible[n.id] == nil {
            if let s = lastSeen[n.id] { next[n.id] = (s, dt) }   // just left the view
            else if let m = neighborMemory[n.id], m.age + dt < boids.memoryDuration { next[n.id] = (m.n, m.age + dt) }
        }
        neighborMemory = next
        lastSeen = visible
    }

    /// Leader takeoff seen while perched → after a reaction delay, a social takeoff drive (held ≤ 1.5 s).
    private func updateSocialTakeoff(dt: Double) {
        let leader = flockingEnabled && !isLeader ? neighbors.first(where: \.isLeader) : nil
        let leaderAirborne = leader?.airborne ?? false
        defer { leaderWasAirborne = leaderAirborne }
        socialTakeoffHold = isPerched ? max(0, socialTakeoffHold - dt) : 0
        guard isPerched, let l = leader else { socialTakeoffTimer = -1; return }
        if leaderAirborne && !leaderWasAirborne && socialTakeoffTimer < 0
            && Double(hypot(l.position.x - position.x, l.position.y - position.y)) < socialTakeoffRadius {
            socialTakeoffTimer = rng.uniform(socialTakeoffDelay.lowerBound, socialTakeoffDelay.upperBound)
        }
        if socialTakeoffTimer >= 0 {
            socialTakeoffTimer -= dt
            if socialTakeoffTimer < 0 { socialTakeoffHold = 1.5 }
        }
    }

    private func abandonTarget() {
        if target != nil { target = nil }
        flightBout = flightTime + rng.uniform(3, 8)
    }

    private func beginTakeoff(pointer: CGPoint, escape: Bool) {
        var dir = CGVector(dx: cos(heading), dy: sin(heading))
        if let perch { dir = world.normal(of: perch) }
        flightTime = 0
        target = nil
        flightBout = rng.uniform(flightBoutRange.lowerBound, flightBoutRange.upperBound)
        let ax = Double(position.x - pointer.x), ay = Double(position.y - pointer.y)
        let ad = max(1, hypot(ax, ay))
        if escape || ad < 300 {
            dir = CGVector(dx: Double(dir.dx) + ax / ad, dy: Double(dir.dy) + ay / ad)
        }
        // Add a bit of randomness so takeoffs differ.
        let jitter = rng.uniform(-0.4, 0.4)
        var h = atan2(Double(dir.dy), Double(dir.dx)) + jitter
        if let perch {
            // Never take off into the surface: stay within +-80 deg of the normal.
            let n = world.normal(of: perch)
            let nh = atan2(Double(n.dy), Double(n.dx))
            let d = angleDiff(h, nh)
            h = nh + max(-1.4, min(1.4, d))
        }
        takeoffDir = CGVector(dx: cos(h), dy: sin(h))
        heading = h
        escapeFrom = pointer
        perch = nil
        perchSite = nil
        perchWindowFrame = nil
        substrateJolt = 0
        landingTarget = nil
        idleTime = 0
        speed = 150
        set(escape ? .escaping : .takingOff)
        landCooldown = 1.5
    }

    private func updatePerched(_ cmd: MotorCommand, pointer: CGPoint, dt: Double) {
        altitudeScale = 1
        guard let perch, let site = perchSite else { set(.flying); return }
        if cmd.takeoff > 0.5 {
            let threat = hypot(Double(pointer.x - position.x), Double(pointer.y - position.y)) < 400
            beginTakeoff(pointer: pointer, escape: threat && cmd.thrust > 0.8)
            return
        }
        speed = 0
        if cmd.freeze > 0.5 {
            set(.perched)
        } else if cmd.groom > 0.5 {
            set(.grooming)
        } else if cmd.walkSpeed > 0.2 {
            set(.walking)
            speed = walkSpeedMax * min(1, cmd.walkSpeed) * (cmd.backward > 0.5 ? -0.5 : 1)
            var p = position
            switch perch {
            case .left, .right: p.y += CGFloat(sin(heading) * speed * dt)
            case .bottom: p.x += CGFloat(cos(heading) * speed * dt)
            }
            let q = world.perchPoint(on: site, near: p)
            if abs(q.x - p.x) > 0.01 || abs(q.y - p.y) > 0.01 { heading = angleDiff(heading + .pi, 0) }
            // Do not walk into another fly's perch spacing (turn around instead).
            let crowding = neighbors.contains { n in
                guard let pp = n.perchPoint else { return false }
                let dNew = Double(hypot(q.x - pp.x, q.y - pp.y)), dOld = Double(hypot(position.x - pp.x, position.y - pp.y))
                return dNew < perchSpacing(n) && dNew < dOld
            }
            if crowding { heading = angleDiff(heading + .pi, 0) } else { position = q }
        } else {
            set(.perched)
        }
        // Keep the body glued to the edge and aligned with it.
        let snapped = world.perchPoint(on: site, near: position)
        position = snapped
        heading = world.alignedHeading(perch, closestTo: heading)
    }

    private func updateTakingOff(_ cmd: MotorCommand, pointer: CGPoint, dt: Double) {
        let dur = 0.18
        let t = min(1, stateTime / dur)
        altitudeScale = 1 + (flyingAltitudeScale - 1) * t
        speed = 150 + (cruiseSpeedRange.lowerBound + 100 - 150) * t
        let look = lookAhead()
        speed = min(speed, max(150, look.speedCap))
        if look.weight > 0 { steer(yawRate: look.yaw, maxRate: avoidYawMax, dt: dt) }
        integrate(dt: dt)
        if stateTime >= dur { set(cmd.takeoff > 0.5 ? .escaping : .flying) }
    }

    private func updateFlying(_ cmd: MotorCommand, pointer: CGPoint, dt: Double) {
        altitudeScale += (flyingAltitudeScale - altitudeScale) * min(1, 6 * dt)
        if cmd.takeoff > 0.5 {
            escapeFrom = threatSource(pointer)
            abandonTarget()
            set(.escaping)
            idleTime = 0
            return
        }
        if cmd.land > 0.5 && landCooldown <= 0 {
            // Landing gate: a site reachable within ~landGateTau at the current speed (screen-size free).
            let gate = max(landGateMin, speed * landGateTau)
            if let t = target,
               let q = spacedPerchPoint(on: t.site, near: targetIsSocial ? t.point : position) {
                if Double(hypot(q.x - position.x, q.y - position.y)) < gate && hasLandingPath(to: q, site: t.site) {
                    landingSite = t.site; landingTarget = q
                    set(.landing)
                    return
                }
            }
            // Any other site only once the flight bout is over (perch seeking), so bouts keep their length.
            if flightTime >= flightBout, let n = world.nearestPerchSite(to: position), n.distance < gate,
               let q = spacedPerchPoint(on: n.site, near: position),
               Double(hypot(q.x - position.x, q.y - position.y)) < gate, hasLandingPath(to: q, site: n.site) {
                landingSite = n.site
                landingTarget = q
                set(.landing)
                return
            }
        }
        var targetSpeed = cruiseSpeedRange.lowerBound
            + (cruiseSpeedRange.upperBound - cruiseSpeedRange.lowerBound) * min(1, max(0, cmd.thrust))
        let look = lookAhead()
        targetSpeed = min(targetSpeed, look.speedCap)
        speed += (targetSpeed - speed) * min(1, (targetSpeed < speed ? 6 : 2) * dt)
        // Body saccade: kinematic shape of a brain-triggered turn (a fast-rising decoded yaw pulse).
        sinceLowYaw = abs(cmd.yawRate) < saccadeOffsetYaw ? 0 : sinceLowYaw + dt
        if inSaccade {
            saccadeTime += dt
            // A saccade that turns against the safety avoidance is cut short; one turning the same way finishes.
            let against = look.weight > 0.3 && (cmd.yawRate > 0) != (look.yaw > 0)
            if abs(cmd.yawRate) < saccadeOffsetYaw || saccadeTime > saccadeMaxDuration || against
                || abs(saccadeTurn) >= saccadeMaxAmplitude {
                inSaccade = false
                saccadeCooldown = saccadeRefractory
            }
        } else if abs(cmd.yawRate) > saccadeOnsetYaw && saccadeCooldown <= 0
                    && sinceLowYaw <= saccadeRiseTime && look.weight == 0 {
            inSaccade = true
            saccadeTime = 0
            saccadeTurn = 0
            saccades += 1
        }
        if inSaccade {
            let rate = max(-saccadeMaxRate, min(saccadeMaxRate, saccadeGain * cmd.yawRate))
            yawSmoothed = rate
            saccadeTurn += rate * dt
            heading = angleDiff(heading + rate * dt, 0)
        } else {
            let yaw = max(-maxTurnRate, min(maxTurnRate, cmd.yawRate))
            steer(yawRate: (1 - look.weight) * yaw + look.weight * look.yaw,
                  maxRate: max(maxTurnRate * 1.6, look.weight * avoidYawMax), dt: dt)
        }
        integrate(dt: dt)
    }

    private func updateEscaping(_ cmd: MotorCommand, pointer: CGPoint, dt: Double) {
        altitudeScale += (flyingAltitudeScale + 0.1 - altitudeScale) * min(1, 8 * dt)
        if cmd.takeoff > 0.5 { escapeFrom = threatSource(pointer); stateTime = min(stateTime, 0.2); abandonTarget() }
        let look = lookAhead()
        let target = min(escapeSpeed, look.speedCap)
        speed += (target - speed) * min(1, 10 * dt)
        let away = atan2(Double(position.y - escapeFrom.y), Double(position.x - escapeFrom.x))
        let yaw = 10 * angleDiff(away, heading)
        steer(yawRate: (1 - look.weight) * yaw + look.weight * look.yaw * 1.5, maxRate: 14, dt: dt)
        integrate(dt: dt)
        if stateTime > 0.7 { set(.flying) }
    }

    private func updateLanding(_ cmd: MotorCommand, pointer: CGPoint, dt: Double) {
        guard let target = landingTarget, let lp = landingSite else { set(.flying); return }
        if cmd.takeoff > 0.5 {
            escapeFrom = threatSource(pointer)
            landingTarget = nil
            abandonTarget()
            set(.escaping)
            idleTime = 0
            return
        }
        let dx = Double(target.x - position.x), dy = Double(target.y - position.y)
        let d = hypot(dx, dy)
        // v4: a landing approach about to cross another fly is aborted (back to flight, where the brain's
        // separation steering acts); the landing gate retries after the cooldown.
        if lastBoids.separationStrength > landingAbortSeparation && d > max(150, 4 * bodySize) {
            abortLanding(lp, cooldown: 0.8)
            return
        }
        // Another fly claimed a perch point too close to ours meanwhile: shift along the site, or abort.
        if d > 20 && !perchPointIsFree(target) {
            if let q = spacedPerchPoint(on: lp, near: target), hasLandingPath(to: q, site: lp) { landingTarget = q; return }
            abortLanding(lp, cooldown: 1.0)
            return
        }
        // The approach no longer fits past a screen corner (it curved): abort, the look-ahead takes over.
        if d > 30 && !hasLandingPath(to: target, site: lp) {
            abortLanding(lp, cooldown: 1.0)
            return
        }
        let bearing = atan2(dy, dx)
        // Slow down with distance so the turning radius (v/omega) stays below the distance.
        // Look-ahead deceleration: speed ∝ distance (constant time-to-contact ≈ 1/landingDecel s), so the
        // fly arrives slowly; plus a floor so the approach always completes.
        let maxRate = 9.0
        let targetSpeed = max(landingMinSpeed, min(cruiseSpeedRange.lowerBound + 150, d * landingDecel))
        speed += (targetSpeed - speed) * min(1, 8 * dt)
        speed = min(speed, safeSpeed(landingOn: lp))
        steer(yawRate: 10 * angleDiff(bearing, heading), maxRate: maxRate, dt: dt)
        altitudeScale = 1 + (flyingAltitudeScale - 1) * min(1, d / 120)
        let step = min(speed * dt, d)
        if d < 4 || step >= d {
            position = target
            touchdown(lp)
            return
        }
        integrate(dt: dt, maxStep: step)
        // v5: the final curve onto a window edge never dips into the window (stay on the open side of its line).
        if let r = windowFrame(of: lp), r.insetBy(dx: 1, dy: 1).contains(position) {
            let n = world.normal(of: lp.side)
            let depth = -(Double(position.x - lp.a.x) * Double(n.dx) + Double(position.y - lp.a.y) * Double(n.dy))
            position = CGPoint(x: Double(position.x) + Double(n.dx) * (depth + 1), y: Double(position.y) + Double(n.dy) * (depth + 1))
        }
        if stateTime > 6 { abortLanding(lp, cooldown: 2) }
    }

    /// Back to flight from a landing approach. Close to the perch line (< 80 pt) the fly turns to fly off it
    /// (heading within ±60° of the site's normal), so an abort next to a border does not run into it.
    private func abortLanding(_ site: PerchSite, cooldown: Double) {
        landingAborts += 1
        if site.windowID != nil { windowLandingAborts += 1 }
        landingTarget = nil; landingSite = nil
        set(.flying); landCooldown = cooldown
        let n = world.normal(of: site.side)
        let off = Double(position.x - site.a.x) * Double(n.dx) + Double(position.y - site.a.y) * Double(n.dy)
        if off < 80 {
            let nh = atan2(Double(n.dy), Double(n.dx))
            heading = nh + max(-1.05, min(1.05, angleDiff(heading, nh)))
            yawSmoothed = 0
        }
    }

    private func touchdown(_ site: PerchSite) {
        let p = site.side
        if let t = target, t.site == site { targetLandings += 1 }
        if site.windowID != nil { windowLandings += 1 }
        perchWindowFrame = windowFrame(of: site)
        lastContactSpeed = speed
        perch = p
        perchSite = site
        landingTarget = nil
        landingSite = nil
        target = nil
        speed = 0
        altitudeScale = 1
        heading = world.alignedHeading(p, closestTo: heading)
        landings += 1
        set(.perched)
        onLanded?(site)
    }

    // MARK: - Kinematics

    private func steer(yawRate: Double, maxRate: Double, dt: Double) {
        let y = max(-maxRate, min(maxRate, yawRate))
        yawSmoothed += (y - yawSmoothed) * min(1, 12 * dt)
        heading = angleDiff(heading + yawSmoothed * dt, 0)
    }

    private func integrate(dt: Double, maxStep: Double? = nil) {
        let s = maxStep ?? speed * dt
        var p = position
        p.x += CGFloat(cos(heading) * s)
        p.y += CGFloat(sin(heading) * s)
        // Last resort (counted in borderClamps): reflect the heading off the bound (only in free flight).
        if state != .landing && !world.flightRegionContains(p) {
            let c = world.clampToFlightRegion(p)
            if abs(c.x - p.x) > 1e-6 { heading = angleDiff(.pi - heading, 0) }
            if abs(c.y - p.y) > 1e-6 { heading = angleDiff(-heading, 0) }
        }
        clampCounting(p)
    }

    private func clampCounting(_ p: CGPoint) {
        let c = world.clampToFlightRegion(p)
        if abs(c.x - p.x) > 1e-6 || abs(c.y - p.y) > 1e-6 { borderClamps += 1 }
        position = c
    }

    /// Borders the fly is moving toward, sampled with flight-region rays (shared edges transparent) at
    /// 0, ±30°, ±60°, ±90° from the heading: perpendicular room (pt, minus the margin) and closing fraction.
    /// `landingOn`: that perch line only needs to keep the body short of the perch point (inset).
    private func closingBorders(landingOn: PerchSite? = nil) -> [(room: Double, closing: Double)] {
        let ux = cos(heading), uy = sin(heading)
        var out: [(Double, Double)] = []
        for a in [0.0, .pi / 6, -.pi / 6, .pi / 3, -.pi / 3, .pi / 2, -.pi / 2] {
            let ang = heading + a
            let r = world.castRegionRay(from: position, angle: ang)
            let n = r.normal
            let closing = -(ux * Double(n.dx) + uy * Double(n.dy))
            guard closing > 1e-6 else { continue }
            let perp = r.distance * -(cos(ang) * Double(n.dx) + sin(ang) * Double(n.dy))
            var margin = borderMargin
            if let s = landingOn {
                let sn = world.normal(of: s.side)
                let h = CGPoint(x: Double(position.x) + cos(ang) * r.distance, y: Double(position.y) + sin(ang) * r.distance)
                if abs(Double(sn.dx - n.dx)) + abs(Double(sn.dy - n.dy)) < 1e-6,
                   FlyController.distance(h, toSegment: s.a, s.b) < Double(world.perchInset) + 30 {
                    margin = max(0, Double(world.perchInset) - 6)
                }
            }
            out.append((perp - margin, closing))
        }
        return out
    }

    /// Speed cap so the fly can still turn away before a border it is closing on: the penetration of a
    /// turn at yaw rate ω from closing fraction c is ≈ (v/ω)·c, plus steering lag.
    private func safeSpeed(landingOn: PerchSite? = nil) -> Double {
        var cap = Double.infinity
        let lag = 0.12
        for b in closingBorders(landingOn: landingOn) {
            let room = max(0, b.room)
            // v·c·(1/ω + lag) <= room
            let v = room / max(b.closing * (1 / avoidYawMax + lag), 1e-6)
            cap = min(cap, v)
        }
        return max(cap, 60)
    }

    /// Look-ahead border avoidance: when the time-to-contact drops below `avoidTau` and the fly is not
    /// landing (a high land drive with a reachable perch has already switched to `.landing`, which
    /// decelerates instead), turn away from the imminent border (the hemifield with the smaller τ; head-on → toward the
    /// screen centre) and cap the speed so the turn fits.
    private func lookAhead() -> (yaw: Double, weight: Double, speedCap: Double) {
        let e = edgeSense()
        let cap = safeSpeed()
        // The chosen perch target's border is not avoided (the landing gate takes over), except as a
        // last-moment safety.
        let tau = e.avoidanceTau(safety: targetSafetyTau)
        // Proximity: a border the fly is closing on within `proximityRoom` pt (beyond the margin) forces
        // avoidance even when τ is long (slow, glancing approach).
        let room = closingBorders().map(\.room).min() ?? .infinity
        let wProx = min(1, max(0, (proximityRoom - room) / max(proximityRoom - 10, 1)))
        let w = max(tau < avoidTau ? weight(tau) : 0, wProx)
        guard w > 0 else { avoidDir = 0; return (0, 0, cap) }
        // The turn direction is chosen once per avoidance manoeuvre (hysteresis), so the fly does not
        // dither when flying along a border or into a corner.
        if avoidDir != 0 {
            // Re-entrant corner: flip a turn whose side has become much more closed than the other.
            let turnSide = avoidDir > 0 ? e.distL : e.distR, otherSide = avoidDir > 0 ? e.distR : e.distL
            if turnSide < 80 && turnSide < 0.5 * otherSide { avoidDir = -avoidDir }
            return (avoidDir * avoidYawMax, w, cap)
        }
        var dir: Double
        // Turn toward the more open hemifield (longer gaze ray, the same rule as the brain's
        // collision-avoidance saccades); head-on: toward the screen centre.
        if abs(e.distL - e.distR) > 0.05 * min(e.distL, e.distR) + 1 {
            dir = e.distL < e.distR ? -1 : 1
        } else {
            let fb = world.nearestScreen(to: position).frame
            let cx = Double(fb.midX - position.x), cy = Double(fb.midY - position.y)
            dir = (cos(heading) * cy - sin(heading) * cx) >= 0 ? 1 : -1
        }
        avoidDir = dir
        return (dir * avoidYawMax, w, cap)
    }

    private func weight(_ tau: Double) -> Double {
        min(1, max(0, (avoidTau - tau) / max(avoidTau - avoidTauHard, 1e-6)))
    }

    private static func targetRoll(perch: Perch?, heading: Double, world: World) -> Double {
        guard let perch else { return 0 }
        // Roll so the ventral side (feet) points toward the edge, i.e. along -normal.
        // The fly's left vector in screen space is (-sin h, cos h); positive roll turns the feet to the left.
        let n = world.normal(of: perch)
        let leftDotEdge = -(-sin(heading)) * Double(n.dx) - cos(heading) * Double(n.dy)
        return leftDotEdge >= 0 ? .pi / 2 : -.pi / 2
    }

    private func updateRoll(dt: Double) {
        var target = FlyController.targetRoll(perch: perch, heading: heading, world: world)
        if perch == nil {
            // Bank into turns: turning left (positive yaw) lowers the left side (negative roll).
            target = max(-maxBank, min(maxBank, -bankGain * yawSmoothed * speed))
        }
        if perch != nil && abs(angleDiff(target, bodyRoll)) > 2.5 {
            bodyRoll = target // heading flipped on the edge: jump to the mirrored side view
        } else {
            bodyRoll += (target - bodyRoll) * min(1, 10 * dt)
        }
    }

    private func updatePitch(dt: Double) {
        var target = 0.0
        switch state {
        case .perched, .walking, .grooming: target = 0
        case .takingOff: target = takeoffPitch
        case .escaping: target = stateTime < 0.3 ? takeoffPitch : 0.15
        case .flying:
            // Climb nose-up while still gaining altitude after takeoff, then near level.
            let climb = max(0, flyingAltitudeScale - altitudeScale) / max(flyingAltitudeScale - 1, 1e-6)
            target = 0.08 + 0.35 * min(1, climb)
        case .landing:
            // Flare (nose up) over the last stretch before touchdown.
            let d = landingTarget.map { Double(hypot($0.x - position.x, $0.y - position.y)) } ?? 0
            target = flarePitch * min(1, max(0, 1 - (d - 10) / 90))
        }
        bodyPitch += (target - bodyPitch) * min(1, 8 * dt)
    }

    private func updatePose(_ cmd: MotorCommand, dt: Double) {
        var p = pose
        let airborne = isAirborne
        let stroke = airborne ? 1.0 : 0.0
        p.wingStroke += (stroke - p.wingStroke) * min(1, 15 * dt)
        if p.wingStroke > 0.01 {
            p.wingPhase = (p.wingPhase + 2 * .pi * wingBeatHz * dt).truncatingRemainder(dividingBy: 2 * .pi)
        }
        p.legTuck += ((airborne ? 1.0 : 0.0) - p.legTuck) * min(1, 8 * dt)
        let walking = state == .walking
        p.walkAmount += ((walking ? 1.0 : 0.0) - p.walkAmount) * min(1, 8 * dt)
        if walking {
            let s = abs(speed) / walkSpeedMax
            p.walkPhase = (p.walkPhase + 2 * .pi * gaitHz * s * dt * (speed < 0 ? -1 : 1))
                .truncatingRemainder(dividingBy: 2 * .pi)
        }
        let grooming = state == .grooming
        p.groomAmount += ((grooming ? 1.0 : 0.0) - p.groomAmount) * min(1, 6 * dt)
        if grooming || p.groomAmount > 0.01 {
            p.groomPhase = (p.groomPhase + 2 * .pi * groomHz * dt).truncatingRemainder(dividingBy: 2 * .pi)
        }
        p.headYaw = airborne ? 0 : max(-0.4, min(0.4, cmd.yawRate * 0.1))
        pose = p
    }

    // MARK: - v5 windows

    /// Frame of the window a site belongs to (nil for screen sites or a window that is gone).
    public func windowFrame(of site: PerchSite) -> CGRect? {
        guard let id = site.windowID else { return nil }
        return world.windows.first { $0.id == id }?.frame
    }

    /// Whether segment p→q passes through the interior of `r` (Liang–Barsky clip).
    static func segment(_ p: CGPoint, _ q: CGPoint, intersects r: CGRect) -> Bool {
        let dx = Double(q.x - p.x), dy = Double(q.y - p.y)
        var t0 = 0.0, t1 = 1.0
        let checks = [(-dx, Double(p.x - r.minX)), (dx, Double(r.maxX - p.x)), (-dy, Double(p.y - r.minY)), (dy, Double(r.maxY - p.y))]
        for (pp, qq) in checks {
            if abs(pp) < 1e-12 { if qq < 0 { return false } else { continue } }
            let t = qq / pp
            if pp < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
            if t0 > t1 { return false }
        }
        return t1 - t0 > 1e-9
    }

    /// First waypoint of the shortest path from the fly to `goal` that does not cross window `r`, through the
    /// window's corners pushed `windowApproachMargin` outward; nil when the straight line is already clear.
    func windowWaypoint(to goal: CGPoint, around r: CGRect) -> CGPoint? {
        let block = r.insetBy(dx: -2, dy: -2)
        guard FlyController.segment(position, goal, intersects: block) else { return nil }
        let e = r.insetBy(dx: -windowApproachMargin, dy: -windowApproachMargin)
        let corners = [CGPoint(x: e.minX, y: e.minY), CGPoint(x: e.maxX, y: e.minY),
                       CGPoint(x: e.maxX, y: e.maxY), CGPoint(x: e.minX, y: e.maxY)].map { world.clampToFlightRegion($0) }
        // Nodes: 0 = fly, 1...4 corners, 5 = goal. Dijkstra on 6 nodes.
        let nodes = [position] + corners + [goal]
        func free(_ i: Int, _ j: Int) -> Bool { !FlyController.segment(nodes[i], nodes[j], intersects: block) }
        var dist = [Double](repeating: .infinity, count: 6), prev = [Int](repeating: -1, count: 6), done = [Bool](repeating: false, count: 6)
        dist[0] = 0
        for _ in 0..<6 {
            guard let u = (0..<6).filter({ !done[$0] && dist[$0].isFinite }).min(by: { dist[$0] < dist[$1] }) else { break }
            done[u] = true
            for v in 0..<6 where !done[v] && free(u, v) {
                let w = dist[u] + Double(hypot(nodes[u].x - nodes[v].x, nodes[u].y - nodes[v].y))
                if w < dist[v] { dist[v] = w; prev[v] = u }
            }
        }
        guard dist[5].isFinite else { return corners.min { hypot($0.x - position.x, $0.y - position.y) < hypot($1.x - position.x, $1.y - position.y) } }
        var v = 5
        while prev[v] != 0 && prev[v] >= 0 { v = prev[v] }
        return nodes[v]
    }

    /// What an escape flees from: the pointer, or the moving window that startled the fly when the pointer is far.
    private func threatSource(_ pointer: CGPoint) -> CGPoint {
        if windowMotionStartle > 0 || substrateJolt > 0, let src = startleSource,
           Double(hypot(pointer.x - position.x, pointer.y - position.y)) > 400 { return src }
        return pointer
    }

    /// How a perched fly on a window edge of `side` follows that window from frame `a` to `b`: the edge's own
    /// coordinate follows it (top → maxY, left edge → minX, right edge → maxX), the along-edge one follows the
    /// window's top (side edges) or left side (top edge).
    static func carryDelta(_ side: Perch, from a: CGRect, to b: CGRect) -> CGVector {
        switch side {
        case .bottom: return CGVector(dx: b.minX - a.minX, dy: b.maxY - a.maxY)
        case .right: return CGVector(dx: b.minX - a.minX, dy: b.maxY - a.maxY)
        case .left: return CGVector(dx: b.maxX - a.maxX, dy: b.maxY - a.maxY)
        }
    }

    /// The app's window tracker reports which windows moved / resized (`moved`) or closed (`removed`); call it
    /// after `world` already holds the new window list. Perched on one of them → substrate jolt (the fly rode
    /// the window meanwhile, see `worldChanged`); within `startleRadius` of one → visual startle ∝ proximity;
    /// a perch target or landing on one is dropped and a new target picked after `windowRetargetDelay`.
    public func windowsChanged(moved: Set<Int>, removed: Set<Int>) {
        let changed = moved.union(removed)
        defer { previousWindowFrames.removeAll() }
        guard !changed.isEmpty else { return }
        var own: Int? = nil
        if isPerched, let wid = perchSite?.windowID, changed.contains(wid) {
            own = wid
            substrateJolt = 1
            startleSource = windowFrame(of: perchSite!).map { nearestEdgePoint(of: $0) } ?? position
        }
        if let t = target, let wid = t.site.windowID, changed.contains(wid) { dropWindowTarget() }
        if state == .landing, let ls = landingSite, let wid = ls.windowID, changed.contains(wid) {
            abortLanding(ls, cooldown: 1.0)
            dropWindowTarget()
        }
        // Visual startle from window motion nearby (old and new frames).
        var best = 0.0, src: CGPoint? = nil
        for id in changed where id != own {
            let frames = [previousWindowFrames[id], world.windows.first { $0.id == id }?.frame].compactMap { $0 }
            for f in frames {
                let q = nearestEdgePoint(of: f)
                let d = Double(hypot(q.x - position.x, q.y - position.y))
                let s = max(0, 1 - d / max(startleRadius, 1))
                if s > best { best = s; src = q }
            }
        }
        if best > windowMotionStartle { windowMotionStartle = best; startleSource = src }
    }

    /// Nearest point to the fly on the border of `r`.
    private func nearestEdgePoint(of r: CGRect) -> CGPoint {
        let x = min(max(position.x, r.minX), r.maxX), y = min(max(position.y, r.minY), r.maxY)
        guard r.contains(position) else { return CGPoint(x: x, y: y) }
        let dl = position.x - r.minX, dr = r.maxX - position.x, db = position.y - r.minY, dt = r.maxY - position.y
        let m = min(dl, dr, db, dt)
        if m == dl { return CGPoint(x: r.minX, y: position.y) }
        if m == dr { return CGPoint(x: r.maxX, y: position.y) }
        if m == db { return CGPoint(x: position.x, y: r.minY) }
        return CGPoint(x: position.x, y: r.maxY)
    }

    /// Weighted random perch site: length / (1 + d/1500), window sites × `windowSiteWeight`.
    private func randomPerchSite() -> PerchSite? {
        let sites = world.perchSites
        // No windows: exactly World.randomPerchSite (same random stream as before v5).
        guard windowSiteWeight != 1, sites.contains(where: { $0.windowID != nil }) else {
            return world.randomPerchSite(from: position, using: &rng)
        }
        let weights = sites.map { s -> Double in
            let q = world.perchPoint(on: s, near: position)
            let d = Double(hypot(q.x - position.x, q.y - position.y))
            return Double(s.length) / (1 + d / 1500) * (s.windowID != nil ? windowSiteWeight : 1)
        }
        let total = weights.reduce(0, +)
        guard total > 0 else { return sites.first }
        var r = rng.uniform(0, total)
        for (s, w) in zip(sites, weights) {
            if r < w { return s }
            r -= w
        }
        return sites.last
    }

    /// "window <id> top|left|right" or "screen edge <left|right|bottom>" (for the app's landing log).
    public static func landingDescription(_ site: PerchSite) -> String {
        guard let id = site.windowID else { return "screen edge \(site.side.rawValue)" }
        let edge: String
        switch site.side {
        case .bottom: edge = "top"
        case .right: edge = "left"
        case .left: edge = "right"
        }
        return "window \(id) \(edge)"
    }

    private func dropWindowTarget() {
        target = nil; targetIsSocial = false
        flightBout = flightTime + rng.uniform(windowRetargetDelay.lowerBound, windowRetargetDelay.upperBound)
    }

    private func worldChanged(old: World) {
        // Remember the frames windows had before this update (moved / closed ones), for `windowsChanged`.
        for w in old.windows where previousWindowFrames[w.id] == nil
            && world.windows.first(where: { $0.id == w.id })?.frame != w.frame {
            previousWindowFrames[w.id] = w.frame
        }
        if let t = target, !world.perchSites.contains(t.site) {
            if t.site.windowID != nil { dropWindowTarget() } else { target = nil }
        }
        if perch != nil, let cur = perchSite {
            if world.perchSites.contains(cur) && cur.windowID == nil { return }
            if let wid = cur.windowID { followWindow(wid, site: cur); return }
            let same = world.perchSites.filter { $0.side == perch && $0.windowID == nil }
            func d(_ s: PerchSite) -> CGFloat { let q = world.perchPoint(on: s, near: position); return hypot(q.x - position.x, q.y - position.y) }
            if let site = same.min(by: { d($0) < d($1) }) ?? world.nearestPerchSite(to: position)?.site {
                perchSite = site
                perch = site.side
                position = world.perchPoint(on: site, near: position)
                heading = world.alignedHeading(site.side, closestTo: heading)
            }
        } else {
            position = world.clampToFlightRegion(position)
            if let ls = landingSite, !world.perchSites.contains(ls) {
                if ls.windowID != nil {
                    // No landing on stale window geometry: back to flight, a new target follows.
                    if state == .landing { abortLanding(ls, cooldown: 1.0) } else { landingSite = nil; landingTarget = nil }
                    dropWindowTarget()
                } else if let n = world.nearestPerchSite(to: position) { landingSite = n.site; landingTarget = n.point }
                else { landingSite = nil; landingTarget = nil }
            }
        }
    }

    /// Kinematic attachment (before liftoff): a fly perched on a window rides along when the window moves or
    /// resizes; when the window is gone it stays where it is (the held jolt makes it lift off).
    private func followWindow(_ wid: Int, site: PerchSite) {
        guard let win = world.windows.first(where: { $0.id == wid }) else { return }
        var s = site
        if let old = perchWindowFrame, old != win.frame {
            let d = FlyController.carryDelta(site.side, from: old, to: win.frame)
            s.a = CGPoint(x: s.a.x + d.dx, y: s.a.y + d.dy); s.b = CGPoint(x: s.b.x + d.dx, y: s.b.y + d.dy)
            position = CGPoint(x: position.x + d.dx, y: position.y + d.dy)
            windowCarry = CGVector(dx: windowCarry.dx + d.dx, dy: windowCarry.dy + d.dy)
        }
        perchWindowFrame = win.frame
        // Back on a real site of that window edge when the foot point lies on one.
        let foot = CGPoint(x: position.x - world.normal(of: s.side).dx * world.perchInset,
                           y: position.y - world.normal(of: s.side).dy * world.perchInset)
        if let real = world.perchSites.first(where: { $0.windowID == wid && $0.side == s.side
            && FlyController.distance(foot, toSegment: $0.a, $0.b) < 1 }) { s = real }
        perchSite = s
        position = world.perchPoint(on: s, near: position)
    }
}
