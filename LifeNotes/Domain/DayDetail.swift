import Foundation

struct DayDetail: Equatable, Sendable {
    let dayKey: DayKey
    let entries: [Entry]
    let state: DayState
}
