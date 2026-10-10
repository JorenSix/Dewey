import Foundation
import FlyCore

/// Group-mean readouts the decoder consumes.
public enum Readout: Int, CaseIterable, Sendable {
    case gf, escape, loomL, loomR, landing, steerL, steerR, walk, backward, freeze, groom, wingMN, legMN, mechano

    /// (group, side filter)
    public var group: (String, Side?) {
        switch self {
        case .gf: return ("gf", nil)
        case .escape: return ("escape_dn", nil)
        case .loomL: return ("loom", .L)
        case .loomR: return ("loom", .R)
        case .landing: return ("landing_dn", nil)
        case .steerL: return ("steer_dn", .L)
        case .steerR: return ("steer_dn", .R)
        case .walk: return ("walk_dn", nil)
        case .backward: return ("backward_dn", nil)
        case .freeze: return ("freeze_dn", nil)
        case .groom: return ("groom_dn", nil)
        case .wingMN: return ("wing_mn", nil)
        case .legMN: return ("leg_mn", nil)
        case .mechano: return ("mechano", nil)
        }
    }
}

/// Per-readout normalisation: x = (mean − baseline) / scale. Filled by `ConnectomeBrain.calibrate()`
/// (scale = probe response − baseline), defaults to baseline 0, scale 1 (raw rates).
public struct Calibration: Sendable {
    public var baseline = [Float](repeating: 0, count: Readout.allCases.count)
    public var scale = [Float](repeating: 1, count: Readout.allCases.count)
    /// Raw steer_dn L − R under the symmetric flight probe (both sides driven equally): the connectome's
    /// built-in steering asymmetry, subtracted from the airborne steering readout.
    public var steerFlightAsymmetry: Float = 0
    public init() {}
    @inline(__always) public func normalized(_ r: Readout, _ raw: Float) -> Float {
        (raw - baseline[r.rawValue]) / scale[r.rawValue]
    }
}

/// out = sigmoid((x − threshold') / slope), threshold' = threshold − hysteresis while the channel is "on"
/// (on ⇔ previous output > 0.5).
public struct ChannelConfig: Sendable {
    public var threshold: Float
    public var slope: Float
    public var hysteresis: Float
    public init(threshold: Float = 0.5, slope: Float = 0.08, hysteresis: Float = 0.1) {
        self.threshold = threshold; self.slope = slope; self.hysteresis = hysteresis
    }
}

public struct DecoderConfig: Sendable {
    public var takeoff = ChannelConfig(threshold: 0.45, slope: 0.07, hysteresis: 0.1)
    public var thrust = ChannelConfig(threshold: 0.3, slope: 0.1, hysteresis: 0)
    public var land = ChannelConfig(threshold: 0.5, slope: 0.08, hysteresis: 0.1)
    public var walk = ChannelConfig(threshold: 0.4, slope: 0.1, hysteresis: 0.05)
    public var backward = ChannelConfig(threshold: 0.5, slope: 0.08, hysteresis: 0.1)
    public var freeze = ChannelConfig(threshold: 0.6, slope: 0.08, hysteresis: 0.1)
    public var groom = ChannelConfig(threshold: 0.5, slope: 0.08, hysteresis: 0.1)
    /// walk input = walkDNWeight·walk_dn + (1 − walkDNWeight)·leg_mn (normalised).
    public var walkDNWeight: Float = 0.7
    /// Steering yaw = steerYawMax · ((sL − sR) − a) / s̄, with sL/sR the raw steer_dn means, a the
    /// flight-calibrated asymmetry (airborne only, see `Calibration.steerFlightAsymmetry`) and s̄ the mean
    /// steer calibration scale (1 when unresponsive), so symmetric input gives yaw ≈ 0.
    public var steerYawMax: Double = 3
    /// Escape yaw = escapeYawMax · (loomR − loomL)/(loomR + loomL + ε) · clamp(loom normalised, 0, 1):
    /// loom on the right → positive yaw (turn left, away).
    public var escapeYawMax: Double = 8
    public var maxYaw: Double = 10
    /// thrust is forced to 0 when not airborne.
    public var gateThrustOnAirborne = true
    public init() {}
}

/// Group activities -> MotorCommand. Stateful only for hysteresis.
public final class MotorDecoder {
    public var config: DecoderConfig
    public var calibration: Calibration
    private var on = [Bool](repeating: false, count: 7)

    public init(config: DecoderConfig = DecoderConfig(), calibration: Calibration = Calibration()) {
        self.config = config; self.calibration = calibration
    }

    public func reset() { for i in on.indices { on[i] = false } }

    @inline(__always) private func channel(_ k: Int, _ x: Float, _ c: ChannelConfig) -> Double {
        let thr = on[k] ? c.threshold - c.hysteresis : c.threshold
        let z = (x - thr) / max(c.slope, 1e-6)
        let y = 1 / (1 + exp(-min(max(z, -30), 30)))
        on[k] = y > 0.5
        return Double(y.isFinite ? y : 0)
    }

    /// `raw` is indexed by `Readout.rawValue` (group mean rates).
    public func decode(raw: [Float], airborne: Bool) -> MotorCommand {
        let cal = calibration, c = config
        func x(_ r: Readout) -> Float { cal.normalized(r, raw[r.rawValue]) }
        var m = MotorCommand()
        m.takeoff = channel(0, max(x(.gf), x(.escape)), c.takeoff)
        let thrust = channel(1, x(.wingMN), c.thrust)
        m.thrust = (c.gateThrustOnAirborne && !airborne) ? 0 : thrust
        m.land = channel(2, x(.landing), c.land)
        m.walkSpeed = channel(3, c.walkDNWeight * x(.walk) + (1 - c.walkDNWeight) * x(.legMN), c.walk)
        m.backward = channel(4, x(.backward), c.backward)
        m.freeze = channel(5, x(.freeze), c.freeze)
        m.groom = channel(6, x(.groom), c.groom)

        let eps: Float = 1e-4
        let sL = max(raw[Readout.steerL.rawValue], 0), sR = max(raw[Readout.steerR.rawValue], 0)
        let scL = cal.scale[Readout.steerL.rawValue], scR = cal.scale[Readout.steerR.rawValue]
        var sc: Float = 1
        if scL.isFinite && scR.isFinite { sc = max((scL + scR) / 2, 1e-3) }
        let asym = airborne ? cal.steerFlightAsymmetry : 0
        let steer = Double(((sL - sR) - asym) / sc)
        let lL = max(raw[Readout.loomL.rawValue], 0), lR = max(raw[Readout.loomR.rawValue], 0)
        let loomLevel = min(max(max(x(.loomL), x(.loomR)), 0), 1)
        let away = Double((lR - lL) / (lR + lL + eps) * loomLevel)
        let yaw = c.steerYawMax * steer + c.escapeYawMax * away
        m.yawRate = yaw.isFinite ? min(max(yaw, -c.maxYaw), c.maxYaw) : 0
        return m
    }
}
