import AppKit
import SceneKit
import FlyCore
import FlyBehavior
import simd

/// What a `FlyActor` needs from the overlay: the per-screen panels and the World screen names.
@MainActor
protocol FlyActorHost: AnyObject {
    var hostPanels: [Int: OverlayPanel] { get }
    var hostDisplays: [DisplayInfo] { get }
    var hostWorldNames: [Int: String] { get }
    /// The actor's view moved to another panel (the display link follows Dewey's view).
    func actorDidRehost(_ actor: FlyActor)
}

/// One fly on screen (v4): its `FlyController` + `Brain`, its `FlyRenderable`, and its own small
/// follower SCNView with scene, tilted camera, pose nodes (`flyRoot` → heading → pitch → roll →
/// renderable) and shadow; plus the per-fly presentation state (edge clearance, perch offset, smoothing)
/// and the logic that re-parents the view into the panel of the screen under the fly.
///
/// Scene units are AppKit global screen points (the same space as `World`); see `OverlayController`.
/// Dewey is actor 0 (`isLeader`), friends are 1…5 with a fixed `sizeFactor` × Dewey's size.
@MainActor
final class FlyActor {
    let id: Int
    let controller: FlyController
    let brain: Brain
    /// Size relative to Dewey (1 for Dewey, drawn once from `DeweySettings.friendSizeFactor` for a friend).
    let sizeFactor: Double
    private(set) var renderable: FlyRenderable
    /// Body length on screen, points.
    private(set) var flySize: Double
    var tuning = PoseTuning()
    unowned let host: FlyActorHost

    private(set) var scnView: SCNView?
    private let scene = SCNScene()
    private let cameraNode = SCNNode()
    let flyRoot = SCNNode()
    private let headingNode = SCNNode()
    private let pitchNode = SCNNode()
    private let rollNode = SCNNode()
    private let shadowNode = ShadowTexture.makeNode()
    /// Plane (scene z) of the fly root and camera target.
    let planeZ: CGFloat = 100
    /// Edge length (points) of the small follower view; see `viewSize(forFlySize:)`.
    private(set) var viewSize: CGFloat
    private(set) var viewOrigin = CGPoint.zero
    private var camera = TiltCamera()
    /// Light direction (scene space, pointing from the light): upper-left, in front of the screen.
    private let lightDirection = simd_normalize(simd_double3(0.45, -0.55, -1))
    /// Display whose panel hosts `scnView`; World screen of the fly's centre (for the crossing log).
    private(set) var hostID: Int?
    private var flyScreenID: Int?

    // Smoothed presentation state.
    private(set) var shownRoll = 0.0, shownPitch = 0.0
    private var perchOffset = CGVector.zero
    private var airBlend = 1.0
    private var yawRateEstimate = 0.0
    private var lastHeading: Double?
    private(set) var lastFrame: FlyFrame
    private var clearance: [Perch: CGFloat] = [:]
    /// True while a removed friend fades out.
    private(set) var removing = false

    var name: String { id == 0 ? "Dewey" : "friend \(id)" }

    init(id: Int, controller: FlyController, brain: Brain, renderable: FlyRenderable, size: Double,
         sizeFactor: Double, host: FlyActorHost) {
        self.id = id
        self.controller = controller
        self.brain = brain
        self.renderable = renderable
        self.flySize = size
        self.sizeFactor = sizeFactor
        self.host = host
        viewSize = FlyActor.viewSize(forFlySize: size)
        lastFrame = controller.frame
        controller.flockID = id
        controller.isLeader = id == 0
        controller.bodySize = size
        controller.onLanded = { site in
            NSLog("Dewey: %@ %@", id == 0 ? "Dewey" : "friend \(id)",
                  FlyController.landingDescription(site))
        }
        buildScene()
        updateClearance()
    }

    /// View edge length for a fly size: wingspan ≈ 1.3 body lengths × altitude 1.4, plus the shadow offset.
    static func viewSize(forFlySize s: Double) -> CGFloat {
        let v = Int((s * 3.4 + 32).rounded(.up))
        return CGFloat(max(128, v + v % 2))
    }

    // MARK: - Size and edge clearance

    func setSize(_ s: Double) {
        guard s != flySize else { return }
        flySize = s
        controller.bodySize = s
        viewSize = FlyActor.viewSize(forFlySize: s)
        scnView?.setFrameSize(CGSize(width: viewSize, height: viewSize))
        updateClearance()
        layoutCamera()
        apply(lastFrame, dt: 0)
    }

    /// Worst-case (over the three edges) distance from a perched body centre to the perch line; this
    /// fly's `World.perchInset` (each controller holds its own World copy, so the inset is per fly).
    var perchClearance: CGFloat { clearance.values.max() ?? CGFloat(renderable.footContact * CGFloat(flySize)) }

    /// Per-edge clearance (points). The drawn fly is shifted by the difference between this and its actual
    /// distance to the perch line, so the feet touch the edge whatever `World.perchInset` is.
    func perchClearance(for perch: Perch) -> CGFloat {
        clearance[perch] ?? CGFloat(renderable.footContact * CGFloat(flySize))
    }

    func updateClearance() {
        for p in [Perch.left, .right, .bottom] { clearance[p] = computeClearance(p) }
        controller.world.perchInset = perchClearance
    }

    /// Projects the standing-pose feet through the perched transform and the tilted camera; the largest
    /// screen distance against the edge normal is where the line must be.
    private func computeClearance(_ perch: Perch) -> CGFloat {
        let feet = renderable.footPoints
        guard !feet.isEmpty else { return CGFloat(renderable.footContact * CGFloat(flySize)) }
        let heading: Double = perch == .bottom ? 0 : .pi / 2
        let (roll, pitch) = perchAngles(perch, heading: heading, sourceRoll: 0, sourcePitch: 0)
        let m = rotation(heading: heading, pitch: pitch, roll: roll)
        let s = flySize / Double(renderable.bodyLength)
        let n = normal(perch)
        var best = 0.0
        for f in feet {
            let sp = camera.project(m * (f * s))
            best = max(best, -(Double(sp.x) * n.x + Double(sp.y) * n.y))
        }
        return CGFloat(best)
    }

    private func normal(_ perch: Perch) -> simd_double2 {
        let v = controller.world.normal(of: perch)
        return simd_double2(Double(v.dx), Double(v.dy))
    }

    /// Same rotation as headingNode → pitchNode → rollNode.
    private func rotation(heading: Double, pitch: Double, roll: Double) -> simd_double3x3 {
        let q = simd_quatd(angle: heading, axis: simd_double3(0, 0, 1))
            * simd_quatd(angle: -pitch, axis: simd_double3(0, 1, 0))
            * simd_quatd(angle: roll, axis: simd_double3(1, 0, 0))
        return simd_double3x3(q)
    }

    /// Three-quarter perched roll/pitch: feet toward the edge, rolled `perchRoll` instead of 90°, and on a
    /// side edge a slight nose-toward-viewer turn. `sourceRoll` only sets how far into the perch tilt the
    /// fly is (it grows from 0 after touchdown); 0 means fully perched.
    private func perchAngles(_ perch: Perch, heading: Double, sourceRoll: Double, sourcePitch: Double) -> (Double, Double) {
        let full = tuning.perchRoll(perch)
        let mag = sourceRoll == 0 ? full : min(abs(sourceRoll), full)
        let k = mag / full
        let roll = PoseTuning.feetSign(perch: perch, heading: heading) * mag
        let extra = perch == .bottom ? tuning.bottomEdgePitch : tuning.sideEdgeTowardViewer
        return (roll, sourcePitch + extra * k)
    }

    func setRenderable(_ r: FlyRenderable) {
        renderable.node.removeFromParentNode()
        renderable = r
        rollNode.addChildNode(r.node)
        updateClearance()
    }

    /// New screens: a fresh World keeping this fly's own perch inset.
    func setScreens(_ screens: [ScreenInfo]) {
        let inset = controller.world.perchInset
        controller.world = World(screens: screens, perchInset: inset).withWindows(controller.world.windows)
        flyScreenID = nil
        updateClearance()
        layoutCamera()
        apply(controller.frame, dt: 0)
    }

    // MARK: - Scene and view

    private func buildScene() {
        scene.background.contents = NSColor.clear
        let cam = SCNCamera()
        cam.usesOrthographicProjection = false
        cam.projectionDirection = .vertical
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)
        layoutCamera()

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.color = NSColor(white: 0.34, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.color = NSColor(white: 1.0, alpha: 1)
        key.light!.intensity = 1150
        key.simdLook(at: simd_float3(lightDirection))
        scene.rootNode.addChildNode(key)

        // Cool, weak rim/fill from the lower right and behind, so the far side keeps some shape.
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light!.type = .directional
        fill.light!.color = NSColor(calibratedRed: 0.55, green: 0.6, blue: 0.7, alpha: 1)
        fill.light!.intensity = 450
        fill.simdLook(at: simd_float3(-0.6, 0.7, 0.4))
        scene.rootNode.addChildNode(fill)

        scene.rootNode.addChildNode(shadowNode)
        rollNode.addChildNode(renderable.node)
        pitchNode.addChildNode(rollNode)
        headingNode.addChildNode(pitchNode)
        flyRoot.addChildNode(headingNode)
        scene.rootNode.addChildNode(flyRoot)
        apply(controller.frame, dt: 0)
    }

    /// Perspective camera tilted `camera.tilt`, at the distance where 1 unit = 1 pt on the target plane,
    /// aimed at the centre of the small view.
    private func layoutCamera() {
        camera.viewSize = Double(viewSize)
        let d = camera.distance
        cameraNode.camera?.fieldOfView = CGFloat(camera.fieldOfView)
        cameraNode.camera?.zNear = max(1, d - 4 * Double(viewSize))
        cameraNode.camera?.zFar = d + 4 * Double(viewSize)
        cameraNode.eulerAngles = SCNVector3(-CGFloat(camera.tilt), 0, 0)
        follow(lastFrame.position)
    }

    /// View centre (scene = global coordinates) = camera target.
    var viewCentre: CGPoint { CGPoint(x: viewOrigin.x + viewSize / 2, y: viewOrigin.y + viewSize / 2) }
    /// The view's rectangle in global points.
    var viewRect: CGRect { CGRect(origin: viewOrigin, size: CGSize(width: viewSize, height: viewSize)) }

    /// Moves the small view (snapped to whole points) and the camera so the fly stays centred.
    private func follow(_ position: CGPoint) {
        rehost(for: position)
        viewOrigin = CGPoint(x: (position.x - viewSize / 2).rounded(), y: (position.y - viewSize / 2).rounded())
        let origin = hostID.flatMap { host.hostPanels[$0]?.frame.origin } ?? .zero
        scnView?.setFrameOrigin(CGPoint(x: viewOrigin.x - origin.x, y: viewOrigin.y - origin.y))
        let c = viewCentre, o = camera.offset
        cameraNode.position = SCNVector3(c.x + o.x, c.y + o.y, planeZ + o.z)
    }

    /// Creates the follower SCNView (once the panels exist) and hosts it.
    func makeView() {
        guard scnView == nil else { return }
        let v = SCNView(frame: CGRect(origin: .zero, size: CGSize(width: viewSize, height: viewSize)),
                        options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        v.scene = scene
        v.pointOfView = cameraNode
        v.backgroundColor = .clear
        v.wantsLayer = true
        v.layer?.isOpaque = false
        v.antialiasingMode = .multisampling2X
        v.preferredFramesPerSecond = 60
        v.isPlaying = false  // redraw on scene changes only; the overlay's display link drives updates
        v.rendersContinuously = false
        scnView = v
        follow(lastFrame.position)
    }

    /// Panels were rebuilt or resized: forget a host whose panel is gone and re-host.
    func panelsChanged() {
        if let h = hostID, host.hostPanels[h] == nil { scnView?.removeFromSuperview(); hostID = nil }
        follow(lastFrame.position)
    }

    /// Picks the panel for the fly's centre and moves the SCNView there when it changes. Logs a crossing
    /// whenever the World screen containing the centre changes.
    private func rehost(for position: CGPoint) {
        let names = host.hostWorldNames
        if let s = controller.world.screen(containing: position), s.id != flyScreenID {
            let first = flyScreenID == nil
            flyScreenID = s.id
            if first {
                NSLog("Dewey: %@ on screen %@", name, names[s.id] ?? "#\(s.id)")
            } else {
                NSLog("Dewey: %@ now on screen %@ at (%.0f,%.0f) state=%@", name, names[s.id] ?? "#\(s.id)",
                      position.x, position.y, lastFrame.state.rawValue)
            }
        }
        let panels = host.hostPanels, displays = host.hostDisplays
        guard let v = scnView, !panels.isEmpty else { return }
        var target = displays.first(where: { $0.frame.contains(position) })?.id
        if target == nil, let h = hostID, panels[h] != nil { target = h }
        if target == nil { target = displays.first?.id }
        guard let tid = target, tid != hostID || v.superview == nil, let panel = panels[tid] else { return }
        v.removeFromSuperview()
        panel.contentView?.addSubview(v)
        hostID = tid
        host.actorDidRehost(self)
        if let d = displays.first(where: { $0.id == tid }) {
            NSLog("Dewey: %@ view hosted on display \"%@\" (scale %.0f)", name, d.name, d.scale)
        }
    }

    /// Removes the view (fading it out first when `fade`), then calls `done`.
    func remove(fade: Bool, done: @escaping @MainActor () -> Void) {
        removing = true
        guard fade, let v = scnView, v.superview != nil else {
            scnView?.removeFromSuperview()
            done()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            v.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                v.removeFromSuperview()
                done()
            }
        })
    }

    // MARK: - Applying a frame

    func apply(_ frame: FlyFrame, dt: Double, staged: Bool = false) {
        lastFrame = frame
        let perched = frame.perch != nil && (frame.state == .perched || frame.state == .walking || frame.state == .grooming)
        let k = dt > 0 ? 1.0 : 0.0 // dt == 0: snap (initial frame / size change)

        var srcRoll = frame.roll
        if srcRoll == 0, !staged { srcRoll = controller.bodyRoll }
        var roll: Double, pitch: Double
        if perched, let perch = frame.perch {
            (roll, pitch) = perchAngles(perch, heading: frame.heading, sourceRoll: srcRoll, sourcePitch: frame.pitch)
        } else {
            if let h = lastHeading, dt > 0 {
                let rate = angleDiff(frame.heading, h) / dt
                yawRateEstimate += (rate - yawRateEstimate) * min(1, 8 * dt)
            }
            let maxRoll = tuning.sideEdgeRoll
            roll = min(max(srcRoll, -maxRoll), maxRoll)
            if frame.roll == 0 && abs(roll) < 0.02 {
                roll = min(max(-yawRateEstimate * controller.speed / tuning.bankDivisor, -tuning.maxBank), tuning.maxBank)
            }
            pitch = frame.pitch
            if pitch == 0 {
                pitch = frame.state == .takingOff ? tuning.takeoffPitch : frame.state == .landing ? tuning.landingPitch : 0
            }
        }
        lastHeading = frame.heading
        if k == 0 || abs(roll - shownRoll) > 2.0 { shownRoll = roll } else { shownRoll += (roll - shownRoll) * min(1, 12 * dt) }
        if k == 0 { shownPitch = pitch } else { shownPitch += (pitch - shownPitch) * min(1, 10 * dt) }

        // Edge standing: shift the drawn fly so the projected feet sit exactly on the perch line.
        var targetOffset = CGVector.zero
        if perched, let perch = frame.perch {
            let gap = perchClearance(for: perch) - perchLineDistance(perch, from: frame.position)
            let g = min(max(gap, -CGFloat(flySize)), CGFloat(flySize))
            let n = controller.world.normal(of: perch)
            targetOffset = CGVector(dx: n.dx * g, dy: n.dy * g)
        }
        let a = k == 0 ? 1 : min(1, 10 * dt)
        perchOffset.dx += (targetOffset.dx - perchOffset.dx) * a
        perchOffset.dy += (targetOffset.dy - perchOffset.dy) * a
        let shown = CGPoint(x: frame.position.x + perchOffset.dx, y: frame.position.y + perchOffset.dy)

        // No explicit SCNTransaction: its commit waits for SceneKit's (global) render lock, and with one
        // SCNView per fly the main thread blocked for 40-130 ms per tick (p95) with 5 friends. Changes made
        // outside an explicit transaction are applied in the implicit one at the end of the run-loop turn,
        // unanimated (implicit duration 0).
        follow(shown)
        flyRoot.position = SCNVector3(shown.x, shown.y, planeZ)
        let s = CGFloat(flySize) / renderable.bodyLength * CGFloat(frame.altitudeScale)
        flyRoot.scale = SCNVector3(s, s, s)
        headingNode.eulerAngles = SCNVector3(0, 0, CGFloat(frame.heading))
        pitchNode.eulerAngles = SCNVector3(0, CGFloat(-shownPitch), 0)
        rollNode.eulerAngles = SCNVector3(CGFloat(shownRoll), 0, 0)
        renderable.apply(frame: frame)
        updateShadow(frame, perched: perched, shown: shown, dt: dt)
    }

    /// The perch site the fly sits on: of the World's sites on side `perch`, the one closest to `p`.
    func perchSite(_ perch: Perch, near p: CGPoint) -> PerchSite? {
        controller.world.perchSites.filter { $0.side == perch }.min { a, b in
            segmentDistance(p, a) < segmentDistance(p, b)
        }
    }

    private func segmentDistance(_ p: CGPoint, _ s: PerchSite) -> CGFloat {
        let dx = s.b.x - s.a.x, dy = s.b.y - s.a.y
        let l2 = dx * dx + dy * dy
        let t = l2 > 0 ? min(max(((p.x - s.a.x) * dx + (p.y - s.a.y) * dy) / l2, 0), 1) : 0
        return hypot(p.x - (s.a.x + t * dx), p.y - (s.a.y + t * dy))
    }

    /// Distance from `p` to the perch line of the site it is perched on, along that side's normal.
    private func perchLineDistance(_ perch: Perch, from p: CGPoint) -> CGFloat {
        guard let s = perchSite(perch, near: p) else { return CGFloat(controller.world.distance(to: perch, from: p)) }
        switch perch {
        case .left: return p.x - s.a.x
        case .right: return s.a.x - p.x
        case .bottom: return p.y - s.a.y
        }
    }

    /// Soft contact/drop shadow on the screen surface. In flight: offset along the light, larger, softer and
    /// fainter with altitude. Perched: a narrow smudge along the edge under the feet.
    private func updateShadow(_ frame: FlyFrame, perched: Bool, shown: CGPoint, dt: Double) {
        let size = flySize
        airBlend += ((perched ? 0 : 1) - airBlend) * (dt > 0 ? min(1, 6 * dt) : 1)
        let w = airBlend

        let alt = min(max((frame.altitudeScale - 1) / 0.3, 0), 1.5)
        let h = size * (0.15 + 1.0 * alt)                       // virtual height above the screen, points
        let l = lightDirection
        let flyOff = simd_double2(l.x / -l.z, l.y / -l.z) * h
        let flyLen = size * (0.95 + 0.45 * alt), flyWid = size * (0.55 + 0.45 * alt * min(1, frame.pose.wingStroke + 0.3))
        let flyAlpha = 0.36 * (1 - 0.4 * min(alt, 1))
        let flyAngle = frame.heading

        var perchOff = simd_double2.zero, perchAngle = flyAngle
        if let perch = frame.perch {
            let n = normal(perch)
            let c = Double(perchClearance(for: perch))
            perchOff = -n * c * 0.55
            perchAngle = perch == .bottom ? 0 : .pi / 2
            if abs(angleDiff(perchAngle, flyAngle)) > .pi / 2 { perchAngle += .pi }
        }
        let perchLen = size * 1.05, perchWid = Double(perchClearance(for: frame.perch ?? .bottom)) * 0.85
        let perchAlpha = 0.42

        let off = perchOff * (1 - w) + flyOff * w
        let angle = perchAngle + angleDiff(flyAngle, perchAngle) * w
        let len = perchLen * (1 - w) + flyLen * w, wid = perchWid * (1 - w) + flyWid * w
        let alpha = perchAlpha * (1 - w) + flyAlpha * w

        let c = viewCentre
        let screenOff = CGPoint(x: Double(shown.x - c.x) + off.x, y: Double(shown.y - c.y) + off.y)
        let p = camera.unproject(screenOff, planeZ: -2)
        shadowNode.simdPosition = simd_float3(Float(Double(c.x) + p.x), Float(Double(c.y) + p.y), Float(Double(planeZ) + p.z))
        shadowNode.simdOrientation = simd_quatf(angle: -Float(camera.tilt), axis: simd_float3(1, 0, 0))
            * simd_quatf(angle: Float(angle), axis: simd_float3(0, 0, 1))
        shadowNode.simdScale = simd_float3(Float(len), Float(wid), 1)
        shadowNode.opacity = CGFloat(alpha)
    }
}
