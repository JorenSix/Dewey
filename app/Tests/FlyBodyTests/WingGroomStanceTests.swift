import AppKit
import Metal
import Foundation
import FlyCore
import SceneKit
import Testing
@testable import FlyBody

// Module F (Dewey v2): figure-eight wingbeat, ghost wings, grooming sequence, standing stance.

private func angle(_ rig: FlyRig, _ n: String) -> Double { rig.joint(named: n)!.angle }

@Test func ghostWingCountAndAlpha() throws {
    let rig = try FlyRig(bundleDirectory: flyResources)
    let anim = JointAnimator(rig: rig)
    #expect(WingGhosts.count == 4)
    #expect(anim.wingGhosts.ghostNodes(side: "left").count == 4)
    #expect(anim.wingGhosts.ghostNodes(side: "right").count == 4)
    let wingMeshes = rig.bodyNode(named: "wing_left")!.childNodes.filter { $0.geometry != nil }.count
    #expect(anim.wingGhosts.ghostMeshNodes.count == 2 * 4 * wingMeshes)
    // A second animator on the same rig reuses the ghosts instead of adding more.
    _ = JointAnimator(rig: rig)
    #expect(rig.node.childNodes(passingTest: { n, _ in (n.name ?? "").hasSuffix("#ghosts") }).count == 2)

    // Alpha falls with k; shared materials per level; no depth writes; geometry shared with the wing.
    let alphas = anim.wingGhosts.materials.map { Double($0.transparency) }
    #expect(abs(alphas[0] - WingGhosts.alpha(1)) < 1e-6)
    for k in 1..<alphas.count { #expect(alphas[k] < alphas[k - 1] && alphas[k] > 0) }
    for (i, a) in alphas.enumerated() { #expect(abs(a - WingGhosts.alpha(i + 1)) < 1e-6) }
    for m in anim.wingGhosts.materials + [anim.wingGhosts.discMaterial] { #expect(!m.writesToDepthBuffer) }
    #expect(Set(anim.wingGhosts.ghostMeshNodes.compactMap { $0.geometry?.firstMaterial.map(ObjectIdentifier.init) }).count == 4)
    #expect(abs(Double(anim.wingGhosts.discMaterial.transparency) - WingGhosts.discAlpha) < 1e-6)
    #expect(anim.wingGhosts.discNodes.count == 2)

    // Full flight: visible, ghost k sits where the real wing was at phase − k·Δ.
    let ph = 0.4
    anim.apply(BodyPose(wingStroke: 1, wingPhase: ph - WingGhosts.delta, legTuck: 1))
    let realEarlier = rig.bodyNode(named: "wing_left")!.simdWorldOrientation
    anim.apply(BodyPose(wingStroke: 1, wingPhase: ph, legTuck: 1))
    let ghost1 = anim.wingGhosts.ghostNodes(side: "left")[0]
    #expect(ghost1.presentation.isHidden == false && ghost1.parent!.isHidden == false)
    #expect(abs(simd_dot(ghost1.simdWorldOrientation.vector, realEarlier.vector)) > 0.9999)
    let g = anim.wingGhosts.ghostNodes(side: "left").map(\.simdWorldOrientation)
    for k in 1..<g.count { #expect(abs(simd_dot(g[k].vector, g[k - 1].vector)) < 0.999) }

    // Invisible below wingStroke 0.3 (and when folded).
    anim.apply(BodyPose(wingStroke: 0.25, wingPhase: ph))
    #expect(ghost1.parent!.isHidden)
    anim.apply(.rest)
    #expect(anim.wingGhosts.discNodes.allSatisfy { $0.parent!.isHidden })
}

@Test func figureEightStroke() throws {
    let rig = try FlyRig(bundleDirectory: flyResources)
    let anim = JointAnimator(rig: rig)
    func sample(_ ph: Double) -> SIMD3<Double> {
        anim.apply(BodyPose(wingStroke: 1, wingPhase: ph, legTuck: 1))
        return SIMD3(angle(rig, "wing_yaw_left"), angle(rig, "wing_roll_left"), angle(rig, "wing_pitch_left"))
    }
    // Rotation flips sign at both stroke reversals (π/2 ventral, 3π/2 dorsal) and is ~90° in total.
    for rev in [Double.pi / 2, 3 * Double.pi / 2] {
        let before = sample(rev - 0.25).z, after = sample(rev + 0.25).z
        #expect(before * after < 0, "pitch must flip at reversal \(rev)")
    }
    #expect(sample(0).z - sample(.pi).z > 1.4)
    // Stroke amplitude about ±69°, deviation at twice the beat frequency.
    let n = 360
    let s = (0..<n).map { sample(2 * .pi * Double($0) / Double(n)) }
    func crossings(_ xs: [Double]) -> Int {
        let m = xs.reduce(0, +) / Double(xs.count)
        return (0..<xs.count).filter { (xs[$0] - m) * (xs[($0 + 1) % xs.count] - m) < 0 }.count
    }
    #expect(crossings(s.map(\.x)) == 2)
    #expect(crossings(s.map(\.y)) == 4)
    let yaws = s.map(\.x)
    #expect(yaws.max()! - yaws.min()! > 2.2)
    // Same yaw on down- and upstroke but different deviation -> the tip path is a loop (figure eight).
    let d = sample(.pi / 4), u = sample(3 * .pi / 4)
    #expect(abs(d.x - u.x) < 1e-6 && abs(d.y - u.y) > 0.2)
    // Right wing mirrors the left (same joint values).
    #expect(abs(angle(rig, "wing_yaw_right") - u.x) < 1e-9)
}

@Test func groomSequenceOrder() throws {
    #expect(GroomStage.allCases == [.head, .frontLegs, .abdomen, .wingLeft, .wingRight])
    var c = 0.0, seen: [GroomStage] = []
    while c < GroomStage.sequenceCycles {
        let st = GroomStage.at(cycle: c).stage
        if seen.last != st { seen.append(st) }
        c += 0.25
    }
    #expect(seen == GroomStage.allCases)
    for len in GroomStage.cycles { #expect(len / 3 >= 2 && len / 3 <= 4) } // 2–4 s at 3 Hz

    // FlyController wraps groomPhase at 2π; the animator unwraps it. 3 Hz for 9 s at 60 fps -> cycle 27.
    let rig = try FlyRig(bundleDirectory: flyResources)
    let anim = JointAnimator(rig: rig)
    var ph = 0.0
    for _ in 0..<(9 * 60) {
        ph = (ph + 2 * .pi * 3 / 60).truncatingRemainder(dividingBy: 2 * .pi)
        anim.apply(BodyPose(groomPhase: ph, groomAmount: 1))
    }
    #expect(abs(anim.groomCycles - 27) < 0.1)
    #expect(anim.groomStage == .wingLeft)
    anim.apply(BodyPose(groomPhase: ph, groomAmount: 0)) // bout ends -> next bout restarts at the head
    #expect(anim.groomStage == .head && anim.groomCycles == 0)
}

/// Triangles of a body's meshes in the rig frame.
private func wingTriangles(_ rig: FlyRig, _ body: String) -> [(simd_float3, simd_float3, simd_float3)] {
    var out: [(simd_float3, simd_float3, simd_float3)] = []
    for mn in rig.meshNodes(ofBody: body) {
        guard let geo = mn.geometry, let el = geo.elements.first, el.bytesPerIndex == 4 else { continue }
        let m = rig.rootTransform(of: mn)
        let v = FlyRig.vertices(of: geo).map { p -> simd_float3 in let q = m * simd_float4(p, 1); return simd_float3(q.x, q.y, q.z) }
        let idx: [UInt32] = el.data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        for t in stride(from: 0, to: idx.count - 2, by: 3) { out.append((v[Int(idx[t])], v[Int(idx[t + 1])], v[Int(idx[t + 2])])) }
    }
    return out
}

/// Closest point on triangle (a, b, c) to p (Ericson, Real-Time Collision Detection 5.1.5).
private func closestPoint(_ p: simd_float3, _ t: (simd_float3, simd_float3, simd_float3)) -> simd_float3 {
    let (a, b, c) = t
    let ab = b - a, ac = c - a, ap = p - a
    let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
    if d1 <= 0 && d2 <= 0 { return a }
    let bp = p - b, d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
    if d3 >= 0 && d4 <= d3 { return b }
    let vc = d1 * d4 - d3 * d2
    if vc <= 0 && d1 >= 0 && d3 <= 0 { return a + ab * (d1 / (d1 - d3)) }
    let cp = p - c, d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
    if d6 >= 0 && d5 <= d6 { return c }
    let vb = d5 * d2 - d1 * d6
    if vb <= 0 && d2 >= 0 && d6 <= 0 { return a + ac * (d2 / (d2 - d6)) }
    let va = d3 * d6 - d5 * d4
    if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0 { return b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))) }
    let den = 1 / (va + vb + vc)
    return a + ab * (vb * den) + ac * (vc * den)
}

/// Fresh animator posed at `cycle` groom cycles (continuous phase selects the stage directly).
private func groomPose(_ rig: FlyRig, cycle: Double) -> JointAnimator {
    let anim = JointAnimator(rig: rig)
    anim.apply(BodyPose(groomPhase: 2 * .pi * cycle, groomAmount: 1))
    return anim
}

@Test func wingGroomingMovesHindLegAndWingTogether() throws {
    let rig = try FlyRig(bundleDirectory: flyResources)
    let start = GroomStage.cycles[0..<3].reduce(0, +) // first wingLeft cycle
    let legJ = ["coxa_T3_left", "femur_T3_left", "tibia_T3_left"], wingJ = ["wing_yaw_left", "wing_roll_left"]

    // Early in the power stroke (near the wing base) vs late (near the tip).
    let a1 = groomPose(rig, cycle: start + 3 + 0.05)
    #expect(a1.groomStage == .wingLeft)
    let leg1 = legJ.map { angle(rig, $0) }, wing1 = wingJ.map { angle(rig, $0) }
    // Wing lowered (roll + from rest 0.7) and abducted (yaw below folded 1.5); other side untouched.
    #expect(wing1[1] > rig.joint(named: "wing_roll_left")!.restAngle + 0.2)
    #expect(wing1[0] < rig.joint(named: "wing_yaw_left")!.restAngle - 0.2)
    #expect(abs(angle(rig, "wing_roll_right") - rig.joint(named: "wing_roll_right")!.restAngle) < 1e-9)
    #expect(abs(angle(rig, "femur_T3_right")) < 1e-9) // right hind leg keeps standing
    #expect(leg1.contains { abs($0) > 0.3 })
    // The claw rests on the wing: within 0.05 rig units of the wing mesh.
    func clawToWing() -> Float {
        let claw = rig.vertices(ofBodies: ["claw_T3_left"]), tris = wingTriangles(rig, "wing_left")
        return claw.map { c in tris.map { simd_distance(closestPoint(c, $0), c) }.min()! }.min()!
    }
    let d1 = clawToWing()

    _ = groomPose(rig, cycle: start + 3 + 0.3)
    let leg2 = legJ.map { angle(rig, $0) }, wing2 = wingJ.map { angle(rig, $0) }
    let d2 = clawToWing()
    print("wing groom: leg", leg1, "->", leg2, "wing", wing1, "->", wing2, "claw-wing", d1, d2)
    #expect(zip(leg1, leg2).contains { abs($0 - $1) > 0.2 })   // the leg sweeps …
    #expect(zip(wing1, wing2).contains { abs($0 - $1) > 0.02 }) // … and the wing moves with it
    #expect(d1 < 0.05 && d2 < 0.05)

    // Mirror stage: right hind leg + right wing.
    let a3 = groomPose(rig, cycle: start + GroomStage.cycles[3] + 3.3)
    #expect(a3.groomStage == .wingRight)
    #expect(angle(rig, "wing_roll_right") > rig.joint(named: "wing_roll_right")!.restAngle + 0.2)
    #expect(abs(angle(rig, "femur_T3_left")) < 1e-9)
}

@Test func standingFootContact() throws {
    let rig = try FlyRig(bundleDirectory: flyResources)
    let anim = JointAnimator(rig: rig)
    anim.apply(BodyPose(wingStroke: 1, wingPhase: 1, legTuck: 1)) // measuring must not disturb the pose
    let before = angle(rig, "femur_T2_left")
    let off = anim.footContactOffset
    #expect(angle(rig, "femur_T2_left") == before)
    print("footContactOffset", off, "bodyHalfWidth", anim.bodyHalfWidth, "stanceHalfWidth", anim.stanceHalfWidth)
    #expect(off > 0.2 && off < 0.8)
    #expect(anim.bodyHalfWidth > 0.05 && anim.bodyHalfWidth < anim.stanceHalfWidth)

    anim.apply(BodyPose()) // perched: legTuck 0
    let all = rig.vertices(ofBodies: JointAnimator.legs.flatMap { rig.tarsalBodies(leg: $0) })
    #expect(abs(all.map(\.y).min()! + off) < 0.005)
    // All six legs touch the ground plane, and nothing of the body is below it.
    for leg in JointAnimator.legs {
        let lo = rig.vertices(ofBodies: rig.tarsalBodies(leg: leg)).map(\.y).min()!
        #expect(abs(lo + off) < 0.02, "\(leg) tarsus not on the ground: \(lo)")
    }
    let body = rig.vertices(ofBodies: rig.bodyNames.filter { !$0.contains("_T") })
    #expect(body.map(\.y).min()! > -off + 0.05)
}

// MARK: renders (renders/v2/F_*.png)

private func composite(_ images: [NSImage], to url: URL) throws {
    let w = images.reduce(0) { $0 + Int($1.size.width) }, h = Int(images.map(\.size.height).max() ?? 0)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    var x = 0.0
    for im in images {
        im.draw(in: NSRect(x: x, y: 0, width: im.size.width, height: im.size.height))
        x += im.size.width
    }
    NSGraphicsContext.restoreGraphicsState()
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// Offscreen render of the rig from an arbitrary eye point (rig frame; +y dorsal, +x head, +z right).
private func renderView(_ rig: FlyRig, eye: simd_float3, up: simd_float3 = simd_float3(0, 1, 0),
                        ortho: Double? = nil, extra: [SCNNode] = [], size: CGSize = CGSize(width: 512, height: 512)) -> NSImage {
    let scene = SCNScene()
    scene.background.contents = NSColor.white
    let parent = rig.node.parent
    let saved = rig.node.simdTransform
    rig.node.removeFromParentNode()
    rig.node.simdTransform = matrix_identity_float4x4
    scene.rootNode.addChildNode(rig.node)
    for n in extra { scene.rootNode.addChildNode(n) }
    defer {
        rig.node.removeFromParentNode(); rig.node.simdTransform = saved; parent?.addChildNode(rig.node)
        for n in extra { n.removeFromParentNode() }
    }
    let cam = SCNCamera()
    cam.fieldOfView = 30; cam.zNear = 0.05; cam.zFar = 20
    if let o = ortho { cam.usesOrthographicProjection = true; cam.orthographicScale = o }
    let camNode = SCNNode(); camNode.camera = cam
    camNode.simdPosition = eye
    let f = simd_normalize(simd_float3(-0.2, 0, 0) - eye), right = simd_normalize(simd_cross(f, up))
    camNode.simdOrientation = simd_quatf(simd_float3x3(columns: (right, simd_cross(right, f), -f)))
    scene.rootNode.addChildNode(camNode)
    let key = SCNNode(); key.light = SCNLight(); key.light!.type = .directional; key.light!.intensity = 900
    key.simdLook(at: simd_float3(0.2, -1, 0.3)); scene.rootNode.addChildNode(key)
    let fill = SCNNode(); fill.light = SCNLight(); fill.light!.type = .ambient; fill.light!.intensity = 450
    scene.rootNode.addChildNode(fill)
    let r = SCNRenderer(device: MTLCreateSystemDefaultDevice()!, options: nil)
    r.scene = scene; r.pointOfView = camNode; r.autoenablesDefaultLighting = false
    return r.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
}

@Test func rendersV2() throws {
    let rig = try FlyRig(bundleDirectory: flyResources)
    let anim = JointAnimator(rig: rig)
    let dir = repoRoot.appendingPathComponent("renders/v2")

    // Flapping with ghosts + blur disc: top view and a three-quarter perspective (front-left, above).
    anim.apply(BodyPose(wingStroke: 1, wingPhase: 0.6, legTuck: 1))
    let top = renderView(rig, eye: simd_float3(-0.2, 3.3, 0), up: simd_float3(0, 0, -1), ortho: 1.0)
    let q34 = renderView(rig, eye: simd_float3(1.6, 2.0, -2.0))
    try composite([top, q34], to: dir.appendingPathComponent("F_flap_ghosts.png"))

    // Wing grooming (left wing): mid power stroke from rear-left-above, and late stroke from the left.
    let start = GroomStage.cycles[0..<3].reduce(0, +)
    _ = groomPose(rig, cycle: start + 3 + 0.25)
    let g1 = renderView(rig, eye: simd_float3(-2.4, 2.0, -1.6))
    _ = groomPose(rig, cycle: start + 3 + 0.5)
    let g2 = renderView(rig, eye: simd_float3(-0.4, 0.8, -3.2))
    try composite([g1, g2], to: dir.appendingPathComponent("F_groom_wing.png"))

    // Standing, orthographic side view from the left, ground line at y = −footContactOffset.
    anim.apply(BodyPose())
    let off = anim.footContactOffset
    let ground = SCNNode(geometry: SCNBox(width: 1.8, height: 0.004, length: 1.6, chamferRadius: 0))
    ground.geometry!.firstMaterial!.diffuse.contents = NSColor(srgbRed: 0.1, green: 0.4, blue: 0.9, alpha: 1)
    ground.geometry!.firstMaterial!.lightingModel = .constant
    ground.simdPosition = simd_float3(-0.2, -off - 0.002, 0)
    let side = renderView(rig, eye: simd_float3(-0.2, 0, -3.3), ortho: 0.75, extra: [ground])
    let front = renderView(rig, eye: simd_float3(3.1, 0, 0), ortho: 0.75, extra: [ground])
    try composite([side, front], to: dir.appendingPathComponent("F_stance_side.png"))

    for f in ["F_flap_ghosts", "F_groom_wing", "F_stance_side"] {
        let size = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("\(f).png").path)[.size] as? Int ?? 0
        #expect(size > 10_000, "\(f).png too small")
    }
}
