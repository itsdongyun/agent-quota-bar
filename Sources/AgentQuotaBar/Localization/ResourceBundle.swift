import Foundation

extension Bundle {
    /// The app's SwiftPM resource bundle. The generated `Bundle.module` only looks next to the executable
    /// (the `.app` root when packaged) and at this machine's absolute `.build` path, and calls `fatalError`
    /// otherwise. `scripts/bundle-app.sh` puts the bundle in `Contents/Resources`, so look there first.
    static let appResources: Bundle = {
        let bundleName = "agent-quota-bar_AgentQuotaBar.bundle"
        let candidates = [Bundle.main.resourceURL, Bundle.main.bundleURL]
            .compactMap { $0?.appendingPathComponent(bundleName) }
        for url in candidates {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return Bundle.module
    }()
}
