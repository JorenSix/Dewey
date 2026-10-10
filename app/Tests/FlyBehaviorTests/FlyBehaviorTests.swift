import CoreGraphics
import Testing
import FlyCore
@testable import FlyBehavior

private let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
private let menuBar: CGFloat = 25

@Suite struct WorldTests {
    @Test func dockAtBottom() {
        let w = World(screenFrame: frame, visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 900 - 70 - menuBar))
        #expect(w.dock == .bottom)
        #expect(w.bottomY == 70)
        #expect(w.leftX == 0)
        #expect(w.rightX == 1440)
        #expect(w.topY == 875)
        let p = w.perchPoint(.bottom, near: CGPoint(x: 600, y: 400))
        #expect(p == CGPoint(x: 600, y: 70 + w.perchInset))
        let n = w.nearestPerch(to: CGPoint(x: 20, y: 500))
        #expect(n.perch == .left)
        #expect(abs(n.distance - (20 - Double(w.perchInset))) < 1e-9)
        #expect(w.nearestPerch(to: CGPoint(x: 700, y: 100)).perch == .bottom)
        #expect(w.nearestPerch(to: CGPoint(x: 1430, y: 500)).perch == .right)
        // Perches never reach into the menu bar.
        #expect(w.perchPoint(.left, near: CGPoint(x: 0, y: 899)).y <= 875)
    }

    @Test func dockLeft() {
        let w = World(screenFrame: frame, visibleFrame: CGRect(x: 64, y: 0, width: 1440 - 64, height: 900 - menuBar))
        #expect(w.dock == .left)
        #expect(w.leftX == 64)
        #expect(w.rightX == 1440)
        #expect(w.bottomY == 0)
        #expect(w.perchPoint(.left, near: CGPoint(x: 300, y: 400)).x == 64 + w.perchInset)
    }

    @Test func dockRight() {
        let w = World(screenFrame: frame, visibleFrame: CGRect(x: 0, y: 0, width: 1440 - 64, height: 900 - menuBar))
        #expect(w.dock == .right)
        #expect(w.rightX == 1376)
        #expect(w.leftX == 0)
        #expect(w.bottomY == 0)
        #expect(w.distance(to: .right, from: CGPoint(x: 1300, y: 400)) == 76)
    }

    @Test func dockHidden() {
        // Auto-hidden Dock leaves a ~4 pt inset; that must not count as a Dock.
        let w = World(screenFrame: frame, visibleFrame: CGRect(x: 0, y: 4, width: 1440, height: 900 - 4 - menuBar))
        #expect(w.dock == .hidden)
        #expect(w.bottomY == 0)
        #expect(w.leftX == 0 && w.rightX == 1440)
    }

    @Test func secondaryScreenOffsetOrigin() {
        let f = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let w = World(screenFrame: f, visibleFrame: CGRect(x: -1920, y: 280, width: 1920, height: 1080 - 80 - menuBar))
        #expect(w.dock == .bottom)
        #expect(w.bottomY == 280)
        #expect(w.leftX == -1920 && w.rightX == 0)
    }

    @Test func angleDiffWraps() {
        #expect(abs(angleDiff(0.1, 2 * .pi - 0.1) - 0.2) < 1e-9)
        #expect(abs(angleDiff(-3, 3) - (2 * .pi - 6)) < 1e-9)
    }
}

private func bottomDockWorld() -> World {
    World(screenFrame: frame, visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 900 - 70 - menuBar))
}

private func isAligned(_ c: FlyController) -> Bool {
    guard let perch = c.perch else { return false }
    switch perch {
    case .left, .right: return abs(abs(sin(c.heading)) - 1) < 1e-6
    case .bottom: return abs(abs(cos(c.heading)) - 1) < 1e-6
    }
}

@Suite struct ControllerTests {
    let dt = 1.0 / 60

    @Test func fastPointerApproachMakesPerchedFlyLeave() {
        let c = FlyController(world: bottomDockWorld(), brain: ScriptedBrain(seed: 7), seed: 7, startState: .perched)
        #expect(c.isPerched)
        let fly = c.position
        // Pointer far away for a moment, then sweeps in at ~1500 pt/s.
        var pointer = CGPoint(x: fly.x + 600, y: fly.y + 300)
        for _ in 0..<30 { c.update(pointer: pointer, dt: dt) }
        #expect(c.isPerched)
        let v = CGVector(dx: -1500 * 0.894, dy: -1500 * 0.447)
        var left: Double? = nil
        var t = 0.0
        while t < 0.5 {
            pointer.x += v.dx * dt; pointer.y += v.dy * dt
            c.update(pointer: pointer, dt: dt)
            t += dt
            if !c.isPerched { left = t; break }
        }
        #expect(left != nil, "fly should leave the perch within 0.5 s")
        // Escaping moves it away from the pointer.
        for _ in 0..<20 { c.update(pointer: pointer, dt: dt) }
        #expect(c.state == .escaping || c.state == .flying)
        #expect(hypot(c.position.x - pointer.x, c.position.y - pointer.y) > 150)
    }

    @Test func leftAloneItLandsAndStaysOnScreen() {
        let w = bottomDockWorld()
        let c = FlyController(world: w, brain: ScriptedBrain(seed: 3), seed: 3, startState: .flying)
        let pointer = CGPoint(x: 5000, y: 5000) // off screen, no threat
        var perches = Set<Perch>()
        var states = Set<FlyState>()
        for _ in 0..<(120 * 60) {
            let f = c.update(pointer: pointer, dt: dt)
            states.insert(f.state)
            #expect(w.screenFrame.contains(f.position))
            if let p = f.perch {
                perches.insert(p)
                #expect(isAligned(c))
                #expect(f.altitudeScale == 1)
            }
        }
        #expect(c.landings >= 1)
        #expect(!perches.isEmpty)
        #expect(states.contains(.flying))
        #expect(states.contains(.perched))
    }

    @Test func randomPointerNeverPushesFlyOffScreen() {
        for seed in UInt64(1)...4 {
            let w = World(screenFrame: frame, visibleFrame: CGRect(x: 64, y: 0, width: 1376, height: 875))
            let c = FlyController(world: w, brain: ScriptedBrain(seed: seed), seed: seed, startState: .flying)
            var rng = SeededRandom(seed: seed * 99)
            var pointer = CGPoint(x: 700, y: 400)
            var target = pointer
            for i in 0..<(60 * 60) {
                if i % 20 == 0 { target = CGPoint(x: rng.uniform(0, 1440), y: rng.uniform(0, 900)) }
                pointer.x += (target.x - pointer.x) * 0.3
                pointer.y += (target.y - pointer.y) * 0.3
                let f = c.update(pointer: pointer, dt: dt)
                #expect(w.screenFrame.contains(f.position))
                #expect(f.position.y <= w.topY)
            }
        }
    }

    @Test func perchedHeadingAlignedOnEveryEdge() {
        // Left alone, several seeds: whenever perched the heading is along the edge.
        var seen = Set<Perch>()
        for seed in UInt64(1)...6 {
            let c = FlyController(world: bottomDockWorld(), brain: ScriptedBrain(seed: seed), seed: seed, startState: .flying)
            var perchedFrames = 0
            for _ in 0..<(90 * 60) {
                c.update(pointer: CGPoint(x: -999, y: -999), dt: dt)
                if let perch = c.perch {
                    seen.insert(perch)
                    perchedFrames += 1
                    #expect(isAligned(c))
                    if perchedFrames > 30 {
                        // Side view with the feet (ventral side) pointing at the edge.
                        let s = sin(c.bodyRoll)
                        let vx = s * -sin(c.heading), vy = s * cos(c.heading)
                        let n = c.world.normal(of: perch)
                        #expect(-(vx * Double(n.dx) + vy * Double(n.dy)) > 0.9)
                    }
                } else {
                    perchedFrames = 0
                }
            }
        }
        #expect(seen.count >= 2, "expected landings on more than one perch, saw \(seen)")
    }

    @Test func posePhasesAdvance() {
        let c = FlyController(world: bottomDockWorld(), brain: ScriptedBrain(seed: 1), seed: 1, startState: .flying)
        var phases = Set<Int>()
        for _ in 0..<10 {
            let f = c.update(pointer: CGPoint(x: -999, y: -999), dt: dt)
            phases.insert(Int(f.pose.wingPhase * 10))
            #expect(f.altitudeScale > 1.2)
        }
        #expect(phases.count > 3)
    }
}

// MARK: - v4 friends (boids)

private final class RecordingBrain: Brain {
    var last = Percept()
    var command = MotorCommand(thrust: 0.5)
    func step(_ p: Percept, dt: Double) -> MotorCommand { last = p; return command }
    var activity: [String: Float] { [:] }
}

@Suite struct FlockTests {
    let dt = 1.0 / 60
    private func me(heading: Double = 0, leader: Bool = false) -> FlockNeighbor {
        FlockNeighbor(id: 0, position: CGPoint(x: 1000, y: 500), velocity: CGVector(dx: 500 * cos(heading), dy: 500 * sin(heading)),
                      heading: heading, airborne: true, isLeader: leader, size: 40)
    }

    @Test func aloneOrPerchedGivesNothing() {
        #expect(Boids.compute(self: me(), neighbors: []) == BoidsOutput())
        var grounded = me(); grounded.airborne = false
        let n = FlockNeighbor(id: 1, position: CGPoint(x: 1200, y: 600), airborne: true)
        #expect(Boids.compute(self: grounded, neighbors: [n]) == BoidsOutput())
        // Perched neighbours and neighbours beyond the visual radius or in the blind spot are not seen.
        let perched = FlockNeighbor(id: 1, position: CGPoint(x: 1200, y: 600), airborne: false)
        let far = FlockNeighbor(id: 2, position: CGPoint(x: 1500, y: 500), airborne: true)
        let behind = FlockNeighbor(id: 3, position: CGPoint(x: 800, y: 500), airborne: true)
        #expect(Boids.compute(self: me(), neighbors: [perched, far, behind]).seen == 0)
    }

    @Test func cohesionAlignmentAndSeparation() {
        // A neighbour ahead-left at 300 pt flying the same way: pull to the left, no separation, ratio ≥ 1.
        let n = FlockNeighbor(id: 1, position: CGPoint(x: 1200, y: 720), velocity: CGVector(dx: 500, dy: 0), heading: 0, airborne: true)
        let o = Boids.compute(self: me(), neighbors: [n])
        #expect(o.flockBearing > 0 && o.flockStrength > 0)
        #expect(o.separationStrength == 0)
        #expect(o.speedRatio > 1, "centroid ahead → catch up")
        // Same neighbour 40 pt to the right: separation points left (away), strong.
        let close = FlockNeighbor(id: 1, position: CGPoint(x: 1010, y: 460), velocity: CGVector(dx: 500, dy: 0), heading: 0, airborne: true)
        let s = Boids.compute(self: me(), neighbors: [close])
        #expect(s.separationStrength > 0.5)
        #expect(s.separationBearing > 0.5, "away from a neighbour on the right = to the left")
        // Head-on at 150 pt: predicted collision repels before the zone is entered.
        let head = FlockNeighbor(id: 1, position: CGPoint(x: 1150, y: 505), velocity: CGVector(dx: -500, dy: 0), heading: .pi, airborne: true)
        #expect(Boids.compute(self: me(), neighbors: [head]).separationStrength > 0)
    }

    @Test func leaderWeighsMore() {
        // Two neighbours symmetric left/right, heading up vs down; the leader one wins alignment + cohesion.
        let a = FlockNeighbor(id: 1, position: CGPoint(x: 1250, y: 800), velocity: CGVector(dx: 0, dy: 500), heading: .pi / 2, airborne: true, isLeader: true)
        let b = FlockNeighbor(id: 2, position: CGPoint(x: 1250, y: 200), velocity: CGVector(dx: 0, dy: -500), heading: -.pi / 2, airborne: true)
        #expect(Boids.compute(self: me(), neighbors: [a, b]).flockBearing > 0.2)
        var la = a; la.isLeader = false
        var lb = b; lb.isLeader = true
        #expect(Boids.compute(self: me(), neighbors: [la, lb]).flockBearing < -0.2)
    }

    @Test func controllerFillsPerceptOnlyWhenAirborneAndFlocking() {
        let w = bottomDockWorld()
        let brain = RecordingBrain()
        let c = FlyController(world: w, brain: brain, seed: 1, startState: .flying)
        let n = FlockNeighbor(id: 1, position: CGPoint(x: Double(c.position.x) + 250 * cos(c.heading + 0.8),
                                                       y: Double(c.position.y) + 250 * sin(c.heading + 0.8)),
                              velocity: c.velocity, heading: c.heading, airborne: true, isLeader: true)
        c.neighbors = [n]
        c.update(pointer: CGPoint(x: 5000, y: 5000), dt: dt)
        #expect(brain.last.flockStrength > 0 && brain.last.flockSpeedRatio > 0)
        c.flockingEnabled = false
        c.update(pointer: CGPoint(x: 5000, y: 5000), dt: dt)
        #expect(brain.last.flockStrength == 0 && brain.last.flockSpeedRatio == 0)
        // Perched fly: zero.
        let pb = RecordingBrain(); pb.command = MotorCommand()
        let p = FlyController(world: w, brain: pb, seed: 1, startState: .perched)
        p.neighbors = [n]
        p.update(pointer: CGPoint(x: 5000, y: 5000), dt: dt)
        #expect(pb.last.flockStrength == 0 && pb.last.separationStrength == 0)
        #expect(p.flockSelf.perchPoint == p.position && !p.flockSelf.airborne)
    }

    @Test func spacedPerchPointKeepsTwoBodyLengths() {
        let w = bottomDockWorld()
        let c = FlyController(world: w, brain: RecordingBrain(), seed: 1, startState: .flying)
        let site = w.perchSites.first { $0.side == .bottom }!
        let taken = w.perchPoint(on: site, near: CGPoint(x: 700, y: 0))
        c.neighbors = [FlockNeighbor(id: 1, position: taken, airborne: false, size: 40, perchPoint: taken)]
        let q = c.spacedPerchPoint(on: site, near: taken)!
        #expect(hypot(q.x - taken.x, q.y - taken.y) >= 2 * 40 - 1e-6)
        #expect(hypot(q.x - taken.x, q.y - taken.y) <= 2.5 * 40 + 8 + 1e-6, "shifted only as far as needed")
    }

    @Test func scriptedFlockStaysSpacedAndOnScreen() {
        let w = World(screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                      visibleFrame: CGRect(x: 0, y: 80, width: 2560, height: 1335))
        let sim = FlockSimulation.make(world: w, count: 4, seed: 2) { _, s in ScriptedBrain(seed: s) }
        var minD = Double.infinity
        for k in 0..<(60 * 60) {
            sim.step(pointer: CGPoint(x: 9999, y: 9999), dt: dt)
            let f = sim.flies
            for i in 0..<f.count { for j in (i + 1)..<f.count where f[i].isAirborne && f[j].isAirborne && k > 60 {
                minD = min(minD, Double(hypot(f[i].position.x - f[j].position.x, f[i].position.y - f[j].position.y)) / max(f[i].bodySize, f[j].bodySize))
            } }
        }
        #expect(minD >= 0.8, "min in-flight spacing \(minD) body lengths")
        #expect(sim.flies.allSatisfy { w.screenFrame.contains($0.position) })
        #expect(sim.flies[0].isLeader && !sim.flies[1].isLeader)
        #expect(sim.flies.dropFirst().allSatisfy { (34...36).contains($0.bodySize) })
    }
}

// MARK: - v5 window perches (module Q)

@Suite struct WindowBehaviorTests {
    /// One 1440×900 screen (Dock 70, menu bar 25) with one qualifying window.
    static let win = WindowInfo(id: 9, frame: CGRect(x: 300, y: 250, width: 600, height: 350))
    static func world(_ w: [WindowInfo] = [win]) -> World {
        World(screenFrame: frame, visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 900 - 70 - menuBar)).withWindows(w)
    }
    static func site(_ w: World, _ side: Perch) -> PerchSite { w.perchSites.first { $0.windowID == win.id && $0.side == side }! }

    @Test func windowSitesPerchOutsideTheWindow() {
        let w = Self.world()
        let c = FlyController(world: w, brain: ScriptedBrain(seed: 1), seed: 1)
        #expect(c.perchSite?.windowID == nil, "start perch is a screen site")
        for side in [Perch.bottom, .right, .left] {
            let s = Self.site(w, side)
            c.forcePerch(on: s, near: s.a)
            #expect(c.perch == side && c.frame.perch == side)
            #expect(!Self.win.frame.contains(c.position), "\(side): body outside the window")
            #expect(abs(angleDiff(c.heading, w.alignedHeading(side, closestTo: c.heading))) < 1e-9)
        }
    }

    @Test func perchedFlyRidesAMovingWindowAndScriptedBrainTakesOff() {
        var w = Self.world()
        let c = FlyController(world: w, brain: ScriptedBrain(seed: 2), seed: 2)
        let s = Self.site(w, .right)   // the window's left edge
        c.forcePerch(on: s, near: CGPoint(x: s.a.x, y: 400))
        let before = c.position
        let m = WindowInfo(id: Self.win.id, frame: Self.win.frame.offsetBy(dx: -30, dy: 20))
        w = w.withWindows([m]); c.world = w
        c.windowsChanged(moved: [m.id], removed: [])
        #expect(c.position == CGPoint(x: before.x - 30, y: before.y + 20))
        #expect(c.substrateJolt == 1)
        #expect(c.perchSite == Self.site(w, .right), "back on the moved window's real site")
        c.update(pointer: CGPoint(x: 5000, y: 5000), dt: 1.0 / 60)
        #expect(!c.isPerched, "jolt → takeoff")
        #expect(c.substrateJolt == 0)
    }

    @Test func windowCloseHoldsTheJoltUntilLiftoff() {
        let w = Self.world()
        let c = FlyController(world: w, brain: ScriptedBrain(seed: 3), seed: 3)
        c.forcePerch(on: Self.site(w, .bottom), near: CGPoint(x: 600, y: 700))
        let p = c.position
        c.world = Self.world([])
        #expect(c.position == p && c.isPerched, "stays where it is until it lifts off")
        c.update(pointer: CGPoint(x: 5000, y: 5000), dt: 1.0 / 60)
        #expect(!c.isPerched)
    }

    @Test func windowApproachComesFromTheOpenSide() {
        let w = Self.world()
        let c = FlyController(world: w, brain: ScriptedBrain(seed: 4), seed: 4, startState: .flying)
        let top = Self.site(w, .bottom)
        let goal = w.perchPoint(on: top, near: CGPoint(x: 600, y: 700))
        // From below the window: route around a corner first, no landing path.
        c.place(at: CGPoint(x: 600, y: 150))
        let wp = c.windowWaypoint(to: goal, around: Self.win.frame)!
        #expect(wp.y < Self.win.frame.minY && (wp.x < Self.win.frame.minX || wp.x > Self.win.frame.maxX))
        #expect(!c.hasLandingPath(to: goal, site: top))
        // From above: direct.
        c.place(at: CGPoint(x: 650, y: 780))
        #expect(c.windowWaypoint(to: goal, around: Self.win.frame) == nil)
        #expect(c.hasLandingPath(to: goal, site: top))
        // Left edge (perch outside, side .right) from the right of the window: around.
        let left = Self.site(w, .right)
        let g2 = w.perchPoint(on: left, near: CGPoint(x: 0, y: 400))
        c.place(at: CGPoint(x: 1100, y: 400))
        #expect(c.windowWaypoint(to: g2, around: Self.win.frame) != nil && !c.hasLandingPath(to: g2, site: left))
        let aim = c.targetAim(FlyController.PerchTarget(site: left, point: g2))
        #expect(!aim.visible && !Self.win.frame.contains(aim.point))
    }

    @Test func nearbyWindowMotionStartlesFarDoesNot() {
        let w = Self.world()
        let c = FlyController(world: w, brain: ScriptedBrain(seed: 5), seed: 5, startState: .flying)
        c.place(at: CGPoint(x: 1000, y: 400))   // 100 pt right of the window
        let m = WindowInfo(id: Self.win.id, frame: Self.win.frame.offsetBy(dx: 0, dy: 30))
        c.world = w.withWindows([m]); c.windowsChanged(moved: [m.id], removed: [])
        #expect(abs(c.windowMotionStartle - (1 - 100.0 / 150)) < 1e-6)
        c.place(at: CGPoint(x: 1300, y: 400))
        let c2 = FlyController(world: w, brain: ScriptedBrain(seed: 6), seed: 6, startState: .flying)
        c2.place(at: CGPoint(x: 1300, y: 400))
        c2.world = w.withWindows([m]); c2.windowsChanged(moved: [m.id], removed: [])
        #expect(c2.windowMotionStartle == 0)
    }
}
