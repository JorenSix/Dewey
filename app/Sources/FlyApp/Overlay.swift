import AppKit
import QuartzCore
import SceneKit
import FlyCore
import FlyBehavior
import FlyBrain
import simd

/// Window level: above the menu bar (statusBar = 25) and the Dock (kCGDockWindowLevel = 20).
let overlayWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)

/// Borderless, transparent, click-through panel covering one screen.
final class OverlayPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = overlayWindowLevel
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        setFrame(frame, display: false)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the overlay panels (one per screen), the displays, the single display-link loop, the screen
/// layout, and the flies: one `FlyActor` per fly (Dewey = actor 0, the flock leader; friends 1…5).
///
/// Scene units are AppKit global screen points (the same space as `World`). Each actor has its own small
/// SceneKit view that is re-parented into the panel of the screen containing the fly's centre (see
/// `FlyActor`). Every display-link tick the `FlockCoordinator` hands each controller its neighbours and
/// updates all controllers with the same pointer and dt; then every actor applies its frame.
@MainActor
final class OverlayController: NSObject, FlyActorHost {
    /// One panel per real display, keyed by `DisplayInfo.id` (CGDirectDisplayID).
    private var panels: [Int: OverlayPanel] = [:]
    private var displays: [DisplayInfo] = []
    private var worldNames: [Int: String] = [:]
    private var worldScreens: [ScreenInfo] = []
    private var showing = false
    /// Dewey first, then friends by id.
    private(set) var actors: [FlyActor] = []
    /// Removed friends still fading out (not simulated).
    private var fadingActors: [FlyActor] = []
    private let coordinator = FlockCoordinator()
    /// v5: the normal application windows; every fly's World carries the same list.
    private let windowTracker = WindowTracker()
    private var loggedWindowCounts: (Int, Int, Int)?
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private let stage = DebugStage.current
    private let baseSeed: UInt64
    private var rng: SeededRandom
    /// FLY_FRIENDS pins the friend count for the session (debug), overriding the setting.
    private let friendsOverride = ProcessInfo.processInfo.environment["FLY_FRIENDS"].flatMap(Int.init)

    /// Builds the fly visual; swap in a FlyBody-backed renderable here.
    static var makeRenderable: @MainActor () -> FlyRenderable = { PlaceholderFly() }

    /// Builds a friend's brain: a ConnectomeBrain on Dewey's circuit with its own seed (no reload), else
    /// the app's brain factory (circuit.json, falling back to ScriptedBrain).
    static var makeFriendBrain: @MainActor (_ seed: UInt64, _ dewey: Brain) -> Brain = { seed, dewey in
        if let cb = dewey as? ConnectomeBrain { return ConnectomeBrain(circuit: cb.circuit, config: cb.config, seed: seed) }
        return AppDelegate.makeBrain(seed)
    }

    init(brain: Brain, seed: UInt64, startState: FlyState) {
        baseSeed = seed
        rng = SeededRandom(seed: seed ^ 0xF00D_F1E5)
        super.init()
        let worldDisplays = ScreenLayout.worldDisplays()
        worldScreens = worldDisplays.map(\.info)
        worldNames = Dictionary(worldDisplays.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        displays = ScreenLayout.realDisplays()
        if let s = ProcessInfo.processInfo.environment["FLY_SIZE"].flatMap(Double.init) {
            flySize = min(max(s, DeweySettings.sizeRange.lowerBound), DeweySettings.sizeRange.upperBound)
        }
        let controller = FlyController(world: World(screens: worldScreens), brain: brain, seed: seed, startState: startState)
        actors = [FlyActor(id: 0, controller: controller, brain: brain, renderable: OverlayController.makeRenderable(),
                           size: flySize, sizeFactor: 1, host: self)]
        logScreens(worldDisplays)
        windowTracker.onChange = { [unowned self] change in windowsChanged(change) }
        if let n = friendsOverride {
            NSLog("Dewey: FLY_FRIENDS=%d (overrides the Friends setting)", n)
            applyFriendCount(n)
        }
    }

    var dewey: FlyActor { actors[0] }
    var controller: FlyController { dewey.controller }
    var isShowing: Bool { showing }

    func show() {
        if panels.isEmpty { buildWindows() }
        for p in panels.values { p.orderFrontRegardless() }
        showing = true
        lastTimestamp = nil
        windowTracker.start()
        logWindowCounts()
        startLoop()
    }

    func hide() {
        stopLoop()
        windowTracker.stop()
        for p in panels.values { p.orderOut(nil) }
        showing = false
    }

    // MARK: - FlyActorHost

    var hostPanels: [Int: OverlayPanel] { panels }
    var hostDisplays: [DisplayInfo] { displays }
    var hostWorldNames: [Int: String] { worldNames }

    func actorDidRehost(_ actor: FlyActor) {
        // The display link comes from Dewey's view, so it follows that screen's refresh rate.
        guard actor.id == 0, displayLink != nil else { return }
        stopLoop()
        startLoop()
    }

    // MARK: - Size

    /// Body length of Dewey on screen in points (DeweySettings.size, clamped to 20...120). Live; every
    /// friend keeps its own factor × this.
    func setFlySize(_ points: Double) {
        let s = min(max(points, DeweySettings.sizeRange.lowerBound), DeweySettings.sizeRange.upperBound)
        guard s != flySize else { return }
        flySize = s
        for a in actors { a.setSize(s * a.sizeFactor) }
    }
    private(set) var flySize: Double = 40

    /// Dewey's perch clearance (points); see `FlyActor.perchClearance`.
    var perchClearance: CGFloat { dewey.perchClearance }
    func perchClearance(for perch: Perch) -> CGFloat { dewey.perchClearance(for: perch) }

    /// Replace Dewey's visual at runtime.
    func setRenderable(_ r: FlyRenderable) { dewey.setRenderable(r) }

    // MARK: - Friends (v4)

    /// Sets the number of companion flies (0...5), adding/removing them live. Added friends get ids
    /// count+1…n; removal drops the highest ids (fading out while visible). With FLY_FRIENDS set this is ignored.
    func setFriends(_ n: Int) {
        if let o = friendsOverride, o != n {
            NSLog("Dewey: setFriends(%d) ignored, FLY_FRIENDS=%d", n, o)
            return
        }
        applyFriendCount(n)
    }

    private func applyFriendCount(_ n: Int) {
        let target = min(max(n, DeweySettings.friendsRange.lowerBound), DeweySettings.friendsRange.upperBound)
        while actors.count - 1 > target { removeFriend(actors.removeLast()) }
        while actors.count - 1 < target { addFriend(id: actors.count) }
    }

    /// Number of friends.
    var friendCount: Int { actors.count - 1 }
    /// Controllers of every fly (Dewey first), for applying settings such as `flightBoutRange`.
    var allControllers: [FlyController] { actors.map(\.controller) }
    /// Brains of the friends (Dewey's brain is owned by AppDelegate), for applying restlessness.
    var friendBrains: [Brain] { actors.dropFirst().map(\.brain) }

    /// Spawns friend `id` airborne 100–200 pt from Dewey, with its own brain (distinct seed), its own
    /// controller on its own copy of the World, and a size factor drawn once from
    /// `DeweySettings.friendSizeFactor`. Restlessness and flight bout come from the saved settings
    /// (AppDelegate re-applies them to everyone after `setFriends`).
    private func addFriend(id: Int) {
        let t0 = CACurrentMediaTime()
        let factor = rng.uniform(DeweySettings.friendSizeFactor.lowerBound, DeweySettings.friendSizeFactor.upperBound)
        let size = flySize * factor
        let seed = baseSeed &+ UInt64(id) &* 0x9E37_79B9_7F4A_7C15
        let brain = OverlayController.makeFriendBrain(seed, dewey.brain)
        let tBrain = CACurrentMediaTime()

        // Airborne 100–200 pt from Dewey, heading roughly with him (±0.5 rad) when he flies.
        let d = dewey.controller
        let r = rng.uniform(100, 200), a = rng.uniform(-.pi, .pi)
        let c = FlyController(world: World(screens: worldScreens, perchInset: d.world.perchInset)
                                .withWindows(windowTracker.windows),
                              brain: brain, seed: seed, startState: .flying)
        c.place(at: CGPoint(x: d.position.x + CGFloat(r * cos(a)), y: d.position.y + CGFloat(r * sin(a))),
                heading: d.isAirborne ? d.heading + rng.uniform(-0.5, 0.5) : nil)
        let settings = SettingsStore(defaults: .standard).load()
        c.flightBoutRange = settings.flightBout
        (brain as? RestlessnessTunable)?.setRestBout(settings.restBout)
        c.flockingEnabled = d.flockingEnabled

        let actor = FlyActor(id: id, controller: c, brain: brain, renderable: OverlayController.makeRenderable(),
                             size: size, sizeFactor: factor, host: self)
        actors.append(actor)
        if !panels.isEmpty { actor.makeView() }
        NSLog("Dewey: friend %d added size=%.1f (factor %.3f) at (%.0f,%.0f) brain=%@ (%.0f ms) total %.0f ms",
              id, size, factor, c.position.x, c.position.y, String(describing: type(of: brain)),
              (tBrain - t0) * 1000, (CACurrentMediaTime() - t0) * 1000)
    }

    private func removeFriend(_ actor: FlyActor) {
        NSLog("Dewey: friend %d removed", actor.id)
        fadingActors.append(actor)
        actor.remove(fade: showing) { [weak self] in
            self?.fadingActors.removeAll { $0 === actor }
        }
    }

    // MARK: - Screens

    /// Screens plugged, unplugged or rearranged: every fly gets a fresh World from all screens (keeping its
    /// own `perchInset`; `FlyController.world.didSet` keeps it in the flight region / on its perch), the
    /// per-screen panels are re-synced and every view re-hosted.
    func screenParametersChanged() {
        let worldDisplays = ScreenLayout.worldDisplays()
        worldNames = Dictionary(worldDisplays.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        worldScreens = worldDisplays.map(\.info)
        displays = ScreenLayout.realDisplays()
        if !panels.isEmpty { syncPanels() }
        NSLog("Dewey: screen parameters changed")
        for a in actors {
            a.setScreens(worldScreens)
            a.controller.world = a.controller.world.withWindows(windowTracker.windows)
        }
        logScreens(worldDisplays)
        logWindowCounts()
    }

    // MARK: - Windows (v5)

    /// The window list changed: every fly's World gets the new windows (keeping its own perch inset), then
    /// every controller hears which windows moved/resized or closed (startle, retargeting; module Q).
    private func windowsChanged(_ change: WindowTracker.Change) {
        for a in actors { a.controller.world = a.controller.world.withWindows(change.windows) }
        for c in allControllers { c.windowsChanged(moved: change.moved, removed: change.removed) }
        logWindowCounts()
    }

    /// Logs `windows=<n> qualifying=<m> windowSites=<k>` (Dewey's World) when any count changed.
    private func logWindowCounts() {
        let w = controller.world
        let counts = (w.windows.count, w.qualifyingWindowIDs.count, w.windowSites.count)
        if let last = loggedWindowCounts, last == counts { return }
        loggedWindowCounts = counts
        NSLog("Dewey: windows=%d qualifying=%d windowSites=%d%@", counts.0, counts.1, counts.2,
              windowTracker.usingFakeWindows ? " (FLY_FAKE_WINDOWS)" : "")
    }

    private func logScreens(_ list: [DisplayInfo]) {
        NSLog("Dewey: %d screen(s)%@", list.count, ScreenLayout.usingFakeScreens ? " (FLY_FAKE_SCREENS)" : "")
        for d in list {
            NSLog("Dewey:   screen %d \"%@\" frame=%@ visible=%@ scale=%.0f", d.id, d.name,
                  NSStringFromRect(d.frame), NSStringFromRect(d.info.visibleFrame), d.scale)
        }
        let sites = controller.world.perchSites
        NSLog("Dewey: %d perch site(s): %@", sites.count, sites.map { s in
            "\(worldNames[s.screenID] ?? "#\(s.screenID)"):\(s.side.rawValue) (\(Int(s.a.x)),\(Int(s.a.y)))-(\(Int(s.b.x)),\(Int(s.b.y)))"
        }.joined(separator: ", "))
    }

    // MARK: - Panels

    private func buildWindows() {
        syncPanels()
        for a in actors { a.makeView() }
    }

    /// One panel per real display: create missing ones, resize existing ones, close those whose display
    /// went away (actors re-host their views first).
    private func syncPanels() {
        let ids = Set(displays.map(\.id))
        let gone = panels.filter { !ids.contains($0.key) }
        for (id, _) in gone { panels[id] = nil }
        for a in actors + fadingActors { a.panelsChanged() }
        for (_, p) in gone { p.orderOut(nil); p.close() }
        for d in displays {
            if let p = panels[d.id] {
                p.setFrame(d.frame, display: false)
            } else {
                let p = OverlayPanel(frame: d.frame)
                let container = NSView(frame: CGRect(origin: .zero, size: d.frame.size))
                container.autoresizingMask = [.width, .height]
                p.contentView = container
                panels[d.id] = p
                if showing { p.orderFrontRegardless() }
            }
        }
        for a in actors { a.panelsChanged() }
    }

    // MARK: - Loop

    private func startLoop() {
        guard displayLink == nil, let v = dewey.scnView else { return }
        let link = v.displayLink(target: self, selector: #selector(tick(_:)))
        let fps = Float(ProcessInfo.processInfo.environment["FLY_FPS"] ?? "") ?? 60
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(fps, 30), maximum: fps, preferred: fps)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopLoop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// Clamp dt so a hide/show or a handoff gap never produces a huge step.
    private func frameDt(_ now: CFTimeInterval) -> Double {
        guard let last = lastTimestamp, now > last else { return 1.0 / 60 }
        return min(now - last, 0.1)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let t0 = CACurrentMediaTime()
        let now = link.timestamp
        let rawDt = lastTimestamp.map { now - $0 } ?? 0
        let dt = frameDt(now)
        lastTimestamp = now
        if let stage {
            if stage == .sweep { sweepClock += dt }
            let time = stage == .sweep ? sweepClock : 0.0074 // fixed wing phase so snapshots are reproducible
            if stage.isFlock {
                for (i, a) in actors.enumerated() {
                    let f = stage.flockFrame(index: i, world: a.controller.world, time: time, size: a.flySize,
                                             leaderSize: flySize) { a.perchClearance(for: $0) }
                    a.apply(f, dt: dt, staged: true)
                }
            } else {
                let f = stage.frame(world: controller.world, time: time) { [unowned self] in perchClearance(for: $0) }
                dewey.apply(f, dt: dt, staged: true)
                let rest = Array(actors.dropFirst())
                let frames = coordinator.step(rest.map(\.controller), pointer: NSEvent.mouseLocation, dt: dt)
                for (a, f) in zip(rest, frames) { a.apply(f, dt: dt) }
            }
        } else {
            let frames = coordinator.step(allControllers, pointer: NSEvent.mouseLocation, dt: dt)
            let t1 = CACurrentMediaTime()
            for (a, f) in zip(actors, frames) { a.apply(f, dt: dt) }
            if frameStats { statStep.append(t1 - t0) }
        }
        debugSnapshotIfNeeded(dt: dt)
        recordFrameStats(rawDt: rawDt, work: CACurrentMediaTime() - t0)
    }

    // MARK: - Frame-time stats (FLY_FRAME_STATS=1): every 10 s, tick interval and main-thread work per tick.

    private let frameStats = ProcessInfo.processInfo.environment["FLY_FRAME_STATS"] == "1"
    private var statDts: [Double] = [], statWork: [Double] = [], statStep: [Double] = []
    private var statClock = 0.0

    private func recordFrameStats(rawDt: Double, work: Double) {
        guard frameStats, rawDt > 0 else { return }
        statDts.append(rawDt)
        statWork.append(work)
        statClock += rawDt
        guard statClock >= 10 else { return }
        func pct(_ a: [Double], _ p: Double) -> Double {
            let s = a.sorted()
            return s[min(s.count - 1, Int(Double(s.count - 1) * p))] * 1000
        }
        NSLog("Dewey: frame stats flies=%d ticks=%d dt median=%.1f p95=%.1f max=%.1f ms; tick work median=%.2f p95=%.2f max=%.2f ms",
              actors.count, statDts.count, pct(statDts, 0.5), pct(statDts, 0.95), pct(statDts, 1),
              pct(statWork, 0.5), pct(statWork, 0.95), pct(statWork, 1))
        if !statStep.isEmpty {
            NSLog("Dewey: frame stats   of which simulation (flock + brains) median=%.2f p95=%.2f max=%.2f ms",
                  pct(statStep, 0.5), pct(statStep, 0.95), pct(statStep, 1))
        }
        statStep.removeAll(keepingCapacity: true)
        statDts.removeAll(keepingCapacity: true)
        statWork.removeAll(keepingCapacity: true)
        statClock = 0
    }

    // MARK: - Debug snapshots (FLY_SNAPSHOT_DIR=<dir>): renders the overlay scenes themselves, which works
    // without Screen Recording permission. Free-running: one PNG every 2 s (max 6) of Dewey's screen with
    // every fly composited on the World drawing. With FLY_FORCE_STATE=<stage> (flying, banking, perched_left,
    // perched_bottom, takeoff, crossing): one <prefix><stage>.png, cropped to Dewey's view at 3×, drawn over
    // the World geometry (screens, Dock, perch sites green, shared edges red) with a projection check marker.
    // Prefix is G_, or K_ with FLY_FAKE_SCREENS, which also writes K_layout.png. The flock stages
    // (flock_flying, flock_perched; use with FLY_FRIENDS=n) write M_<stage>.png, cropped around all flies at 2×.
    // FLY_SNAPSHOT_EXIT=1 then quits.

    private var snapshotClock = 0.0
    private var sweepClock = 0.0
    private var snapshotCount = 0
    private let snapshotDir = ProcessInfo.processInfo.environment["FLY_SNAPSHOT_DIR"]

    private func debugSnapshotIfNeeded(dt: Double) {
        guard let dir = snapshotDir, snapshotCount < 6, dewey.scnView != nil else { return }
        snapshotClock += dt
        if let stage {
            guard stage != .sweep, snapshotClock >= 1.5 else { return }
            snapshotCount = 6
            if stage.isFlock { writeFlockSnapshot(stage, dir: dir) } else { writeStageSnapshot(stage, dir: dir) }
            if ScreenLayout.usingFakeScreens {
                LayoutDrawing.writeLayout(world: controller.world, names: worldNames, fly: dewey.lastFrame,
                                          to: URL(fileURLWithPath: dir).appendingPathComponent("K_layout.png"))
            }
            if ProcessInfo.processInfo.environment["FLY_SNAPSHOT_EXIT"] == "1" { NSApp.terminate(nil) }
            return
        }
        guard snapshotClock >= 2 else { return }
        snapshotClock = 0
        snapshotCount += 1
        // Dewey's host panel's screen, in global points.
        let area = dewey.hostID.flatMap { panels[$0]?.frame } ?? controller.world.boundingBox
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(area.width), pixelsHigh: Int(area.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let xf = NSAffineTransform()
        xf.translateX(by: -area.minX, yBy: -area.minY)
        xf.concat()
        LayoutDrawing.drawWorld(controller.world, in: area, lineScale: 1)
        for a in actors { if let v = a.scnView { v.snapshot().draw(in: a.viewRect) } }
        NSGraphicsContext.restoreGraphicsState()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("C_snapshot_\(snapshotCount).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        let f = controller.frame
        NSLog("FlyApp: snapshot %@ state=%@ pos=(%.0f,%.0f) heading=%.2f perch=%@ flies=%d", url.lastPathComponent,
              f.state.rawValue, f.position.x, f.position.y, f.heading, f.perch?.rawValue ?? "-", actors.count)
    }

    private func writeStageSnapshot(_ stage: DebugStage, dir: String) {
        guard let v = dewey.scnView else { return }
        let zoom: CGFloat = 3
        let img = v.snapshot()
        let r = dewey.viewRect  // crop, global points
        let px = Int(r.width * zoom)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        let xf = NSAffineTransform()
        xf.scale(by: zoom)
        xf.translateX(by: -r.minX, yBy: -r.minY)
        xf.concat()
        LayoutDrawing.drawWorld(controller.world, in: r.insetBy(dx: -1, dy: -1), lineScale: 0.4)
        img.draw(in: r)
        // Projection check: red cross = where FlyBehavior puts the fly (+ edge-standing offset);
        // cyan ring = where SceneKit actually projects the fly root.
        let root = dewey.flyRoot
        let expected = CGPoint(x: root.position.x, y: root.position.y)
        let pr = v.projectPoint(root.worldPosition)
        let got = CGPoint(x: r.minX + pr.x, y: r.minY + pr.y)
        NSColor.systemRed.withAlphaComponent(0.7).setStroke()
        let cross = NSBezierPath()
        cross.lineWidth = 0.4
        cross.move(to: CGPoint(x: expected.x - 3, y: expected.y)); cross.line(to: CGPoint(x: expected.x + 3, y: expected.y))
        cross.move(to: CGPoint(x: expected.x, y: expected.y - 3)); cross.line(to: CGPoint(x: expected.x, y: expected.y + 3))
        cross.stroke()
        NSColor.systemTeal.withAlphaComponent(0.8).setStroke()
        let ring = NSBezierPath(ovalIn: CGRect(x: got.x - 1.5, y: got.y - 1.5, width: 3, height: 3))
        ring.lineWidth = 0.4
        ring.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let prefix = ScreenLayout.usingFakeScreens ? "K_" : "G_"
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)\(stage.rawValue).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        let last = dewey.lastFrame
        let onScreen = controller.world.screen(containing: last.position).map { worldNames[$0.id] ?? "#\($0.id)" } ?? "-"
        NSLog("FlyApp: stage snapshot %@ size=%.0f view=%.0f pos=(%.0f,%.0f) screen=%@ projErr=(%.2f,%.2f) roll=%.2f pitch=%.2f clearance L/R/B=%.1f/%.1f/%.1f footContact=%.3f",
              url.lastPathComponent, flySize, dewey.viewSize, last.position.x, last.position.y, onScreen,
              got.x - expected.x, got.y - expected.y, dewey.shownRoll, dewey.shownPitch,
              perchClearance(for: .left), perchClearance(for: .right), perchClearance(for: .bottom),
              dewey.renderable.footContact)
    }

    /// M_<stage>.png: every fly's view composited over the World drawing, cropped around the flock at 2×.
    private func writeFlockSnapshot(_ stage: DebugStage, dir: String) {
        let zoom: CGFloat = 2
        var r = actors.map(\.viewRect).reduce(dewey.viewRect) { $0.union($1) }.insetBy(dx: -12, dy: -12)
        r = r.integral
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(r.width * zoom), pixelsHigh: Int(r.height * zoom),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        let xf = NSAffineTransform()
        xf.scale(by: zoom)
        xf.translateX(by: -r.minX, yBy: -r.minY)
        xf.concat()
        LayoutDrawing.drawWorld(controller.world, in: r, lineScale: 0.5)
        for a in actors.reversed() { if let v = a.scnView { v.snapshot().draw(in: a.viewRect) } }
        NSGraphicsContext.restoreGraphicsState()
        let url = URL(fileURLWithPath: dir).appendingPathComponent("M_\(stage.rawValue).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        NSLog("FlyApp: flock snapshot %@ flies=%d crop=%@ sizes=%@", url.lastPathComponent, actors.count,
              NSStringFromRect(r), actors.map { String(format: "%.1f", $0.flySize) }.joined(separator: ","))
    }
}
