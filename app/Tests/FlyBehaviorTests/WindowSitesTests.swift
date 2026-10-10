import CoreGraphics
import Testing
import FlyCore
@testable import FlyBehavior

/// v5 window perch sites: the 10% rule, minimum size, orientation, occlusion.
@Suite struct WindowSitesTests {
    // The user's layout: DELL (Dock bottom) with the built-in display to its upper left.
    static let dell = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 3840, height: 2160),
                                 visibleFrame: CGRect(x: 0, y: 93, width: 3840, height: 2042))
    static let laptop = ScreenInfo(id: 2, frame: CGRect(x: -1800, y: 991, width: 1800, height: 1169),
                                   visibleFrame: CGRect(x: -1800, y: 991, width: 1800, height: 1131))
    static let base = World(screens: [dell, laptop])

    // DELL thresholds: 384 pt from left/right (visible x 0…3840), 216 pt from the visible top 2135 / bottom 93.
    static let dLeft: CGFloat = 384, dRight: CGFloat = 3840 - 384, dTop: CGFloat = 2135 - 216, dBottom: CGFloat = 93 + 216

    func world(_ frames: [CGRect]) -> World {
        Self.base.withWindows(frames.enumerated().map { WindowInfo(id: $0.offset + 1, frame: $0.element) })
    }

    func qualifies(_ f: CGRect) -> Bool { world([f]).qualifyingWindowIDs.contains(1) }

    func windowSites(_ w: World, _ id: Int, _ side: Perch) -> [PerchSite] {
        w.perchSites.filter { $0.windowID == id && $0.side == side }
    }

    // MARK: 10% rule

    @Test func insetRuleEachSideOnTheDell() {
        let h: CGFloat = 600, wd: CGFloat = 1200
        // Left side.
        #expect(qualifies(CGRect(x: Self.dLeft + 0.5, y: 800, width: wd, height: h)))
        #expect(!qualifies(CGRect(x: Self.dLeft - 0.5, y: 800, width: wd, height: h)))
        // Right side.
        #expect(qualifies(CGRect(x: Self.dRight - 0.5 - wd, y: 800, width: wd, height: h)))
        #expect(!qualifies(CGRect(x: Self.dRight + 0.5 - wd, y: 800, width: wd, height: h)))
        // Top (below the menu bar).
        #expect(qualifies(CGRect(x: 1000, y: Self.dTop - 0.5 - h, width: wd, height: h)))
        #expect(!qualifies(CGRect(x: 1000, y: Self.dTop + 0.5 - h, width: wd, height: h)))
        // Bottom (above the Dock).
        #expect(qualifies(CGRect(x: 1000, y: Self.dBottom + 0.5, width: wd, height: h)))
        #expect(!qualifies(CGRect(x: 1000, y: Self.dBottom - 0.5, width: wd, height: h)))
    }

    @Test func maximisedWindowHasNoSites() {
        let w = world([Self.dell.visibleFrame])
        #expect(w.qualifyingWindowIDs.isEmpty)
        #expect(w.windowSites.isEmpty)
        #expect(world([Self.laptop.visibleFrame]).windowSites.isEmpty)
    }

    @Test func laptopUsesItsOwnDimensions() {
        // Laptop thresholds: 180 pt from left/right, 116.9 pt from the visible top 2122 / bottom 991.
        // 200 pt from its left edge: enough on the laptop (180), not enough on the DELL (384).
        let inside = CGRect(x: -1800 + 200, y: 1200, width: 800, height: 500)
        #expect(qualifies(inside))
        #expect(world([inside]).windowSites.allSatisfy { $0.screenID == Self.laptop.id })
        #expect(!qualifies(CGRect(x: -1800 + 170, y: 1200, width: 800, height: 500)))
        // Top: 2122 - 116.9 = 2005.1 (the DELL rule would need 216).
        #expect(qualifies(CGRect(x: -1500, y: 2005 - 500, width: 800, height: 500)))
        #expect(!qualifies(CGRect(x: -1500, y: 2006 - 500, width: 800, height: 500)))
        // Right: within 180 of x = 0.
        #expect(!qualifies(CGRect(x: -1000, y: 1200, width: 850, height: 500)))
    }

    @Test func minimumSize() {
        #expect(qualifies(CGRect(x: 1000, y: 800, width: 200, height: 120)))
        #expect(!qualifies(CGRect(x: 1000, y: 800, width: 199, height: 300)))
        #expect(!qualifies(CGRect(x: 1000, y: 800, width: 300, height: 119)))
    }

    // MARK: Orientation

    @Test func orientationAndBodySide() {
        let f = CGRect(x: 1000, y: 800, width: 1200, height: 600)
        let w = world([f])
        let inset = w.perchInset
        let top = windowSites(w, 1, .bottom), left = windowSites(w, 1, .right), right = windowSites(w, 1, .left)
        #expect(top.count == 1 && left.count == 1 && right.count == 1)
        #expect(w.windowSites.count == 3)
        guard let t = top.first, let l = left.first, let r = right.first else { return }
        #expect(t.a.y == f.maxY && t.b.y == f.maxY && t.screenID == Self.dell.id)
        #expect(l.a.x == f.minX && l.b.x == f.minX)
        #expect(r.a.x == f.maxX && r.b.x == f.maxX)
        // Ranges stay inside the edge, clear of the corners.
        #expect(min(t.a.x, t.b.x) > f.minX && max(t.a.x, t.b.x) < f.maxX)
        #expect(min(l.a.y, l.b.y) > f.minY && max(l.a.y, l.b.y) < f.maxY)

        // Body centres sit outside the window, `perchInset` from the line.
        let pt = w.perchPoint(on: t, near: CGPoint(x: 1600, y: 0))
        #expect(pt.y == f.maxY + inset && pt.x == 1600)
        let pl = w.perchPoint(on: l, near: CGPoint(x: 0, y: 1100))
        #expect(pl.x == f.minX - inset && pl.y == 1100)
        let pr = w.perchPoint(on: r, near: CGPoint(x: 5000, y: 1100))
        #expect(pr.x == f.maxX + inset && pr.y == 1100)
        for p in [pt, pl, pr] { #expect(!f.contains(p)) }
        // The normals point away from the window.
        #expect(w.normal(of: t.side).dy > 0 && w.normal(of: l.side).dx < 0 && w.normal(of: r.side).dx > 0)
    }

    // MARK: Occlusion

    @Test func frontWindowSplitsBackTopEdge() {
        let back = CGRect(x: 1000, y: 800, width: 1200, height: 600)
        let front = CGRect(x: 1400, y: 1300, width: 400, height: 400)  // covers the middle of back's top edge
        let w = world([front, back])                                     // front to back
        let top = windowSites(w, 2, .bottom).sorted { $0.a.x < $1.a.x }
        #expect(top.count == 2)
        guard top.count == 2 else { return }
        #expect(abs(max(top[0].a.x, top[0].b.x) - front.minX) < 0.01)
        #expect(abs(min(top[1].a.x, top[1].b.x) - front.maxX) < 0.01)
        // Back's sides are untouched; the front window keeps all three of its own edges.
        #expect(windowSites(w, 2, .right).count == 1 && windowSites(w, 2, .left).count == 1)
        #expect(windowSites(w, 1, .bottom).count == 1)
        // Swapping the order: the (now front) big window hides front's lower part, not the other way round.
        let swapped = world([back, front])
        #expect(windowSites(swapped, 1, .bottom).count == 1)
    }

    @Test func frontWindowCutsBackSideEdge() {
        let back = CGRect(x: 1000, y: 600, width: 1200, height: 800)
        let front = CGRect(x: 700, y: 900, width: 500, height: 200)   // over back's left edge, y 900…1100
        let w = world([front, back])
        let left = windowSites(w, 2, .right).sorted { $0.a.y < $1.a.y }
        #expect(left.count == 2)
        guard left.count == 2 else { return }
        #expect(abs(max(left[0].a.y, left[0].b.y) - front.minY) < 0.01)
        #expect(abs(min(left[1].a.y, left[1].b.y) - front.maxY) < 0.01)
        #expect(windowSites(w, 2, .left).count == 1)
    }

    @Test func windowInStandingSpaceAboveTopEdgeCutsIt() {
        let back = CGRect(x: 1000, y: 800, width: 1200, height: 600)
        let band = Self.base.perchInset + World.windowStandingMargin
        // Floating just above the edge, inside the strip the fly would stand in.
        let near = CGRect(x: 1400, y: back.maxY + band - 5, width: 400, height: 300)
        #expect(windowSites(world([near, back]), 2, .bottom).count == 2)
        // Higher up: the fly fits underneath, the edge is whole.
        let far = CGRect(x: 1400, y: back.maxY + band + 5, width: 400, height: 300)
        #expect(windowSites(world([far, back]), 2, .bottom).count == 1)
    }

    @Test func nonQualifyingWindowInFrontStillOccludes() {
        let back = CGRect(x: 1000, y: 800, width: 1200, height: 600)
        let w = world([Self.dell.visibleFrame, back])  // maximised window in front
        // Fully hidden behind it: not one of the top visible windows any more (minVisibleFraction).
        #expect(w.qualifyingWindowIDs.isEmpty)
        #expect(w.windowSites.isEmpty)
        // Behind it instead: back's sites are back.
        #expect(world([back, Self.dell.visibleFrame]).windowSites.count == 3)
    }

    @Test func shortPiecesAreDropped() {
        let back = CGRect(x: 1000, y: 800, width: 1200, height: 600)
        let inset = Self.base.perchInset, margin = Self.base.cornerMargin
        let lo = back.minX + inset + margin                          // top range starts here
        // Leaves 50 pt on the left of the top range (dropped) and a long piece on the right.
        let front = CGRect(x: lo + 50, y: 1300, width: 700, height: 400)
        let top = windowSites(world([front, back]), 2, .bottom)
        #expect(top.count == 1)
        #expect(top.allSatisfy { $0.length >= World.minPerchSiteLength })
        #expect(abs((top.first.map { min($0.a.x, $0.b.x) } ?? 0) - front.maxX) < 0.01)
        // 70 pt is kept.
        let front2 = CGRect(x: lo + 70, y: 1300, width: 700, height: 400)
        #expect(windowSites(world([front2, back]), 2, .bottom).count == 2)
    }

    // MARK: World plumbing

    @Test func withWindowsKeepsScreenSites() {
        let screenSites = Self.base.perchSites
        let w = world([CGRect(x: 1000, y: 800, width: 1200, height: 600), CGRect(x: -1500, y: 1300, width: 800, height: 500)])
        #expect(Array(w.perchSites.prefix(screenSites.count)) == screenSites)
        #expect(w.perchSites.dropFirst(screenSites.count).allSatisfy { $0.windowID != nil })
        #expect(w.windowSites.count == 6)
        #expect(screenSites.allSatisfy { $0.windowID == nil })
        #expect(w.withWindows([]).perchSites == screenSites)
        #expect(w.windows.count == 2)
        // A new perch inset recomputes the window sites too.
        var v = w
        v.perchInset = 14
        #expect(v.windowSites.count == 6)
        #expect(v.perchSites.prefix(World(screens: [Self.dell, Self.laptop], perchInset: 14).perchSites.count).allSatisfy { $0.windowID == nil })
    }

    @Test func windowOffEveryScreenIsIgnored() {
        let w = world([CGRect(x: 5000, y: 5000, width: 800, height: 600)])
        #expect(w.qualifyingWindowIDs.isEmpty && w.windowSites.isEmpty)
    }

    @Test func onlyMostlyUncoveredWindowsQualify() {
        let back = WindowInfo(id: 10, frame: CGRect(x: 1000, y: 700, width: 1200, height: 800))
        // Front window covering ~25% of the back window: back still qualifies.
        let smallFront = WindowInfo(id: 11, frame: CGRect(x: 1000, y: 1100, width: 600, height: 400))
        let w1 = Self.base.withWindows([smallFront, back])
        #expect(World.visibleFraction(of: 1, in: [smallFront, back]) > 0.7)
        #expect(w1.qualifyingWindowIDs.contains(10))
        // Front window covering ~50% of it: back no longer counts and has no perch sites.
        let bigFront = WindowInfo(id: 12, frame: CGRect(x: 1000, y: 700, width: 1200, height: 400))
        let w2 = Self.base.withWindows([bigFront, back])
        #expect(World.visibleFraction(of: 1, in: [bigFront, back]) < 0.7)
        #expect(!w2.qualifyingWindowIDs.contains(10))
        #expect(!w2.perchSites.contains { $0.windowID == 10 })
        // The frontmost window is always fully visible.
        #expect(World.visibleFraction(of: 0, in: [bigFront, back]) == 1)
    }
}
