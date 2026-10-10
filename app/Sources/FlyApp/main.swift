import AppKit
import FlyCore
import FlyBehavior
import FlyBrain

/// Menu-bar app. Status-item menu: "Dewey" title, Show/Hide Dewey, Size, Restlessness and Friends
/// (0–5) sliders, About, Quit. Settings persist via `SettingsStore` (UserDefaults key "settings", JSON). The fly lives
/// on `OverlayController`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var overlay: OverlayController!
    private var brain: Brain!
    private let store = SettingsStore(defaults: .standard)
    private var settings = DeweySettings()

    /// The connectome-driven brain; falls back to `ScriptedBrain` if `circuit.json` is missing or invalid,
    /// or when `FLY_BRAIN=scripted`.
    static var makeBrain: @MainActor (_ seed: UInt64) -> Brain = { seed in
        if ProcessInfo.processInfo.environment["FLY_BRAIN"] != "scripted", let url = AppResources.url("circuit.json") {
            do {
                let brain = try ConnectomeBrain(url: url, seed: seed)
                NSLog("FlyApp: connectome brain loaded from %@", url.path)
                return brain
            } catch {
                NSLog("FlyApp: connectome brain failed (%@), using scripted brain", String(describing: error))
            }
        }
        return ScriptedBrain(seed: seed)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        let seed = env["FLY_SEED"].flatMap(UInt64.init) ?? UInt64(Date().timeIntervalSince1970)
        let start = env["FLY_START_STATE"].flatMap(FlyState.init(rawValue:)) ?? .flying

        NSLog("FlyApp: resources=%@", AppResources.bundle?.bundlePath ?? "<not found>")

        OverlayController.makeRenderable = {
            if ProcessInfo.processInfo.environment["FLY_PLACEHOLDER"] != "1",
               let dir = AppResources.url(ProcessInfo.processInfo.environment["FLY_MODEL"] == "flybody"
                                          ? "fly/body.json" : "dewey/body.json")?.deletingLastPathComponent() {
                do { return try RigFly(bundleDirectory: dir) } catch {
                    NSLog("FlyApp: fly rig failed (%@), using placeholder", String(describing: error))
                }
            }
            return PlaceholderFly()
        }
        brain = AppDelegate.makeBrain(seed)
        overlay = OverlayController(brain: brain, seed: seed, startState: start)

        if store.migrate(from: UserDefaults(suiteName: SettingsStore.legacyDomain)) {
            NSLog("Dewey: migrated settings from %@", SettingsStore.legacyDomain)
        }
        settings = store.load()
        store.save(settings)  // write back clamped values (and create the key on first launch)
        applySize()
        applyRestlessness()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = makeFlyGlyph()
            button.toolTip = "Dewey — a connectome-driven fruit fly"
        }
        statusItem.menu = buildMenu()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.overlay.screenParametersChanged() }
        }

        // Restore visibility from last time (FLY_AUTORELEASE=1 forces a release).
        if settings.visible || env["FLY_AUTORELEASE"] == "1" { release() } else { updateToggleTitle() }
        applyFriends()
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let title = NSMenuItem(title: "Dewey", action: nil, keyEquivalent: "")
        title.attributedTitle = NSAttributedString(string: "Dewey",
                                                   attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
        title.isEnabled = false
        menu.addItem(title)

        toggleItem = NSMenuItem(title: "Show Dewey", action: #selector(toggleFly), keyEquivalent: "d")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        let size = MenuSliderView(title: "Size", min: DeweySettings.sizeRange.lowerBound,
                                  max: DeweySettings.sizeRange.upperBound, value: settings.size,
                                  minLabel: "Small", maxLabel: "Large") { [weak self] v in
            guard let self else { return }
            self.settings.size = v
            self.applySize()
            self.store.save(self.settings)
        }
        menu.addItem(MenuSliderView.item(size))

        let rest = MenuSliderView(title: "Restlessness", min: 0, max: 1, value: settings.restlessness,
                                  minLabel: "Calm", maxLabel: "Restless") { [weak self] v in
            guard let self else { return }
            self.settings.restlessness = v
            self.applyRestlessness()
            self.store.save(self.settings)
        }
        menu.addItem(MenuSliderView.item(rest))

        let lo = DeweySettings.friendsRange.lowerBound, hi = DeweySettings.friendsRange.upperBound
        let friends = MenuSliderView(title: "Friends", min: Double(lo), max: Double(hi),
                                     value: Double(settings.friends), minLabel: "Alone", maxLabel: "\(hi) friends",
                                     tickMarks: hi - lo + 1,
                                     valueText: { v in AppDelegate.friendsText(Int(v.rounded())) }) { [weak self] v in
            guard let self else { return }
            let n = min(max(Int(v.rounded()), lo), hi)
            guard n != self.settings.friends else { return }
            self.settings.friends = n
            self.store.save(self.settings)
            self.applyFriends()
        }
        menu.addItem(MenuSliderView.item(friends))

        menu.addItem(.separator())
        let about = NSMenuItem(title: "About Dewey", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(NSMenuItem(title: "Quit Dewey", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    private func applySize() { overlay.setFlySize(settings.size) }

    private func applyRestlessness() { applySettingsToAll() }

    /// Restlessness (rest bout on every brain, flight bout on every controller) for Dewey and all friends.
    /// Called on launch, on Restlessness changes, and after friends are added.
    func applySettingsToAll() {
        let brains: [Brain] = [brain] + overlay.friendBrains
        for b in brains { (b as? RestlessnessTunable)?.setRestBout(settings.restBout) }
        for c in overlay.allControllers { c.flightBoutRange = settings.flightBout }
    }

    private func applyFriends() {
        overlay.setFriends(settings.friends)
        applySettingsToAll()
        NSLog("Dewey: friends=%d", settings.friends)
    }

    static func friendsText(_ n: Int) -> String {
        switch n { case 0: "Alone"; case 1: "1 friend"; default: "\(n) friends" }
    }

    private func updateToggleTitle() {
        toggleItem?.title = overlay.isShowing ? "Hide Dewey" : "Show Dewey"
    }

    @objc private func toggleFly() {
        if overlay.isShowing { catchFly() } else { release() }
        settings.visible = overlay.isShowing
        store.save(settings)
    }

    private func release() {
        overlay.show()
        updateToggleTitle()
        NSLog("FlyApp: released, level=%d dock=%@", overlayWindowLevel.rawValue, overlay.controller.world.dock.rawValue)
    }

    private func catchFly() {
        overlay.hide()
        updateToggleTitle()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Dewey"
        alert.informativeText = """
        A fruit fly for your desktop, driven by a rate network built from the fruit-fly connectome.

        Connectome: FlyEM male CNS connectome (Berg et al. 2025, bioRxiv 10.1101/2025.10.09.680999), CC-BY 4.0.
        Body model: flybody (TuragaLab), Apache-2.0.
        """
        alert.icon = makeFlyGlyph(size: 64)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
