import Foundation

/// 寝る時刻のお知らせと監視の自動終了の設定。時刻は 0 時からの分で持つ。
/// 開始 (お知らせ) が終了より遅い場合 (23:00〜7:00 など) は日をまたぐ時間帯とみなす。
struct MonitoringSchedule: Equatable {
    var isOn = false
    var startMinutes = 23 * 60
    var endMinutes = 7 * 60

    /// 開始と終了が同じ時刻のときは時間帯が決まらないため使わない
    var isEnabled: Bool { isOn && startMinutes != endMinutes }

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
            for index in 0..<Self.reminderCount {
                let date = start.addingTimeInterval(Self.reminderInterval * Double(index))
                if date <= now { continue }
                if let monitoringUntil, date < monitoringUntil { continue }
                dates.append(date)
            }
        }
        return dates
    }

    private static func next(_ minutes: Int, after date: Date, calendar: Calendar) -> Date? {
        calendar.nextDate(after: date, matching: DateComponents(hour: minutes / 60, minute: minutes % 60, second: 0),
                          matchingPolicy: .nextTime)
    }

    static func timeText(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}
