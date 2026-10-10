import CoreGraphics
import Foundation
import Testing
import FlyCore
import FlyBrain
import FlyBehavior

/// v2 border anticipation and restlessness, with the real circuit.json driving the real FlyController.
private let circuitURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/FlyApp/Resources/circuit.json")

private func world() -> World {
    World(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
          visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 900 - 70 - 25))
}

private let dt = 1.0 / 60
private let farPointer = CGPoint(x: 5000, y: 5000)

private func median(_ xs: [Double]) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted(); return s[s.count / 2]
}

@Suite(.enabled(if: FileManager.default.fileExists(atPath: circuitURL.path)))
struct BorderAnticipationTests {
    /// 15 simulated minutes, no pointer: no clamping at the borders, soft touchdowns, and the
    /// visual_landing drive rises on τ (before contact), not only at contact.
    @Test func fifteenMinutesNoClampsSoftLandingsTauDrivenLanding() throws {
        let brain = try ConnectomeBrain(url: circuitURL, seed: 7)
        let c = FlyController(world: world(), brain: brain, seed: 7, startState: .flying)
        let landingMax = Double(brain.encoder.config.landingMax)
        var contact: [Double] = []
        var onsetTau: [Double] = []
        var driveNearTau: [Double] = [], driveFarTau: [Double] = []
        var activityAtTau05: [Double] = []
        var lastState = c.state
        var lastLandings = 0
        var crossed05 = false
        for _ in 0..<(15 * 60 * 60) {
            let pre = c.edgeSense()
            let tau = min(pre.tauL, pre.tauR)
            c.update(pointer: farPointer, dt: dt)
            let d = brain.encoder.lastDrive
            if c.state == .flying || c.state == .landing {
                let edge = Double(max(d.edgeLoomL, d.edgeLoomR))
                if tau < 0.5 { driveNearTau.append(edge) } else if tau > 1.5 { driveFarTau.append(edge) }
            }
            if c.state == .flying { crossed05 = false }
            if (c.state == .flying || c.state == .landing) && tau < 0.5 && !crossed05 {
                crossed05 = true
                activityAtTau05.append(Double(brain.activity["landing"] ?? 0))
            }
            if lastState == .flying && c.state == .landing { onsetTau.append(tau) }
            if c.landings > lastLandings { contact.append(c.lastContactSpeed); lastLandings = c.landings }
            lastState = c.state
        }
        let meanNear = driveNearTau.reduce(0, +) / Double(max(driveNearTau.count, 1))
        let meanFar = driveFarTau.reduce(0, +) / Double(max(driveFarTau.count, 1))
        print(String(format: "border 15min: clamps=%d landings=%d contact median=%.1f max=%.1f pt/s; onset τ median=%.2f s (n=%d, finite=%d); edge drive τ<0.5=%.2f τ>1.5=%.3f (landingMax %.1f); landing act @τ=0.5 median=%.2f",
                     c.borderClamps, c.landings, median(contact), contact.max() ?? -1, median(onsetTau.filter(\.isFinite)),
                     onsetTau.count, onsetTau.filter(\.isFinite).count, meanNear, meanFar, landingMax, median(activityAtTau05)))
        #expect(c.borderClamps == 0)
        #expect(c.landings >= 5)
        #expect((contact.max() ?? 999) < 80, "landing contact speed")
        #expect(meanNear > 0.5 * landingMax * exp(-0.5 / 0.4), "visual_landing drive rises as τ falls below 0.5 s")
        #expect(meanFar < 0.1 * landingMax)
        // Landing decisions happen on approach (finite τ), before contact.
        #expect(Double(onsetTau.filter(\.isFinite).count) >= 0.8 * Double(onsetTau.count))
    }

    /// Clamp-free across seeds, Dock layouts and perch insets, with startle escapes provoked every 20 s.
    @Test func noClampsAcrossSeedsWithEscapes() throws {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let worlds = [
            world(),
            World(screenFrame: frame, visibleFrame: CGRect(x: 0, y: 4, width: 1440, height: 900 - 4 - 25), perchInset: 22),
            World(screenFrame: frame, visibleFrame: CGRect(x: 64, y: 0, width: 1440 - 64, height: 900 - 25), perchInset: 16),
        ]
        var total = 0
        for (k, w) in worlds.enumerated() {
            for seed in UInt64(1)...4 {
                let brain = try ConnectomeBrain(url: circuitURL, seed: seed)
                let c = FlyController(world: w, brain: brain, seed: seed, startState: .flying)
                for f in 0..<(180 * 60) {
                    var ptr = farPointer
                    let phase = f % (20 * 60)
                    if phase < 30 {
                        let d = Double(30 - phase) * 20
                        ptr = CGPoint(x: c.position.x + CGFloat(d), y: c.position.y + CGFloat(d * 0.3))
                    }
                    c.update(pointer: ptr, dt: dt)
                }
                if c.borderClamps > 0 { print("world \(k) seed \(seed): clamps=\(c.borderClamps)") }
                total += c.borderClamps
            }
        }
        print("escape stress 3 worlds x 4 seeds x 180 s: clamps=\(total)")
        #expect(total == 0)
    }

    @Test func restlessSettingTakesOffMoreThanCalm() throws {
        func takeoffs(_ restlessness: Double) throws -> Int {
            var n = 0
            for seed in UInt64(1)...2 {
                let brain = try ConnectomeBrain(url: circuitURL, seed: seed)
                brain.setRestBout(DeweySettings(restlessness: restlessness).restBout)
                let c = FlyController(world: world(), brain: brain, seed: seed, startState: .perched)
                var was = true
                for _ in 0..<(10 * 60 * 60) {
                    let f = c.update(pointer: farPointer, dt: dt)
                    if was && f.perch == nil { n += 1 }
                    was = f.perch != nil
                }
            }
            return n
        }
        let calm = try takeoffs(0), restless = try takeoffs(1)
        print("restlessness 2x10min: takeoffs calm=\(calm) restless=\(restless)")
        #expect(restless > calm)
    }
}
