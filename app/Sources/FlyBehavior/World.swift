import CoreGraphics
import FlyCore

/// Where the Dock sits, inferred from `screenFrame` minus `visibleFrame`.
public enum DockPosition: String, Sendable {
    case bottom, left, right, hidden
}

/// Screen geometry and perch surfaces. Pure value type, AppKit global points (origin bottom-left, y up).
///
/// Multi-screen: `World(screens:)` holds every display; `perchSites`, `flightRegionContains`,
/// `clampToFlightRegion`, `borderDistance` etc. (see `WorldGeometry.swift`) work across all of them.
/// The single-screen properties below (`screenFrame`, `visibleFrame`, `dock`, `leftX`, `rightX`, `bottomY`,
/// `topY`, `flightBounds`, `perchPoint(_:near:)`, `nearestPerch`, `castBorderRay`, ...) describe the PRIMARY
/// screen (`screens[0]`). For the screen the fly is on, use `local(at:)`, which returns a one-screen World
/// for the screen containing (or nearest to) a point. `World(screenFrame:visibleFrame:)` equals
/// `World(screens: [one])`.
public struct World: Sendable {
    /// All displays; `screens[0]` is the primary one the single-screen properties refer to.
    public let screens: [ScreenInfo]

    public let screenFrame: CGRect
    public let visibleFrame: CGRect
    public let dock: DockPosition

    /// Perch lines: the fly's feet touch these.
    public let leftX: CGFloat
    public let rightX: CGFloat
    public let bottomY: CGFloat
    /// Top limit for perching / flying (bottom of the menu bar).
    public let topY: CGFloat

    /// Distance from a perch line to the fly's body centre when perched (half the body height in side view).
    /// Settable from outside (the app derives it from the rig's foot clearance × fly size).
    public var perchInset: CGFloat = World.defaultPerchInset {
        didSet { perchSites = computePerchSites() }
    }
    public static let defaultPerchInset: CGFloat = 10
    /// Keep perch points this far from the corners.
    public var cornerMargin: CGFloat = 30 {
        didSet { perchSites = computePerchSites() }
    }

    /// Dock insets smaller than this are treated as "no Dock" (auto-hide leaves a few points).
    public static let dockThreshold: CGFloat = 8

    /// Per-screen derived geometry (Dock, perch lines, menu-bar bottom), same order as `screens`.
    let geometries: [ScreenGeometry]
    /// Union of screens minus menu bars, as a snapped cell grid (for ray casts / containment).
    let region: RegionGrid
    /// The flight region (union eroded by `flightInset` at outer borders only), as overlapping rects.
    let flightRects: [CGRect]

    /// Unshared edge segments + Dock tops, clipped from corners. Recomputed when `perchInset` /
    /// `cornerMargin` change. The segment endpoints are the range of foot points whose body-centre
    /// point (`perchPoint(on:near:)`) keeps the corner margins of the old single-screen `alongRange`.
    public internal(set) var perchSites: [PerchSite] = []

    /// v5: the normal application windows (layer 0, not Dewey's own), front to back, AppKit global points.
    /// Raw list; `qualifyingWindowIDs` and the window perch sites are derived from it (`WindowSites.swift`).
    public internal(set) var windows: [WindowInfo] = []
    /// v5: ids of the windows that pass the 10% inset rule and the minimum size.
    public internal(set) var qualifyingWindowIDs: Set<Int> = []

    public init(screenFrame: CGRect, visibleFrame: CGRect, perchInset: CGFloat = World.defaultPerchInset) {
        self.init(screens: [ScreenInfo(id: 0, frame: screenFrame, visibleFrame: visibleFrame)], perchInset: perchInset)
    }

    /// All screens. An empty list falls back to one 1440×900 screen.
    public init(screens: [ScreenInfo], perchInset: CGFloat = World.defaultPerchInset) {
        let list = screens.isEmpty
            ? [ScreenInfo(id: 0, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                          visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))]
            : screens
        self.screens = list
        self.perchInset = perchInset
        let geos = list.map(ScreenGeometry.init)
        geometries = geos
        let g = geos[0]
        screenFrame = g.frame
        visibleFrame = g.visible
        dock = g.dock
        leftX = g.leftX
        rightX = g.rightX
        bottomY = g.bottomY
        topY = g.topY
        let reg = RegionGrid(rects: ScreenGeometry.flightPieces(geos))
        region = reg
        flightRects = reg.erodedRects(by: World.flightInset)
        perchSites = computePerchSites()
    }

    /// Area the fly's centre may occupy.
    public var flightBounds: CGRect {
        CGRect(x: screenFrame.minX + 4, y: screenFrame.minY + 4,
               width: max(1, screenFrame.width - 8), height: max(1, topY - screenFrame.minY - 8))
    }

    /// Unit normal pointing away from the perch surface into the open screen.
    public func normal(of perch: Perch) -> CGVector {
        switch perch {
        case .left: return CGVector(dx: 1, dy: 0)
        case .right: return CGVector(dx: -1, dy: 0)
        case .bottom: return CGVector(dx: 0, dy: 1)
        }
    }

    /// Unsigned distance from `p` to the perch line.
    public func distance(to perch: Perch, from p: CGPoint) -> Double {
        switch perch {
        case .left: return Double(abs(p.x - leftX))
        case .right: return Double(abs(rightX - p.x))
        case .bottom: return Double(abs(p.y - bottomY))
        }
    }

    /// Valid range of the along-edge coordinate (y for side edges, x for bottom) for a perched body centre.
    public func alongRange(_ perch: Perch) -> ClosedRange<CGFloat> {
        switch perch {
        case .left, .right:
            let lo = bottomY + perchInset + cornerMargin
            let hi = max(lo, topY - cornerMargin)
            return lo...hi
        case .bottom:
            let lo = leftX + perchInset + cornerMargin
            let hi = max(lo, rightX - perchInset - cornerMargin)
            return lo...hi
        }
    }

    /// Body-centre position for a fly perched on `perch` nearest to `p` (inset from the line, clamped from corners).
    public func perchPoint(_ perch: Perch, near p: CGPoint) -> CGPoint {
        let r = alongRange(perch)
        switch perch {
        case .left: return CGPoint(x: leftX + perchInset, y: min(max(p.y, r.lowerBound), r.upperBound))
        case .right: return CGPoint(x: rightX - perchInset, y: min(max(p.y, r.lowerBound), r.upperBound))
        case .bottom: return CGPoint(x: min(max(p.x, r.lowerBound), r.upperBound), y: bottomY + perchInset)
        }
    }

    /// Nearest perch surface to `p`, its body-centre point and the distance to that point.
    public func nearestPerch(to p: CGPoint) -> (perch: Perch, point: CGPoint, distance: Double) {
        var best: (Perch, CGPoint, Double)? = nil
        for perch in [Perch.left, .right, .bottom] {
            let q = perchPoint(perch, near: p)
            let d = Double(hypot(q.x - p.x, q.y - p.y))
            if best == nil || d < best!.2 { best = (perch, q, d) }
        }
        return (best!.0, best!.1, best!.2)
    }

    /// Edge-aligned headings for a perch (two options, travelling either way along the edge).
    public func edgeHeadings(_ perch: Perch) -> (Double, Double) {
        switch perch {
        case .left, .right: return (Double.pi / 2, -Double.pi / 2)
        case .bottom: return (0, Double.pi)
        }
    }

    /// Edge-aligned heading closest to `heading`.
    public func alignedHeading(_ perch: Perch, closestTo heading: Double) -> Double {
        let (a, b) = edgeHeadings(perch)
        return abs(angleDiff(a, heading)) <= abs(angleDiff(b, heading)) ? a : b
    }

    public func clampToFlightBounds(_ p: CGPoint) -> CGPoint {
        let b = flightBounds
        return CGPoint(x: min(max(p.x, b.minX), b.maxX), y: min(max(p.y, b.minY), b.maxY))
    }

    public func contains(_ p: CGPoint) -> Bool { screenFrame.contains(p) }

    /// Which border a gaze ray hits.
    public enum Border: Sendable { case left, right, bottom, top }

    /// The visual borders the fly sees from `p`: perch lines (Dock top included) and the menu-bar bottom.
    /// Where the fly is already beyond a perch line (e.g. flying over the Dock) the flight bound is used.
    public func borderRect(from p: CGPoint) -> CGRect {
        let fb = flightBounds
        let x0 = p.x >= leftX ? leftX : fb.minX, x1 = p.x <= rightX ? rightX : fb.maxX
        let y0 = p.y >= bottomY ? bottomY : fb.minY, y1 = max(p.y, topY)
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    /// Casts a ray from `p` along `angle` (radians) to the visual border: distance along the ray, the
    /// border hit and its inward unit normal.
    public func castBorderRay(from p: CGPoint, angle: Double) -> (distance: Double, border: Border, normal: CGVector) {
        let r = borderRect(from: p)
        let ux = cos(angle), uy = sin(angle)
        let x = Double(p.x), y = Double(p.y)
        var best = (Double.infinity, Border.top, CGVector(dx: 0, dy: -1))
        if ux < -1e-9 { let t = (Double(r.minX) - x) / ux; if t < best.0 { best = (t, .left, CGVector(dx: 1, dy: 0)) } }
        if ux > 1e-9 { let t = (Double(r.maxX) - x) / ux; if t < best.0 { best = (t, .right, CGVector(dx: -1, dy: 0)) } }
        if uy < -1e-9 { let t = (Double(r.minY) - y) / uy; if t < best.0 { best = (t, .bottom, CGVector(dx: 0, dy: 1)) } }
        if uy > 1e-9 { let t = (Double(r.maxY) - y) / uy; if t < best.0 { best = (t, .top, CGVector(dx: 0, dy: -1)) } }
        return (max(0, best.0), best.1, best.2)
    }
}

/// Signed smallest difference a - b, in (-pi, pi].
@inline(__always)
public func angleDiff(_ a: Double, _ b: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
    if d > .pi { d -= 2 * .pi }
    if d <= -.pi { d += 2 * .pi }
    return d
}

/// SplitMix64: small deterministic RNG.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    public mutating func uniform(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * Double(next() >> 11) / Double(1 << 53)
    }
    public mutating func chance(_ p: Double) -> Bool { uniform(0, 1) < p }
}
