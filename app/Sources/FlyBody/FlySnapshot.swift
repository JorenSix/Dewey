import AppKit
import FlyCore
import Metal
import SceneKit

/// Headless offscreen rendering of a `FlyRig` (Metal via `SCNRenderer`), used by tests and tooling.
public enum FlySnapshot {
    /// SceneKit offscreen renders are not safe to run concurrently (parallel tests aborted with SIGABRT).
    private static let lock = NSLock()

    /// Renders the rig in `pose` seen from above (camera on +y, slight perspective tilt toward the tail,
    /// fly facing screen-right) on a transparent background and writes a PNG to `url`.
    @discardableResult
    public static func renderPNG(rig: FlyRig, pose: BodyPose, size: CGSize = CGSize(width: 512, height: 512),
                                 to url: URL, cameraTilt: Double = 0.25) throws -> NSImage {
        JointAnimator(rig: rig).apply(pose)
        return try renderCurrent(rig: rig, size: size, to: url, cameraTilt: cameraTilt)
    }

    /// Renders the rig in whatever joint configuration it currently has.
    @discardableResult
    public static func renderCurrent(rig: FlyRig, size: CGSize = CGSize(width: 512, height: 512),
                                     to url: URL, cameraTilt: Double = 0.25) throws -> NSImage {
        lock.lock(); defer { lock.unlock() }
        guard let device = MTLCreateSystemDefaultDevice() else { throw SnapshotError.noMetal }

        let scene = SCNScene()
        scene.background.contents = NSColor.clear
        let parent = rig.node.parent
        rig.node.removeFromParentNode()
        scene.rootNode.addChildNode(rig.node)
        defer {
            rig.node.removeFromParentNode()
            parent?.addChildNode(rig.node)
        }

        let cam = SCNCamera()
        cam.fieldOfView = 30
        cam.zNear = 0.05
        cam.zFar = 20
        let camNode = SCNNode()
        camNode.camera = cam
        // Above the fly, tilted slightly so some depth shows; screen-up = -z (the fly's left).
        let d: Float = 3.3
        camNode.simdPosition = simd_float3(0, d * Float(cos(cameraTilt)), d * Float(sin(cameraTilt)))
        camNode.simdLook(at: .zero, up: simd_float3(0, 0, -1), localFront: simd_float3(0, 0, -1))
        scene.rootNode.addChildNode(camNode)

        let key = SCNNode()
        key.light = SCNLight()
        key.light!.type = .directional
        key.light!.intensity = 900
        key.simdLook(at: simd_float3(0.2, -1, 0.3))
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light!.type = .ambient
        fill.light!.intensity = 450
        scene.rootNode.addChildNode(fill)

        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camNode
        renderer.autoenablesDefaultLighting = false
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { throw SnapshotError.encode }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url)
        return image
    }

    public enum SnapshotError: Error { case noMetal, encode }
}
