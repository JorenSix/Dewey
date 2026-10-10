import AppKit
import SceneKit
import simd
import FlyCore
import FlyBehavior

/// Tilted perspective camera that still maps 1 scene unit to 1 screen point at the camera target.
///
/// The camera looks at a target point T on the fly plane (z = `planeZ`), from above the screen
/// ("viewer slightly above the monitor"): position C = T + D·(0, sin t, cos t), looking along
/// f = (0, -sin t, -cos t) with screen-up u = (0, cos t, -sin t) and screen-right r = (1, 0, 0).
/// With a vertical field of view φ and a view `viewSize` points tall, D = (viewSize/2) / tan(φ/2), so a
/// segment perpendicular to the view axis at depth D spans exactly its length in points. For an offset
/// p from T the screen offset (points, y up) is
///     x_s = (p·r)·D / (D + p·f),   y_s = (p·u)·D / (D + p·f).
/// The SceneKit view is centred on T, and T is the view centre in screen coordinates, so any scene point's
/// screen position is viewCentre + (x_s, y_s); the fly root sits at T + δ with |δ| < 0.5 pt (view
/// origin snapping), i.e. it lands on its true screen point.
struct TiltCamera {
    /// Vertical field of view, degrees. Narrow, so the projection stays close to orthographic.
    var fieldOfView: Double = 22
    /// Tilt of the view axis away from the screen normal, radians (camera above, looking down-screen).
    var tilt: Double = 28 * .pi / 180
    var viewSize: Double = 128

    var distance: Double { (viewSize / 2) / tan(fieldOfView * .pi / 360) }
    var forward: simd_double3 { simd_double3(0, -sin(tilt), -cos(tilt)) }
    var up: simd_double3 { simd_double3(0, cos(tilt), -sin(tilt)) }
    /// Camera position relative to the target.
    var offset: simd_double3 { simd_double3(0, sin(tilt), cos(tilt)) * distance }

    /// Screen offset (points) of scene offset `p` from the target.
    func project(_ p: simd_double3) -> CGPoint {
        let d = distance
        let depth = d + simd_dot(p, forward)
        return CGPoint(x: p.x * d / depth, y: simd_dot(p, up) * d / depth)
    }

    /// Scene offset on the plane z = target.z + `z` that projects to screen offset `s`.
    func unproject(_ s: CGPoint, planeZ z: Double = 0) -> simd_double3 {
        // y_s·(D − y sin t − z cos t) = (y cos t − z sin t)·D  → solve for y, then x.
        let d = distance, st = sin(tilt), ct = cos(tilt), ys = Double(s.y)
        let y = (ys * (d - z * ct) + z * st * d) / (ct * d + ys * st)
        let depth = d - y * st - z * ct
        return simd_double3(Double(s.x) * depth / d, y, z)
    }
}

/// How the fly is posed relative to the screen: bank, pitch and the three-quarter perched tilt.
struct PoseTuning {
    /// Roll magnitude when perched on the left/right screen edge (0 = top view, π/2 = pure side view).
    var sideEdgeRoll: Double = 45 * .pi / 180
    /// Extra nose-toward-viewer rotation on a side edge, so the head turns a little out of the screen.
    var sideEdgeTowardViewer: Double = 16 * .pi / 180
    /// Roll magnitude when standing on the Dock / bottom edge (camera tilt adds to the dorsal view).
    var bottomEdgeRoll: Double = 50 * .pi / 180
    /// Small nose-down on the bottom edge so the head reads as resting on the shelf.
    var bottomEdgePitch: Double = -6 * .pi / 180
    /// Fallback bank when FlyFrame.roll is 0 in flight: roll = -yawRate·speed / bankDivisor (clamped).
    var bankDivisor: Double = 3500
    var maxBank: Double = 0.75
    /// Fallback pitch when FlyFrame.pitch is 0.
    var takeoffPitch: Double = 0.45
    var landingPitch: Double = 0.25

    /// +1 when the fly's feet point toward its left side (positive roll), for a perch edge and heading.
    static func feetSign(perch: Perch, heading: Double) -> Double {
        let n: (Double, Double)
        switch perch {
        case .left: n = (1, 0)
        case .right: n = (-1, 0)
        case .bottom: n = (0, 1)
        }
        // Fly's left in screen space = (-sin h, cos h); feet go toward -n.
        let leftDotEdge = sin(heading) * n.0 - cos(heading) * n.1
        return leftDotEdge >= 0 ? 1 : -1
    }

    func perchRoll(_ perch: Perch) -> Double { perch == .bottom ? bottomEdgeRoll : sideEdgeRoll }
}

/// Soft radial shadow texture (black, Gaussian-like alpha falloff), generated once.
enum ShadowTexture {
    static let image: CGImage? = {
        let n = 64
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Gaussian falloff sampled into gradient stops; reaches 0 at the rim so the plane edge never shows.
        var colors: [CGColor] = [], locs: [CGFloat] = []
        for i in 0...8 {
            let r = Double(i) / 8
            let a = exp(-r * r * 3.2) * (1 - r * r)
            colors.append(CGColor(red: 0, green: 0, blue: 0, alpha: CGFloat(a)))
            locs.append(CGFloat(r))
        }
        guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
                                 locations: locs) else { return nil }
        let c = CGPoint(x: Double(n) / 2, y: Double(n) / 2)
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: CGFloat(n) / 2, options: [])
        return ctx.makeImage()
    }()

    static func makeNode() -> SCNNode {
        let plane = SCNPlane(width: 1, height: 1)
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = image
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = false
        m.isDoubleSided = true
        plane.firstMaterial = m
        let node = SCNNode(geometry: plane)
        node.name = "shadow"
        node.renderingOrder = -100   // drawn first, the fly always on top
        node.castsShadow = false
        return node
    }
}

/// Debug staging (FLY_FORCE_STATE): pins the fly to a fixed, representative frame for snapshots.
/// Positions come from the multi-screen World: flight stages at the centre of the primary screen
/// (`screens[0]`), perched stages on the middle of the longest perch site of that side (primary screen
/// preferred), `crossing` on the middle of the longest shared edge, 4 pt inside the screen to its right
/// (or above), heading across it.
enum DebugStage: String, CaseIterable {
    case flying, banking, perched_left, perched_bottom, takeoff, crossing
    /// Not snapshotted: the fly swings ±300 pt across the longest shared edge (period 4 s), to exercise
    /// the panel handoff on the real screens.
    case sweep
    /// v4 (use with FLY_FRIENDS=n): every fly staged — the flock flying in a loose wedge behind Dewey,
    /// or perched side by side on the longest bottom site of the primary screen. See `flockFrame`.
    case flock_flying, flock_perched

    var isFlock: Bool { self == .flock_flying || self == .flock_perched }

    static var current: DebugStage? {
        ProcessInfo.processInfo.environment["FLY_FORCE_STATE"].flatMap(DebugStage.init(rawValue:))
    }

    /// Flock stages: the frame of fly `index` (0 = Dewey) of body length `size` (Dewey: `leaderSize`).
    /// Flying: Dewey at the primary screen centre heading -0.6 rad; friends trail in a loose wedge 2–6
    /// leader body lengths behind, with small heading, bank and wing-phase differences. Perched: Dewey in
    /// the middle of the longest bottom site, friends alternating right/left at 2.6 leader lengths spacing.
    func flockFrame(index: Int, world: World, time: Double, size: Double, leaderSize: Double,
                    clearance: (Perch) -> CGFloat) -> FlyFrame {
        let L = leaderSize
        switch self {
        case .flock_perched:
            var f = DebugStage.perched_bottom.frame(world: world, time: time, clearance: clearance)
            let slot = index == 0 ? 0 : (index % 2 == 1 ? 1 : -1) * ((index + 1) / 2)
            f.position.x += CGFloat(Double(slot) * 2.6 * L)
            f.heading = [0, .pi, 0, .pi, 0.0, .pi][index % 6]
            if index == 3 { f.state = .grooming; f.pose = BodyPose(groomPhase: 1.2, groomAmount: 1) }
            return f
        default:
            // Offsets in Dewey's body frame (forward, left), leader body lengths.
            let slots: [(Double, Double, Double)] = [(0, 0, 0), (-2.4, 2.0, 0.12), (-2.6, -2.2, -0.10),
                                                     (-4.6, 0.4, 0.05), (-5.2, 3.6, 0.2), (-5.6, -3.4, -0.18)]
            let (fw, lf, dh) = slots[index % slots.count]
            var f = DebugStage.flying.frame(world: world, time: time + Double(index) * 0.0061, clearance: clearance)
            let h = f.heading
            f.position.x += CGFloat((fw * cos(h) - lf * sin(h)) * L)
            f.position.y += CGFloat((fw * sin(h) + lf * cos(h)) * L)
            f.heading = h + dh
            f.roll = -dh * 2.5
            return f
        }
    }

    /// `time` advances the wing beat; `clearance` = perch inset (points) for perched stages.
    func frame(world: World, time: Double, clearance: (Perch) -> CGFloat) -> FlyFrame {
        let primary = world.screens.first?.frame ?? world.screenFrame
        let mid = CGPoint(x: primary.midX, y: primary.midY)
        let flap = BodyPose(wingStroke: 1, wingPhase: (2 * .pi * 27 * time).truncatingRemainder(dividingBy: 2 * .pi),
                            legTuck: 1)
        func perched(_ side: Perch, heading: Double) -> FlyFrame {
            let primaryID = world.screens.first?.id
            let sites = world.perchSites.filter { $0.side == side }
            let site = sites.filter { $0.screenID == primaryID }.max { $0.length < $1.length }
                ?? sites.max { $0.length < $1.length }
            let foot = site.map { CGPoint(x: ($0.a.x + $0.b.x) / 2, y: ($0.a.y + $0.b.y) / 2) }
                ?? CGPoint(x: side == .bottom ? mid.x : world.leftX, y: side == .bottom ? world.bottomY : mid.y)
            let n = world.normal(of: side), c = clearance(side)
            return FlyFrame(position: CGPoint(x: foot.x + n.dx * c, y: foot.y + n.dy * c), heading: heading,
                            altitudeScale: 1, state: .perched, perch: side, pose: .rest)
        }
        switch self {
        case .flying, .flock_flying:
            return FlyFrame(position: mid, heading: -0.6, altitudeScale: 1.3, state: .flying, pose: flap,
                            roll: 0, pitch: 0.08)
        case .banking:
            // Turning left hard: left side down (negative roll), slight nose up.
            return FlyFrame(position: mid, heading: 0.4, altitudeScale: 1.3, state: .flying, pose: flap,
                            roll: -0.65, pitch: 0.12)
        case .perched_left:
            return perched(.left, heading: .pi / 2)
        case .perched_bottom, .flock_perched:
            return perched(.bottom, heading: 0)
        case .takeoff:
            var p = flap
            p.legTuck = 0.4
            return FlyFrame(position: mid, heading: 1.2, altitudeScale: 1.12, state: .takingOff, pose: p,
                            roll: 0, pitch: 0.5)
        case .sweep:
            var f = DebugStage.crossing.frame(world: world, time: time, clearance: clearance)
            let dx = 300 * sin(2 * .pi * time / 4)
            f.position.x += CGFloat(dx)
            f.heading = cos(2 * .pi * time / 4) >= 0 ? 0 : .pi
            return f
        case .crossing:
            guard let e = ScreenLayout.sharedEdges(world.screens).max(by: {
                hypot($0.b.x - $0.a.x, $0.b.y - $0.a.y) < hypot($1.b.x - $1.a.x, $1.b.y - $1.a.y)
            }) else {
                return FlyFrame(position: mid, heading: .pi, altitudeScale: 1.3, state: .flying, pose: flap)
            }
            let c = CGPoint(x: (e.a.x + e.b.x) / 2, y: (e.a.y + e.b.y) / 2)
            let vertical = e.a.x == e.b.x
            // Flying across the edge toward -x (or -y), centre still 4 pt on the far side.
            return FlyFrame(position: vertical ? CGPoint(x: c.x + 4, y: c.y) : CGPoint(x: c.x, y: c.y + 4),
                            heading: vertical ? .pi : -.pi / 2, altitudeScale: 1.3, state: .flying, pose: flap,
                            roll: 0, pitch: 0.08)
        }
    }
}
