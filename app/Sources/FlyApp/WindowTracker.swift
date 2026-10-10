import AppKit
import FlyCore
import FlyBehavior

/// v5: polls the normal application windows (~4 Hz) with `CGWindowListCopyWindowInfo`. Only bounds, layer,
/// alpha, owner PID and window number are read (no titles, no pixels), which needs no Screen Recording
/// permission. Windows are layer 0, on screen, not Dewey's own, not fully transparent and not tiny; frames
/// are converted from CG global coordinates (top-left origin of the primary screen, y down) to AppKit
/// global points. The list is front to back, as CGWindowList returns it.
///
/// Change detection is by window id against the last applied list: a frame delta > `moveThreshold` on any
/// of x, y, width, height is a move/resize (so slow drags accumulate until they cross it), a missing id is
/// a removal; new ids and z-order changes also re-apply the list (they change occlusion) with empty sets.
///
/// `FLY_FAKE_WINDOWS="x,y,w,h;..."` (AppKit global points, front to back, ids 1, 2, …) replaces the real
/// list (debug / layout diagrams).
@MainActor
final class WindowTracker {
    struct Change {
        var windows: [WindowInfo]
        var moved: Set<Int>
        var removed: Set<Int>
    }

    static let pollInterval: TimeInterval = 0.25
    static let moveThreshold: CGFloat = 2
    /// Windows smaller than this in either dimension (tool tips, drag images, …) are skipped.
    static let tinySize: CGFloat = 40

    /// Called on the main thread after the list changed.
    var onChange: ((Change) -> Void)?
    /// The last applied list.
    private(set) var windows: [WindowInfo] = []
    private var timer: Timer?
    private let fake: [WindowInfo]?

    init(env: [String: String] = ProcessInfo.processInfo.environment) {
        fake = WindowTracker.fakeWindows(env)
        if let fake { NSLog("Dewey: FLY_FAKE_WINDOWS: %d window(s)", fake.count) }
    }

    var usingFakeWindows: Bool { fake != nil }

    func start() {
        poll()
        guard timer == nil, fake == nil else { return }
        let t = Timer(timeInterval: WindowTracker.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        let list = fake ?? WindowTracker.readWindows()
        guard let change = WindowTracker.diff(old: windows, new: list) else { return }
        windows = list
        onChange?(change)
    }

    /// nil when nothing changed beyond the move threshold (same ids, same order).
    static func diff(old: [WindowInfo], new: [WindowInfo]) -> Change? {
        let oldByID = Dictionary(old.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        let newIDs = Set(new.map(\.id))
        var moved = Set<Int>()
        for w in new {
            guard let f = oldByID[w.id] else { continue }
            if abs(f.minX - w.frame.minX) > moveThreshold || abs(f.minY - w.frame.minY) > moveThreshold
                || abs(f.width - w.frame.width) > moveThreshold || abs(f.height - w.frame.height) > moveThreshold {
                moved.insert(w.id)
            }
        }
        let removed = Set(old.map(\.id)).subtracting(newIDs)
        let sameOrder = old.map(\.id) == new.map(\.id)
        if moved.isEmpty, removed.isEmpty, sameOrder { return nil }
        return Change(windows: new, moved: moved, removed: removed)
    }

    /// The on-screen normal windows of other processes, front to back, in AppKit global points.
    static func readWindows() -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var out: [WindowInfo] = []
        for d in raw {
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let pid = (d[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                  let num = (d[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let bd = d[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
            if let alpha = (d[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0.01 { continue }
            guard cg.width >= tinySize, cg.height >= tinySize else { continue }
            let frame = CGRect(x: cg.minX, y: primaryHeight - cg.minY - cg.height, width: cg.width, height: cg.height)
            out.append(WindowInfo(id: num, frame: frame, ownerPID: pid))
        }
        return out
    }

    /// Parsed `FLY_FAKE_WINDOWS`, or nil when unset or malformed.
    static func fakeWindows(_ env: [String: String]) -> [WindowInfo]? {
        guard let spec = env["FLY_FAKE_WINDOWS"], !spec.isEmpty else { return nil }
        var out: [WindowInfo] = []
        for (i, part) in spec.split(separator: ";").enumerated() {
            let v = part.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard v.count == 4 else {
                NSLog("Dewey: FLY_FAKE_WINDOWS entry %d malformed (%@), ignoring the override", i, String(part))
                return nil
            }
            out.append(WindowInfo(id: i + 1, frame: CGRect(x: v[0], y: v[1], width: v[2], height: v[3])))
        }
        return out
    }
}
