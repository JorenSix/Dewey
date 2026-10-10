import FlyCore
import Foundation
import SceneKit
import simd

// MARK: - body.json schema (see docs/contracts.md)

struct BodyFile: Decodable {
    var version: Int
    var bodies: [BodyDef]
    var materials: [String: [Double]]
}

struct BodyDef: Decodable {
    var name: String
    var parent: String?
    var pos: [Double]
    var quat: [Double]
    var meshes: [MeshDef]
    var joints: [JointDef]
}

struct MeshDef: Decodable {
    var file: String
    var pos: [Double]
    var quat: [Double]
    var material: String
}

struct JointDef: Decodable {
    var name: String
    var type: String
    var pos: [Double]
    var axis: [Double]
    var range: [Double]?
    var springref: Double?
}

public enum FlyRigError: Error, CustomStringConvertible {
    case missingParent(body: String, parent: String)
    case badMesh(String)
    public var description: String {
        switch self {
        case let .missingParent(b, p): return "body \(b) references parent \(p) before it is defined"
        case let .badMesh(f): return "could not parse mesh \(f)"
        }
    }
}

// MARK: - Joint

/// A MuJoCo hinge joint. Its angle rotates the owning body's `jointNode` about `axis` (body frame).
public final class FlyJoint {
    public let name: String
    public let body: String
    public let axis: simd_float3
    /// Joint limits in radians (from fruitfly.xml); angles set through the rig are clamped to this.
    public let range: ClosedRange<Double>?
    /// flybody's spring reference angle; the rig's rest pose.
    public let restAngle: Double
    public internal(set) var angle: Double = 0
    unowned let owner: FlyRig.BodyNode

    init(def: JointDef, body: String, owner: FlyRig.BodyNode) {
        name = def.name
        self.body = body
        axis = simd_normalize(simd_float3(Float(def.axis[0]), Float(def.axis[1]), Float(def.axis[2])))
        if let r = def.range, r.count == 2 { range = r[0]...r[1] } else { range = nil }
        restAngle = def.springref ?? 0
        angle = restAngle
        self.owner = owner
    }
}

// MARK: - Rig

/// The flybody fruit fly as a SceneKit node tree, built from `body.json` + OBJ meshes.
///
/// Frame convention of `node` (the root):
/// - +x = forward (head), +y = dorsal (up, away from the surface), +z = the fly's right side.
///   (MuJoCo z-up/x-forward/y-left is converted by a -90 degree rotation about x.)
/// - Origin = centre of the thorax mesh; scaled so head-to-abdomen-tip length ~= 1 unit.
/// - Seen from above (camera at +y looking along -y, screen-up = -z) the fly faces screen-right.
///   To turn it to a screen heading, rotate `node` about its y axis.
public final class FlyRig {
    final class BodyNode {
        let name: String
        let node: SCNNode       // fixed MuJoCo body frame (pos/quat relative to parent)
        let jointNode: SCNNode  // carries the joint rotation; meshes + child bodies hang here
        var joints: [FlyJoint] = []
        init(name: String, node: SCNNode, jointNode: SCNNode) {
            self.name = name; self.node = node; self.jointNode = jointNode
        }
        func refresh() {
            var q = simd_quatf(angle: 0, axis: simd_float3(1, 0, 0))
            for j in joints { q = q * simd_quatf(angle: Float(j.angle), axis: j.axis) }
            jointNode.simdOrientation = q
        }
    }

    /// Root node (see the type doc comment for its frame). Add this to your scene.
    public let node: SCNNode
    /// Node holding the MuJoCo-frame model (z-up), child of `node`.
    public let modelNode: SCNNode
    /// Scale factor from body.json centimetres to rig units.
    public let unitsPerCm: Float
    public private(set) var joints: [String: FlyJoint] = [:]
    /// Joint names in body.json order.
    public private(set) var jointNames: [String] = []
    var bodies: [String: BodyNode] = [:]
    public var bodyNames: [String] { Array(bodies.keys) }
    public private(set) var materials: [String: SCNMaterial] = [:]
    /// Ghost wings installed by the first `JointAnimator` on this rig (shared by later animators).
    var wingGhosts: WingGhosts?
    /// Standing-stance measurements, cached by `JointAnimator`.
    struct StanceMetrics { var footContactOffset: Float; var bodyHalfWidth: Float; var stanceHalfWidth: Float }
    var stanceMetrics: StanceMetrics?

    /// - Parameter bundleDirectory: folder containing body.json and the OBJ files
    ///   (e.g. `Bundle.module.url(forResource: "Resources/fly", withExtension: nil)`).
    public init(bundleDirectory: URL) throws {
        let file = try FlyRig.cachedBodyFile(bundleDirectory)

        for (name, rgba) in file.materials { materials[name] = FlyRig.makeMaterial(name: name, rgba: rgba) }

        node = SCNNode()
        node.name = "fly"
        modelNode = SCNNode()
        modelNode.name = "mujoco_zup"
        modelNode.simdOrientation = simd_quatf(angle: -.pi / 2, axis: simd_float3(1, 0, 0))
        node.addChildNode(modelNode)

        for def in file.bodies {
            let bn = SCNNode()
            bn.name = def.name
            bn.simdPosition = FlyRig.vec(def.pos)
            bn.simdOrientation = FlyRig.quat(def.quat)
            let jn = SCNNode()
            jn.name = def.name + "#joints"
            bn.addChildNode(jn)
            let body = BodyNode(name: def.name, node: bn, jointNode: jn)
            if let p = def.parent {
                guard let parent = bodies[p] else { throw FlyRigError.missingParent(body: def.name, parent: p) }
                parent.jointNode.addChildNode(bn)
            } else {
                modelNode.addChildNode(bn)
            }
            for m in def.meshes {
                // Shared vertex/index data (parsed once per file); per-rig copy so materials stay per instance.
                let geo = try FlyRig.cachedGeometry(bundleDirectory.appendingPathComponent(m.file)).copy() as! SCNGeometry
                geo.materials = [materials[m.material] ?? FlyRig.makeMaterial(name: m.material, rgba: [0.5, 0.5, 0.5, 1])]
                let mn = SCNNode(geometry: geo)
                mn.name = m.file
                mn.simdPosition = FlyRig.vec(m.pos)
                mn.simdOrientation = FlyRig.quat(m.quat)
                if m.material == "wing" { mn.renderingOrder = 10; mn.castsShadow = false }
                jn.addChildNode(mn)
            }
            for jd in def.joints where jd.type == "hinge" {
                let j = FlyJoint(def: jd, body: def.name, owner: body)
                body.joints.append(j)
                joints[j.name] = j
                jointNames.append(j.name)
            }
            body.refresh()
            bodies[def.name] = body
        }

        // Normalise: centre on the thorax mesh, body length (head..abdomen tip) = 1 unit.
        let all = bodies
        let core = ["thorax", "head", "abdomen", "abdomen_7"].compactMap { all[$0]?.node }
        var lo = simd_float3(repeating: .greatestFiniteMagnitude), hi = -lo
        for n in core {
            for child in n.childNodes(passingTest: { c, _ in c.geometry != nil }) {
                guard child.parent?.parent === n else { continue } // own meshes only
                let (bmin, bmax) = child.boundingBox
                for corner in FlyRig.corners(bmin, bmax) {
                    let p = node.simdConvertPosition(corner, from: child)
                    lo = simd_min(lo, p); hi = simd_max(hi, p)
                }
            }
        }
        let length = max(hi.x - lo.x, 1e-6)
        unitsPerCm = 1 / length
        var thoraxCentre = simd_float3.zero
        if let t = bodies["thorax"], let mesh = t.jointNode.childNodes.first(where: { $0.geometry != nil }) {
            let (bmin, bmax) = mesh.boundingBox
            thoraxCentre = node.simdConvertPosition((simd_float3(bmin) + simd_float3(bmax)) / 2, from: mesh)
        }
        modelNode.simdPosition = -thoraxCentre * unitsPerCm
        modelNode.simdScale = simd_float3(repeating: unitsPerCm)
    }

    public func joint(named name: String) -> FlyJoint? { joints[name] }

    // MARK: geometry sharing (v4: several flies)

    /// Parsed `body.json` and OBJ meshes, keyed by file path. A second `FlyRig` of the same directory
    /// reuses them: every rig gets its own node tree (bodies, joint nodes, mesh nodes, materials), but the
    /// mesh nodes hold shallow `SCNGeometry` copies that share the parsed vertex/normal/index sources.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var geometryCache: [String: SCNGeometry] = [:]
    nonisolated(unsafe) private static var bodyFileCache: [String: BodyFile] = [:]

    /// Number of distinct OBJ meshes parsed so far (shared by all rigs).
    public static var cachedMeshCount: Int { cacheLock.lock(); defer { cacheLock.unlock() }; return geometryCache.count }

    static func cachedGeometry(_ url: URL) throws -> SCNGeometry {
        let key = url.standardizedFileURL.path
        cacheLock.lock()
        if let g = geometryCache[key] { cacheLock.unlock(); return g }
        cacheLock.unlock()
        let g = try OBJLoader.load(url)
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let existing = geometryCache[key] { return existing }
        geometryCache[key] = g
        return g
    }

    static func cachedBodyFile(_ dir: URL) throws -> BodyFile {
        let key = dir.standardizedFileURL.path
        cacheLock.lock()
        if let f = bodyFileCache[key] { cacheLock.unlock(); return f }
        cacheLock.unlock()
        let data = try Data(contentsOf: dir.appendingPathComponent("body.json"))
        let f = try JSONDecoder().decode(BodyFile.self, from: data)
        cacheLock.lock(); defer { cacheLock.unlock() }
        bodyFileCache[key] = f
        return f
    }

    /// Scene node of a MuJoCo body (e.g. "wing_left"); its world transform includes joint rotations.
    public func bodyNode(named name: String) -> SCNNode? { bodies[name]?.jointNode }

    /// Sets a joint angle (radians, clamped to the joint range) and updates its body node.
    public func setAngle(_ name: String, _ angle: Double, clamp: Bool = true) {
        guard let j = joints[name] else { return }
        var a = angle
        if clamp, let r = j.range { a = min(max(a, r.lowerBound), r.upperBound) }
        j.angle = a
        j.owner.refresh()
    }

    /// Restores every joint to flybody's spring-reference (rest) angle.
    public func resetToRest() {
        for j in joints.values { j.angle = j.restAngle }
        for b in bodies.values { b.refresh() }
    }

    // MARK: helpers

    static func vec(_ a: [Double]) -> simd_float3 {
        a.count >= 3 ? simd_float3(Float(a[0]), Float(a[1]), Float(a[2])) : .zero
    }

    /// MuJoCo (w,x,y,z) -> simd (ix,iy,iz,r).
    static func quat(_ a: [Double]) -> simd_quatf {
        guard a.count == 4 else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        return simd_normalize(simd_quatf(ix: Float(a[1]), iy: Float(a[2]), iz: Float(a[3]), r: Float(a[0])))
    }

    static func corners(_ a: SCNVector3, _ b: SCNVector3) -> [simd_float3] {
        let lo = simd_float3(a), hi = simd_float3(b)
        return (0..<8).map { i in
            simd_float3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z)
        }
    }

    static func makeMaterial(name: String, rgba: [Double]) -> SCNMaterial {
        let m = SCNMaterial()
        m.name = name
        let c = NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: 1)
        m.lightingModel = .blinn
        m.diffuse.contents = c
        m.locksAmbientWithDiffuse = true
        switch name {
        case "wing":
            // Unlit so both faces (the mirrored wings expose opposite faces to the camera) look alike.
            m.lightingModel = .constant
            m.diffuse.contents = NSColor(srgbRed: rgba[0] * 0.8, green: rgba[1] * 0.85, blue: rgba[2] * 0.95, alpha: 1)
            m.transparency = CGFloat(rgba.count > 3 ? rgba[3] : 0.35)
            m.transparencyMode = .singleLayer
            m.blendMode = .alpha
            m.isDoubleSided = true
            m.writesToDepthBuffer = false
        case "eye":
            m.specular.contents = NSColor(white: 0.5, alpha: 1)
            m.shininess = 0.6
        default:
            m.specular.contents = NSColor(white: 0.25, alpha: 1)
            m.shininess = 0.4
        }
        return m
    }
}

// MARK: - OBJ loader (positions, normals, triangles; enough for export_body.py output)

enum OBJLoader {
    static func load(_ url: URL) throws -> SCNGeometry {
        let text = try String(contentsOf: url, encoding: .utf8)
        var v: [simd_float3] = [], n: [simd_float3] = []
        var outV: [SCNVector3] = [], outN: [SCNVector3] = [], idx: [UInt32] = []
        var map: [Int64: UInt32] = [:]
        func vertex(_ tok: Substring) -> UInt32? {
            let parts = tok.split(separator: "/", omittingEmptySubsequences: false)
            guard let vi = Int(parts[0]) else { return nil }
            let ni = parts.count >= 3 ? Int(parts[2]) ?? 0 : 0
            let key = Int64(vi) << 32 | Int64(ni)
            if let k = map[key] { return k }
            let p = v[vi > 0 ? vi - 1 : v.count + vi]
            outV.append(SCNVector3(p))
            if ni != 0 { outN.append(SCNVector3(n[ni > 0 ? ni - 1 : n.count + ni])) } else { outN.append(SCNVector3(0, 0, 1)) }
            let k = UInt32(outV.count - 1)
            map[key] = k
            return k
        }
        for line in text.split(separator: "\n") {
            if line.hasPrefix("v ") || line.hasPrefix("vn ") {
                let f = line.split(separator: " ").dropFirst().compactMap { Float($0) }
                guard f.count >= 3 else { continue }
                if line.hasPrefix("v ") { v.append(simd_float3(f[0], f[1], f[2])) } else { n.append(simd_float3(f[0], f[1], f[2])) }
            } else if line.hasPrefix("f ") {
                let ids = line.split(separator: " ").dropFirst().compactMap(vertex)
                guard ids.count >= 3 else { continue }
                for k in 1..<(ids.count - 1) { idx += [ids[0], ids[k], ids[k + 1]] }
            }
        }
        guard !idx.isEmpty else { throw FlyRigError.badMesh(url.lastPathComponent) }
        let geo = SCNGeometry(sources: [SCNGeometrySource(vertices: outV), SCNGeometrySource(normals: outN)],
                              elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        geo.name = url.deletingPathExtension().lastPathComponent
        return geo
    }
}
