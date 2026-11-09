import Foundation

/// 監視中に、いびきを数えるのを休止した時間帯 (iPhone を手に持って使っていたとき) の記録。
/// 休止中も音は録音しているので、一晩の記録のグラフに帯で出し、いびきを見逃していないかを確かめられるようにする。
/// 監視の記録と同じく約 8 日分残す。
enum PauseStore {
    struct Pause: Codable, Hashable {
        var start: Date
        /// 休止を終えた時刻。休止中、またはアプリが終了して記録できなかった場合は nil
        var end: Date?
    }

    static let key = "pauses"
    static let retention = MonitoringSessionStore.retention

    static func load(from defaults: UserDefaults = .standard) -> [Pause] {
        guard let data = defaults.data(forKey: key),
              let pauses = try? JSONDecoder().decode([Pause].self, from: data) else {
            return []
        }
        return pauses
    }

    static func begin(at date: Date = Date(), in defaults: UserDefaults = .standard) {
        var pauses = load(from: defaults).filter { date.timeIntervalSince($0.start) <= retention }
        if let last = pauses.indices.last, pauses[last].end == nil {
            pauses[last].end = max(date, pauses[last].start)
        }
        pauses.append(Pause(start: date))
        save(pauses, to: defaults)
    }

    static func end(at date: Date = Date(), in defaults: UserDefaults = .standard) {
        var pauses = load(from: defaults)
        guard let last = pauses.indices.last, pauses[last].end == nil else { return }
        pauses[last].end = max(date, pauses[last].start)
        save(pauses, to: defaults)
    }

    private static func save(_ pauses: [Pause], to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(pauses) {
            defaults.set(data, forKey: key)
        }
    }
}
