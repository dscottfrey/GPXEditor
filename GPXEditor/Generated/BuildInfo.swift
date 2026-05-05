// BuildInfo.swift
// AUTO-GENERATED at build time by Scripts/generate_build_info.sh.
// Do not edit by hand.  After cloning the repository, run once:
//   git update-index --skip-worktree GPXEditor/Generated/BuildInfo.swift
// to suppress local-modification noise from every build.

enum BuildInfo {
    static let timestamp: String = "2605051038"
    static let gitSHA: String = "41141e0"
    static let isDirty: Bool = true
    static let configuration: String = "Debug"

    /// Display string suitable for an About screen, e.g. "2604051847 · a3f9c1e+".
    /// The trailing "+" appears when the working tree had uncommitted changes
    /// at build time — a quick visual cue that the binary doesn't correspond
    /// to a clean commit.
    static var displayString: String {
        let dirtyMarker = isDirty ? "+" : ""
        return "\(timestamp) · \(gitSHA)\(dirtyMarker)"
    }
}
