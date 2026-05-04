// BuildInfo.swift
//
// PLACEHOLDER — overwritten on every build by Scripts/generate_build_info.sh.
// This file is committed to the repository so a fresh clone has *something*
// for the compiler to read on the first build (Xcode's
// PBXFileSystemSynchronizedRootGroup determines target membership at build-
// graph construction time, before any Run Script has run).
//
// After cloning the repository, every developer should run once:
//
//     git update-index --skip-worktree GPXEditor/Generated/BuildInfo.swift
//
// to suppress the every-build local-modification noise that would otherwise
// fill `git status`.  This is mentioned in .gitignore for visibility, even
// though the .gitignore rule is technically inert on a tracked file.
//
// See Scripts/generate_build_info.sh for what the regenerated content looks
// like and why we go through this dance.  The values below are placeholders
// that should never appear in a real build — if you see "uninit" in an
// About panel, the Run Script phase isn't wired up.

enum BuildInfo {
    static let timestamp: String = "0000000000"
    static let gitSHA: String = "uninit"
    static let isDirty: Bool = false
    static let configuration: String = "Unknown"

    /// Display string suitable for an About screen, e.g. "2604051847 · a3f9c1e+".
    /// The trailing "+" appears when the working tree had uncommitted changes
    /// at build time — a quick visual cue that the binary doesn't correspond
    /// to a clean commit.
    static var displayString: String {
        let dirtyMarker = isDirty ? "+" : ""
        return "\(timestamp) · \(gitSHA)\(dirtyMarker)"
    }
}
