import Foundation

enum Sensitivity: String, CaseIterable, Identifiable {
    case high, medium, low

    var id: String { rawValue }

    var label: String {
        switch self {
        case .high: "高 (小さないびきも検知)"
        case .medium: "中"
        case .low: "低 (大きないびきのみ)"
        }
    }

    var marginDB: Float {
        switch self {
        case .high: 8
        case .medium: 12
        case .low: 18
        }
    }
}

/// ユーザー設定。`SettingsView` の `@AppStorage` と同じキーで UserDefaults に保存される。
struct AlarmSettings {
    enum Key {
        static let sensitivity = "sensitivity"
        static let requiredSnores = "requiredSnores"
        static let windowSeconds = "windowSeconds"
        static let vibrationSeconds = "vibrationSeconds"
        static let startDelayMinutes = "startDelayMinutes"
        static let recordSnores = "recordSnores"
        static let scheduleEnabled = "scheduleEnabled"
        static let scheduleStartMinutes = "scheduleStartMinutes"
        static let scheduleEndMinutes = "scheduleEndMinutes"
        /// 一晩の記録の区切り (0 時からの分)。グラフの表示にだけ使う
        static let dayBoundaryMinutes = "dayBoundaryMinutes"
        /// いびきを知らせる端末 (`AlertDevice`)。監視中でも次のアラームから反映する
        static let alertDevice = "alertDevice"
        /// Watch で知らせたあともいびきが続いたら iPhone も振動させる
        static let watchFallback = "watchFallback"
        /// 初回の案内 (知らせる端末の選択) を終えた
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        /// ショートカットの「監視が必要か調べる」が最後に動いた日時。あれば、オートメーションを設定したとみなして
        /// 「昨夜は監視していませんでした」の知らせを出す
        static let automationCheckedAt = "automationCheckedAt"
        /// 始め忘れの防止で「アプリを自動で開く」を選んだ。オフのときは、ショートカットの「必要なら監視を開始」などが
        /// 呼ばれても監視を始めない (オートメーションを消し忘れても、勝手に開かないように)
        static let autoOpenEnabled = "autoOpenEnabled"
        /// 始め忘れの防止で「アラームで知らせる」を選んだ (iOS 26 から)。お知らせの時刻に、通知の代わりに目覚ましのアラームを鳴らす
        static let bedtimeAlarmEnabled = "bedtimeAlarmEnabled"
        /// 始め忘れの防止を休む曜日 (カンマ区切りの weekday。1 が日曜)
        static let skipWeekdays = "skipWeekdays"
        /// 始め忘れの防止を休む日 (カンマ区切りの "yyyy-MM-dd")。「今夜は知らせない」もここに入れる
        static let skipDays = "skipDays"
        /// 休み方 (`SkipMode`)。日付で選ぶか、曜日で選ぶか
        static let skipMode = "skipMode"
    }

    /// 始め忘れの防止の休み方
    enum SkipMode: String, CaseIterable, Identifiable {
        /// 日付で選ぶ (`skipDays`)
        case days
        /// 曜日で選ぶ (`skipWeekdays`)。毎週くり返す
        case weekdays

        var id: String { rawValue }

        var label: String {
            switch self {
            case .days: "日付で選ぶ"
            case .weekdays: "曜日で選ぶ"
            }
        }
    }

    static func parseWeekdays(_ text: String) -> Set<Int> {
        Set(text.split(separator: ",").compactMap { Int($0) }.filter { (1...7).contains($0) })
    }

    static func parseDays(_ text: String) -> Set<String> {
        Set(text.split(separator: ",").map(String.init))
    }

    static func joined(_ weekdays: Set<Int>) -> String {
        weekdays.sorted().map(String.init).joined(separator: ",")
    }

    static func joined(_ days: Set<String>) -> String {
        days.sorted().joined(separator: ",")
    }

    /// 休む日から、昨日より前の日を除く (今夜が日付をまたいでいても、昨日の分は残す)
    static func prunedDays(_ days: Set<String>, now: Date = Date(), calendar: Calendar = .current) -> Set<String> {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let limit = MonitoringSchedule.dayKey(yesterday, calendar: calendar)
        return days.filter { $0 >= limit }
    }

    /// 「アプリを自動で開く」を選んでいるか。まだ選んだことがなければ、この設定ができる前にオートメーションを作っていた人
    /// (「監視が必要か調べる」が一度でも動いた人) を、選んでいるものとみなす
    static func autoOpenEnabled(in defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: Key.autoOpenEnabled) != nil {
            return defaults.bool(forKey: Key.autoOpenEnabled)
        }
        return defaults.object(forKey: Key.automationCheckedAt) != nil
    }

    enum Default {
        static let sensitivity = Sensitivity.medium
        static let requiredSnores = 4
        static let windowSeconds = 60
        static let vibrationSeconds = 10
        static let startDelayMinutes = 0
        static let recordSnores = true
        static let scheduleEnabled = false
        static let scheduleStartMinutes = 23 * 60
        static let scheduleEndMinutes = 7 * 60
        static let dayBoundaryMinutes = 12 * 60
        static let alertDevice = AlertDevice.iPhone
        static let watchFallback = true
    }

    var sensitivity = Default.sensitivity
    var requiredSnores = Default.requiredSnores
    var windowSeconds = Default.windowSeconds
    var vibrationSeconds = Default.vibrationSeconds
    var startDelayMinutes = Default.startDelayMinutes
    var recordSnores = Default.recordSnores
    var alertDevice = Default.alertDevice
    var watchFallback = Default.watchFallback
    var schedule = MonitoringSchedule(isOn: Default.scheduleEnabled,
                                      startMinutes: Default.scheduleStartMinutes,
                                      endMinutes: Default.scheduleEndMinutes)

    static func load(from defaults: UserDefaults = .standard) -> AlarmSettings {
        var settings = AlarmSettings()
        if let raw = defaults.string(forKey: Key.sensitivity), let value = Sensitivity(rawValue: raw) {
            settings.sensitivity = value
        }
        if defaults.object(forKey: Key.requiredSnores) != nil {
            settings.requiredSnores = defaults.integer(forKey: Key.requiredSnores)
        }
        if defaults.object(forKey: Key.windowSeconds) != nil {
            settings.windowSeconds = defaults.integer(forKey: Key.windowSeconds)
        }
        if defaults.object(forKey: Key.vibrationSeconds) != nil {
            settings.vibrationSeconds = defaults.integer(forKey: Key.vibrationSeconds)
        }
        if defaults.object(forKey: Key.startDelayMinutes) != nil {
            settings.startDelayMinutes = defaults.integer(forKey: Key.startDelayMinutes)
        }
        if defaults.object(forKey: Key.recordSnores) != nil {
            settings.recordSnores = defaults.bool(forKey: Key.recordSnores)
        }
        if let raw = defaults.string(forKey: Key.alertDevice), let value = AlertDevice(rawValue: raw) {
            settings.alertDevice = value
        }
        if defaults.object(forKey: Key.watchFallback) != nil {
            settings.watchFallback = defaults.bool(forKey: Key.watchFallback)
        }
        if defaults.object(forKey: Key.scheduleEnabled) != nil {
            settings.schedule.isOn = defaults.bool(forKey: Key.scheduleEnabled)
        }
        if defaults.object(forKey: Key.scheduleStartMinutes) != nil {
            settings.schedule.startMinutes = defaults.integer(forKey: Key.scheduleStartMinutes)
        }
        if defaults.object(forKey: Key.scheduleEndMinutes) != nil {
            settings.schedule.endMinutes = defaults.integer(forKey: Key.scheduleEndMinutes)
        }
        settings.schedule.skipWeekdays = parseWeekdays(defaults.string(forKey: Key.skipWeekdays) ?? "")
        settings.schedule.skipDays = parseDays(defaults.string(forKey: Key.skipDays) ?? "")
        settings.schedule.skipByWeekday = defaults.string(forKey: Key.skipMode) == SkipMode.weekdays.rawValue
        return settings
    }

    var detectorConfig: SnoreDetectorConfig {
        var config = SnoreDetectorConfig()
        config.marginDB = sensitivity.marginDB
        config.requiredSnores = requiredSnores
        config.windowSeconds = TimeInterval(windowSeconds)
        return config
    }
}
