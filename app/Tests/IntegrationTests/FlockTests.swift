import CoreGraphics
import Foundation
import Testing
import FlyCore
import FlyBrain
import FlyBehavior

/// v4 friends: Dewey + 5 friends, each a full FlyController + ConnectomeBrain on the real circuit, flocking
/// through the brain's steering/thrust inputs (boids → Percept → SensoryEncoder → steer_dn / wing_mn).
private let circuitURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/FlyApp/Resources/circuit.json")
private let dt = 1.0 / 60
private let farPointer = CGPoint(x: 99999, y: 99999)
private let friendSizes = [34.0, 35.2, 34.6, 36.0, 35.6]   // 0.85–0.90 × 40

private func world4K() -> World {
    World(screenFrame: CGRect(x: 0, y: 0, width: 3840, height: 2160),
          visibleFrame: CGRect(x: 0, y: 93, width: 3840, height: 2160 - 93 - 25))
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

private func onSharedEdge(_ w: World, _ p: CGPoint, _ perch: Perch) -> Bool {
    let n = w.normal(of: perch)
    let k = w.perchInset + 3
    let beyond = CGPoint(x: p.x - n.dx * k, y: p.y - n.dy * k)
    let own = w.nearestScreen(to: p).id
    return w.screens.contains { $0.id != own && $0.frame.insetBy(dx: 1, dy: 1).contains(beyond) }
}

private func makeFlock(_ w: World, seed: UInt64, flocking: Bool) throws -> FlockSimulation {
    let circuit = try Circuit.load(url: circuitURL)
    let sim = FlockSimulation.make(world: w, count: 6, leaderSize: 40, sizes: friendSizes, seed: seed) { _, s in
        ConnectomeBrain(circuit: circuit, seed: s)
    }
    sim.setFlocking(flocking)
    return sim
}

private func median(_ a: [Double]) -> Double {
    guard !a.isEmpty else { return .nan }
    let s = a.sorted(); return s[s.count / 2]
}

struct FlockStats {
    /// Friend→Dewey distance samples while Dewey is airborne: friend airborne too / any friend state.
    var distAir: [Double] = []
    var distAll: [Double] = []
    var orderSum = 0.0, orderN = 0
    /// Min in-flight pairwise distance in body lengths (of the larger fly).
    var minFlight = Double.infinity
    /// Min distance between simultaneous perch points, in body lengths (of the larger fly).
    var minPerch = Double.infinity
    var landings: [Int] = []
    var clamps = 0
    var shared = 0
    var escapes = 0
    var saccades: [Int] = []
    var safeguards = 0
    var minFlightStates = ""
    var inRange = 0
    var order: Double { orderN > 0 ? orderSum / Double(orderN) : .nan }
}

private func simulate(_ sim: FlockSimulation, minutes: Double, pointer: (Double) -> CGPoint = { _ in farPointer }) -> FlockStats {
    var st = FlockStats()
    let w = sim.world
    let flies = sim.flies
    var last = flies.map(\.landings)
    let frames = Int(minutes * 3600)
    for k in 0..<frames {
        sim.step(pointer: pointer(Double(k) * dt), dt: dt)
        let lead = flies[0]
        if lead.isAirborne {
            for f in flies.dropFirst() {
                let d = Double(hypot(f.position.x - lead.position.x, f.position.y - lead.position.y))
                st.distAll.append(d)
                if f.isAirborne { st.distAir.append(d); if d < 400 { st.inRange += 1 } }
            }
        }
        let flying = flies.filter { $0.state == .flying }
        if flying.count >= 3 { st.orderSum += FlockSimulation.orderParameter(flying); st.orderN += 1 }
        for i in 0..<flies.count {
            for j in (i + 1)..<flies.count {
                let a = flies[i], b = flies[j]
                let d = Double(hypot(a.position.x - b.position.x, a.position.y - b.position.y)) / max(a.bodySize, b.bodySize)
                if a.isAirborne && b.isAirborne && k > 60 && d < st.minFlight {
                    st.minFlight = d; st.minFlightStates = "\(i):\(a.state.rawValue)/\(j):\(b.state.rawValue)@\(k / 60)s"
                }
                if a.isPerched && b.isPerched { st.minPerch = min(st.minPerch, d) }
            }
        }
        for (i, f) in flies.enumerated() where f.landings > last[i] {
            last[i] = f.landings
            if let p = f.perch, onSharedEdge(w, f.position, p) { st.shared += 1 }
        }
    }
    st.landings = flies.map(\.landings)
    st.clamps = flies.map(\.borderClamps).reduce(0, +)
    st.escapes = flies.map(\.escapes).reduce(0, +)
    st.saccades = flies.map(\.saccades)
    st.safeguards = flies.map(\.separationSafeguards).reduce(0, +)
    return st
}

private func describe(_ s: FlockStats) -> String {
    String(format: "inRange=%.2f minAt=%@ ", Double(s.inRange) / Double(max(s.distAir.count, 1)), s.minFlightStates) + String(format: "distAir med=%.0f distAll med=%.0f order=%.2f minFlight=%.2f BL minPerch=%.2f BL clamps=%d shared=%d escapes=%d safeguards=%d landings=%@ saccades=%@",
           median(s.distAir), median(s.distAll), s.order, s.minFlight, s.minPerch, s.clamps, s.shared, s.escapes, s.safeguards,
           "\(s.landings)", "\(s.saccades)")
}

@Suite(.enabled(if: FileManager.default.fileExists(atPath: circuitURL.path)))
struct FlockTests {
    /// A pointer looming at one fly of the flock (parked 350 pt away, then approaching it at 1500 pt/s) makes
    /// that fly escape, whether flying or perched; flock neighbours never cause escapes.
    @Test func loomingPointerAtFlock() throws {
        var hits = 0, trials = 0, others = 0
        for seed in UInt64(1)...3 {
            let sim = try makeFlock(world4K(), seed: seed, flocking: true)
            var pointer = farPointer
            var t = 0.0
            func run(_ seconds: Double) { for _ in 0..<Int(seconds * 60) { sim.step(pointer: pointer, dt: dt); t += dt } }
            run(15)
            for k in 0..<12 {
                let target = sim.flies[k % 6]
                let p = target.position
                // Park the pointer 350 pt away (toward the screen centre), still, so it does not loom.
                let c = CGPoint(x: sim.world.screenFrame.midX, y: sim.world.screenFrame.midY)
                let ang = atan2(Double(c.y - p.y), Double(c.x - p.x))
                // Keep the pointer at a fixed 350-pt offset from the target (no radial motion → no loom).
                for _ in 0..<30 {
                    let q = target.position
                    pointer = CGPoint(x: Double(q.x) + 350 * cos(ang), y: Double(q.y) + 350 * sin(ang))
                    sim.step(pointer: pointer, dt: dt); t += dt
                }
                let before = sim.flies.map(\.escapes)
                let wasAirborne = target.isAirborne
                for _ in 0..<36 {
                    let q = target.position
                    let dx = Double(q.x - pointer.x), dy = Double(q.y - pointer.y), d = max(hypot(dx, dy), 1)
                    let step = min(1500 * dt, max(d - 15, 0))
                    pointer = CGPoint(x: Double(pointer.x) + dx / d * step, y: Double(pointer.y) + dy / d * step)
                    sim.step(pointer: pointer, dt: dt); t += dt
                }
                let escaped = target.escapes > before[k % 6] || target.state == .escaping
                trials += 1; if escaped { hits += 1 }
                others += zip(sim.flies.map(\.escapes), before).enumerated().filter { $0.offset != k % 6 && $0.element.0 > $0.element.1 }.count
                print(String(format: "loom seed %d trial %d fly %d (%@): escaped=%@", seed, k, k % 6, wasAirborne ? "airborne" : "perched", escaped ? "yes" : "NO"))
                pointer = farPointer
                run(6)
            }
        }
        print("loom: \(hits)/\(trials) targeted flies escaped; \(others) other flies also escaped (near the pointer path)")
        #expect(hits == trials)
    }

    /// Dewey + 5 friends, 10 sim-min × 3 seeds, flocking ON vs OFF: friend→Dewey median distance (both
    /// airborne) < 350 pt ON / > 800 pt OFF; order parameter (≥ 3 flies flying) > 0.6 ON; in-flight spacing
    /// ≥ 0.8 body lengths; simultaneous perch points ≥ 2 body lengths apart; ≥ 5 landings per fly; no clamps,
    /// no shared-edge landings, no escapes without a pointer.
    @Test(arguments: ["user", "4K"])
    func flockOnVsOff(layout: String) throws {
        let w = layout == "user" ? userLayout() : world4K()
        for seed in UInt64(1)...3 {
            let on = simulate(try makeFlock(w, seed: seed, flocking: true), minutes: 10)
            let off = simulate(try makeFlock(w, seed: seed, flocking: false), minutes: 10)
            print("\(layout) seed \(seed) ON : \(describe(on))")
            print("\(layout) seed \(seed) OFF: \(describe(off))")
            #expect(median(on.distAir) < 350, "\(layout) seed \(seed)")
            #expect(median(off.distAir) > 800, "\(layout) seed \(seed)")
            #expect(on.order > 0.6, "\(layout) seed \(seed)")
            #expect(on.minFlight >= 0.8, "\(layout) seed \(seed)")
            #expect(on.minPerch >= 2 - 1e-6, "\(layout) seed \(seed)")
            #expect(on.landings.allSatisfy { $0 >= 5 }, "\(layout) seed \(seed)")
            #expect(on.clamps == 0 && off.clamps == 0, "\(layout) seed \(seed)")
            #expect(on.shared == 0 && off.shared == 0, "\(layout) seed \(seed)")
            #expect(on.escapes == 0 && off.escapes == 0, "\(layout) seed \(seed): escape without a pointer threat")
        }
    }
}
