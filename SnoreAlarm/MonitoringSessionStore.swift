import Foundation

/// 監視した時間帯 (開始・終了の時刻) の記録。一晩のいびきのグラフで、監視していた範囲を示すのに使う。
/// 画面のログはアプリを終了すると消えるが、こちらは録音と同じく約 1 週間残す。
enum MonitoringSessionStore {
    struct Session: Codable, Hashable {
        var start: Date
        /// 監視を終えた時刻。監視中、またはアプリが終了して記録できなかった場合は nil
        var end: Date?
        /// 監視中に最後に動いていた時刻 (数分ごとに更新)。アプリが終了して終了時刻を記録できなかったときに使う
        var lastSeen: Date?
    }

    static let key = "monitoringSessions"
    /// 録音より 1 日長く残す (一晩の区切りをまたぐ監視のため)
    static let retention = RecordingStore.retention + 24 * 60 * 60
    /// 監視中に `lastSeen` を更新する間隔
    static let heartbeatInterval: TimeInterval = 5 * 60

    static func load(from defaults: UserDefaults = .standard) -> [Session] {
        guard let data = defaults.data(forKey: key),
              let sessions = try? JSONDecoder().decode([Session].self, from: data) else {
            return []
        }
        return sessions
    }

    static func begin(at date: Date = Date(), in defaults: UserDefaults = .standard) {
        var sessions = load(from: defaults).filter { date.timeIntervalSince($0.start) <= retention }
        sessions.append(Session(start: date, lastSeen: date))
        save(sessions, to: defaults)
    }

    /// 監視中であることを記録する (終了時刻を記録できずにアプリが終了しても、ここまでは監視していたと分かる)
    static func touch(at date: Date = Date(), in defaults: UserDefaults = .standard) {
        var sessions = load(from: defaults)
        guard let last = sessions.indices.last, sessions[last].end == nil else { return }
        sessions[last].lastSeen = max(date, sessions[last].start)
        save(sessions, to: defaults)
    }

    static func end(at date: Date = Date(), in defaults: UserDefaults = .standard) {
        var sessions = load(from: defaults)
        guard let last = sessions.indices.last, sessions[last].end == nil else { return }
        sessions[last].end = max(date, sessions[last].start)
        save(sessions, to: defaults)
    }

    private static func save(_ sessions: [Session], to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(sessions) {
            defaults.set(data, forKey: key)
        }
    }
}
