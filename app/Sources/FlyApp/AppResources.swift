import Foundation

/// Locates the SwiftPM resource bundle (`ConnectomeFly_FlyApp.bundle`).
///
/// SwiftPM's generated `Bundle.module` only looks next to `Bundle.main.bundleURL` (i.e. the `.app` root,
/// which codesign rejects) or at a hard-coded build path, so inside `FlyApp.app` we look in
/// `Contents/Resources` first. Use this instead of `Bundle.module`.
enum AppResources {
    static let bundleName = "ConnectomeFly_FlyApp.bundle"

    static let bundle: Bundle? = {
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent(bundleName)) }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(bundleName))
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            candidates.append(exe.appendingPathComponent(bundleName))
        }
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let b = Bundle(url: url) { return b }
        }
        return nil
    }()

    /// URL of a file copied from `Sources/FlyApp/Resources/`, e.g. `url("circuit.json")` or `url("fly/body.json")`.
    static func url(_ relativePath: String) -> URL? {
        guard let base = bundle?.bundleURL else { return nil }
        for prefix in ["Resources/", "Contents/Resources/Resources/", ""] {
            let u = base.appendingPathComponent(prefix + relativePath)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
}
