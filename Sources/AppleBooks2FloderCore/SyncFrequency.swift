import Foundation

public enum SyncFrequency: Int, CaseIterable {
    case oneMinute = 1, fiveMinutes = 5, fifteenMinutes = 15, thirtyMinutes = 30, hourly = 60

    public static let defaultFrequency = Self.fifteenMinutes
    public var interval: TimeInterval { TimeInterval(rawValue * 60) }

    public var label: String {
        if self == .oneMinute { return message("每 1 分钟", "Every minute") }
        return String(format: message("每 %d 分钟", "Every %d minutes"), rawValue)
    }
}
