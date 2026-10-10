import SceneKit
import simd

/// Geometry queries on a posed `FlyRig` (vertex extents in the rig's root frame).
extension FlyRig {
    /// Mesh nodes owned directly by a body (not those of its child bodies).
    func meshNodes(ofBody name: String) -> [SCNNode] {
        guard let b = bodies[name] else { return [] }
        return b.jointNode.childNodes.filter { $0.geometry != nil && !($0.name ?? "").contains("#ghost") }
    }

    /// Vertex positions of a geometry (cached per geometry object).
    static func vertices(of geo: SCNGeometry) -> [simd_float3] {
        if let cached = vertexCache.object(forKey: geo) { return cached.v }
        var out: [simd_float3] = []
        if let src = geo.sources(for: .vertex).first, src.usesFloatComponents, src.bytesPerComponent == 4 {
            let n = src.vectorCount, stride = src.dataStride, off = src.dataOffset
            out.reserveCapacity(n)
            src.data.withUnsafeBytes { raw in
                for i in 0..<n {
                    let base = off + i * stride
                    let x = raw.loadUnaligned(fromByteOffset: base, as: Float.self)
                    let y = raw.loadUnaligned(fromByteOffset: base + 4, as: Float.self)
                    let z = raw.loadUnaligned(fromByteOffset: base + 8, as: Float.self)
                    out.append(simd_float3(x, y, z))
                }
            }
        }
        vertexCache.setObject(VertexBox(out), forKey: geo)
        return out
    }

    /// All vertices of the named bodies' own meshes, in the frame of `node` (the rig root),
    /// for the rig's current joint angles.
    public func vertices(ofBodies names: [String]) -> [simd_float3] {
        var out: [simd_float3] = []
        for name in names {
            for mn in meshNodes(ofBody: name) {
                guard let geo = mn.geometry else { continue }
                let m = rootTransform(of: mn)
                for v in FlyRig.vertices(of: geo) {
                    let p = m * simd_float4(v, 1)
                    out.append(simd_float3(p.x, p.y, p.z))
                }
            }
        }
        return out
    }

    /// Transform from `n`'s local frame to the rig root `node` frame (ignores `node`'s own placement).
    func rootTransform(of n: SCNNode) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        var cur: SCNNode? = n
        while let c = cur, c !== node {
            m = c.simdTransform * m
            cur = c.parent
        }
        return m
    }

    /// Names of the tarsus / claw bodies (the parts that touch the ground) of one leg, e.g. "T2_left".
    public func tarsalBodies(leg: String) -> [String] {
        bodyNames.filter { ($0.hasPrefix("tarsus") || $0.hasPrefix("claw")) && $0.hasSuffix("_" + leg) }
    }
}

final class VertexBox { let v: [simd_float3]; init(_ v: [simd_float3]) { self.v = v } }
nonisolated(unsafe) let vertexCache = NSMapTable<SCNGeometry, VertexBox>.weakToStrongObjects()
