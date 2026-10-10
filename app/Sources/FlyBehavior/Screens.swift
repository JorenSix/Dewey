import CoreGraphics
import FlyCore

/// One display, in AppKit global points (origin bottom-left of the primary screen, y up).
public struct ScreenInfo: Sendable, Equatable {
    public var id: Int
    public var frame: CGRect
    public var visibleFrame: CGRect
    public init(id: Int, frame: CGRect, visibleFrame: CGRect) {
        self.id = id; self.frame = frame; self.visibleFrame = visibleFrame
    }
}

/// A straight piece of screen border the fly may land on: an edge (or the Dock top) of one screen,
/// minus every part shared with an adjacent screen. `a`/`b` are the endpoints of the perch line
/// (where the feet touch); the fly's body sits `World.perchInset` inside it along `normal`.
public struct PerchSite: Sendable, Equatable {
    public var screenID: Int
    public var side: Perch
    public var a: CGPoint
    public var b: CGPoint
    /// v5: set when this site is an application window's edge (nil = screen edge / Dock).
    /// Orientation follows `side`: window top → .bottom (feet down), window left edge → .right
    /// (fly outside, feet pointing right), window right edge → .left.
    public var windowID: Int? = nil
    public init(screenID: Int, side: Perch, a: CGPoint, b: CGPoint, windowID: Int? = nil) {
        self.screenID = screenID; self.side = side; self.a = a; self.b = b; self.windowID = windowID
    }
    public var length: CGFloat { hypot(b.x - a.x, b.y - a.y) }
}

// Multi-screen API (module I implements; this is the contract other modules build against):
//   World(screens: [ScreenInfo], perchInset:)            all screens; single-screen init stays
//   world.screens: [ScreenInfo]
//   world.perchSites: [PerchSite]                         unshared edge segments + Dock tops
//   world.screen(containing: CGPoint) -> ScreenInfo?
//   world.flightRegionContains(_ p: CGPoint) -> Bool      union of screens (minus menu bars), inset
//   world.clampToFlightRegion(_ p: CGPoint) -> CGPoint
//   world.nearestPerchSite(to: CGPoint) -> (site: PerchSite, point: CGPoint, distance: Double)?
//   world.perchPoint(on site: PerchSite, near: CGPoint) -> CGPoint     body-centre point (inset applied)
//   world.randomPerchSite<G: RandomNumberGenerator>(from: CGPoint, using: inout G) -> PerchSite?
//   world.boundingBox: CGRect                             union of all screen frames
// Implemented in World.swift / WorldGeometry.swift, plus these extras:
//   world.borderDistance(from: CGPoint, direction: Double) -> Double   ray to the first OUTER border of the
//       un-inset union (screens minus menu bars); shared edges are transparent
//   world.castRegionRay(from:angle:) -> (distance, normal)             same, with the inward border normal
//   world.nearestScreen(to: CGPoint) -> ScreenInfo                      containing screen, else nearest
//   world.local(at: CGPoint) -> World                                   one-screen World for that screen
//   world.normal(of: site.side)                                         inward normal of a site
// Single-screen properties (screenFrame, dock, leftX/rightX/bottomY/topY, flightBounds, perchPoint(_:near:),
// nearestPerch, castBorderRay, …) describe screens[0]; use local(at:) for the fly's current screen.
// A menu-bar strip stays passable where another screen sits directly above it (stacked screens).

/// v5: an application window, AppKit global points (origin bottom-left of the primary screen, y up).
/// `windows` arrays are ordered front-to-back (index 0 = frontmost), as CGWindowList returns them.
public struct WindowInfo: Sendable, Equatable {
    public var id: Int
    public var frame: CGRect
    public var ownerPID: Int32
    public init(id: Int, frame: CGRect, ownerPID: Int32 = 0) {
        self.id = id; self.frame = frame; self.ownerPID = ownerPID
    }
}

// v5 window API (module P implements in World; module Q consumes):
//   world.windows: [WindowInfo]                      front-to-back, already filtered by the app? NO — raw normal windows;
//                                                    World applies the 10% inset rule + min size + occlusion itself
//   world.withWindows(_ w: [WindowInfo]) -> World    copy with window perch sites recomputed
//   world.qualifyingWindowIDs: Set<Int>              windows passing the 10% rule and size
//   PerchSite.windowID                               non-nil for window sites (included in world.perchSites)
//   World.windowInsetFraction = 0.10, World.minWindowSize = CGSize(200, 120)
// Implemented in WindowSites.swift (P), plus: world.qualifies(_:), world.screen(of:), world.windowSites,
//   World.windowStandingMargin (an occluder within perchInset + this outside an edge also cuts it).
//   Inset measured from the visibleFrame edges of the screen containing the window centre, as a fraction of
//   that screen's frame width (left/right) and height (top/bottom). Occluders: every earlier window.
