import Foundation

/// Shared time formatting utility used across the app
enum TimeFormatting {
    /// Format seconds into a human-readable time string (e.g., "1:23:45" or "3:21")
    static func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && seconds.isFinite else { return "0:00" }
        let total = Int(max(0, seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
