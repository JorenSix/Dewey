import Foundation

/// Hemisphere of a collapsed node. "C" = centre / unknown.
public enum Side: String, Codable, Sendable, CaseIterable {
    case L, R, C

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Side(rawValue: raw.uppercased()) ?? .C
    }
}

/// One type-level node of the reduced circuit (see docs/contracts.md).
public struct CircuitNode: Codable, Sendable {
    public var id: Int
    public var name: String
    public var type: String
    public var side: Side
    public var cls: String
    public var superclass: String
    public var nt: String
    /// sensor | inter | dn | an | mn
    public var role: String
    /// Number of neurons collapsed into this node.
    public var n: Int
    /// Membrane/rate time constant in seconds.
    public var tau: Double

    enum CodingKeys: String, CodingKey {
        case id, name, type, side, cls = "class", superclass, nt, role, n, tau
    }

    public init(id: Int, name: String, type: String, side: Side, cls: String = "", superclass: String = "",
                nt: String = "unknown", role: String = "inter", n: Int = 1, tau: Double = 0.02) {
        self.id = id; self.name = name; self.type = type; self.side = side; self.cls = cls
        self.superclass = superclass; self.nt = nt; self.role = role; self.n = n; self.tau = tau
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        side = try c.decodeIfPresent(Side.self, forKey: .side) ?? .C
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "\(type)_\(side.rawValue)"
        cls = try c.decodeIfPresent(String.self, forKey: .cls) ?? ""
        superclass = try c.decodeIfPresent(String.self, forKey: .superclass) ?? ""
        nt = try c.decodeIfPresent(String.self, forKey: .nt) ?? "unknown"
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "inter"
        n = try c.decodeIfPresent(Int.self, forKey: .n) ?? 1
        tau = try c.decodeIfPresent(Double.self, forKey: .tau) ?? 0.02
    }
}

/// Edge list in structure-of-arrays form. `w` is signed and normalised by the post node's total input.
public struct CircuitEdges: Codable, Sendable {
    public var pre: [Int]
    public var post: [Int]
    public var w: [Float]
    public init(pre: [Int] = [], post: [Int] = [], w: [Float] = []) {
        self.pre = pre; self.post = post; self.w = w
    }
}

public enum CircuitError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self { case .invalid(let s): return "invalid circuit: \(s)" }
    }
}

/// The reduced connectome (`circuit.json`, schema in docs/contracts.md).
public struct Circuit: Codable, Sendable {
    public static let groupNames = [
        "loom", "mechano", "visual_landing",
        "gf", "escape_dn", "landing_dn", "steer_dn", "walk_dn",
        "backward_dn", "freeze_dn", "groom_dn",
        "wing_mn", "haltere_mn", "leg_mn",
    ]

    public var version: Int
    public var source: String
    public var citation: String
    public var nodes: [CircuitNode]
    public var edges: CircuitEdges
    public var groups: [String: [Int]]

    public init(version: Int = 1, source: String = "", citation: String = "", nodes: [CircuitNode],
                edges: CircuitEdges, groups: [String: [Int]]) {
        self.version = version; self.source = source; self.citation = citation
        self.nodes = nodes; self.edges = edges; self.groups = groups
    }

    enum CodingKeys: String, CodingKey { case version, source, citation, nodes, edges, groups }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        citation = try c.decodeIfPresent(String.self, forKey: .citation) ?? ""
        nodes = try c.decode([CircuitNode].self, forKey: .nodes)
        edges = try c.decode(CircuitEdges.self, forKey: .edges)
        groups = try c.decodeIfPresent([String: [Int]].self, forKey: .groups) ?? [:]
    }

    public var nodeCount: Int { nodes.count }
    public var edgeCount: Int { edges.pre.count }

    /// Decodes and validates a circuit file.
    public static func load(url: URL) throws -> Circuit {
        let data = try Data(contentsOf: url)
        let c = try JSONDecoder().decode(Circuit.self, from: data)
        try c.validate()
        return c
    }

    /// Checks ids == index, equal edge-array lengths and in-range indices. Missing group keys are tolerated
    /// (treated as empty) but reported by `missingGroups`.
    public func validate() throws {
        for (i, nd) in nodes.enumerated() where nd.id != i {
            throw CircuitError.invalid("node at index \(i) has id \(nd.id)")
        }
        guard edges.pre.count == edges.post.count, edges.pre.count == edges.w.count else {
            throw CircuitError.invalid("edge arrays differ in length")
        }
        let n = nodes.count
        for k in 0..<edges.pre.count {
            guard edges.pre[k] >= 0, edges.pre[k] < n, edges.post[k] >= 0, edges.post[k] < n else {
                throw CircuitError.invalid("edge \(k) out of range")
            }
            guard edges.w[k].isFinite else { throw CircuitError.invalid("edge \(k) weight not finite") }
        }
        for (g, ids) in groups {
            for id in ids where id < 0 || id >= n { throw CircuitError.invalid("group \(g) id \(id) out of range") }
        }
    }

    public var missingGroups: [String] { Circuit.groupNames.filter { groups[$0] == nil } }

    /// Node ids of a group, optionally restricted to one side.
    public func group(_ name: String, side: Side? = nil) -> [Int] {
        let ids = groups[name] ?? []
        guard let side else { return ids }
        return ids.filter { nodes[$0].side == side }
    }

    /// Weight matrix in CSR form, one row per post-synaptic node (incoming edges), for r_post += W r_pre.
    public func csr() -> CSRMatrix {
        let n = nodes.count, m = edges.pre.count
        var counts = [Int32](repeating: 0, count: n + 1)
        for p in edges.post { counts[p + 1] += 1 }
        for i in 0..<n { counts[i + 1] += counts[i] }
        var fill = counts
        var col = [Int32](repeating: 0, count: m)
        var val = [Float](repeating: 0, count: m)
        for k in 0..<m {
            let p = edges.post[k]
            let slot = Int(fill[p]); fill[p] += 1
            col[slot] = Int32(edges.pre[k]); val[slot] = edges.w[k]
        }
        return CSRMatrix(n: n, rowPtr: counts, col: col, val: val)
    }
}

/// Compressed sparse rows: row i holds the incoming weights of node i.
public struct CSRMatrix: Sendable {
    public let n: Int
    public let rowPtr: [Int32]
    public let col: [Int32]
    public let val: [Float]

    public var nnz: Int { val.count }

    /// max_i Σ_j |W_ij| (the induced ∞-norm). gain * this < 1 makes the rate map a contraction.
    public var maxRowAbsSum: Float {
        var best: Float = 0
        for i in 0..<n {
            var s: Float = 0
            for k in Int(rowPtr[i])..<Int(rowPtr[i + 1]) { s += abs(val[k]) }
            best = max(best, s)
        }
        return best
    }
}
