import Foundation

/// 寝る時刻のお知らせと監視の自動終了の設定。時刻は 0 時からの分で持つ。
/// 開始 (お知らせ) が終了より遅い場合 (23:00〜7:00 など) は日をまたぐ時間帯とみなす。
struct MonitoringSchedule: Equatable {
    var isOn = false
    var startMinutes = 23 * 60
    var endMinutes = 7 * 60
    /// 始め忘れの防止を休む曜日 (`Calendar` の weekday。1 が日曜)。夜の時間帯が始まる日の曜日で見る
    var skipWeekdays: Set<Int> = []
    /// 始め忘れの防止を休む日 (`dayKey` の "yyyy-MM-dd")。夜の時間帯が始まる日で見る
    var skipDays: Set<String> = []
    /// 休み方が「曜日で選ぶ」。そのときだけ `skipWeekdays` を使う (休む日 `skipDays` はどちらでも使う)
    var skipByWeekday = false

    /// 開始と終了が同じ時刻のときは時間帯が決まらないため使わない
    var isEnabled: Bool { isOn && startMinutes != endMinutes }

    /// `nightStart` に始まる夜は、始め忘れの防止 (お知らせ・アラーム・自動で開く・翌朝の知らせ) を休むか
    func isSkipped(nightStart: Date, calendar: Calendar = .current) -> Bool {
        (skipByWeekday && skipWeekdays.contains(calendar.component(.weekday, from: nightStart)))
            || skipDays.contains(Self.dayKey(nightStart, calendar: calendar))
    }

    /// 今夜の夜の時間帯が始まる時刻。夜の時間帯の中ならその始まり、外なら次の始まり
    func tonightStart(at now: Date, calendar: Calendar = .current) -> Date? {
        let window = nightWindow
        if window.contains(now, calendar: calendar) {
            return Self.previous(window.startMinutes, before: now.addingTimeInterval(1), calendar: calendar)
        }
        return window.nextStart(after: now, calendar: calendar)
    }

    /// 日付を "yyyy-MM-dd" にする (休む日の保存に使う)
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// お知らせを繰り返す回数と間隔 (監視を始めるまで)
    static let reminderCount = 4
    static let reminderInterval: TimeInterval = 15 * 60

    /// `date` が開始〜終了の時間帯に入っているか
    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if startMinutes < endMinutes {
            return minutes >= startMinutes && minutes < endMinutes
        }
        return minutes >= startMinutes || minutes < endMinutes
    }

    /// `date` より後で最初の開始時刻
    func nextStart(after date: Date, calendar: Calendar = .current) -> Date? {
        Self.next(startMinutes, after: date, calendar: calendar)
    }

    /// `date` より後で最初の終了時刻
    func nextEnd(after date: Date, calendar: Calendar = .current) -> Date? {
        Self.next(endMinutes, after: date, calendar: calendar)
    }

    /// 寝る時刻のお知らせを出す時刻 (`days` 日分)。毎日、開始時刻から `reminderInterval` おきに `reminderCount` 回。
    /// - Parameter monitoringUntil: 監視中ならその終了時刻。それより前のお知らせは出さない (その夜はもう始めているため)
    func reminderDates(after now: Date, monitoringUntil: Date?, days: Int = 7,
                       calendar: Calendar = .current) -> [Date] {
        guard isEnabled else { return [] }
        var dates: [Date] = []
        // 今夜のお知らせの途中 (23:20 など) でも、残りのお知らせを出せるように少し前から探す
        var after = now.addingTimeInterval(-Self.reminderInterval * Double(Self.reminderCount - 1) - 1)
        for _ in 0..<days {
            guard let start = nextStart(after: after, calendar: calendar) else { break }
            after = start
            if isSkipped(nightStart: start, calendar: calendar) { continue }
            for index in 0..<Self.reminderCount {
                let date = start.addingTimeInterval(Self.reminderInterval * Double(index))
                if date <= now { continue }
                if let monitoringUntil, date < monitoringUntil { continue }
                dates.append(date)
            }
        }
        return dates
    }

    /// 「アラームで知らせる」のアラームを鳴らす時刻 (`days` 日分)。毎日、開始時刻に 1 回。休む夜は鳴らさない。
    /// - Parameter monitoringUntil: 監視中ならその終了時刻。それより前のアラームは鳴らさない (その夜はもう始めているため)
    func alarmDates(after now: Date, monitoringUntil: Date?, days: Int = 7,
                    calendar: Calendar = .current) -> [Date] {
        guard isEnabled else { return [] }
        var dates: [Date] = []
        var after = now
        for _ in 0..<days {
            guard let start = nextStart(after: after, calendar: calendar) else { break }
            after = start
            if isSkipped(nightStart: start, calendar: calendar) { continue }
            if let monitoringUntil, start < monitoringUntil { continue }
            dates.append(start)
        }
        return dates
    }

    // MARK: - ショートカットで監視を自動で始める夜の時間帯

    /// お知らせ・自動終了がオフのときの夜の時間帯 (22:00〜5:00)
    static let defaultNightStartMinutes = 22 * 60
    static let defaultNightEndMinutes = 5 * 60

    /// ショートカットの「監視が必要か調べる」で使う夜の時間帯。お知らせ・自動終了が使えるならその時刻、なければ 22:00〜5:00
    var nightWindow: MonitoringSchedule {
        isEnabled ? self : MonitoringSchedule(isOn: true, startMinutes: Self.defaultNightStartMinutes,
                                              endMinutes: Self.defaultNightEndMinutes)
    }

    /// 監視を始める必要があるか: 夜の時間帯に入っていて、まだ監視しておらず、休む夜でもない
    func needsMonitoring(at date: Date, isMonitoring: Bool, calendar: Calendar = .current) -> Bool {
        guard !isMonitoring, nightWindow.contains(date, calendar: calendar) else { return false }
        if let start = tonightStart(at: date, calendar: calendar), isSkipped(nightStart: start, calendar: calendar) {
            return false
        }
        return true
    }

    /// 「昨夜は監視していませんでした」の知らせを出す時刻 (`days` 日分)。夜の時間帯の終了時刻に出す。
    /// 夜の時間帯 (開始〜終了) に少しでも監視していた夜は出さない。
    /// - Parameters:
    ///   - sessions: これまでの監視 (`MonitoringSessionStore`)
    ///   - isMonitoring: 今監視中なら、終了していない最後の監視は今も続いているものとする
    func missedNightDates(after now: Date, sessions: [MonitoringSessionStore.Session], isMonitoring: Bool,
                          days: Int = 7, calendar: Calendar = .current) -> [Date] {
        let window = nightWindow
        // 今続いている監視は、今夜の終了時刻まで続くものとみなす (止めたら予約し直すので、次の夜からは知らせを出す)
        let ongoingEnd = window.nextEnd(after: now, calendar: calendar) ?? now
        var dates: [Date] = []
        var after = now
        for _ in 0..<days {
            guard let end = window.nextEnd(after: after, calendar: calendar) else { break }
            after = end
            guard let start = Self.previous(window.startMinutes, before: end, calendar: calendar) else { continue }
            if isSkipped(nightStart: start, calendar: calendar) { continue }
            let monitored = sessions.indices.contains { index in
                let session = sessions[index]
                let sessionEnd = session.end
                    ?? (isMonitoring && index == sessions.count - 1 ? ongoingEnd : (session.lastSeen ?? session.start))
                return session.start < end && sessionEnd > start
            }
            if !monitored {
                dates.append(end)
            }
        }
        return dates
    }

    private static func next(_ minutes: Int, after date: Date, calendar: Calendar) -> Date? {
        calendar.nextDate(after: date, matching: DateComponents(hour: minutes / 60, minute: minutes % 60, second: 0),
                          matchingPolicy: .nextTime)
    }

    private static func previous(_ minutes: Int, before date: Date, calendar: Calendar) -> Date? {
        calendar.nextDate(after: date, matching: DateComponents(hour: minutes / 60, minute: minutes % 60, second: 0),
                          matchingPolicy: .nextTime, direction: .backward)
    }

    static func timeText(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}
