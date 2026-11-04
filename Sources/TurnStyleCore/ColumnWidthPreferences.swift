import Foundation

/// Treat persisted preferences as untrusted input before indexing or laying out cells.
public enum ColumnWidthPreferences {
    public static let defaults: [Double] = [420, 122, 80, 136, 130, 120, 106]

    public static func load(_ saved: [Double]?) -> [Double] {
        guard let saved, saved.count == defaults.count else { return defaults }
        return zip(saved, defaults).map { value, fallback in
            value.isFinite && value >= 65 && value <= 1400 ? value : fallback
        }
    }
}
