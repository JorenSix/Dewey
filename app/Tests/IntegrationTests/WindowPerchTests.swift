import CoreGraphics
import Foundation
import Testing
import FlyCore
import FlyBrain
import FlyBehavior

/// v5 window perches and window startle with the real circuit.json driving the real FlyController.
private let circuitURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/FlyApp/Resources/circuit.json")
private let dt = 1.0 / 60
private let farPointer = CGPoint(x: 99999, y: 99999)
private let friendSizes = [34.0, 35.2, 34.6, 36.0, 35.6]

/// The user's setup: Dell 4K (Dock bottom) + laptop to its left, offset upward.
private func userLayout() -> World {
    World(screens: [
        ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 3840, height: 2160),
                   visibleFrame: CGRect(x: 0, y: 93, width: 3840, height: 2042)),
        ScreenInfo(id: 2, frame: CGRect(x: -1800, y: 991, width: 1800, height: 1169),
                   visibleFrame: CGRect(x: -1800, y: 991, width: 1800, height: 1131)),
    ])
}
/// Two qualifying windows on the Dell (inset ≥ 10% from every side of its visible frame).
private let winA = WindowInfo(id: 101, frame: CGRect(x: 800, y: 600, width: 1400, height: 900), ownerPID: 7)
private let winB = WindowInfo(id: 202, frame: CGRect(x: 2400, y: 400, width: 1000, height: 700), ownerPID: 8)
private func windowWorld() -> World { userLayout().withWindows([winA, winB]) }

private func moved(_ w: WindowInfo, by d: CGVector) -> WindowInfo {
    WindowInfo(id: w.id, frame: w.frame.offsetBy(dx: d.dx, dy: d.dy), ownerPID: w.ownerPID)
}

private struct WindowRunStats {
    var landings = 0, windowLandings = 0, clamps = 0
    var sides = Set<Perch>()
    /// Window landings per orientation, counted through `FlyController.onLanded`: top / window-left / window-right.
    var top = 0, winLeft = 0, winRight = 0
    /// Window landings with the body inside the window (should be none).
    var inside = 0
    var aborts = 0, windowAborts = 0
    var counts: String { "top=\(top) left=\(winLeft) right=\(winRight)" }
    /// Window landings whose landing approach passed through the window (should be none).
    var throughWindow = 0
    /// Frames perched on a window site with the body off that site's perch line (should be none).
    var offSegment = 0
}

/// Runs one controller for `minutes` from flight, recording window landings.
private func runSolo(_ w: World, seed: UInt64, minutes: Double) throws -> WindowRunStats {
    let brain = try ConnectomeBrain(url: circuitURL, seed: seed)
    let c = FlyController(world: w, brain: brain, seed: seed, startState: .flying)
    var s = WindowRunStats()
    var log: [String] = []
    c.onLanded = { log.append(FlyController.landingDescription($0)) }
    var trail: [CGPoint] = []
    var last = 0
    for _ in 0..<Int(minutes * 3600) {
        c.update(pointer: farPointer, dt: dt)
        if c.state == .landing { trail.append(c.position) } else if c.isAirborne { trail.removeAll() }
        check(c, w, &s, &last, trail)
    }
    s.landings = c.landings; s.windowLandings = c.windowLandings; s.clamps = c.borderClamps
    s.aborts = c.landingAborts; s.windowAborts = c.windowLandingAborts
    tally(log, &s)
    return s
}

private func tally(_ log: [String], _ s: inout WindowRunStats) {
    s.top = log.filter { $0.hasPrefix("window") && $0.hasSuffix(" top") }.count
    s.winLeft = log.filter { $0.hasPrefix("window") && $0.hasSuffix(" left") }.count
    s.winRight = log.filter { $0.hasPrefix("window") && $0.hasSuffix(" right") }.count
}

private func check(_ c: FlyController, _ w: World, _ s: inout WindowRunStats, _ last: inout Int, _ trail: [CGPoint]) {
    if c.isPerched, let site = c.perchSite, site.windowID != nil {
        let q = w.perchPoint(on: site, near: c.position)
        if hypot(q.x - c.position.x, q.y - c.position.y) > 0.5 { s.offSegment += 1 }
    }
    guard c.landings > last else { return }
    last = c.landings
    guard let site = c.perchSite, let id = site.windowID, let win = w.windows.first(where: { $0.id == id }) else { return }
    s.sides.insert(site.side)
    if win.frame.contains(c.position) { s.inside += 1 }
    if trail.contains(where: { win.frame.insetBy(dx: 1, dy: 1).contains($0) }) { s.throughWindow += 1 }
}

private func brainFactory() throws -> (Int, UInt64) -> Brain {
    let circuit = try Circuit.load(url: circuitURL)
    return { _, s in ConnectomeBrain(circuit: circuit, seed: s) }
}

/// A perched controller on the real circuit, placed on window `id`'s site of `side`, settled for `settle` s.
private func perchedOnWindow(_ w: World, id: Int, side: Perch, seed: UInt64, settle: Double = 1) throws -> FlyController {
    let brain = try ConnectomeBrain(url: circuitURL, seed: seed)
    let c = FlyController(world: w, brain: brain, seed: seed, startState: .perched)
    let site = try #require(w.perchSites.first { $0.windowID == id && $0.side == side })
    c.forcePerch(on: site, near: CGPoint(x: (site.a.x + site.b.x) / 2, y: (site.a.y + site.b.y) / 2))
    for _ in 0..<Int(settle * 60) { c.update(pointer: farPointer, dt: dt) }
    return c
}

/// Frames (s) until the fly is no longer perched, up to `limit` s.
private func takeoffLatency(_ c: FlyController, limit: Double) -> Double? {
    var t = 0.0
    while t < limit - 1e-9 {
        c.update(pointer: farPointer, dt: dt)
        t += dt
        if !c.isPerched { return t }
    }
    return nil
}

@Suite(.enabled(if: FileManager.default.fileExists(atPath: circuitURL.path)))
struct WindowPerchTests {
    /// User layout + 2 qualifying windows, 10 sim-min × 3 seeds, Dewey alone: ≥ 3 window landings per seed,
    /// all three window orientations seen across seeds, approaches from the open side, perched flies stay on the
    /// segment, no clamps.
    @Test func deweyLandsOnWindows() throws {
        let w = windowWorld()
        #expect(w.windowSites.count == 6)
        var sides = Set<Perch>()
        for seed in UInt64(1)...3 {
            let s = try runSolo(w, seed: seed, minutes: 10)
            print("windows solo seed \(seed): landings=\(s.landings) window=\(s.windowLandings) [\(s.counts)] aborts=\(s.aborts) (window \(s.windowAborts)) through=\(s.throughWindow) inside=\(s.inside) offSegment=\(s.offSegment) clamps=\(s.clamps)")
            #expect(s.top + s.winLeft + s.winRight == s.windowLandings)
            #expect(s.inside == 0, "seed \(seed)")
            sides.formUnion(s.sides)
            #expect(s.windowLandings >= 3, "seed \(seed)")
            #expect(s.clamps == 0, "seed \(seed)")
            #expect(s.throughWindow == 0, "seed \(seed)")
            #expect(s.offSegment == 0, "seed \(seed)")
        }
        #expect(sides == [.left, .right, .bottom])
    }

    /// Dewey + 5 friends with the windows, 10 sim-min × 3 seeds: friends land on windows too, no clamps.
    @Test func flockLandsOnWindows() throws {
        let w = windowWorld()
        let make = try brainFactory()
        var flockSides = Set<Perch>()
        defer { #expect(flockSides == [.left, .right, .bottom]) }
        for seed in UInt64(1)...3 {
            let sim = FlockSimulation.make(world: w, count: 6, leaderSize: 40, sizes: friendSizes, seed: seed, brain: make)
            var logs = [[String]](repeating: [], count: 6)
            for (i, c) in sim.flies.enumerated() { c.onLanded = { logs[i].append(FlyController.landingDescription($0)) } }
            var stats = [WindowRunStats](repeating: WindowRunStats(), count: 6)
            var last = [Int](repeating: 0, count: 6)
            var trails = [[CGPoint]](repeating: [], count: 6)
            for _ in 0..<(10 * 3600) {
                sim.step(pointer: farPointer, dt: dt)
                for (i, c) in sim.flies.enumerated() {
                    if c.state == .landing { trails[i].append(c.position) } else if c.isAirborne { trails[i].removeAll() }
                    check(c, w, &stats[i], &last[i], trails[i])
                }
            }
            for i in 0..<6 { tally(logs[i], &stats[i]) }
            let win = sim.flies.map(\.windowLandings), all = sim.flies.map(\.landings)
            let inside = stats.map(\.inside).reduce(0, +)
            let aborts = sim.flies.map(\.landingAborts), wAborts = sim.flies.map(\.windowLandingAborts)
            print("windows flock seed \(seed): Dewey [\(stats[0].counts)] friends [top=\(stats.dropFirst().map(\.top).reduce(0, +)) left=\(stats.dropFirst().map(\.winLeft).reduce(0, +)) right=\(stats.dropFirst().map(\.winRight).reduce(0, +))] aborts=\(aborts) window aborts=\(wAborts) inside=\(inside)")
            for st in stats { flockSides.formUnion(st.sides) }
            #expect(win[0] >= 3, "seed \(seed): Dewey lands on windows with friends too")
            #expect(win.dropFirst().allSatisfy { $0 >= 3 }, "seed \(seed): every friend lands on windows")
            #expect(inside == 0, "seed \(seed)")
            let clamps = sim.flies.map(\.borderClamps).reduce(0, +)
            let through = stats.map(\.throughWindow).reduce(0, +), off = stats.map(\.offSegment).reduce(0, +)
            print("windows flock seed \(seed): window landings=\(win) of \(all) through=\(through) offSegment=\(off) clamps=\(clamps)")
            #expect(win.dropFirst().reduce(0, +) >= 3, "seed \(seed): friends land on windows")
            #expect(clamps == 0 && through == 0 && off == 0, "seed \(seed)")
        }
    }

    /// A fly perched on a window (each orientation) rides along when the window moves 50 pt and takes off within
    /// 0.3 s (substrate jolt through the brain): 3 seeds × 5 trials.
    @Test func windowMoveStartlesPerchedFly() throws {
        var latencies: [Double] = []
        var misses = 0
        let sides: [Perch] = [.bottom, .right, .left, .bottom, .right]
        for seed in UInt64(1)...3 {
            for k in 0..<5 {
                let w0 = windowWorld()
                let side = sides[k]
                let c = try perchedOnWindow(w0, id: winA.id, side: side, seed: seed * 10 + UInt64(k), settle: 0.5 + 0.4 * Double(k))
                try #require(c.isPerched && c.perchSite?.windowID == winA.id)
                let before = c.position
                let ang = Double(k) * 1.3 + Double(seed)
                let d = CGVector(dx: 50 * cos(ang), dy: 50 * sin(ang))
                c.world = w0.withWindows([moved(winA, by: d), winB])
                c.windowsChanged(moved: [winA.id], removed: [])
                // Kinematic attachment: the fly moved with the window (along-edge coordinate clamped to the site).
                let delta = CGVector(dx: c.position.x - before.x, dy: c.position.y - before.y)
                #expect(abs(delta.dx - d.dx) < 1e-6 && abs(delta.dy - d.dy) < 1e-6, "seed \(seed) trial \(k): carried \(delta) vs \(d)")
                let t = takeoffLatency(c, limit: 0.3)
                if let t { latencies.append(t) } else { misses += 1 }
                print(String(format: "move startle seed %d trial %d side %@: takeoff %@", seed, k, side.rawValue,
                             t.map { String(format: "%.3f s", $0) } ?? "NONE"))
            }
        }
        print(String(format: "move startle: %d/15 took off within 0.3 s, latency max %.3f s mean %.3f s", latencies.count,
                     latencies.max() ?? -1, latencies.reduce(0, +) / Double(max(latencies.count, 1))))
        #expect(misses == 0)
    }

    /// A drag (window moved 10 pt per frame): while the fly is still perched its position follows the window
    /// frame by frame (delta matches the window's).
    @Test func movingWindowCarriesPerchedFly() throws {
        for seed in UInt64(1)...3 {
            var w = windowWorld()
            let c = try perchedOnWindow(w, id: winB.id, side: .bottom, seed: seed)
            var win = winB
            var steps = 0
            for _ in 0..<20 where c.isPerched {
                let before = c.position
                win = moved(win, by: CGVector(dx: 10, dy: -6))
                w = w.withWindows([winA, win])
                c.world = w
                c.windowsChanged(moved: [win.id], removed: [])
                #expect(abs(c.position.x - before.x - 10) < 1e-6 && abs(c.position.y - before.y + 6) < 1e-6)
                c.update(pointer: farPointer, dt: dt)
                steps += 1
            }
            print("carry seed \(seed): rode \(steps) drag steps, total carry \(c.windowCarry), state \(c.state.rawValue)")
            #expect(!c.isPerched, "seed \(seed): the drag startles it off")
        }
    }

    /// Closing the window under a perched fly → takeoff within 0.3 s, from where it was.
    @Test func windowCloseStartlesPerchedFly() throws {
        for seed in UInt64(1)...3 {
            for side in [Perch.bottom, .right, .left] {
                let w = windowWorld()
                let c = try perchedOnWindow(w, id: winA.id, side: side, seed: seed)
                let before = c.position
                c.world = userLayout().withWindows([winB])
                c.windowsChanged(moved: [], removed: [winA.id])
                #expect(c.position == before)
                let t = takeoffLatency(c, limit: 0.3)
                print("close seed \(seed) side \(side.rawValue): takeoff \(t.map { String(format: "%.3f s", $0) } ?? "NONE")")
                #expect(t != nil, "seed \(seed) side \(side.rawValue)")
            }
        }
    }

    /// Moving an unrelated window far away (> 150 pt) causes no takeoff and no startle, for a fly on a window and
    /// one on the Dock.
    @Test func farWindowMoveDoesNotStartle() throws {
        for seed in UInt64(1)...3 {
            let w = windowWorld()
            let c = try perchedOnWindow(w, id: winA.id, side: .right, seed: seed)   // left edge of A, x ≈ 790
            let dockSite = try #require(w.perchSites.first { $0.windowID == nil && $0.side == .bottom && $0.screenID == 1 })
            let brain2 = try ConnectomeBrain(url: circuitURL, seed: seed + 100)
            let d = FlyController(world: w, brain: brain2, seed: seed + 100)
            d.forcePerch(on: dockSite, near: CGPoint(x: 400, y: 100))
            for _ in 0..<30 { d.update(pointer: farPointer, dt: dt) }
            for k in 0..<5 {
                let w2 = w.withWindows([winA, moved(winB, by: CGVector(dx: 50 * Double(k % 2 == 0 ? 1 : -1), dy: 0))])
                for f in [c, d] { f.world = w2; f.windowsChanged(moved: [winB.id], removed: []) }
                #expect(c.windowMotionStartle == 0 && c.substrateJolt == 0 && d.windowMotionStartle == 0)
                for _ in 0..<12 { c.update(pointer: farPointer, dt: dt); d.update(pointer: farPointer, dt: dt) }
                #expect(c.isPerched && d.isPerched, "seed \(seed) move \(k)")
            }
        }
    }

    /// A window moving right next to an airborne / nearby fly gives a visual startle ∝ proximity (weaker than the
    /// jolt): 0 beyond 150 pt.
    @Test func nearbyWindowMotionStartle() throws {
        let w = windowWorld()
        let brain = try ConnectomeBrain(url: circuitURL, seed: 3)
        let c = FlyController(world: w, brain: brain, seed: 3, startState: .flying)
        c.place(at: CGPoint(x: winA.frame.maxX + 60, y: winA.frame.midY))
        c.world = w.withWindows([moved(winA, by: CGVector(dx: 0, dy: 40)), winB])
        c.windowsChanged(moved: [winA.id], removed: [])
        print("nearby startle at 60 pt: \(c.windowMotionStartle)")
        #expect(abs(c.windowMotionStartle - 0.6) < 0.05)
    }

    /// A fly heading to land on a window that moves drops that target (no landing on stale geometry) and later
    /// lands on a current site.
    @Test func retargetWhenTargetWindowMoves() throws {
        var found = 0
        for seed in UInt64(1)...6 where found < 3 {
            var w = windowWorld()
            let brain = try ConnectomeBrain(url: circuitURL, seed: seed)
            let c = FlyController(world: w, brain: brain, seed: seed, startState: .flying)
            var frames = 0
            while frames < 10 * 3600, !(c.target?.site.windowID != nil || (c.state == .landing && c.perchPoint != nil
                    && w.windowSites.contains { FlyControllerTestGeometry.near(c.perchPoint!, $0, w) })) {
                c.update(pointer: farPointer, dt: dt); frames += 1
            }
            guard frames < 10 * 3600 else { continue }
            found += 1
            let staleSites = w.windowSites
            let id = c.target?.site.windowID ?? staleSites.first { FlyControllerTestGeometry.near(c.perchPoint!, $0, w) }!.windowID!
            let wasLanding = c.state == .landing
            let list = w.windows.map { $0.id == id ? moved($0, by: CGVector(dx: 50, dy: 50)) : $0 }
            w = w.withWindows(list)
            c.world = w
            c.windowsChanged(moved: [id], removed: [])
            let landingOnStale = c.state == .landing && staleSites.contains { $0.windowID == id && FlyControllerTestGeometry.near(c.perchPoint!, $0, w) }
            #expect(c.target?.site.windowID != id && !landingOnStale, "seed \(seed) state \(c.state) pp \(String(describing: c.perchPoint))")
            let before = c.landings
            var t = 0
            while c.landings == before && t < 5 * 3600 { c.update(pointer: farPointer, dt: dt); t += 1 }
            let site = try #require(c.perchSite)
            let stale = staleSites.contains(site) && !w.perchSites.contains(site)
            print("retarget seed \(seed): \(wasLanding ? "landing" : "target") on window \(id) moved → next landing after \(String(format: "%.1f", Double(t) / 60)) s on \(site.windowID.map { "window \($0)" } ?? "screen") \(site.side.rawValue)")
            #expect(!stale && w.perchSites.contains(site), "seed \(seed): landed on stale geometry")
        }
        #expect(found >= 3)
    }

    /// Friends are FlyControllers too: a friend perched on a window takes off when it moves.
    @Test func friendOnWindowIsStartled() throws {
        let w = windowWorld()
        let sim = FlockSimulation.make(world: w, count: 6, leaderSize: 40, sizes: friendSizes, seed: 4, brain: try brainFactory())
        for _ in 0..<60 { sim.step(pointer: farPointer, dt: dt) }
        let f = sim.flies[3]
        let site = try #require(w.perchSites.first { $0.windowID == winB.id && $0.side == .left })
        f.forcePerch(on: site, near: site.a)
        for _ in 0..<20 { sim.step(pointer: farPointer, dt: dt) }
        try #require(f.isPerched)
        sim.world = w.withWindows([winA, moved(winB, by: CGVector(dx: -50, dy: 0))])
        for c in sim.flies { c.windowsChanged(moved: [winB.id], removed: []) }
        var t = 0.0
        while f.isPerched && t < 0.3 { sim.step(pointer: farPointer, dt: dt); t += dt }
        print(String(format: "friend startle: took off after %.3f s", t))
        #expect(!f.isPerched)
    }
}

enum FlyControllerTestGeometry {
    /// Whether `p` is the body-centre perch point of a spot on `site`.
    static func near(_ p: CGPoint, _ site: PerchSite, _ w: World) -> Bool {
        let q = w.perchPoint(on: site, near: p)
        return hypot(q.x - p.x, q.y - p.y) < 1
    }
}
