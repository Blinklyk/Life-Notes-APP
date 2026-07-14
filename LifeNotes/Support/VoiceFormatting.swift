import Foundation

enum VoiceFormatting {
    static func duration(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds) / 1_000
        return String(
            format: "%d:%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            totalSeconds / 60,
            totalSeconds % 60
        )
    }

    static func accessibleDuration(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds) / 1_000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes == 0 {
            return "\(seconds) 秒"
        }
        return "\(minutes) 分 \(seconds) 秒"
    }
}
