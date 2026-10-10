import CoreGraphics
import FlyCore

// v5 window perch sites (contract in Screens.swift).
//
// Qualifying windows: on the screen whose frame contains the window's centre, the window frame is inset at
// least `windowInsetFraction` × that screen's frame width from the left and right sides and × its frame
// height from the top (the bottom of the menu bar, `visibleFrame.maxY`) and the bottom (the Dock top,
// `visibleFrame.minY`); the sides are measured from `visibleFrame` too, so a left/right Dock counts as the
// border. And the window is at least `minWindowSize`, and it is one of the top visible windows: at least
// `minVisibleFraction` of its area is not covered by windows in front of it.
//
// Sites, per qualifying window (each a foot line on the window border, the body outside the window):
//   top edge   → side .bottom (feet down, body above the line),   line y = maxY, x in the clipped range
//   left edge  → side .right  (body left of the line, feet right), line x = minX
//   right edge → side .left   (body right of the line, feet left), line x = maxX
// Ranges are clipped `cornerMargin` (plus `perchInset` toward the top corners, like the screen sites) from
// the corners. Then every part hidden by a window in front (any earlier window in `windows`, qualifying or
// not) is removed: an occluder cuts its extent along the edge when it covers the edge line or the strip
// the fly stands in outside it (`perchInset + windowStandingMargin` deep). Pieces shorter than
// `minPerchSiteLength` are dropped.

extension World {
    /// A window must be inset at least this fraction of its screen's size from every side to count.
    public static let windowInsetFraction: CGFloat = 0.10
    /// Windows smaller than this never count.
    public static let minWindowSize = CGSize(width: 200, height: 120)
    /// The standing strip outside a window edge is `perchInset + windowStandingMargin` deep.
    public static let windowStandingMargin: CGFloat = 10
    /// Only mostly uncovered windows count: at least this fraction of the window's area must be visible
    /// (not behind any window in front of it).
    public static let minVisibleFraction: CGFloat = 0.70

    /// A copy of this World with `windows` (front to back) and the window perch sites recomputed. Screen
    /// sites are unchanged and stay first in `perchSites`.
    public func withWindows(_ list: [WindowInfo]) -> World {
        var w = self
        w.setWindows(list)
        return w
    }

    mutating func setWindows(_ list: [WindowInfo]) {
        windows = list
        qualifyingWindowIDs = Set(list.indices.filter { i in
            qualifies(list[i]) && World.visibleFraction(of: i, in: list) >= World.minVisibleFraction
        }.map { list[$0].id })
        perchSites = computePerchSites()
    }

    /// The screen the window belongs to: the one whose frame contains its centre.
    public func screen(of window: WindowInfo) -> ScreenInfo? {
        screen(containing: CGPoint(x: window.frame.midX, y: window.frame.midY))
    }

    /// Whether `window` passes the 10% inset rule on its screen and the minimum size.
    public func qualifies(_ window: WindowInfo) -> Bool {
        let f = window.frame
        guard f.width >= World.minWindowSize.width, f.height >= World.minWindowSize.height,
              let s = screen(of: window) else { return false }
        let mx = World.windowInsetFraction * s.frame.width
        let my = World.windowInsetFraction * s.frame.height
        let v = s.visibleFrame
        return f.minX - v.minX >= mx && v.maxX - f.maxX >= mx
            && v.maxY - f.maxY >= my && f.minY - v.minY >= my
    }

    /// Fraction of `list[index]`'s area not covered by the windows in front of it (`list[0..<index]`),
    /// estimated on a 24×24 sample grid.
    public static func visibleFraction(of index: Int, in list: [WindowInfo]) -> CGFloat {
        let f = list[index].frame
        let front = list[..<index].map(\.frame).filter { $0.intersects(f) }
        guard !front.isEmpty, f.width > 0, f.height > 0 else { return 1 }
        let n = 24
        var visible = 0
        for i in 0..<n {
            for j in 0..<n {
                let p = CGPoint(x: f.minX + (CGFloat(i) + 0.5) * f.width / CGFloat(n),
                                y: f.minY + (CGFloat(j) + 0.5) * f.height / CGFloat(n))
                if !front.contains(where: { $0.contains(p) }) { visible += 1 }
            }
        }
        return CGFloat(visible) / CGFloat(n * n)
    }

    func computeWindowSites() -> [PerchSite] {
        guard !windows.isEmpty else { return [] }
        let band = perchInset + World.windowStandingMargin
        var out: [PerchSite] = []
        for (i, win) in windows.enumerated() where qualifyingWindowIDs.contains(win.id) {
            guard let s = screen(of: win) else { continue }
            let f = win.frame
            let front = windows[..<i].map(\.frame)

            // Top edge: feet on y = maxY, body above.
            let topCuts: [(CGFloat, CGFloat)] = front.compactMap { o in
                o.maxY >= f.maxY && o.minY <= f.maxY + band ? (o.minX, o.maxX) : nil
            }
            let topRange = (f.minX + perchInset + cornerMargin, f.maxX - perchInset - cornerMargin)
            for (lo, hi) in World.subtract(topRange, topCuts) where hi - lo >= World.minPerchSiteLength {
                out.append(PerchSite(screenID: s.id, side: .bottom, a: CGPoint(x: lo, y: f.maxY),
                                     b: CGPoint(x: hi, y: f.maxY), windowID: win.id))
            }

            // Side edges: body outside the window, below the top edge's corner zone.
            let sideRange = (f.minY + cornerMargin, f.maxY - perchInset - cornerMargin)
            for (side, x, outward) in [(Perch.right, f.minX, CGFloat(-1)), (Perch.left, f.maxX, CGFloat(1))] {
                let cuts: [(CGFloat, CGFloat)] = front.compactMap { o in
                    let covers = outward < 0
                        ? o.minX <= x && o.maxX >= x - band
                        : o.maxX >= x && o.minX <= x + band
                    return covers ? (o.minY, o.maxY) : nil
                }
                for (lo, hi) in World.subtract(sideRange, cuts) where hi - lo >= World.minPerchSiteLength {
                    out.append(PerchSite(screenID: s.id, side: side, a: CGPoint(x: x, y: lo),
                                         b: CGPoint(x: x, y: hi), windowID: win.id))
                }
            }
        }
        return out
    }

    /// The window perch sites (subset of `perchSites`).
    public var windowSites: [PerchSite] { perchSites.filter { $0.windowID != nil } }
}
