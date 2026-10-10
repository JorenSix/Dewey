import AppKit
import SceneKit
import FlyCore
import FlyBody
import simd

/// The flybody mesh rig as a `FlyRenderable`.
///
/// `FlyRig.node` is y-up (+x forward, +y dorsal, +z fly's right, ~1 unit long); the overlay wants
/// +x forward, +y fly's left, +z dorsal in screen points, so rotate +π/2 about x and scale to `length`.
@MainActor
final class RigFly: FlyRenderable {
    let node = SCNNode()
    private let rig: FlyRig
    private let animator: JointAnimator
    let bodyLength: CGFloat
    private(set) var footPoints: [simd_double3] = []

    init(bundleDirectory: URL, length: CGFloat = 38) throws {
        rig = try FlyRig(bundleDirectory: bundleDirectory)
        animator = JointAnimator(rig: rig)
        rig.node.eulerAngles = SCNVector3(CGFloat.pi / 2, 0, 0)
        node.scale = SCNVector3(length, length, length)
        node.addChildNode(rig.node)
        bodyLength = length
        animator.apply(.rest)
        footPoints = RigFly.measureFeet(rig: rig, node: node)
    }

    /// Tarsal-claw centres in the current (standing) pose, in `node`'s parent space. If FlyBody grows a
    /// `footContactOffset`, this is the empirical equivalent: max(-z) / length.
    private static func measureFeet(rig: FlyRig, node: SCNNode) -> [simd_double3] {
        var out: [simd_double3] = []
        for leg in JointAnimator.legs {
            guard let claw = rig.bodyNode(named: "claw_\(leg)") else { continue }
            let mesh = claw.childNodes.first { $0.geometry != nil } ?? claw
            let (lo, hi) = mesh.boundingBox
            let local = (simd_float3(lo) + simd_float3(hi)) / 2
            let inNode = node.simdConvertPosition(local, from: mesh)
            let p = node.simdTransform * simd_float4(inNode, 1)
            out.append(simd_double3(Double(p.x), Double(p.y), Double(p.z)))
        }
        return out
    }

    func apply(frame: FlyFrame) {
        animator.apply(frame.pose)
    }
}
