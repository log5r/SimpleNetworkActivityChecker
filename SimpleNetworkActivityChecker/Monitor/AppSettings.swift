import Foundation

/// UserDefaults のキーと既定値。
enum AppSettings {
    static let checkIntervalKey = "checkInterval"
    static let retentionDaysKey = "retentionDays"
    static let notificationsEnabledKey = "notificationsEnabled"
    static let showDockIconWhenClosedKey = "showDockIconWhenClosed"

    static let defaultCheckInterval: TimeInterval = 60
    static let defaultRetentionDays = 90
    /// 障害中は復旧時刻を正確に捉えるため短い間隔で確認する
    static let offlineCheckInterval: TimeInterval = 10

    static let checkIntervalOptions: [(TimeInterval, String)] = [
        (15, "15 秒"), (30, "30 秒"), (60, "1 分"), (120, "2 分"), (300, "5 分"), (600, "10 分"),
    ]

    static let retentionOptions: [(Int, String)] = [
        (7, "7 日間"), (30, "30 日間"), (90, "90 日間"), (365, "1 年間"), (0, "無期限"),
    ]

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            checkIntervalKey: defaultCheckInterval,
            retentionDaysKey: defaultRetentionDays,
            notificationsEnabledKey: true,
            showDockIconWhenClosedKey: false,
        ])
    }

    static var checkInterval: TimeInterval {
        let value = UserDefaults.standard.double(forKey: checkIntervalKey)
        return value >= 5 ? value : defaultCheckInterval
    }

    static var retentionDays: Int { UserDefaults.standard.integer(forKey: retentionDaysKey) }
    static var notificationsEnabled: Bool { UserDefaults.standard.bool(forKey: notificationsEnabledKey) }
    static var showDockIconWhenClosed: Bool { UserDefaults.standard.bool(forKey: showDockIconWhenClosedKey) }
}

nonisolated extension TimeInterval {
    /// 「1時間 5分 3秒」のような読みやすい表記。
    var durationText: String {
        let seconds = max(0, self.rounded())
        if seconds < 1 { return "0秒" }
        return Duration.seconds(seconds).formatted(.units(allowed: [.days, .hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 3))
    }
}
