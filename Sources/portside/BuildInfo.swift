// GENERATED FILE. Do not edit by hand.
// Written by scripts/gen-version.sh from VERSION and git state.
// The version number is edited only in VERSION at the repo root.

enum BuildInfo {
    /// Marketing version from VERSION.
    static let version = "1.2.0"
    /// Short hash of HEAD when this file was generated, or "unknown".
    static let commit = "ae50dfc"
    /// Uncommitted changes when generated. nil if git was unavailable.
    static let isDirty: Bool? = true
    /// True for a tagged release build (see scripts/gen-version.sh).
    static let isRelease = true
}
