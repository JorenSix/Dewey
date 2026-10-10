import Foundation
import FlyBrain

/// Builds a schema-conformant synthetic circuit: named seed nodes with hand-wired chains
/// (loom → GF → escape DN → wing/leg MN, visual_landing → landing DN, mechano → backward/freeze DN,
/// walk DN → leg MN) embedded in a random sparse pool (~`inDegree` random in-edges per node).
/// Weights follow the pipeline rule w = sign(nt pre) · syn / total_input_syn(post).
enum SyntheticCircuit {
    static func make(nodes total: Int = 3000, inDegree: Int = 30, seed: UInt64 = 42) -> Circuit {
        var rng = SplitMix64(seed: seed)
        var nodes: [CircuitNode] = []
        var groups: [String: [Int]] = [:]
        for g in Circuit.groupNames { groups[g] = [] }

        @discardableResult
        func add(_ type: String, _ side: Side, group: String?, role: String, nt: String = "acetylcholine",
                 tau: Double = 0.02) -> Int {
            let id = nodes.count
            nodes.append(CircuitNode(id: id, name: "\(type)_\(side.rawValue)", type: type, side: side,
                                     nt: nt, role: role, n: 1, tau: tau))
            if let group { groups[group, default: []].append(id) }
            return id
        }
        var named: [String: Int] = [:]
        for s in [Side.L, .R] {
            let k = s.rawValue
            named["LPLC2_\(k)"] = add("LPLC2", s, group: "loom", role: "sensor", tau: 0.02)
            named["LC4_\(k)"] = add("LC4", s, group: "loom", role: "sensor", tau: 0.02)
            named["JO_\(k)"] = add("JO", s, group: "mechano", role: "sensor", tau: 0.01)
            named["LC6_\(k)"] = add("LC6", s, group: "visual_landing", role: "sensor", tau: 0.03)
            named["DNp01_\(k)"] = add("DNp01", s, group: "gf", role: "dn", tau: 0.005)
            named["DNp02_\(k)"] = add("DNp02", s, group: "escape_dn", role: "dn", tau: 0.02)
            named["DNp11_\(k)"] = add("DNp11", s, group: "escape_dn", role: "dn", tau: 0.02)
            named["DNp07_\(k)"] = add("DNp07", s, group: "landing_dn", role: "dn", tau: 0.03)
            named["DNa01_\(k)"] = add("DNa01", s, group: "steer_dn", role: "dn", tau: 0.03)
            named["DNa02_\(k)"] = add("DNa02", s, group: "steer_dn", role: "dn", tau: 0.03)
            named["DNp09_\(k)"] = add("DNp09", s, group: "walk_dn", role: "dn", tau: 0.05)
            named["MDN_\(k)"] = add("MDN", s, group: "backward_dn", role: "dn", tau: 0.05)
            named["DNp18_\(k)"] = add("DNp18", s, group: "freeze_dn", role: "dn", tau: 0.05)
            named["DNg11_\(k)"] = add("DNg11", s, group: "groom_dn", role: "dn", tau: 0.1)
            named["DLMn_\(k)"] = add("DLMn", s, group: "wing_mn", role: "mn", tau: 0.02)
            named["DVMn_\(k)"] = add("DVMn", s, group: "wing_mn", role: "mn", tau: 0.02)
            named["hMN_\(k)"] = add("hMN", s, group: "haltere_mn", role: "mn", tau: 0.02)
            named["TTMn_\(k)"] = add("TTMn", s, group: "leg_mn", role: "mn", tau: 0.01)
            named["legMN_\(k)"] = add("legMN", s, group: "leg_mn", role: "mn", tau: 0.02)
        }
        while nodes.count < total {
            let u = rng.nextUnit()
            let nt = u < 0.75 ? "acetylcholine" : (u < 0.9 ? "gaba" : "glutamate")
            add("IN\(nodes.count)", rng.nextUnit() < 0.5 ? .L : .R, group: nil, role: "inter", nt: nt,
                tau: 0.01 + 0.04 * Double(rng.nextUnit()))
        }
        let n = nodes.count

        // Synapse counts per (post) row: random pool + hand-wired chain synapses.
        var rows = [[(Int, Float)]](repeating: [], count: n)
        for post in 0..<n {
            for _ in 0..<inDegree {
                var pre = Int(rng.next() % UInt64(n))
                if pre == post { pre = (pre + 1) % n }
                rows[post].append((pre, 1 + 9 * rng.nextUnit()))
            }
        }
        func wire(_ pre: String, _ post: String, _ syn: Float) { rows[named[post]!].append((named[pre]!, syn)) }
        for s in ["L", "R"] {
            let o = s == "L" ? "R" : "L"
            wire("LPLC2_\(s)", "DNp01_\(s)", 600); wire("LC4_\(s)", "DNp01_\(s)", 400)
            wire("LPLC2_\(o)", "DNp01_\(s)", 100)
            wire("DNp01_\(s)", "DNp02_\(s)", 500); wire("DNp01_\(o)", "DNp02_\(s)", 300); wire("LC4_\(s)", "DNp02_\(s)", 200)
            wire("DNp01_\(s)", "DNp11_\(s)", 500); wire("DNp01_\(o)", "DNp11_\(s)", 300); wire("LPLC2_\(s)", "DNp11_\(s)", 200)
            wire("DNp02_\(s)", "DLMn_\(s)", 500); wire("DNp11_\(s)", "DLMn_\(s)", 300)
            wire("DNp02_\(s)", "DVMn_\(s)", 500); wire("DNp11_\(s)", "DVMn_\(s)", 300)
            wire("DNp01_\(s)", "TTMn_\(s)", 900)
            wire("LC6_\(s)", "DNp07_\(s)", 900)
            wire("JO_\(s)", "MDN_\(s)", 900); wire("JO_\(s)", "DNp18_\(s)", 500); wire("LC4_\(s)", "DNp18_\(s)", 200)
            wire("DNp09_\(s)", "legMN_\(s)", 900)
            wire("DNa01_\(s)", "hMN_\(s)", 300)
        }

        var pre: [Int] = [], post: [Int] = [], w: [Float] = []
        pre.reserveCapacity(n * (inDegree + 2)); post.reserveCapacity(n * (inDegree + 2)); w.reserveCapacity(n * (inDegree + 2))
        for p in 0..<n {
            let total = rows[p].reduce(Float(0)) { $0 + $1.1 }
            for (q, syn) in rows[p] {
                let sign: Float = (nodes[q].nt == "gaba" || nodes[q].nt == "glutamate") ? -1 : 1
                pre.append(q); post.append(p); w.append(sign * syn / total)
            }
        }
        return Circuit(version: 1, source: "synthetic", citation: "test", nodes: nodes,
                       edges: CircuitEdges(pre: pre, post: post, w: w), groups: groups)
    }
}
