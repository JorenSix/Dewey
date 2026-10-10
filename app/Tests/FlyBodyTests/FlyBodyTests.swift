import Foundation
import FlyCore
import SceneKit
import Testing
@testable import FlyBody

/// FlyBody has no bundle resources of its own; the meshes live in the FlyApp target.
let flyResources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../Sources/FlyApp/Resources/fly").standardized
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../..").standardized

func nodeCount(_ n: SCNNode) -> Int { 1 + n.childNodes.reduce(0) { $0 + nodeCount($1) } }

@Test func rigLoads() throws {
    let rig = try FlyRig(bundleDirectory: flyResources)
    #expect(rig.bodyNames.count == 67)
    #expect(rig.jointNames.count == 102)
    #expect(nodeCount(rig.node) > 200)
    for leg in JointAnimator.legs {
        for part in ["coxa", "femur", "tibia", "tarsus"] {
            #expect(rig.bodyNode(named: "\(part)_\(leg)") != nil, "missing \(part)_\(leg)")
        }
        #expect(rig.joint(named: "coxa_\(leg)") != nil)
    }
    for side in ["left", "right"] {
        #expect(rig.bodyNode(named: "wing_\(side)") != nil)
        for j in ["yaw", "roll", "pitch"] { #expect(rig.joint(named: "wing_\(j)_\(side)") != nil) }
    }
    // Normalised to ~1 unit body length, facing +x.
    let (lo, hi) = rig.node.boundingBox
    #expect(hi.x - lo.x > 0.9 && hi.x - lo.x < 2.0)
    let head = rig.bodyNode(named: "head")!.simdConvertPosition(.zero, to: rig.node)
    let abdomen = rig.bodyNode(named: "abdomen_7")!.simdConvertPosition(.zero, to: rig.node)
    print("head origin", head, "abdomen_7 origin", abdomen, "bbox", lo, hi, "unitsPerCm", rig.unitsPerCm)
    #expect(head.x > 0.1 && abdomen.x < -0.1)
    // Legs hang below the body (dorsal = +y) and the left legs sit on -z.
    let claw = rig.bodyNode(named: "claw_T2_left")!
    JointAnimator(rig: rig).apply(.rest)
    let c = claw.simdConvertPosition(.zero, to: rig.node)
    #expect(c.y < 0 && c.z < 0)
}

@Test func applyMovesWings() throws {
    let rig = try FlyRig(bundleDirectory: flyResources)
    let anim = JointAnimator(rig: rig)
    let wing = rig.bodyNode(named: "wing_left")!
    anim.apply(.rest)
    let folded = wing.simdWorldOrientation
    anim.apply(BodyPose(wingStroke: 1, wingPhase: 0))
    let mid = wing.simdWorldOrientation
    anim.apply(BodyPose(wingStroke: 1, wingPhase: .pi / 2))
    let end = wing.simdWorldOrientation
    #expect(abs(simd_dot(folded.vector, mid.vector)) < 0.95)
    #expect(abs(simd_dot(mid.vector, end.vector)) < 0.95)
    #expect(rig.joint(named: "wing_yaw_left")!.angle != rig.joint(named: "wing_yaw_left")!.restAngle)
}

@Test func walkMovesTripods() throws {
    let rig = try FlyRig(bundleDirectory: flyResources)
    let anim = JointAnimator(rig: rig)
    anim.apply(BodyPose(walkPhase: .pi / 2, walkAmount: 1))
    let a = rig.joint(named: "femur_T1_left")!.angle, b = rig.joint(named: "femur_T1_right")!.angle
    #expect(a < b) // T1_left (tripod A) is lifted while T1_right is in stance
}

@Test func rendersPNGs() throws {
    let rig = try FlyRig(bundleDirectory: flyResources)
    let dir = repoRoot.appendingPathComponent("renders")
    let shots: [(String, BodyPose)] = [
        ("fly_rest", .rest),
        ("fly_flap_mid", BodyPose(wingStroke: 1, wingPhase: 0, legTuck: 1)),
        ("fly_walk_mid", BodyPose(walkPhase: .pi / 2, walkAmount: 1)),
    ]
    for (name, pose) in shots {
        let url = dir.appendingPathComponent("\(name).png")
        try FlySnapshot.renderPNG(rig: rig, pose: pose, size: CGSize(width: 512, height: 512), to: url)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(size > 10_000, "\(name).png too small")
    }
}
