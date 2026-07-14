import Foundation

enum DailyFeeling: Int, Codable, CaseIterable, Hashable, Sendable {
    case veryLow = 1
    case low = 2
    case calm = 3
    case happy = 4
    case veryHappy = 5

    var level: Int { rawValue }

    var label: String {
        switch self {
        case .veryLow:
            return "很低落"
        case .low:
            return "低落"
        case .calm:
            return "平静"
        case .happy:
            return "开心"
        case .veryHappy:
            return "很开心"
        }
    }
}
