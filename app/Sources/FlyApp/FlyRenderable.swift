import AppKit
import SceneKit
import FlyCore
import simd

/// Something that draws the fly. The overlay owns a parent node that carries position, heading
/// (rotation about the view axis), altitude scale and perch roll; `node` is added beneath it.
///
/// Conventions for `node` (local space, scene units = screen points):
/// - forward (head) = +x, fly's left = +y, dorsal = +z (toward the viewer, top-down view)
/// - origin at the body centre, body roughly 30-40 pt long
/// - `apply(frame:)` animates the pose only (wings, legs, head) from `frame.pose` / `frame.state`.
@MainActor
protocol FlyRenderable: AnyObject {
    var node: SCNNode { get }
    func apply(frame: FlyFrame)
    /// Body length (head to abdomen tip) of `node` in its parent's units; the overlay scales by size / this.
    var bodyLength: CGFloat { get }
    /// Foot (tarsal claw) positions in the standing pose, in `node`'s parent space (same units as bodyLength).
    var footPoints: [simd_double3] { get }
    /// Distance from the body centre to the sole plane (ventral, along -z) in rig units (body lengths).
    var footContact: CGFloat { get }
}

extension FlyRenderable {
    var footContact: CGFloat {
        let lowest = footPoints.map { -$0.z }.max() ?? 0.25 * Double(bodyLength)
        return CGFloat(lowest) / bodyLength
    }
}

/// Obvious placeholder: dark ellipsoid body, a head, and two translucent wing planes.
@MainActor
final class PlaceholderFly: FlyRenderable {
    let node = SCNNode()
    private let leftHinge = SCNNode()
    private let rightHinge = SCNNode()
    private let legs = SCNNode()
    let bodyLength: CGFloat = 38
    /// Leg cylinders end ~9.5 pt below and 7 pt beside the body centre.
    let footPoints: [simd_double3] = [6.0, 0, -6].flatMap { x in [1.0, -1].map { simd_double3(x, 7 * $0, -9) } }

    init() {
        let bodyMat = SCNMaterial()
        bodyMat.diffuse.contents = NSColor(calibratedRed: 0.18, green: 0.12, blue: 0.08, alpha: 1)
        bodyMat.specular.contents = NSColor(white: 0.6, alpha: 1)
        bodyMat.shininess = 0.4

        let body = SCNNode(geometry: SCNSphere(radius: 1))
        body.geometry?.firstMaterial = bodyMat
        body.scale = SCNVector3(14, 6, 5.5)
        body.position = SCNVector3(-3, 0, 0)
        node.addChildNode(body)

        let head = SCNNode(geometry: SCNSphere(radius: 5))
        let eyeMat = SCNMaterial()
        eyeMat.diffuse.contents = NSColor(calibratedRed: 0.65, green: 0.08, blue: 0.05, alpha: 1)
        head.geometry?.firstMaterial = eyeMat
        head.position = SCNVector3(13, 0, 0.5)
        node.addChildNode(head)

        let wingMat = SCNMaterial()
        wingMat.diffuse.contents = NSColor(calibratedRed: 0.85, green: 0.9, blue: 0.97, alpha: 0.45)
        wingMat.isDoubleSided = true
        wingMat.lightingModel = .constant
        wingMat.writesToDepthBuffer = false

        for (hinge, side) in [(leftHinge, 1.0), (rightHinge, -1.0)] {
            hinge.position = SCNVector3(4, CGFloat(side * 2.5), 4)
            let plane = SCNPlane(width: 9, height: 24)
            plane.cornerRadius = 4.5
            plane.firstMaterial = wingMat
            let wing = SCNNode(geometry: plane)
            // Plane spans x (chord) by y (span); offset so the hinge is at the wing root.
            wing.position = SCNVector3(-2, CGFloat(side * 12), 0)
            hinge.addChildNode(wing)
            node.addChildNode(hinge)
        }

        // Stubby legs, visible mostly in the perched side view.
        let legMat = SCNMaterial()
        legMat.diffuse.contents = NSColor(white: 0.1, alpha: 1)
        for i in 0..<3 {
            for side in [1.0, -1.0] {
                let leg = SCNNode(geometry: SCNCylinder(radius: 0.8, height: 9))
                leg.geometry?.firstMaterial = legMat
                leg.position = SCNVector3(CGFloat(6 - Double(i) * 6), CGFloat(side * 4), -5)
                leg.eulerAngles = SCNVector3(CGFloat(side * 0.9), 0, 0)
                legs.addChildNode(leg)
            }
        }
        node.addChildNode(legs)
    }

    func apply(frame: FlyFrame) {
        let p = frame.pose
        // Folded: wings swept back over the abdomen. Flight: spread and flapping (roll about the body axis).
        let spread = p.wingStroke
        let sweepFolded = 1.25, sweepSpread = 0.35
        let sweep = sweepFolded + (sweepSpread - sweepFolded) * spread
        let flap = spread * 1.1 * sin(p.wingPhase)
        leftHinge.eulerAngles = SCNVector3(CGFloat(flap), 0, CGFloat(sweep))
        rightHinge.eulerAngles = SCNVector3(CGFloat(-flap), 0, CGFloat(-sweep))
        // Legs: tucked in flight, small tripod jiggle when walking, front-leg rub when grooming.
        legs.scale = SCNVector3(1, 1, CGFloat(1 - 0.6 * p.legTuck))
        legs.position = SCNVector3(CGFloat(1.5 * p.walkAmount * sin(p.walkPhase)
                                           + 1.0 * p.groomAmount * sin(p.groomPhase)), 0, 0)
    }
}
