import Foundation
import Combine

/// Live "N waiting for iCloud download (5:00)" text for the dropdown. Kept in its own small
/// observable so the once-a-second countdown only refreshes that status line.
@MainActor
final class CloudCountdown: ObservableObject {
    @Published private(set) var text: String?

    func update(count: Int, suffix: String) {
        let t: String? = count > 0 ? "\(count) waiting for iCloud download (\(suffix))" : nil
        if t != text { text = t }                  // @Published fires even for equal values; avoid that
    }

    /// 5:00, 59:59, 1:05:00
    static func format(_ seconds: Int) -> String {
        let s = max(seconds, 0)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
