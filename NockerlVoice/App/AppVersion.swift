import Foundation

/// The running build's identity, read from the bundle at launch.
///
/// `CFBundleShortVersionString` is the marketing version (bumped by hand in `project.yml`);
/// `CFBundleVersion` and `GitCommit` are stamped per build by `scripts/build-and-install.sh`
/// from git, so two builds of the same marketing version are still distinguishable, which
/// is the whole point of showing it.
enum AppVersion {

    /// Marketing version, e.g. "1.2.0".
    static var short: String { string("CFBundleShortVersionString") ?? "?" }

    /// Build number: the repo's commit count at build time, so it always increases.
    static var build: String { string("CFBundleVersion") ?? "?" }

    /// Short commit the build came from, with a trailing "+" when the tree had
    /// uncommitted changes. Nil for a plain `xcodebuild` that skipped the script.
    static var commit: String? {
        guard let value = string("GitCommit"), !value.isEmpty, value != "dev" else { return nil }
        return value
    }

    /// What the UI shows: "1.2.0 (147)", or "1.2.0 (147) · a1b2c3d" when the git stamp
    /// is present.
    static var display: String {
        let base = "\(short) (\(build))"
        guard let commit else { return base }
        return "\(base) · \(commit)"
    }

    private static func string(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
