import Foundation
import FlyCore
import SceneKit
import Testing
@testable import FlyBody

// Debug renders for tuning JointAnimator; they do nothing unless FLY_DEBUG_DIR is set.

/// FLY_DEBUG_POSES="label:joint=val;joint=val|label2:..." (absolute angles over rest-with-legs-at-0;
/// a joint name ending in * applies to all joints containing that prefix-free substring).
@Test func debugPoses() throws {
    guard let dir = ProcessInfo.processInfo.environment["FLY_DEBUG_DIR"],
          let spec = ProcessInfo.processInfo.environment["FLY_DEBUG_POSES"] else { return }
    let rig = try FlyRig(bundleDirectory: flyResources)
    let out = URL(fileURLWithPath: dir)
    for item in spec.split(separator: "|") {
        let parts = item.split(separator: ":", maxSplits: 1)
        rig.resetToRest()
        for n in rig.jointNames where n.contains("_T") { rig.setAngle(n, 0) }
        if parts.count > 1 {
            for kv in parts[1].split(separator: ";") {
                let p = kv.split(separator: "=")
                let key = String(p[0]), val = Double(p[1])!
                if key.hasSuffix("*") {
                    let sub = String(key.dropLast())
                    for n in rig.jointNames where n.contains(sub) { rig.setAngle(n, val, clamp: false) }
                } else { rig.setAngle(key, val, clamp: false) }
            }
        }
        let label = String(parts[0])
        try FlySnapshot.renderCurrent(rig: rig, size: CGSize(width: 320, height: 320), to: out.appendingPathComponent("\(label)_p_top.png"))
        try FlySnapshot.renderCurrent(rig: rig, size: CGSize(width: 320, height: 320), to: out.appendingPathComponent("\(label)_p_side.png"), cameraTilt: 1.45)
        try FlySnapshot.renderCurrent(rig: rig, size: CGSize(width: 320, height: 320), to: out.appendingPathComponent("\(label)_m_top.png"), cameraTilt: -1.45)
        try FlySnapshot.renderCurrent(rig: rig, size: CGSize(width: 320, height: 320), to: out.appendingPathComponent("\(label)_m_side.png"), cameraTilt: 3.0)
    }
}

/// FLY_DEBUG_BODYPOSES="label:wingStroke,wingPhase,walkPhase,walkAmount,groomPhase,groomAmount,legTuck,headYaw|..."
@Test func debugBodyPoses() throws {
    guard let dir = ProcessInfo.processInfo.environment["FLY_DEBUG_DIR"],
          let spec = ProcessInfo.processInfo.environment["FLY_DEBUG_BODYPOSES"] else { return }
    let rig = try FlyRig(bundleDirectory: flyResources)
    let out = URL(fileURLWithPath: dir)
    for item in spec.split(separator: "|") {
        let parts = item.split(separator: ":")
        let v = parts[1].split(separator: ",").map { Double($0)! } + Array(repeating: 0, count: 8)
        let pose = BodyPose(wingStroke: v[0], wingPhase: v[1], walkPhase: v[2], walkAmount: v[3],
                            groomPhase: v[4], groomAmount: v[5], legTuck: v[6], headYaw: v[7])
        let sz = CGSize(width: 320, height: 320)
        for (tag, tilt) in [("p_top", 0.25), ("p_side", 1.45), ("m_top", -1.45), ("m_side", 3.0)] {
            try FlySnapshot.renderPNG(rig: rig, pose: pose, size: sz, to: out.appendingPathComponent("\(parts[0])_\(tag).png"), cameraTilt: tilt)
        }
    }
}
