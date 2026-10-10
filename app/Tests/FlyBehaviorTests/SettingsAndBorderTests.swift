import CoreGraphics
import Foundation
import Testing
import FlyCore
@testable import FlyBehavior

private func freshDefaults(_ name: String) -> UserDefaults {
    let suite = "dewey.tests.\(name).\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
}

@Suite struct SettingsStoreTests {
    @Test func defaultsWhenEmptyOrCorrupt() {
        let d = freshDefaults("empty")
        let store = SettingsStore(defaults: d)
        #expect(store.load() == DeweySettings())
        d.set("{not json", forKey: SettingsStore.key)
        #expect(store.load() == DeweySettings())
        d.set(42, forKey: SettingsStore.key)
        #expect(store.load() == DeweySettings())
    }

    @Test func roundTripAsJSONString() throws {
        let d = freshDefaults("roundtrip")
        let s = DeweySettings(size: 77, restlessness: 0.8, visible: false)
        SettingsStore(defaults: d).save(s)
        // A fresh store on the same defaults (= relaunch) reads it back.
        #expect(SettingsStore(defaults: d).load() == s)
        let raw = try #require(d.string(forKey: "settings"))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        #expect(obj["size"] as? Double == 77)
        #expect(obj["visible"] as? Bool == false)
    }

    @Test func clampsOnSaveAndLoad() {
        let d = freshDefaults("clamp")
        let store = SettingsStore(defaults: d)
        store.save(DeweySettings(size: 500, restlessness: -3, visible: true))
        #expect(store.load() == DeweySettings(size: 120, restlessness: 0, visible: true))
        d.set(#"{"size":5,"restlessness":7,"visible":true}"#, forKey: SettingsStore.key)
        #expect(store.load() == DeweySettings(size: 20, restlessness: 1, visible: true))
        let nan = SettingsStore.clamped(DeweySettings(size: .nan, restlessness: .infinity))
        #expect(nan.size == 40 && nan.restlessness == 0.5)
    }

    @Test func friendsRoundTrip() throws {
        let d = freshDefaults("friends")
        let s = DeweySettings(size: 50, restlessness: 0.3, visible: true, friends: 4)
        SettingsStore(defaults: d).save(s)
        #expect(SettingsStore(defaults: d).load() == s)
        let raw = try #require(d.string(forKey: "settings"))
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        #expect(obj["friends"] as? Int == 4)
    }

    @Test func friendsClamped() {
        let d = freshDefaults("friendsclamp")
        let store = SettingsStore(defaults: d)
        store.save(DeweySettings(friends: -3))
        #expect(store.load().friends == 0)
        store.save(DeweySettings(friends: 9))
        #expect(store.load().friends == 5)
        d.set(#"{"friends":-3,"restlessness":0.5,"size":40,"visible":true}"#, forKey: SettingsStore.key)
        #expect(store.load().friends == 0)
        d.set(#"{"friends":9,"restlessness":0.5,"size":40,"visible":true}"#, forKey: SettingsStore.key)
        #expect(store.load().friends == 5)
        #expect(SettingsStore.clamped(DeweySettings(friends: 3)).friends == 3)
    }

    @Test func legacyJSONWithoutFriendsLoadsZero() {
        let d = freshDefaults("legacyfriends")
        d.set(#"{"restlessness":0.2,"size":60,"visible":false}"#, forKey: SettingsStore.key)
        #expect(SettingsStore(defaults: d).load() == DeweySettings(size: 60, restlessness: 0.2, visible: false, friends: 0))
    }

    @Test func migrationUnaffectedByFriends() {
        let legacy = freshDefaults("legacydomain")
        legacy.set(#"{"restlessness":0.7,"size":30,"visible":true}"#, forKey: SettingsStore.key)
        let d = freshDefaults("migrated")
        let store = SettingsStore(defaults: d)
        #expect(store.migrate(from: legacy))
        #expect(store.load() == DeweySettings(size: 30, restlessness: 0.7, visible: true, friends: 0))
        // Existing settings (with friends) are never overwritten by a second migration.
        store.save(DeweySettings(size: 30, restlessness: 0.7, visible: true, friends: 2))
        #expect(!store.migrate(from: legacy))
        #expect(store.load().friends == 2)
    }

    @Test func restBoutMappingIsMonotonic() {
        var prev: ClosedRange<Double>? = nil
        for i in 0...20 {
            let r = DeweySettings(restlessness: Double(i) / 20).restBout
            #expect(r.lowerBound > 0 && r.lowerBound <= r.upperBound)
            if let p = prev {
                #expect(r.lowerBound < p.lowerBound && r.upperBound < p.upperBound, "more restless → shorter bouts")
            }
            prev = r
        }
        #expect(DeweySettings(restlessness: 0).restBout == 60...180)
        #expect(DeweySettings(restlessness: 1).restBout == 8...25)
    }

    @Test func scriptedBrainRestlessnessChangesTakeoffs() {
        func takeoffs(_ r: Double) -> Int {
            let w = World(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                          visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805))
            let b = ScriptedBrain(seed: 2)
            b.setRestBout(DeweySettings(restlessness: r).restBout)
            let c = FlyController(world: w, brain: b, seed: 2, startState: .perched)
            var n = 0, was = true
            for _ in 0..<(300 * 60) {
                let f = c.update(pointer: CGPoint(x: 5000, y: 5000), dt: 1.0 / 60)
                if was && f.perch == nil { n += 1 }
                was = f.perch != nil
            }
            return n
        }
        let calm = takeoffs(0), restless = takeoffs(1)
        #expect(restless > calm, "calm=\(calm) restless=\(restless)")
    }
}

@Suite struct BorderSenseTests {
    let w = World(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                  visibleFrame: CGRect(x: 0, y: 70, width: 1440, height: 805))

    @Test func rayCastHitsDockTopAndMenuBar() {
        let down = w.castBorderRay(from: CGPoint(x: 700, y: 400), angle: -.pi / 2)
        #expect(down.border == .bottom && abs(down.distance - 330) < 1e-9)
        let up = w.castBorderRay(from: CGPoint(x: 700, y: 400), angle: .pi / 2)
        #expect(up.border == .top && abs(up.distance - 475) < 1e-9)
        let left = w.castBorderRay(from: CGPoint(x: 100, y: 400), angle: .pi)
        #expect(left.border == .left && abs(left.distance - 100) < 1e-9)
        // Over the Dock the flight bound is the floor.
        #expect(w.castBorderRay(from: CGPoint(x: 700, y: 40), angle: -.pi / 2).distance < 40)
    }

    @Test func perchInsetSettableAndApplied() {
        var w2 = World(screenFrame: w.screenFrame, visibleFrame: w.visibleFrame, perchInset: 18)
        let y = Double(w2.perchPoint(.bottom, near: CGPoint(x: 600, y: 300)).y)
        #expect(abs(y - 88) < 1e-9, "y=\(y) bottomY=\(w2.bottomY)")
        w2.perchInset = 25
        #expect(w2.perchPoint(.left, near: CGPoint(x: 300, y: 400)).x == 25)
    }

    @Test func timeToContactPerHemifield() {
        let c = FlyController(world: w, brain: ScriptedBrain(seed: 1), seed: 1, startState: .flying)
        // Flying: τ is finite toward the border it closes on, +inf when flying parallel/away is not checked here.
        for _ in 0..<5 { c.update(pointer: CGPoint(x: 5000, y: 5000), dt: 1.0 / 60) }
        let p = c.makePercept(pointer: CGPoint(x: 5000, y: 5000))
        #expect(p.airborne)
        #expect(p.edgeTimeToContactLeft.isFinite || p.edgeTimeToContactRight.isFinite)
        #expect(p.edgeClosingSpeed >= 0)
        let perched = FlyController(world: w, brain: ScriptedBrain(seed: 1), seed: 1, startState: .perched)
        let q = perched.makePercept(pointer: .zero)
        #expect(q.edgeTimeToContactLeft == .infinity && q.edgeTimeToContactRight == .infinity && q.edgeClosingSpeed == 0)
    }

    @Test func frameRollAndPitchBounded() {
        for seed in UInt64(1)...3 {
            let c = FlyController(world: w, brain: ScriptedBrain(seed: seed), seed: seed, startState: .flying)
            var sawBank = false, sawTakeoffPitch = false, sawFlare = false
            for _ in 0..<(120 * 60) {
                let f = c.update(pointer: CGPoint(x: 5000, y: 5000), dt: 1.0 / 60)
                #expect(f.roll.isFinite && f.pitch.isFinite)
                #expect(f.pitch >= -0.01 && f.pitch <= 0.5)
                if f.perch == nil && f.state != .landing && f.state != .takingOff {
                    if abs(f.roll) > 0.05 { sawBank = true }
                }
                if f.state == .flying || f.state == .escaping { #expect(abs(f.roll) <= 0.6 + 1e-9 || c.bodyRoll == f.roll) }
                if f.state == .takingOff && f.pitch > 0.1 { sawTakeoffPitch = true }
                if f.state == .landing && f.pitch > 0.15 { sawFlare = true }
                #expect(f.roll == c.bodyRoll && f.pitch == c.bodyPitch)
            }
            #expect(sawBank)
            #expect(sawTakeoffPitch)
            #expect(sawFlare)
            #expect(c.borderClamps == 0, "seed \(seed) clamps \(c.borderClamps)")
        }
    }
}
