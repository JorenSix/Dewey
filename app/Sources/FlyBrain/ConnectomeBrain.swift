import Foundation
import FlyCore

public struct BrainConfig: Sendable {
    public var network = NetworkConfig()
    public var encoder = EncoderConfig()
    public var decoder = DecoderConfig()
    /// Run canonical probe stimuli at init to set per-readout baseline/scale (see `calibrate()`).
    public var autoCalibrate = true
    /// A readout whose probe response is below this (raw rate units) is marked unresponsive
    /// (scale = +inf, so its normalised value is 0) rather than amplifying noise.
    public var minCalibrationScale: Float = 0.01
    public init() {}
}

/// Connectome-driven brain: SensoryEncoder → RateNetwork → MotorDecoder.
public final class ConnectomeBrain: Brain, RestlessnessTunable {
    public let circuit: Circuit
    public let config: BrainConfig
    public let network: RateNetwork
    public let encoder: SensoryEncoder
    public let decoder: MotorDecoder
    public private(set) var lastCommand = MotorCommand.idle
    private let seed: UInt64
    private let readoutIdx: [[Int32]]
    private var raw = [Float](repeating: 0, count: Readout.allCases.count)

    public init(circuit: Circuit, config: BrainConfig = BrainConfig(), seed: UInt64 = 1) {
        self.circuit = circuit
        self.config = config
        self.seed = seed
        network = RateNetwork(circuit: circuit, config: config.network, seed: seed)
        encoder = SensoryEncoder(circuit: circuit, config: config.encoder, seed: seed)
        decoder = MotorDecoder(config: config.decoder)
        readoutIdx = Readout.allCases.map { r in
            let (g, s) = r.group
            return circuit.group(g, side: s).map { Int32($0) }
        }
        if config.autoCalibrate { calibrate() }
    }

    public convenience init(url: URL, config: BrainConfig = BrainConfig(), seed: UInt64 = 1) throws {
        self.init(circuit: try Circuit.load(url: url), config: config, seed: seed)
    }

    public func step(_ percept: Percept, dt: Double) -> MotorCommand {
        let d = encoder.drive(for: percept, dt: dt)
        encoder.apply(d, to: network)
        network.step(dt: dt)
        readRaw()
        lastCommand = decoder.decode(raw: raw, airborne: percept.airborne)
        return lastCommand
    }

    private func readRaw() {
        for (k, idx) in readoutIdx.enumerated() { raw[k] = network.mean(idx) }
    }

    public func rawReadout(_ r: Readout) -> Float { raw[r.rawValue] }
    public func normalizedReadout(_ r: Readout) -> Float { decoder.calibration.normalized(r, raw[r.rawValue]) }

    /// Normalised (calibrated, clamped 0...1) activity for the brain overlay.
    public var activity: [String: Float] {
        func a(_ r: Readout) -> Float { min(max(normalizedReadout(r), 0), 1) }
        return [
            "GF": a(.gf), "loom": max(a(.loomL), a(.loomR)), "escape": a(.escape), "landing": a(.landing),
            "steerL": a(.steerL), "steerR": a(.steerR), "walk": a(.walk), "groom": a(.groom),
            "wingMN": a(.wingMN), "legMN": a(.legMN),
        ]
    }

    /// Restlessness setting (DeweySettings.restBout) → EncoderConfig.restMin/restMax, live.
    public func setRestBout(_ range: ClosedRange<Double>) { encoder.setRestBout(range) }

    public func reset() {
        network.reset(); network.reseed(seed); decoder.reset()
        for i in raw.indices { raw[i] = 0 }
        lastCommand = .idle
    }

    /// Probes the network (noise off) with canonical drives and sets, per readout,
    /// baseline = level at rest and scale = peak under its probe − baseline
    /// (or +inf = unresponsive when that is below minCalibrationScale):
    ///
    /// | probe (duration) | drive | readouts calibrated |
    /// |---|---|---|
    /// | rest (1 s) | none | baseline of all |
    /// | flight (1 s) | wing + steer tonic | wingMN, steerL, steerR; landing *baseline* = flight level; steer L−R asymmetry |
    /// | loom (0.3 s) | loomMax both sides | gf, escape, loomL, loomR, legMN |
    /// | landing (1 s) | flight + landingMax | landing |
    /// | groom (2 s) | groomMax | groom |
    /// | walk (1 s) | walkTonic | walk, legMN (max with loom) |
    /// | mechano (0.5 s) | mechanoMax both sides | mechano, backward, freeze |
    public func calibrate() {
        let ec = config.encoder
        let savedNoise = network.noiseStd
        network.noiseStd = 0
        decoder.calibration = Calibration()
        let dt = 1.0 / 60
        let nR = Readout.allCases.count

        func run(_ d: SensoryDrive, _ seconds: Double) -> (peak: [Float], last: [Float]) {
            network.reset()
            encoder.apply(d, to: network)
            var peak = [Float](repeating: -.infinity, count: nR)
            for _ in 0..<Int((seconds / dt).rounded()) {
                network.step(dt: dt)
                readRaw()
                for k in 0..<nR { peak[k] = max(peak[k], raw[k]) }
            }
            return (peak, raw)
        }

        var cal = Calibration()
        let rest = run(SensoryDrive(), 1).last
        cal.baseline = rest
        func setScale(_ r: Readout, _ peak: [Float]) {
            let s = peak[r.rawValue] - cal.baseline[r.rawValue]
            // No meaningful path from the probe: mark unresponsive (normalised readout is then always 0)
            // instead of amplifying noise.
            cal.scale[r.rawValue] = s >= config.minCalibrationScale ? s : .infinity
        }

        var flight = SensoryDrive()
        flight.wing = ec.flightWing; flight.steerL = ec.flightSteer; flight.steerR = ec.flightSteer
        let fl = run(flight, 1)
        for r in [Readout.wingMN, .steerL, .steerR] { setScale(r, fl.peak) }
        cal.steerFlightAsymmetry = fl.last[Readout.steerL.rawValue] - fl.last[Readout.steerR.rawValue]

        var loom = SensoryDrive(); loom.loomL = ec.loomMax; loom.loomR = ec.loomMax
        let lo = run(loom, 0.3)
        for r in [Readout.gf, .escape, .loomL, .loomR] { setScale(r, lo.peak) }

        var land = flight; land.landing = ec.landingMax
        let la = run(land, 1)
        cal.baseline[Readout.landing.rawValue] = fl.last[Readout.landing.rawValue]
        setScale(.landing, la.peak)

        var groom = SensoryDrive(); groom.groom = ec.groomMax
        setScale(.groom, run(groom, 2).peak)

        var walk = SensoryDrive(); walk.walk = ec.walkTonic
        let wa = run(walk, 1)
        setScale(.walk, wa.peak)
        var legPeak = wa.peak; legPeak[Readout.legMN.rawValue] = max(wa.peak[Readout.legMN.rawValue], lo.peak[Readout.legMN.rawValue])
        setScale(.legMN, legPeak)

        var mech = SensoryDrive(); mech.mechanoL = ec.mechanoMax; mech.mechanoR = ec.mechanoMax
        let me = run(mech, 0.5)
        for r in [Readout.mechano, .backward, .freeze] { setScale(r, me.peak) }

        decoder.calibration = cal
        network.noiseStd = savedNoise
        reset()
    }

    /// Human-readable calibration summary (for logs / integration tuning).
    public var calibrationReport: String {
        let c = decoder.calibration
        return Readout.allCases.map { r in
            String(format: "%@ n=%d base=%.4f scale=%.4f", "\(r)", readoutIdx[r.rawValue].count,
                   c.baseline[r.rawValue], c.scale[r.rawValue])
        }.joined(separator: "\n") + String(format: "\nsteerFlightAsymmetry=%.4f", c.steerFlightAsymmetry)
    }
}
