import CoreGraphics
import Foundation
import Testing
import FlyCore
import FlyBrain
import FlyBehavior

/// The real `circuit.json` driving the real `FlyController`: the end-to-end behaviour checks from TASKS.md.
private let circuitURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/FlyApp/Resources/circuit.json")

private func world() -> World {
    World(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
          visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 900 - 70 - 25))
}

private let dt = 1.0 / 60

@Suite(.enabled(if: FileManager.default.fileExists(atPath: circuitURL.path)))
struct ConnectomeFlyTests {
    @Test func loomingPointerMakesPerchedFlyEscape() throws {
        for seed in UInt64(1)...5 {
            let brain = try ConnectomeBrain(url: circuitURL, seed: seed)
            let c = FlyController(world: world(), brain: brain, seed: seed, startState: .perched)
            var pointer = CGPoint(x: c.position.x + 600, y: c.position.y + 300)
            for _ in 0..<60 { c.update(pointer: pointer, dt: dt) }
            #expect(c.isPerched, "seed \(seed): still pointer should not scare the fly")
            let dir = CGVector(dx: c.position.x - pointer.x, dy: c.position.y - pointer.y)
            let len = hypot(dir.dx, dir.dy)
            var left: Double?
            var t = 0.0
            while t < 0.6 {
                pointer.x += dir.dx / len * 1500 * dt; pointer.y += dir.dy / len * 1500 * dt
                c.update(pointer: pointer, dt: dt)
                t += dt
                if !c.isPerched { left = t; break }
            }
            #expect(left != nil, "seed \(seed): looming pointer should trigger takeoff")
            print("escape seed=\(seed) t=\(left.map { String(format: "%.3f", $0) } ?? "none") GF=\(brain.activity["GF"] ?? -1)")
        }
    }

    @Test func leftAloneItVisitsLeftRightAndBottomPerches() throws {
        let w = world()
        var perches = Set<Perch>()
        var landings = 0
        var takeoffs = 0
        for seed in UInt64(1)...3 {
            let c = FlyController(world: w, brain: try ConnectomeBrain(url: circuitURL, seed: seed), seed: seed, startState: .flying)
            var wasPerched = false
            for _ in 0..<(300 * 60) {
                let f = c.update(pointer: CGPoint(x: 5000, y: 5000), dt: dt)
                #expect(w.screenFrame.contains(f.position))
                if let p = f.perch { perches.insert(p) }
                if wasPerched && f.perch == nil { takeoffs += 1 }
                wasPerched = f.perch != nil
            }
            landings += c.landings
        }
        print("idle 3x300s: landings=\(landings) spontaneous takeoffs=\(takeoffs) perches=\(perches.map(\.rawValue).sorted())")
        #expect(perches == [.left, .right, .bottom])
        #expect(takeoffs >= 3, "a perched fly should take off again by itself now and then")
    }

    @Test func stepCostWithRealCircuit() throws {
        let brain = try ConnectomeBrain(url: circuitURL, seed: 1)
        let c = FlyController(world: world(), brain: brain, seed: 1, startState: .flying)
        let n = 600
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<n { c.update(pointer: CGPoint(x: Double(i), y: 400), dt: dt) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6 / Double(n)
        print(String(format: "frame cost (brain+behaviour) = %.3f ms", ms))
    }
}
