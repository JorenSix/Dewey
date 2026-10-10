import AppKit
import FlyCore
import FlyBehavior

/// One display as the overlay sees it: the World's `ScreenInfo` plus a name and backing scale.
struct DisplayInfo {
    var info: ScreenInfo
    var name: String
    var scale: CGFloat
    var id: Int { info.id }
    var frame: CGRect { info.frame }
}

/// Screen discovery for the overlay. Real displays come from `NSScreen.screens` (id = CGDirectDisplayID,
/// stable across rearrangement). `FLY_FAKE_SCREENS="x,y,w,h,vx,vy,vw,vh;..."` overrides the list used to
/// build the World (ids 0, 1, …); the overlay panels always sit on the real screens.
enum ScreenLayout {
    /// The real displays, one per `NSScreen`.
    @MainActor static func realDisplays() -> [DisplayInfo] {
        NSScreen.screens.enumerated().map { i, s in
            let num = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? i
            return DisplayInfo(info: ScreenInfo(id: num, frame: s.frame, visibleFrame: s.visibleFrame),
                               name: s.localizedName, scale: s.backingScaleFactor)
        }
    }

    /// Parsed `FLY_FAKE_SCREENS`, or nil when unset or malformed.
    static func fakeDisplays(_ env: [String: String] = ProcessInfo.processInfo.environment) -> [DisplayInfo]? {
        guard let spec = env["FLY_FAKE_SCREENS"], !spec.isEmpty else { return nil }
        var out: [DisplayInfo] = []
        for (i, part) in spec.split(separator: ";").enumerated() {
            let v = part.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard v.count == 8 else {
                NSLog("Dewey: FLY_FAKE_SCREENS entry %d malformed (%@), ignoring the override", i, String(part))
                return nil
            }
            let f = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
            let vf = CGRect(x: v[4], y: v[5], width: v[6], height: v[7])
            out.append(DisplayInfo(info: ScreenInfo(id: i, frame: f, visibleFrame: vf), name: "fake\(i)", scale: 1))
        }
        return out.isEmpty ? nil : out
    }

    /// Displays the World is built from: the fake list when set, else the real screens.
    @MainActor static func worldDisplays() -> [DisplayInfo] {
        if let fake = fakeDisplays() { return fake }
        let real = realDisplays()
        if real.isEmpty {
            let f = CGRect(x: 0, y: 0, width: 1440, height: 900)
            return [DisplayInfo(info: ScreenInfo(id: 0, frame: f, visibleFrame: f), name: "default", scale: 1)]
        }
        return real
    }

    static var usingFakeScreens: Bool { fakeDisplays() != nil }

    /// Edges shared by two screens (frames touching within 1 pt, overlap > 1 pt), as segments.
    static func sharedEdges(_ screens: [ScreenInfo]) -> [(a: CGPoint, b: CGPoint)] {
        var out: [(CGPoint, CGPoint)] = []
        for i in screens.indices {
            for j in screens.indices where j > i {
                let p = screens[i].frame, q = screens[j].frame
                for x in [p.maxX, p.minX] where abs(x - q.minX) <= 1 || abs(x - q.maxX) <= 1 {
                    let lo = max(p.minY, q.minY), hi = min(p.maxY, q.maxY)
                    if hi - lo > 1 { out.append((CGPoint(x: x, y: lo), CGPoint(x: x, y: hi))) }
                }
                for y in [p.maxY, p.minY] where abs(y - q.minY) <= 1 || abs(y - q.maxY) <= 1 {
                    let lo = max(p.minX, q.minX), hi = min(p.maxX, q.maxX)
                    if hi - lo > 1 { out.append((CGPoint(x: lo, y: y), CGPoint(x: hi, y: y))) }
                }
            }
        }
        return out
    }

    /// Dock strips (screen frame minus visible frame at the bottom, left or right), for drawing.
    static func dockRects(_ s: ScreenInfo) -> [CGRect] {
        let f = s.frame, v = s.visibleFrame, t = World.dockThreshold
        var r: [CGRect] = []
        if v.minY - f.minY > t { r.append(CGRect(x: f.minX, y: f.minY, width: f.width, height: v.minY - f.minY)) }
        if v.minX - f.minX > t { r.append(CGRect(x: f.minX, y: f.minY, width: v.minX - f.minX, height: f.height)) }
        if f.maxX - v.maxX > t { r.append(CGRect(x: v.maxX, y: f.minY, width: f.maxX - v.maxX, height: f.height)) }
        return r
    }

    /// Menu-bar strip at the top of a screen.
    static func menuBarRect(_ s: ScreenInfo) -> CGRect? {
        let h = s.frame.maxY - s.visibleFrame.maxY
        return h > 1 ? CGRect(x: s.frame.minX, y: s.visibleFrame.maxY, width: s.frame.width, height: h) : nil
    }
}

/// Draws the World geometry (screens, Dock, menu bar, perch sites, shared edges) in global points into
/// the current graphics context. Used for staged snapshots (`K_crossing.png`) and the `K_layout.png` schematic.
@MainActor
enum LayoutDrawing {
    /// `lineScale` multiplies line widths (1 = 1 pt in global coordinates).
    static func drawWorld(_ world: World, in rect: CGRect, lineScale: CGFloat) {
        NSColor(white: 0.35, alpha: 1).setFill()                 // outside every screen
        rect.fill()
        for s in world.screens {
            NSColor(white: 0.84, alpha: 1).setFill()
            s.frame.fill()
            NSColor(white: 0.62, alpha: 1).setFill()             // Dock
            for d in ScreenLayout.dockRects(s) { d.fill() }
            if let m = ScreenLayout.menuBarRect(s) {
                NSColor(white: 0.72, alpha: 1).setFill()
                m.fill()
            }
            NSColor(white: 0.2, alpha: 1).setStroke()
            let outline = NSBezierPath(rect: s.frame)
            outline.lineWidth = 0.5 * lineScale
            outline.stroke()
        }
        for e in ScreenLayout.sharedEdges(world.screens) {
            segment(e.a, e.b, color: .systemRed, width: 3 * lineScale)
        }
        drawWindows(world, lineScale: lineScale)
        for site in world.perchSites {
            segment(site.a, site.b, color: NSColor(calibratedRed: 0.1, green: 0.7, blue: 0.2, alpha: 1),
                    width: (site.windowID == nil ? 2 : 3) * lineScale)
        }
    }

    /// v5: application windows, painted back to front: qualifying ones outlined blue, the others dashed grey.
    static func drawWindows(_ world: World, lineScale: CGFloat) {
        for w in world.windows.reversed() {
            let q = world.qualifyingWindowIDs.contains(w.id)
            NSColor(white: 0.97, alpha: 1).setFill()
            w.frame.fill()
            NSColor(white: 0.88, alpha: 1).setFill()             // title bar
            CGRect(x: w.frame.minX, y: w.frame.maxY - min(28, w.frame.height), width: w.frame.width,
                   height: min(28, w.frame.height)).fill()
            let path = NSBezierPath(rect: w.frame)
            path.lineWidth = (q ? 2 : 1.5) * lineScale
            if q {
                NSColor.systemBlue.setStroke()
            } else {
                NSColor(white: 0.45, alpha: 1).setStroke()
                let dash: [CGFloat] = [8 * lineScale, 5 * lineScale]
                path.setLineDash(dash, count: dash.count, phase: 0)
            }
            path.stroke()
        }
    }

    static func segment(_ a: CGPoint, _ b: CGPoint, color: NSColor, width: CGFloat) {
        color.setStroke()
        let p = NSBezierPath()
        p.lineWidth = width
        p.lineCapStyle = .butt
        p.move(to: a); p.line(to: b)
        p.stroke()
    }

    /// Writes a schematic of the whole World (`world.boundingBox`, padded) with the fly marked.
    static func writeLayout(world: World, names: [Int: String], fly: FlyFrame, to url: URL) {
        let box = world.boundingBox.insetBy(dx: -120, dy: -120)
        let k: CGFloat = 1600 / box.width
        let pw = Int(box.width * k), ph = Int(box.height * k) + 60
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor.white.setFill()
        CGRect(x: 0, y: 0, width: pw, height: ph).fill()
        let legend: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black]
        ("green = perch sites (\(world.perchSites.count), \(world.windowSites.count) on windows)   red = shared edges   "
         + "grey = Dock / menu bar   windows: blue = qualifying, dashed = not (\(world.qualifyingWindowIDs.count)/\(world.windows.count))   "
         + "blue dot = fly at (\(Int(fly.position.x)), \(Int(fly.position.y))) \(fly.state.rawValue)" as NSString)
            .draw(at: CGPoint(x: 12, y: CGFloat(ph) - 36), withAttributes: legend)
        let xf = NSAffineTransform()
        xf.scale(by: k)
        xf.translateX(by: -box.minX, yBy: -box.minY)
        xf.concat()
        LayoutDrawing.drawWorld(world, in: box, lineScale: 1 / k * 1.5)
        let label: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14 / k), .foregroundColor: NSColor.black]
        for s in world.screens {
            let f = s.frame
            ("\(names[s.id] ?? "#\(s.id)")  frame \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height))" as NSString)
                .draw(at: CGPoint(x: f.minX + 40, y: f.maxY - 80), withAttributes: label)
        }
        for w in world.windows {
            let f = w.frame
            ("window \(w.id)  \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height))" as NSString)
                .draw(at: CGPoint(x: f.minX + 10 / k, y: f.maxY - 28 - 20 / k), withAttributes: label)
        }
        let r = 14 / k
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: CGRect(x: fly.position.x - r, y: fly.position.y - r, width: 2 * r, height: 2 * r)).fill()
        segment(fly.position, CGPoint(x: fly.position.x + cos(fly.heading) * 60 / k, y: fly.position.y + sin(fly.heading) * 60 / k),
                color: .systemBlue, width: 3 / k)
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        NSLog("Dewey: layout snapshot %@", url.lastPathComponent)
    }
}
