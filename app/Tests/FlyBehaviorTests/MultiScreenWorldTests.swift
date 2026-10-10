import CoreGraphics
import Testing
import FlyCore
@testable import FlyBehavior

private func sites(_ w: World, _ id: Int, _ side: Perch) -> [PerchSite] {
    w.perchSites.filter { $0.screenID == id && $0.side == side }
}

/// The along-edge interval of a site (y for side edges, x for bottom).
private func span(_ s: PerchSite) -> (CGFloat, CGFloat) {
    s.side == .bottom ? (min(s.a.x, s.b.x), max(s.a.x, s.b.x)) : (min(s.a.y, s.b.y), max(s.a.y, s.b.y))
}

/// True when no perch site of `w` touches a part of an edge shared between two screens.
private func noSiteOnSharedEdge(_ w: World) -> Bool {
    for s in w.perchSites {
        let (lo, hi) = span(s)
        for t in w.screens where t.id != s.screenID {
            let f = t.frame
            switch s.side {
            case .left, .right:
                if abs(f.maxX - s.a.x) <= 1 || abs(f.minX - s.a.x) <= 1 {
                    if min(hi, f.maxY) - max(lo, f.minY) > 1 { return false }
                }
            case .bottom:
                if abs(f.maxY - s.a.y) <= 1, min(hi, f.maxX) - max(lo, f.minX) > 1 { return false }
            }
        }
    }
    return true
}

@Suite struct MultiScreenWorldTests {
    // DELL P2715Q (Dock bottom) with the built-in display to its upper left.
    static let dell = ScreenInfo(id: 1, frame: CGRect(x: 0, y: 0, width: 3840, height: 2160),
                                 visibleFrame: CGRect(x: 0, y: 93, width: 3840, height: 2042))
    static let laptop = ScreenInfo(id: 2, frame: CGRect(x: -1800, y: 991, width: 1800, height: 1169),
                                   visibleFrame: CGRect(x: -1800, y: 991, width: 1800, height: 1131))

    @Test func usersRealLayout() {
        let w = World(screens: [Self.dell, Self.laptop])
        let m = w.cornerMargin, i = w.perchInset
        // Dell left edge: only below the laptop.
        let dl = sites(w, 1, .left)
        #expect(dl.count == 1)
        #expect(span(dl[0]).0 == 93 + i + m)
        #expect(span(dl[0]).1 == 991)
        #expect(dl[0].a.x == 0)
        // Dell right edge: full height below the menu bar; bottom = Dock top.
        #expect(sites(w, 1, .right).count == 1)
        #expect(span(sites(w, 1, .right)[0]).1 == 2135 - m)
        let db = sites(w, 1, .bottom)
        #expect(db.count == 1 && db[0].a.y == 93)
        // Laptop: right edge fully shared, bottom (no Dock) and left edge perchable.
        #expect(sites(w, 2, .right).isEmpty)
        let lb = sites(w, 2, .bottom)
        #expect(lb.count == 1 && lb[0].a.y == 991)
        #expect(span(lb[0]) == (-1800 + i + m, -i - m))
        #expect(sites(w, 2, .left).count == 1)
        #expect(span(sites(w, 2, .left)[0]).1 == 2122 - m)
        #expect(noSiteOnSharedEdge(w))

        // Crossing point between the screens.
        #expect(w.flightRegionContains(CGPoint(x: 0, y: 1500)))
        #expect(w.flightRegionContains(CGPoint(x: -500, y: 1500)))
        // Dell's free left edge below the laptop is an outer border (inset).
        #expect(!w.flightRegionContains(CGPoint(x: 1, y: 500)))
        #expect(w.flightRegionContains(CGPoint(x: 5, y: 500)))
        // Below the laptop, left of the Dell: outside.
        #expect(!w.flightRegionContains(CGPoint(x: -500, y: 500)))
        #expect(w.clampToFlightRegion(CGPoint(x: -500, y: 500)) == CGPoint(x: -500, y: 995))
        // Menu bars are excluded (laptop's is taller).
        #expect(!w.flightRegionContains(CGPoint(x: -500, y: 2125)))
        #expect(w.flightRegionContains(CGPoint(x: 500, y: 2125)))
        // Gaze ray westwards passes into the laptop and hits its left border.
        #expect(abs(w.borderDistance(from: CGPoint(x: 100, y: 1500), direction: .pi) - 1900) < 1e-6)
        // Below the laptop the same ray hits the Dell's left border.
        #expect(abs(w.borderDistance(from: CGPoint(x: 100, y: 500), direction: .pi) - 100) < 1e-6)
        let r = w.castRegionRay(from: CGPoint(x: 100, y: 1500), angle: .pi)
        #expect(r.normal == CGVector(dx: 1, dy: 0))

        #expect(w.screen(containing: CGPoint(x: -100, y: 1500))?.id == 2)
        #expect(w.screen(containing: CGPoint(x: 100, y: 500))?.id == 1)
        #expect(w.screen(containing: CGPoint(x: -100, y: 500)) == nil)
        #expect(w.boundingBox == CGRect(x: -1800, y: 0, width: 5640, height: 2160))

        // Nearest site from inside the laptop near its right side is NOT the shared edge.
        let n = w.nearestPerchSite(to: CGPoint(x: -20, y: 1600))!
        #expect(!(n.site.screenID == 2 && n.site.side == .right))
        #expect(!(n.site.screenID == 1 && n.site.side == .left))
    }

    @Test func sideBySideEqualHeights() {
        let a = ScreenInfo(id: 0, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                           visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055))
        let b = ScreenInfo(id: 1, frame: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
                           visibleFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1055))
        let w = World(screens: [a, b])
        #expect(sites(w, 0, .right).isEmpty)
        #expect(sites(w, 1, .left).isEmpty)
        #expect(sites(w, 0, .left).count == 1 && sites(w, 1, .right).count == 1)
        #expect(sites(w, 0, .bottom).count == 1 && sites(w, 1, .bottom).count == 1)
        #expect(w.perchSites.count == 4)
        #expect(noSiteOnSharedEdge(w))
        #expect(w.flightRegionContains(CGPoint(x: 1920, y: 500)))
        #expect(abs(w.borderDistance(from: CGPoint(x: 100, y: 500), direction: 0) - 3740) < 1e-6)
    }

    @Test func differentHeightsWithOffset() {
        // Small screen to the right, vertically offset: its left edge shares y 300..1068 with the big one.
        let big = ScreenInfo(id: 0, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                             visibleFrame: CGRect(x: 0, y: 80, width: 2560, height: 1335))
        let small = ScreenInfo(id: 1, frame: CGRect(x: 2560, y: 300, width: 1366, height: 768),
                               visibleFrame: CGRect(x: 2560, y: 300, width: 1366, height: 743))
        let w = World(screens: [big, small])
        // Big right edge: free below 300 and above 1068 (partial sharing leaves both pieces).
        let br = sites(w, 0, .right).map(span).sorted { $0.0 < $1.0 }
        #expect(br.count == 2)
        #expect(br[0].1 == 300)
        #expect(br[1].0 == 1068)
        #expect(br[1].1 == 1415 - w.cornerMargin)
        // Small left edge fully shared.
        #expect(sites(w, 1, .left).isEmpty)
        #expect(sites(w, 1, .bottom).count == 1)
        #expect(noSiteOnSharedEdge(w))
        #expect(w.flightRegionContains(CGPoint(x: 2560, y: 600)))
        #expect(!w.flightRegionContains(CGPoint(x: 3000, y: 200)))
        #expect(abs(w.borderDistance(from: CGPoint(x: 2000, y: 600), direction: 0) - (3926 - 2000)) < 1e-6)
        #expect(abs(w.borderDistance(from: CGPoint(x: 2000, y: 200), direction: 0) - 560) < 1e-6)
    }

    @Test func stackedScreens() {
        let bottom = ScreenInfo(id: 0, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                visibleFrame: CGRect(x: 0, y: 70, width: 1920, height: 985))
        let top = ScreenInfo(id: 1, frame: CGRect(x: 200, y: 1080, width: 1440, height: 900),
                             visibleFrame: CGRect(x: 200, y: 1080, width: 1440, height: 875))
        let w = World(screens: [bottom, top])
        // The top screen's bottom edge lies on the lower screen: no perch.
        #expect(sites(w, 1, .bottom).isEmpty)
        // The lower screen's menu-bar top is never a perch; its Dock bottom is.
        #expect(sites(w, 0, .bottom).count == 1 && sites(w, 0, .bottom)[0].a.y == 70)
        #expect(w.perchSites.allSatisfy { $0.side != .bottom || $0.screenID == 0 })
        #expect(sites(w, 1, .left).count == 1 && sites(w, 1, .right).count == 1)
        #expect(noSiteOnSharedEdge(w))
        // The lower screen's menu bar is passable only under the upper screen.
        #expect(w.flightRegionContains(CGPoint(x: 900, y: 1070)))
        #expect(!w.flightRegionContains(CGPoint(x: 100, y: 1070)))
        #expect(!w.flightRegionContains(CGPoint(x: 202, y: 1070)))
        #expect(abs(w.borderDistance(from: CGPoint(x: 900, y: 500), direction: .pi / 2) - (1955 - 500)) < 1e-6)
        #expect(abs(w.borderDistance(from: CGPoint(x: 100, y: 500), direction: .pi / 2) - (1055 - 500)) < 1e-6)
    }

    @Test func stackedScreensWithoutMenuBarBetween() {
        // Secondary below with no menu bar: the fly can cross the shared horizontal edge.
        let top = ScreenInfo(id: 0, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                             visibleFrame: CGRect(x: 0, y: 0, width: 1920, height: 1055))
        let below = ScreenInfo(id: 1, frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
                               visibleFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1080))
        let w = World(screens: [top, below])
        #expect(sites(w, 0, .bottom).isEmpty)
        #expect(sites(w, 1, .bottom).count == 1)
        #expect(noSiteOnSharedEdge(w))
        #expect(w.flightRegionContains(CGPoint(x: 900, y: 0)))
        #expect(abs(w.borderDistance(from: CGPoint(x: 900, y: 500), direction: -.pi / 2) - 1580) < 1e-6)
    }

    @Test func largeSingleScreens() {
        for (wd, ht) in [(CGFloat(3840), CGFloat(2160)), (5120, 2880)] {
            let f = CGRect(x: 0, y: 0, width: wd, height: ht)
            let w = World(screens: [ScreenInfo(id: 7, frame: f,
                                               visibleFrame: CGRect(x: 0, y: 90, width: wd, height: ht - 90 - 25))])
            #expect(w.perchSites.count == 3)
            #expect(Set(w.perchSites.map(\.side.rawValue)) == ["left", "right", "bottom"])
            #expect(w.flightRegionContains(CGPoint(x: wd / 2, y: ht / 2)))
            #expect(!w.flightRegionContains(CGPoint(x: 2, y: ht / 2)))
            #expect(w.clampToFlightRegion(CGPoint(x: wd + 50, y: ht + 50)) == CGPoint(x: wd - 4, y: ht - 25 - 4))
            let site = w.nearestPerchSite(to: CGPoint(x: wd / 2, y: 120))!
            #expect(site.site.side == .bottom && site.point == CGPoint(x: wd / 2, y: 90 + w.perchInset))
            #expect(abs(w.borderDistance(from: CGPoint(x: wd / 2, y: ht / 2), direction: 0) - Double(wd / 2)) < 1e-6)
        }
    }

    @Test func singleScreenEquivalence() {
        let frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visibles = [CGRect(x: 0, y: 70, width: 1440, height: 805), CGRect(x: 64, y: 0, width: 1376, height: 875),
                        CGRect(x: 0, y: 0, width: 1376, height: 875), CGRect(x: 0, y: 4, width: 1440, height: 871)]
        for vf in visibles {
            let old = World(screenFrame: frame, visibleFrame: vf, perchInset: 14)
            let new = World(screens: [ScreenInfo(id: 0, frame: frame, visibleFrame: vf)], perchInset: 14)
            #expect(old.dock == new.dock && old.leftX == new.leftX && old.rightX == new.rightX)
            #expect(old.bottomY == new.bottomY && old.topY == new.topY && old.flightBounds == new.flightBounds)
            #expect(new.perchSites.count == 3)
            var rng = SeededRandom(seed: 3)
            for _ in 0..<200 {
                let p = CGPoint(x: rng.uniform(-100, 1540), y: rng.uniform(-100, 1000))
                for perch in [Perch.left, .right, .bottom] {
                    let site = new.perchSites.first { $0.side == perch }!
                    #expect(new.perchPoint(on: site, near: p) == old.perchPoint(perch, near: p))
                }
                let a = old.nearestPerch(to: p), b = new.nearestPerchSite(to: p)!
                #expect(a.point == b.point && a.perch == b.site.side)
                #expect(old.clampToFlightBounds(p) == new.clampToFlightRegion(p))
                #expect(old.flightBounds.contains(p) == new.flightRegionContains(p))
            }
            // perchInset changes propagate to the sites.
            var w2 = new
            w2.perchInset = 20
            let s = w2.perchSites.first { $0.side == .left }!
            #expect(w2.perchPoint(on: s, near: CGPoint(x: 0, y: -50)) == old.local(at: .zero).with(inset: 20)
                .perchPoint(.left, near: CGPoint(x: 0, y: -50)))
        }
    }

    @Test func randomPerchSiteFavoursNearButReachesAll() {
        let w = World(screens: [Self.dell, Self.laptop])
        var rng = SeededRandom(seed: 11)
        var counts: [String: Int] = [:]
        let from = CGPoint(x: 3700, y: 1000) // near the Dell's right edge
        for _ in 0..<4000 {
            let s = w.randomPerchSite(from: from, using: &rng)!
            counts["\(s.screenID)-\(s.side.rawValue)", default: 0] += 1
        }
        #expect(counts.count == w.perchSites.count)
        #expect(counts["1-right", default: 0] > counts["2-left", default: 0])
    }

    @Test func localWorldPicksScreen() {
        let w = World(screens: [Self.dell, Self.laptop], perchInset: 12)
        let l = w.local(at: CGPoint(x: -900, y: 1500))
        #expect(l.screenFrame == Self.laptop.frame && l.perchInset == 12)
        #expect(w.local(at: CGPoint(x: -900, y: 100)).screenFrame == Self.laptop.frame)
        #expect(w.screenFrame == Self.dell.frame && w.dock == .bottom)
    }
}

private extension World {
    func with(inset: CGFloat) -> World { var w = self; w.perchInset = inset; return w }
}
