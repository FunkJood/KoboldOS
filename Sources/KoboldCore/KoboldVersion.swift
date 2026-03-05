/// Single source of truth for the KoboldOS version string.
/// Update ONLY here — all other code references `KoboldVersion.current`.
public enum KoboldVersion {
    public static let current = "0.3.81"
    public static let label   = "Alpha v\(current)"
}
