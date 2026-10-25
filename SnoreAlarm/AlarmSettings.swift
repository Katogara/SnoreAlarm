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
