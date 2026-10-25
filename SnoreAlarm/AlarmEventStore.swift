import Foundation

/// 振動で知らせた記録 (いつ、どの端末で、自分で止めたか)。一晩の記録のグラフとまとめに出す。
/// 画面のログはアプリを終了すると消えるが、こちらは監視の記録と同じく約 8 日分残す。
enum AlarmEventStore {
    struct Event: Codable, Hashable {
        enum Device: String, Codable {
            /// iPhone 本体の振動 (iPhone で知らせる設定、または Watch に届かないと分かっていたとき)
            case iPhone = "iphone"
            /// Apple Watch への通知
            case watch
            /// Apple Watch への通知と iPhone の振動の両方 (Watch で起きなかったとみなしたとき)
            case both
        }

        var date: Date
        var device: Device
        /// 「振動を止める」などで自分で止めた
        var stopped = false
    }

    static let key = "alarmEvents"
    static let retention = MonitoringSessionStore.retention

    static func load(from defaults: UserDefaults = .standard) -> [Event] {
        guard let data = defaults.data(forKey: key),
              let events = try? JSONDecoder().decode([Event].self, from: data) else {
            return []
        }
        return events
    }

    static func record(_ device: Event.Device, at date: Date = Date(), in defaults: UserDefaults = .standard) {
        var events = load(from: defaults).filter { date.timeIntervalSince($0.date) <= retention }
        events.append(Event(date: date, device: device))
        save(events, to: defaults)
    }

    /// 最後の振動を、自分で止めたことにする
    static func markLastStopped(in defaults: UserDefaults = .standard) {
        var events = load(from: defaults)
        guard let last = events.indices.last else { return }
        events[last].stopped = true
        save(events, to: defaults)
    }

    private static func save(_ events: [Event], to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: key)
        }
    }
}
