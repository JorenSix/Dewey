import CoreGraphics
import FlyCore

// Multi-screen geometry for `World` (contract in Screens.swift).
//
// Perch sites: per screen, the left/right edges and the bottom (Dock top when the Dock is at the bottom;
// a left/right Dock moves that side's line to the Dock edge), clipped like the old single-screen
// `alongRange` (below the menu bar, `cornerMargin` from corners, `perchInset` from the crossing line).
// Then every interval shared with another screen frame is subtracted (edges coincide within
// `sharedEdgeTolerance`, overlap > `sharedEdgeTolerance`). Dock lines are never shared. Segments shorter
// than `minPerchSiteLength` are dropped. Top edges are never perches.
//
// Flight region: union of (screen frame minus its menu-bar strip; the strip stays passable where another
// screen sits directly above it), eroded by `flightInset` — the erosion
// of the union, so outer borders are inset but shared edges are not and the fly can cross screens.

/// Derived geometry of one screen.
struct ScreenGeometry: Sendable {
    let id: Int
    let frame: CGRect
    let visible: CGRect
    let dock: DockPosition
    let leftX: CGFloat, rightX: CGFloat, bottomY: CGFloat, topY: CGFloat

    init(_ s: ScreenInfo) {
        id = s.id
        frame = s.frame
        visible = s.visibleFrame
        let bottomInset = visible.minY - frame.minY
        let leftInset = visible.minX - frame.minX
        let rightInset = frame.maxX - visible.maxX
        if bottomInset > World.dockThreshold {
            dock = .bottom
        } else if leftInset > World.dockThreshold {
            dock = .left
        } else if rightInset > World.dockThreshold {
            dock = .right
        } else {
            dock = .hidden
        }
        leftX = dock == .left ? visible.minX : frame.minX
        rightX = dock == .right ? visible.maxX : frame.maxX
        bottomY = dock == .bottom ? visible.minY : frame.minY
        // The menu bar is the gap between visibleFrame.maxY and frame.maxY.
        topY = min(frame.maxY, visible.maxY)
    }

    /// Screen frame minus the menu-bar strip: this screen's part of the flight region (before inset).
    var flyRect: CGRect {
        CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: max(0, topY - frame.minY))
    }

    /// The rects whose union is the (un-inset) flight region: each screen minus its menu-bar strip, plus
    /// the parts of a menu-bar strip directly under another screen (stacked screens), so the fly can pass
    /// through the menu bar into the screen above.
    static func flightPieces(_ geos: [ScreenGeometry]) -> [CGRect] {
        var out = geos.map(\.flyRect)
        for (i, g) in geos.enumerated() where g.topY < g.frame.maxY {
            for (j, t) in geos.enumerated() where j != i && abs(t.frame.minY - g.frame.maxY) <= World.sharedEdgeTolerance {
                let lo = max(g.frame.minX, t.frame.minX), hi = min(g.frame.maxX, t.frame.maxX)
                if hi - lo > World.sharedEdgeTolerance {
                    out.append(CGRect(x: lo, y: g.topY, width: hi - lo, height: g.frame.maxY - g.topY))
                }
            }
        }
        return out
    }
}

/// A union of axis-aligned rects as a grid of covered cells (coordinates within 1 pt are merged).
struct RegionGrid: Sendable {
    let xs: [CGFloat]
    let ys: [CGFloat]
    /// covered[i][j]: cell xs[i]..xs[i+1] × ys[j]..ys[j+1] lies inside the union.
    let covered: [[Bool]]

    init(rects: [CGRect]) {
        func merge(_ v: [CGFloat]) -> [CGFloat] {
            var out: [CGFloat] = []
            for x in v.sorted() where out.last.map({ x - $0 > World.sharedEdgeTolerance }) ?? true { out.append(x) }
            return out
        }
        let xs = merge(rects.flatMap { [$0.minX, $0.maxX] })
        let ys = merge(rects.flatMap { [$0.minY, $0.maxY] })
        func snap(_ v: CGFloat, _ grid: [CGFloat]) -> CGFloat {
            grid.min(by: { abs($0 - v) < abs($1 - v) }) ?? v
        }
        let snapped = rects.map { r in
            (snap(r.minX, xs), snap(r.maxX, xs), snap(r.minY, ys), snap(r.maxY, ys))
        }
        var cov: [[Bool]] = []
        for i in 0..<max(0, xs.count - 1) {
            var col: [Bool] = []
            let cx = (xs[i] + xs[i + 1]) / 2
            for j in 0..<max(0, ys.count - 1) {
                let cy = (ys[j] + ys[j + 1]) / 2
                col.append(snapped.contains { cx > $0.0 && cx < $0.1 && cy > $0.2 && cy < $0.3 })
            }
            cov.append(col)
        }
        self.xs = xs; self.ys = ys; covered = cov
    }

    /// Whether `p` lies in the open interior of a covered cell (points on grid lines: use cell lookup by <).
    func contains(_ p: CGPoint) -> Bool {
        guard let i = Self.index(p.x, xs), let j = Self.index(p.y, ys) else { return false }
        return covered[i][j]
    }

    private static func index(_ v: CGFloat, _ grid: [CGFloat]) -> Int? {
        guard grid.count >= 2, v >= grid[0], v <= grid[grid.count - 1] else { return nil }
        for k in 0..<(grid.count - 1) where v <= grid[k + 1] { return k }
        return grid.count - 2
    }

    /// The union eroded by `inset` (a point is inside iff the square of half-size `inset` around it lies in
    /// the union), as the eroded maximal covered blocks of cells. Exact for rect unions.
    func erodedRects(by inset: CGFloat) -> [CGRect] {
        let nx = xs.count - 1, ny = ys.count - 1
        guard nx > 0, ny > 0 else { return [] }
        func full(_ i0: Int, _ i1: Int, _ j0: Int, _ j1: Int) -> Bool {
            guard i0 >= 0, j0 >= 0, i1 < nx, j1 < ny else { return false }
            for i in i0...i1 { for j in j0...j1 where !covered[i][j] { return false } }
            return true
        }
        var out: [CGRect] = []
        for i0 in 0..<nx { for i1 in i0..<nx { for j0 in 0..<ny { for j1 in j0..<ny {
            guard full(i0, i1, j0, j1) else { continue }
            // Keep only maximal blocks.
            if full(i0 - 1, i1, j0, j1) || full(i0, i1 + 1, j0, j1)
                || full(i0, i1, j0 - 1, j1) || full(i0, i1, j0, j1 + 1) { continue }
            let r = CGRect(x: xs[i0] + inset, y: ys[j0] + inset,
                           width: xs[i1 + 1] - xs[i0] - 2 * inset, height: ys[j1 + 1] - ys[j0] - 2 * inset)
            if r.width >= 0, r.height >= 0 { out.append(r) }
        } } } }
        return out
    }

    /// Distance along the ray from `p` (unit direction `ux,uy`) to where it first leaves the union, and
    /// the inward normal of the border it crosses. 0 if `p` is outside.
    func exit(from p: CGPoint, ux: Double, uy: Double) -> (distance: Double, normal: CGVector) {
        var hits: [(t: Double, n: CGVector)] = []
        if abs(ux) > 1e-12 {
            for x in xs {
                let t = (Double(x) - Double(p.x)) / ux
                if t > 1e-9 { hits.append((t, CGVector(dx: ux > 0 ? -1 : 1, dy: 0))) }
            }
        }
        if abs(uy) > 1e-12 {
            for y in ys {
                let t = (Double(y) - Double(p.y)) / uy
                if t > 1e-9 { hits.append((t, CGVector(dx: 0, dy: uy > 0 ? -1 : 1))) }
            }
        }
        hits.sort { $0.t < $1.t }
        var prev = 0.0
        var prevNormal = CGVector(dx: -ux, dy: -uy)
        for h in hits {
            let m = (prev + h.t) / 2
            if !contains(CGPoint(x: Double(p.x) + ux * m, y: Double(p.y) + uy * m)) { return (prev, prevNormal) }
            prev = h.t
            prevNormal = h.n
        }
        return (prev, prevNormal)
    }
}

extension World {
    /// Two screen edges count as shared when they coincide within this and overlap by more than this.
    public static let sharedEdgeTolerance: CGFloat = 1
    /// Perch segments shorter than this are dropped.
    public static let minPerchSiteLength: CGFloat = 60
    /// The flight region is inset this far from outer borders (matches the single-screen `flightBounds`).
    public static let flightInset: CGFloat = 4

    // MARK: Perch sites

    func computePerchSites() -> [PerchSite] {
        let tol = World.sharedEdgeTolerance
        var out: [PerchSite] = []
        for (idx, g) in geometries.enumerated() {
            let others = geometries.enumerated().filter { $0.offset != idx }.map(\.element.frame)
            let f = g.frame
            func yOverlap(_ t: CGRect) -> (CGFloat, CGFloat) { (max(f.minY, t.minY), min(f.maxY, t.maxY)) }
            func xOverlap(_ t: CGRect) -> (CGFloat, CGFloat) { (max(f.minX, t.minX), min(f.maxX, t.maxX)) }

            // Side edges: body-centre along-range as the old `alongRange`.
            let sideLo = g.bottomY + perchInset + cornerMargin, sideHi = g.topY - cornerMargin
            for side in [Perch.left, .right] {
                let onFrameEdge = side == .left ? g.dock != .left : g.dock != .right
                let edgeX = side == .left ? f.minX : f.maxX
                let cuts: [(CGFloat, CGFloat)] = onFrameEdge ? others.compactMap { t in
                    let tx = side == .left ? t.maxX : t.minX
                    guard abs(tx - edgeX) <= tol else { return nil }
                    let o = yOverlap(t)
                    return o.1 - o.0 > tol ? o : nil
                } : []
                let x = side == .left ? g.leftX : g.rightX
                for (lo, hi) in World.subtract((sideLo, sideHi), cuts) where hi - lo >= World.minPerchSiteLength {
                    out.append(PerchSite(screenID: g.id, side: side, a: CGPoint(x: x, y: lo), b: CGPoint(x: x, y: hi)))
                }
            }
            // Bottom edge (or Dock top).
            let botLo = g.leftX + perchInset + cornerMargin, botHi = g.rightX - perchInset - cornerMargin
            let cuts: [(CGFloat, CGFloat)] = g.dock != .bottom ? others.compactMap { t in
                guard abs(t.maxY - f.minY) <= tol else { return nil }
                let o = xOverlap(t)
                return o.1 - o.0 > tol ? o : nil
            } : []
            for (lo, hi) in World.subtract((botLo, botHi), cuts) where hi - lo >= World.minPerchSiteLength {
                out.append(PerchSite(screenID: g.id, side: .bottom,
                                     a: CGPoint(x: lo, y: g.bottomY), b: CGPoint(x: hi, y: g.bottomY)))
            }
        }
        return out + computeWindowSites()
    }

    /// `base` minus the union of `cuts` (1-D closed intervals), as sorted free pieces.
    static func subtract(_ base: (CGFloat, CGFloat), _ cuts: [(CGFloat, CGFloat)]) -> [(CGFloat, CGFloat)] {
        guard base.1 > base.0 else { return [] }
        var free: [(CGFloat, CGFloat)] = []
        var cursor = base.0
        for c in cuts.sorted(by: { $0.0 < $1.0 }) {
            if c.1 <= cursor { continue }
            if c.0 >= base.1 { break }
            if c.0 > cursor { free.append((cursor, c.0)) }
            cursor = max(cursor, c.1)
            if cursor >= base.1 { break }
        }
        if cursor < base.1 { free.append((cursor, base.1)) }
        return free
    }

    /// Body-centre point for a fly perched on `site` nearest to `p`: `p` projected onto the segment
    /// (clamped to it), then moved `perchInset` along the inward normal.
    public func perchPoint(on site: PerchSite, near p: CGPoint) -> CGPoint {
        // Sites are axis-aligned: clamp the along-edge coordinate directly (bit-identical to the old
        // single-screen `perchPoint(_:near:)`).
        let n = normal(of: site.side)
        switch site.side {
        case .left, .right:
            let y = min(max(p.y, min(site.a.y, site.b.y)), max(site.a.y, site.b.y))
            return CGPoint(x: site.a.x + n.dx * perchInset, y: y)
        case .bottom:
            let x = min(max(p.x, min(site.a.x, site.b.x)), max(site.a.x, site.b.x))
            return CGPoint(x: x, y: site.a.y + n.dy * perchInset)
        }
    }

    /// Nearest perch site to `p`, its body-centre point and the distance to that point.
    public func nearestPerchSite(to p: CGPoint) -> (site: PerchSite, point: CGPoint, distance: Double)? {
        var best: (site: PerchSite, point: CGPoint, distance: Double)? = nil
        for s in perchSites {
            let q = perchPoint(on: s, near: p)
            let d = Double(hypot(q.x - p.x, q.y - p.y))
            if best == nil || d < best!.distance { best = (s, q, d) }
        }
        return best
    }

    /// A random perch site, favouring nearer ones: weight ∝ length · 1/(1 + d/1500), d = distance from
    /// `p` to the site's nearest body-centre point. Every site has a chance.
    public func randomPerchSite<G: RandomNumberGenerator>(from p: CGPoint, using g: inout G) -> PerchSite? {
        let weights = perchSites.map { s -> Double in
            let q = perchPoint(on: s, near: p)
            let d = Double(hypot(q.x - p.x, q.y - p.y))
            return Double(s.length) / (1 + d / 1500)
        }
        let total = weights.reduce(0, +)
        guard total > 0 else { return perchSites.first }
        var r = Double.random(in: 0..<total, using: &g)
        for (s, w) in zip(perchSites, weights) {
            if r < w { return s }
            r -= w
        }
        return perchSites.last
    }

    // MARK: Screens

    /// The screen whose frame contains `p` (first match on shared edges).
    public func screen(containing p: CGPoint) -> ScreenInfo? {
        screens.first { s in
            p.x >= s.frame.minX && p.x <= s.frame.maxX && p.y >= s.frame.minY && p.y <= s.frame.maxY
        }
    }

    /// The screen containing `p`, else the one whose frame is nearest.
    public func nearestScreen(to p: CGPoint) -> ScreenInfo {
        if let s = screen(containing: p) { return s }
        return screens.min { World.distance(p, $0.frame) < World.distance(p, $1.frame) }!
    }

    /// A one-screen World for the screen containing (or nearest to) `p`, with the same `perchInset` and
    /// `cornerMargin`. Its single-screen helpers (leftX, flightBounds, perchPoint(_:near:), …) ignore other
    /// screens, so they may name shared edges; use `perchSites` / `flightRegion*` for multi-screen logic.
    public func local(at p: CGPoint) -> World {
        let s = nearestScreen(to: p)
        var w = World(screens: [s], perchInset: perchInset)
        w.cornerMargin = cornerMargin
        return w
    }

    /// Union of all screen frames.
    public var boundingBox: CGRect {
        screens.dropFirst().reduce(screens[0].frame) { $0.union($1.frame) }
    }

    // MARK: Flight region

    /// Whether the fly's centre may be at `p`: inside the union of screens minus menu bars, inset
    /// `flightInset` from outer borders (not at shared edges).
    public func flightRegionContains(_ p: CGPoint) -> Bool {
        flightRects.contains { p.x >= $0.minX && p.x <= $0.maxX && p.y >= $0.minY && p.y <= $0.maxY }
    }

    /// Nearest point of the flight region to `p` (`p` itself when inside).
    public func clampToFlightRegion(_ p: CGPoint) -> CGPoint {
        if flightRegionContains(p) { return p }
        var best = p, bestD = CGFloat.infinity
        for r in flightRects {
            let q = CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < bestD { bestD = d; best = q }
        }
        return best
    }

    /// Distance from `p` along heading `direction` (radians) to the first OUTER border of the (un-inset)
    /// union of screens minus menu bars. Shared edges between screens are transparent. 0 if `p` is outside.
    public func borderDistance(from p: CGPoint, direction: Double) -> Double {
        region.exit(from: p, ux: cos(direction), uy: sin(direction)).distance
    }

    /// Like `borderDistance`, also returning the inward unit normal of the border hit.
    public func castRegionRay(from p: CGPoint, angle: Double) -> (distance: Double, normal: CGVector) {
        region.exit(from: p, ux: cos(angle), uy: sin(angle))
    }

    static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }
}
