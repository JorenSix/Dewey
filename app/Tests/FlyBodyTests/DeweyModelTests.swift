import Foundation
import FlyCore
import SceneKit
import Testing
@testable import FlyBody

/// Dewey: the procedural Blender model (pipeline/blender/build_dewey.py) in the flybody body.json format.
let deweyResources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../Sources/FlyApp/Resources/dewey").standardized

private func triangleCount(_ n: SCNNode) -> Int {
    let own = n.geometry?.elements.reduce(0) { $0 + ($1.primitiveType == .triangles ? $1.primitiveCount : 0) } ?? 0
    return own + n.childNodes.reduce(0) { $0 + triangleCount($1) }
}

@Test func deweyRigLoadsWithFlybodyBodiesAndJoints() throws {
    let dewey = try FlyRig(bundleDirectory: deweyResources)
    let fly = try FlyRig(bundleDirectory: flyResources)
    #expect(Set(dewey.bodyNames) == Set(fly.bodyNames))
    #expect(dewey.jointNames == fly.jointNames)
    for name in fly.jointNames {
        let a = try #require(dewey.joint(named: name)), b = try #require(fly.joint(named: name))
        #expect(a.body == b.body && a.axis == b.axis && a.range == b.range && a.restAngle == b.restAngle, "\(name)")
    }
    // Every joint JointAnimator drives exists.
    var used = ["head_abduct", "haltere_left", "haltere_right"]
    for side in ["left", "right"] { for j in ["yaw", "roll", "pitch"] { used.append("wing_\(j)_\(side)") } }
    for leg in JointAnimator.legs { for j in JointAnimator.legJoints { used.append("\(j)_\(leg)") } }
    for name in used { #expect(dewey.joint(named: name) != nil, "missing joint \(name)") }
    // Same normalisation as flybody: ~1 unit long, head forward (+x), legs below (-y), left legs on -z.
    let (lo, hi) = dewey.node.boundingBox
    #expect(hi.x - lo.x > 0.9 && hi.x - lo.x < 2.2)
    let head = dewey.bodyNode(named: "head")!.simdConvertPosition(.zero, to: dewey.node)
    #expect(head.x > 0.1)
    JointAnimator(rig: dewey).apply(.rest)
    let claw = dewey.bodyNode(named: "claw_T2_left")!.simdConvertPosition(.zero, to: dewey.node)
    #expect(claw.y < 0 && claw.z < 0)
    print("dewey unitsPerCm", dewey.unitsPerCm, "flybody unitsPerCm", fly.unitsPerCm, "bbox", lo, hi)
}

@Test func deweyBudget() throws {
    let dewey = try FlyRig(bundleDirectory: deweyResources)
    let tris = triangleCount(dewey.node)
    let files = try FileManager.default.contentsOfDirectory(at: deweyResources, includingPropertiesForKeys: [.fileSizeKey])
    let bytes = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    print("dewey triangles", tris, "folder bytes", bytes)
    #expect(tris > 10_000 && tris <= 40_000)
    #expect(bytes <= 8_000_000)
}

@Test func deweyRenders() throws {
    let dewey = try FlyRig(bundleDirectory: deweyResources)
    let fly = try FlyRig(bundleDirectory: flyResources)
    let dir = repoRoot.appendingPathComponent("renders/v2")
    let size = CGSize(width: 512, height: 512)
    let shots: [(String, BodyPose)] = [
        ("rest", .rest),
        ("flap", BodyPose(wingStroke: 1, wingPhase: 0, legTuck: 1)),
        ("walk", BodyPose(walkPhase: .pi / 2, walkAmount: 1)),
        ("groom", BodyPose(groomPhase: 0, groomAmount: 1)),
    ]
    for (name, pose) in shots {
        let url = dir.appendingPathComponent("E_scn_\(name).png")
        try FlySnapshot.renderPNG(rig: dewey, pose: pose, size: size, to: url)
        let bytes = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(bytes > 10_000, "E_scn_\(name).png too small")
    }
    // Same camera, flybody, for side-by-side comparison; plus an oblique (3/4) view of both.
    try FlySnapshot.renderPNG(rig: fly, pose: .rest, size: size, to: dir.appendingPathComponent("E_scn_flybody_rest.png"))
    try FlySnapshot.renderPNG(rig: dewey, pose: .rest, size: size, to: dir.appendingPathComponent("E_scn_rest_34.png"), cameraTilt: 0.95)
    try FlySnapshot.renderPNG(rig: fly, pose: .rest, size: size, to: dir.appendingPathComponent("E_scn_flybody_rest_34.png"), cameraTilt: 0.95)
}
