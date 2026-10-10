import AppKit
import SceneKit
import simd

/// Motion-blur stand-ins for the beating wings.
///
/// A real fly beats its wings at ~200 Hz; rendered at ≤ 60 fps a single wing would look frozen or
/// strobe. For each wing this adds `count` "ghost" copies of the wing meshes, posed at earlier stroke
/// phases (phase − k·Δ, k = 1…count, together spanning half a wingbeat) with falling alpha, plus a faint
/// fan-shaped disc covering the stroke plane between the two stroke reversals.
///
/// The ghosts hang under a sibling of the wing body node with the identical fixed transform, so they
/// follow the thorax exactly; geometry is shared with the real wing (only the material differs) and
/// there is one material per alpha level, shared by both wings. Hidden below `wingStroke` 0.3.
public final class WingGhosts {
    /// Ghost copies per wing.
    public static let count = 4
    /// Phase spanned by all ghosts (half a wingbeat), so Δ = span / count.
    public static let span = Double.pi
    public static var delta: Double { span / Double(count) }
    /// Ghost k (1…count) alpha: 0.22·(1 − (k−1)/count) → 0.22, 0.165, 0.11, 0.055. Kept faint so the
    /// in-between wings read as motion blur without hiding the body.
    public static func alpha(_ k: Int) -> Double { 0.22 * (1 - Double(k - 1) / Double(count)) }
    /// Blur-disc alpha at full stroke.
    public static let discAlpha = 0.05
    /// Below this wingStroke the ghosts and the disc are hidden.
    public static let minStroke = 0.3

    struct Side {
        let name: String
        let body: FlyRig.BodyNode
        let root: SCNNode
        let ghosts: [SCNNode]   // one joint-frame node per ghost (index k-1)
        let disc: SCNNode
    }

    let sides: [Side]
    /// One material per alpha level (index k-1), shared by both wings.
    public let materials: [SCNMaterial]
    public let discMaterial: SCNMaterial

    /// All ghost mesh nodes (both wings).
    public var ghostMeshNodes: [SCNNode] { sides.flatMap { $0.ghosts.flatMap(\.childNodes) } }
    /// The ghost joint-frame nodes per side ("left"/"right"), ordered k = 1…count.
    public func ghostNodes(side: String) -> [SCNNode] { sides.first { $0.name == side }?.ghosts ?? [] }
    public var discNodes: [SCNNode] { sides.map(\.disc) }

    init(rig: FlyRig) {
        let base = rig.materials["wing"] ?? FlyRig.makeMaterial(name: "wing", rgba: [0.85, 0.9, 0.95, 0.35])
        materials = (1...Self.count).map { k in
            let m = base.copy() as! SCNMaterial
            m.name = "wing_ghost_\(k)"
            m.transparency = CGFloat(Self.alpha(k))
            m.writesToDepthBuffer = false
            m.isDoubleSided = true
            return m
        }
        let dm = base.copy() as! SCNMaterial
        dm.name = "wing_blur_disc"
        dm.transparency = CGFloat(Self.discAlpha)
        dm.writesToDepthBuffer = false
        dm.isDoubleSided = true
        discMaterial = dm

        var sides: [Side] = []
        for name in ["left", "right"] {
            guard let body = rig.bodies["wing_\(name)"], let parent = body.node.parent else { continue }
            let root = SCNNode()
            root.name = "wing_\(name)#ghosts"
            root.simdTransform = body.node.simdTransform
            root.isHidden = true
            parent.addChildNode(root)
            let meshes = body.jointNode.childNodes.filter { $0.geometry != nil }
            var ghosts: [SCNNode] = []
            for k in 1...Self.count {
                let g = SCNNode()
                g.name = "wing_\(name)#ghost\(k)"
                for mn in meshes {
                    let geo = mn.geometry!.copy() as! SCNGeometry // shares the vertex data
                    geo.materials = [materials[k - 1]]
                    let c = SCNNode(geometry: geo)
                    c.name = (mn.name ?? "wing") + "#ghost\(k)"
                    c.simdTransform = mn.simdTransform
                    c.renderingOrder = 10 + k
                    c.castsShadow = false
                    g.addChildNode(c)
                }
                root.addChildNode(g)
                ghosts.append(g)
            }
            let disc = SCNNode(geometry: Self.discGeometry(rig: rig, body: body, meshes: meshes, material: dm))
            disc.name = "wing_\(name)#blurdisc"
            disc.renderingOrder = 9
            disc.castsShadow = false
            root.addChildNode(disc)
            sides.append(Side(name: name, body: body, root: root, ghosts: ghosts, disc: disc))
        }
        self.sides = sides
    }

    func hide() { for s in sides { s.root.isHidden = true } }

    /// Poses the ghosts. `angles(side, phase)` returns the (yaw, roll, pitch) joint angles of that wing.
    func update(stroke: Double, phase: Double, angles: (String, Double) -> SIMD3<Double>) {
        let visible = stroke >= Self.minStroke
        let ghostFade = Float(smoothstep(Self.minStroke, 0.6, stroke))
        let discFade = Float(smoothstep(Self.minStroke, 1.0, stroke))
        for s in sides {
            s.root.isHidden = !visible
            guard visible else { continue }
            for (i, g) in s.ghosts.enumerated() {
                let a = angles(s.name, phase - Double(i + 1) * Self.delta)
                g.simdOrientation = Self.orientation(s.body, a)
                g.opacity = CGFloat(ghostFade)
            }
            s.disc.opacity = CGFloat(discFade)
        }
    }

    /// Joint-frame orientation of a wing body for (yaw, roll, pitch), composed like `BodyNode.refresh`.
    static func orientation(_ body: FlyRig.BodyNode, _ a: SIMD3<Double>) -> simd_quatf {
        var q = simd_quatf(angle: 0, axis: simd_float3(1, 0, 0))
        for j in body.joints {
            let v: Double
            if j.name.contains("yaw") { v = a.x } else if j.name.contains("roll") { v = a.y }
            else if j.name.contains("pitch") { v = a.z } else { v = j.angle }
            q = q * simd_quatf(angle: Float(v), axis: j.axis)
        }
        return q
    }

    /// Fan between the inner (20 % span) and outer (97 % span) wing radius, swept along the full-stroke
    /// downstroke from the dorsal to the ventral reversal; in the wing body's fixed frame.
    static func discGeometry(rig: FlyRig, body: FlyRig.BodyNode, meshes: [SCNNode], material: SCNMaterial) -> SCNGeometry {
        var tip = simd_float3(1, 0, 0)
        var best: Float = 0
        for mn in meshes {
            guard let geo = mn.geometry else { continue }
            for v in FlyRig.vertices(of: geo) {
                let p4 = mn.simdTransform * simd_float4(v, 1)
                let p = simd_float3(p4.x, p4.y, p4.z)
                if simd_length(p) > best { best = simd_length(p); tip = p }
            }
        }
        let names = ["yaw", "roll", "pitch"]
        func clamped(_ a: SIMD3<Double>) -> SIMD3<Double> {
            var out = a
            for i in 0..<3 {
                if let j = body.joints.first(where: { $0.name.contains(names[i]) }), let r = j.range {
                    out[i] = min(max(a[i], r.lowerBound), r.upperBound)
                }
            }
            return out
        }
        let n = 32
        var verts: [SCNVector3] = [], norms: [SCNVector3] = [], idx: [UInt32] = []
        for i in 0...n {
            let ph = -Double.pi / 2 + Double.pi * Double(i) / Double(n)
            let q = orientation(body, clamped(JointAnimator.WingStroke.angles(phase: ph)))
            let inner = q.act(tip * 0.2), outer = q.act(tip * 0.97)
            verts += [SCNVector3(inner), SCNVector3(outer)]
            let nrm = simd_normalize(simd_cross(q.act(simd_float3(0, 0, 1)), outer - inner) + simd_float3(0, 1e-4, 0))
            norms += [SCNVector3(nrm), SCNVector3(nrm)]
            if i < n {
                let b = UInt32(2 * i)
                idx += [b, b + 1, b + 3, b, b + 3, b + 2]
            }
        }
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: norms)],
                              elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        geo.name = "wing_blur_disc"
        geo.materials = [material]
        return geo
    }
}
