import Foundation

/// Deterministic, seedable RNG (SplitMix64).
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    public mutating func nextUnit() -> Float { Float(next() >> 40) * (1.0 / 16_777_216.0) }
}

public struct NetworkConfig: Sendable {
    /// Stability heuristic: gain = gainScale / max_i Σ_j |W_ij|. With gainScale < 1 the map
    /// r -> clamp(relu(gain W r + I)) is a contraction in the ∞-norm, so the network has a unique,
    /// globally attracting fixed point for constant input (no runaway or oscillation).
    public var gainScale: Float = 0.95
    /// If set, used verbatim instead of the heuristic.
    public var gainOverride: Float? = nil
    /// Upper rate clamp (rates are dimensionless, 0...rMax).
    public var rMax: Float = 1
    /// Substeps are chosen so dt_sub <= substepFraction * min(tau).
    public var substepFraction: Double = 0.5
    /// Taus below this (or non-finite / <= 0) are clamped; protects against tau = 0 in the file.
    public var minTau: Double = 0.002
    /// Std-dev of per-frame input noise (uniform distribution with matching variance), for spontaneous activity.
    public var noiseStd: Float = 0.01
    public init() {}
}

/// Firing-rate network  τ_i dr_i/dt = −r_i + clamp(relu(gain·Σ_j W_ij r_j + I_i + bias_i), 0, rMax).
///
/// Integrated with exponential Euler, r ← r + (1 − e^{−dt_sub/τ})(target − r), which is unconditionally
/// stable for the leak term and keeps r inside [0, rMax] (a convex combination of values in that range).
/// Substeps are synchronous (Jacobi) with a ping-pong buffer; `step` allocates nothing.
public final class RateNetwork {
    public let n: Int
    public let gain: Float
    public let rMax: Float
    public var noiseStd: Float
    public let substepFraction: Double
    public let minTauUsed: Double

    /// External current per node; written by the encoder each frame, read by `step`.
    public var input: [Float]
    /// Constant per-node offset.
    public var bias: [Float]

    private let rowPtr: [Int32]
    private let col: [Int32]
    private let val: [Float]
    private let tau: [Float]
    private var alpha: [Float]
    private var alphaDt: Double = -1
    private var drive: [Float]
    /// 2n floats: two rate buffers (ping-pong).
    private var state: [Float]
    private var cur = 0
    private var rng: SplitMix64

    public init(circuit: Circuit, config: NetworkConfig = NetworkConfig(), seed: UInt64 = 1) {
        let m = circuit.csr()
        n = m.n
        rowPtr = m.rowPtr; col = m.col; val = m.val
        let rs = m.maxRowAbsSum
        gain = config.gainOverride ?? (rs > 0 ? config.gainScale / rs : config.gainScale)
        rMax = config.rMax
        noiseStd = config.noiseStd
        substepFraction = config.substepFraction
        let taus = circuit.nodes.map { nd -> Float in
            let t = nd.tau.isFinite && nd.tau > 0 ? nd.tau : 0.02
            return Float(max(t, config.minTau))
        }
        tau = taus
        minTauUsed = Double(taus.min() ?? 0.02)
        alpha = [Float](repeating: 0, count: n)
        drive = [Float](repeating: 0, count: n)
        input = [Float](repeating: 0, count: n)
        bias = [Float](repeating: 0, count: n)
        state = [Float](repeating: 0, count: 2 * n)
        rng = SplitMix64(seed: seed)
    }

    public func reset() {
        for i in 0..<state.count { state[i] = 0 }
        cur = 0
    }

    public func reseed(_ seed: UInt64) { rng = SplitMix64(seed: seed) }

    @inline(__always) public func rate(_ i: Int) -> Float { state[cur * n + i] }

    /// Copy of the current rates (allocates; for tests/inspection).
    public var rates: [Float] { Array(state[(cur * n)..<(cur * n + n)]) }

    /// Mean rate over the given node indices (0 for an empty list).
    public func mean(_ idx: [Int32]) -> Float {
        if idx.isEmpty { return 0 }
        let off = cur * n
        return state.withUnsafeBufferPointer { s in
            var acc: Float = 0
            for i in idx { acc += s[off + Int(i)] }
            return acc / Float(idx.count)
        }
    }

    public func substeps(for dt: Double) -> Int {
        max(1, Int((dt / (substepFraction * minTauUsed)).rounded(.up)))
    }

    /// Advances the network by `dt` seconds using `input` (+ bias + noise held constant over the frame).
    public func step(dt: Double) {
        guard dt > 0, n > 0 else { return }
        let nSub = substeps(for: dt)
        let h = dt / Double(nSub)
        if h != alphaDt {
            for i in 0..<n { alpha[i] = Float(1 - exp(-h / Double(tau[i]))) }
            alphaDt = h
        }
        // Per-frame drive = input + bias + noise (uniform with std noiseStd).
        let amp = noiseStd * 3.4641016 // sqrt(12)
        for i in 0..<n {
            var d = input[i] + bias[i]
            if amp > 0 { d += amp * (rng.nextUnit() - 0.5) }
            drive[i] = d
        }
        let n = self.n, g = gain, rmax = rMax
        var c = cur
        state.withUnsafeMutableBufferPointer { st in
            rowPtr.withUnsafeBufferPointer { rp in
            col.withUnsafeBufferPointer { cl in
            val.withUnsafeBufferPointer { vl in
            alpha.withUnsafeBufferPointer { al in
            drive.withUnsafeBufferPointer { dr in
                let base = st.baseAddress!
                for _ in 0..<nSub {
                    let r = base + c * n
                    let out = base + (1 - c) * n
                    var lo = Int(rp[0])
                    for i in 0..<n {
                        let hi = Int(rp[i + 1])
                        var s0: Float = 0, s1: Float = 0
                        var k = lo
                        while k + 1 < hi {
                            s0 += vl[k] * r[Int(cl[k])]
                            s1 += vl[k + 1] * r[Int(cl[k + 1])]
                            k += 2
                        }
                        if k < hi { s0 += vl[k] * r[Int(cl[k])] }
                        lo = hi
                        let target = min(max(g * (s0 + s1) + dr[i], 0), rmax)
                        let ri = r[i]
                        out[i] = ri + al[i] * (target - ri)
                    }
                    c = 1 - c
                }
            }}}}}
        }
        cur = c
    }
}
