import Foundation

/// 一晩分のいびきの記録。1日の区切り (初期値 12:00) から翌日の区切りの前までに始めた監視を一晩とし、
/// その間の最初の開始から最後の終了までをまとめる。途中で監視を止めて再開しても同じ夜として扱う。
/// 区切りを変えれば、昼に眠る生活にも合わせられる。
struct NightRecord: Identifiable {
    struct Period: Hashable {
        let start: Date
        let end: Date
    }

    /// この夜の区切りの時刻 (ここから翌日の同じ時刻の前まで)
    let dayStart: Date
    /// 監視していた時間帯 (古い順)
    let periods: [Period]
    /// 録音したいびき (古い順)
    let recordings: [RecordingStore.Recording]
    /// 振動で知らせた記録 (古い順)
    let alarms: [AlarmEventStore.Event]
    /// グラフに表示する範囲 (最初の監視の開始から最後の監視の終了まで)
    let start: Date
    let end: Date

    var id: Date { dayStart }

    /// 監視した時間帯の記録がある (監視の記録を始める前の版で録音した夜にはない)
    var hasMonitoringRecord: Bool { !periods.isEmpty }

    /// 監視していた時間の合計
    var monitoredDuration: TimeInterval {
        periods.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }

    /// 録音したいびきの合計の長さ
    var snoreDuration: TimeInterval {
        recordings.reduce(0) { $0 + $1.duration }
    }

    /// `date` を含む夜の区切りの時刻
    static func dayStart(containing date: Date, boundaryMinutes: Int, calendar: Calendar = .current) -> Date {
        let minutes = min(max(boundaryMinutes, 0), 24 * 60 - 1)
        guard let boundary = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: date) else {
            return calendar.startOfDay(for: date)
        }
        if boundary <= date {
            return boundary
        }
        return calendar.date(byAdding: .day, value: -1, to: boundary) ?? boundary
    }

    /// 監視の記録・録音・振動を一晩ごとにまとめる (新しい夜が先)。
    /// - Parameter isMonitoring: 今監視中なら、終了していない最後の監視は今まで続いているものとする
    static func nights(sessions: [MonitoringSessionStore.Session], recordings: [RecordingStore.Recording],
                       alarms: [AlarmEventStore.Event] = [], boundaryMinutes: Int, isMonitoring: Bool,
                       now: Date = Date(), calendar: Calendar = .current) -> [NightRecord] {
        let sessions = sessions.sorted { $0.start < $1.start }
        let recordings = recordings.sorted { $0.date < $1.date }
        let alarms = alarms.sorted { $0.date < $1.date }

        var periods: [Period] = []
        for (index, session) in sessions.enumerated() {
            let next = index + 1 < sessions.count ? sessions[index + 1].start : now
            let end: Date
            if let sessionEnd = session.end {
                end = sessionEnd
            } else if isMonitoring && index == sessions.count - 1 {
                end = now
            } else {
                // アプリが終了して終了時刻を記録できなかった: 最後に動いていた時刻か、その監視の最後の録音までとする
                let lastRecording = recordings.last { $0.date >= session.start && $0.date <= next }?.date
                end = [session.lastSeen, lastRecording].compactMap { $0 }.filter { $0 <= next }.max() ?? session.start
            }
            periods.append(Period(start: session.start, end: max(end, session.start)))
        }

        struct Group {
            var periods: [Period] = []
            var recordings: [RecordingStore.Recording] = []
            var alarms: [AlarmEventStore.Event] = []
        }
        var groups: [Date: Group] = [:]
        for period in periods {
            groups[dayStart(containing: period.start, boundaryMinutes: boundaryMinutes, calendar: calendar),
                   default: Group()].periods.append(period)
        }
        for recording in recordings {
            // 録音はいびきの直後に保存するので、監視の終了時刻を少し過ぎることがある
            let owner = periods.last { $0.start <= recording.date && recording.date <= $0.end.addingTimeInterval(60) }
            groups[dayStart(containing: owner?.start ?? recording.date, boundaryMinutes: boundaryMinutes, calendar: calendar),
                   default: Group()].recordings.append(recording)
        }
        for alarm in alarms {
            let owner = periods.last { $0.start <= alarm.date && alarm.date <= $0.end.addingTimeInterval(60) }
            groups[dayStart(containing: owner?.start ?? alarm.date, boundaryMinutes: boundaryMinutes, calendar: calendar),
                   default: Group()].alarms.append(alarm)
        }

        return groups.compactMap { dayStart, group in
            let starts = group.periods.map(\.start) + group.recordings.map { $0.date.addingTimeInterval(-$0.duration) }
                + group.alarms.map(\.date)
            let ends = group.periods.map(\.end) + group.recordings.map(\.date) + group.alarms.map(\.date)
            guard let start = starts.min(), var end = ends.max() else { return nil }
            // 短すぎるとグラフの横軸が細かくなりすぎるため、最低 10 分の幅にする
            end = max(end, start.addingTimeInterval(10 * 60))
            return NightRecord(dayStart: dayStart, periods: group.periods, recordings: group.recordings,
                               alarms: group.alarms, start: start, end: end)
        }
        .sorted { $0.dayStart > $1.dayStart }
    }
}
