import CoreGraphics
import Foundation
import Testing
import FlyCore
import FlyBrain
import FlyBehavior

/// v3: large screens, natural (saccadic) flight and perch seeking, with the real circuit.json driving the
/// real FlyController and no pointer.
private let circuitURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/FlyApp/Resources/circuit.json")
private let dt = 1.0 / 60
private let farPointer = CGPoint(x: 99999, y: 99999)

private func world4K() -> World {
    World(screenFrame: CGRect(x: 0, y: 0, width: 3840, height: 2160),
          visibleFrame: CGRect(x: 0, y: 93, width: 3840, height: 2160 - 93 - 25))
}
private func world5K() -> World {
    World(screenFrame: CGRect(x: 0, y: 0, width: 5120, height: 2880),
          visibleFrame: CGRect(x: 0, y: 93, width: 5120, height: 2880 - 93 - 25))
}
/// The user's setup: Dell 4K (Dock bottom) + laptop to its left, offset upward.
private func userLayout() -> World {
    World(screens: [
        ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 3840, height: 2160),
                   visibleFrame: CGRect(x: 0, y: 93, width: 3840, height: 2042)),
        ScreenInfo(id: 2, frame: CGRect(x: -1800, y: 991, width: 1800, height: 1169),
                   visibleFrame: CGRect(x: -1800, y: 991, width: 1800, height: 1131)),
    ])
}

/// Two 2560×1440 screens stacked (the upper one centred above), Dock on the lower one.
private func stackedLayout() -> World {
    World(screens: [
        ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                   visibleFrame: CGRect(x: 0, y: 80, width: 2560, height: 1440 - 80 - 25)),
        ScreenInfo(id: 2, frame: CGRect(x: 400, y: 1440, width: 1920, height: 1080),
                   visibleFrame: CGRect(x: 400, y: 1440, width: 1920, height: 1080 - 25)),
    ])
}

/// Whether a landing point (body centre) lies on an edge shared with another screen: the point just
/// beyond its perch line is inside another screen.
private func onSharedEdge(_ w: World, _ p: CGPoint, _ perch: Perch) -> Bool {
    let n = w.normal(of: perch)
    let k = w.perchInset + 3
    let beyond = CGPoint(x: p.x - n.dx * k, y: p.y - n.dy * k)
    let own = w.nearestScreen(to: p).id
    // Strictly inside (1 pt) the other screen: a site may end exactly where the shared interval starts.
    return w.screens.contains { $0.id != own && $0.frame.insetBy(dx: 1, dy: 1).contains(beyond) }
}

private struct RunStats {
    var landings = 0
    var clamps = 0
    var perches = Set<Perch>()
    var landingPoints: [CGPoint] = []
    var sharedLandings = 0
    var cells = Set<Int>()
    var screensVisited = Set<Int>()
    var crossings = 0
    var targetLandings = 0
    /// Landing points not on any perch site (should be none).
    var offSite = 0
}

/// Runs `minutes` of simulated time from flight; records landing points, perches and coverage of a 4×4 grid.
private func run(_ w: World, seed: UInt64, minutes: Double, configure: (FlyController) -> Void = { _ in }) throws
    -> (RunStats, FlyController) {
    let brain = try ConnectomeBrain(url: circuitURL, seed: seed)
    let c = FlyController(world: w, brain: brain, seed: seed, startState: .flying)
    configure(c)
    var s = RunStats()
    let box = w.boundingBox
    var lastLandings = 0
    var lastScreen = w.nearestScreen(to: c.position).id
    for _ in 0..<Int(minutes * 60 * 60) {
        let f = c.update(pointer: farPointer, dt: dt)
        if c.landings > lastLandings {
            lastLandings = c.landings
            s.landingPoints.append(f.position)
            let onSite = w.perchSites.contains { site in
                let q = w.perchPoint(on: site, near: f.position)
                return hypot(q.x - f.position.x, q.y - f.position.y) < 1
            }
            if !onSite { s.offSite += 1 }
            if let p = f.perch {
                s.perches.insert(p)
                if onSharedEdge(w, f.position, p) { s.sharedLandings += 1 }
            }
        }
        let gx = min(3, max(0, Int((f.position.x - box.minX) / box.width * 4)))
        let gy = min(3, max(0, Int((f.position.y - box.minY) / box.height * 4)))
        s.cells.insert(gy * 4 + gx)
        if c.isAirborne, let scr = w.screen(containing: f.position) {
            s.screensVisited.insert(scr.id)
            if scr.id != lastScreen { s.crossings += 1; lastScreen = scr.id }
        }
    }
    s.landings = c.landings
    s.clamps = c.borderClamps
    s.targetLandings = c.targetLandings
    return (s, c)
}

@Suite(.enabled(if: FileManager.default.fileExists(atPath: circuitURL.path)))
struct LargeScreenFlightTests {
    /// 4K (Dock bottom 93) and 5K, 10 sim-min × 3 seeds: ≥5 landings, left/right/bottom perches, no clamps;
    /// coverage of the 4K screen ≥ 60% of a 4×4 grid.
    @Test(arguments: [("4K", 0), ("5K", 1)])
    func largeScreenPerching(name: String, which: Int) throws {
        let w = which == 0 ? world4K() : world5K()
        for seed in UInt64(1)...3 {
            let (s, _) = try run(w, seed: seed, minutes: 10)
            print("\(name) seed \(seed): landings=\(s.landings) (on target \(s.targetLandings)) clamps=\(s.clamps) perches=\(s.perches.map(\.rawValue).sorted()) coverage=\(s.cells.count)/16")
            #expect(s.landings >= 5, "\(name) seed \(seed)")
            #expect(s.perches == [.left, .right, .bottom], "\(name) seed \(seed)")
            #expect(s.clamps == 0, "\(name) seed \(seed)")
            #expect(s.offSite == 0, "\(name) seed \(seed)")
            if which == 0 { #expect(s.cells.count >= 10, "4K coverage seed \(seed)") }
        }
    }

    /// 5 sim-min of continuous flight on 4K (perch seeking off): no constant yaw, saccade intervals
    /// spread, no sustained circling.
    @Test func naturalFlightStatistics() throws {
        for seed in UInt64(1)...3 {
            let brain = try ConnectomeBrain(url: circuitURL, seed: seed)
            let c = FlyController(world: world4K(), brain: brain, seed: seed, startState: .flying)
            c.flightBoutRange = 1e9...1e9
            var dHeading: [Double] = []   // per frame, flying only
            var saccadeTimes: [Double] = []
            var amplitudes: [Double] = []
            var lastSacc = 0, t = 0.0, lastH = c.heading, saccStartH = c.heading, wasIn = false
            var pathLen = 0.0, lastP = c.position
            for _ in 0..<(5 * 60 * 60) {
                c.update(pointer: farPointer, dt: dt)
                t += dt
                let dh = angleDiff(c.heading, lastH); lastH = c.heading
                pathLen += Double(hypot(c.position.x - lastP.x, c.position.y - lastP.y)); lastP = c.position
                if c.isAirborne { dHeading.append(dh) }
                if !c.isAirborne { saccadeTimes.append(-1) }  // flight broken: no interval across it
                if c.saccades > lastSacc { saccadeTimes.append(t); lastSacc = c.saccades; saccStartH = c.heading - dh }
                if wasIn && !c.inSaccade { amplitudes.append(abs(angleDiff(c.heading, saccStartH)) * 180 / .pi) }
                wasIn = c.inSaccade
            }
            // Sign flips of the 10-s mean yaw.
            let win = 600
            var signs: [Double] = []
            for k in stride(from: 0, to: dHeading.count - win + 1, by: win) {
                signs.append(dHeading[k..<(k + win)].reduce(0, +))
            }
            var flips = 0
            for k in 1..<signs.count where (signs[k] > 0) != (signs[k - 1] > 0) { flips += 1 }
            // Saccade interval CV.
            let iv = zip(saccadeTimes.dropFirst(), saccadeTimes).filter { $0 >= 0 && $1 >= 0 }.map { $0 - $1 }
            let m = iv.reduce(0, +) / Double(max(iv.count, 1))
            let sd = (iv.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(max(iv.count, 1))).squareRoot()
            let cv = sd / max(m, 1e-9)
            // Circling: |cumulative heading change| over any 20-s window.
            let w20 = 1200
            var run = dHeading.prefix(w20).reduce(0, +), worst = abs(run)
            if dHeading.count > w20 {
                for k in w20..<dHeading.count { run += dHeading[k] - dHeading[k - w20]; worst = max(worst, abs(run)) }
            }
            let meanYaw = dHeading.reduce(0, +) / Double(dHeading.count) / dt
            let sortedA = amplitudes.sorted()
            func q(_ f: Double) -> Double { sortedA.isEmpty ? .nan : sortedA[min(sortedA.count - 1, Int(f * Double(sortedA.count)))] }
            print(String(format: "flight seed %d: meanYaw=%.3f rad/s 10s-sign flips=%d saccades=%d interval mean=%.2f s CV=%.2f amplitude p10/p50/p90=%.0f/%.0f/%.0f deg worst 20s |Σdh|=%.1f rad (limit %.1f) path=%.0f pt clamps=%d",
                         seed, meanYaw, flips, c.saccades, m, cv, q(0.1), q(0.5), q(0.9), worst, 6 * Double.pi, pathLen, c.borderClamps))
            #expect(flips >= 3, "seed \(seed)")
            #expect(cv > 0.5, "seed \(seed)")
            #expect(c.saccades > 60, "seed \(seed): saccadic flight")
            #expect(worst < 6 * .pi, "seed \(seed): sustained circling")
            #expect(c.borderClamps == 0)
        }
    }

    /// Multi-screen, 10 sim-min × 3 seeds: the user's Dell 4K + offset laptop (Dell left edge shared for
    /// y > 991, laptop right edge fully shared), and two stacked screens: never lands on a shared edge,
    /// crosses screens, no clamps.
    @Test(arguments: ["user", "stacked"])
    func multiScreenSharedEdgesAndCrossing(layout: String) throws {
        let w = layout == "user" ? userLayout() : stackedLayout()
        for seed in UInt64(1)...3 {
            let (s, _) = try run(w, seed: seed, minutes: 10)
            var explicit = 0
            if layout == "user" {
                explicit = s.landingPoints.filter { p in abs(p.x) < 30 && (p.y > 991 || p.x < 0) }.count
            }
            print("\(layout) layout seed \(seed): landings=\(s.landings) (on target \(s.targetLandings)) offSite=\(s.offSite) clamps=\(s.clamps) crossings=\(s.crossings) screens=\(s.screensVisited.sorted()) perches=\(s.perches.map(\.rawValue).sorted()) sharedLandings=\(s.sharedLandings)+\(explicit)")
            #expect(s.sharedLandings == 0 && explicit == 0, "\(layout) seed \(seed): landed on a shared edge")
            #expect(s.offSite == 0, "\(layout) seed \(seed)")
            #expect(s.crossings >= 1, "\(layout) seed \(seed)")
            #expect(s.clamps == 0, "\(layout) seed \(seed)")
            #expect(s.landings >= 3, "\(layout) seed \(seed)")
        }
    }
}
