import SwiftUI

/// メイン画面のいちばん上に出す、アラームの日付の帯。始め忘れの防止で「アラームで知らせる」を選んでいるときだけ出す。
/// - 休み方が「日付で選ぶ」: 今日を左端に 1 週間分を並べ、左へスクロールすると `dayCount` 日先まで見える。
///   押した日のアラームを止める (休む日 `skipDays` に入れる)
/// - 休み方が「曜日で選ぶ」: 今日の曜日を左端に 7 つの曜日を並べる (スクロールなし)。
///   押した曜日のアラームを毎週止める (休む曜日 `skipWeekdays` に入れる)
/// それぞれの下にアラームの時刻を小さく出し、止めた日はグレーにして時刻に線を引く
struct AlarmStripSection: View {
    @Environment(SnoreMonitor.self) private var monitor
    @Environment(\.calendar) private var calendar
    @AppStorage(AlarmSettings.Key.scheduleEnabled) private var scheduleEnabled = AlarmSettings.Default.scheduleEnabled
    @AppStorage(AlarmSettings.Key.scheduleStartMinutes) private var startMinutes = AlarmSettings.Default.scheduleStartMinutes
    @AppStorage(AlarmSettings.Key.scheduleEndMinutes) private var endMinutes = AlarmSettings.Default.scheduleEndMinutes
    @AppStorage(AlarmSettings.Key.autoOpenEnabled) private var autoOpenEnabled = false
    @AppStorage(AlarmSettings.Key.bedtimeAlarmEnabled) private var bedtimeAlarmEnabled = false
    @AppStorage(AlarmSettings.Key.skipWeekdays) private var skipWeekdays = ""
    @AppStorage(AlarmSettings.Key.skipDays) private var skipDays = ""
    @AppStorage(AlarmSettings.Key.skipMode) private var skipMode = AlarmSettings.SkipMode.days.rawValue

    /// 日付で選ぶときに並べる日数
    static let dayCount = 60
    /// 曜日の短い名前 (日本語なら「日」「月」、英語なら「Sun」「Mon」)。日曜から
    static var weekdaySymbols: [String] { Calendar.current.shortStandaloneWeekdaySymbols }
    /// 曜日の名前 (日本語なら「日曜日」、英語なら「Sunday」)。読み上げに使う
    static var weekdayNames: [String] { Calendar.current.standaloneWeekdaySymbols }

    private var isShown: Bool {
        scheduleEnabled && bedtimeAlarmEnabled && !autoOpenEnabled && BedtimeAlarm.isSupported && startMinutes != endMinutes
    }

    private var byWeekday: Bool { skipMode == AlarmSettings.SkipMode.weekdays.rawValue }

    private var timeText: String { MonitoringSchedule.timeText(startMinutes) }

    var body: some View {
        if isShown {
            Section {
                // 日付が変わったら並びを今日からにし直す
                TimelineView(.everyMinute) { context in
                    let today = calendar.startOfDay(for: context.date)
                    if byWeekday {
                        weekdayRow(from: today)
                    } else {
                        dayScroller(from: today)
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            } header: {
                // アプリ名「いびきアラーム」と被らないよう、右上の目覚ましのボタンから開く画面と同じ名前とアイコンにする
                Label("おやすみコール", systemImage: "alarm")
            } footer: {
                PhraseText(byWeekday
                           ? "曜日を押すと、毎週その曜日のアラームを止めます。もう一度押すと元に戻ります。"
                           : "日付を押すと、その日のアラームを止めます。もう一度押すと元に戻ります。左へなぞると先の日付も見られます。")
            }
        }
    }

    // MARK: - 日付で選ぶ

    private func dayScroller(from today: Date) -> some View {
        let days = AlarmSettings.parseDays(skipDays)
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 4) {
                ForEach(0..<Self.dayCount, id: \.self) { offset in
                    let date = calendar.date(byAdding: .day, value: offset, to: today) ?? today
                    let key = MonitoringSchedule.dayKey(date, calendar: calendar)
                    let isOff = days.contains(key)
                    let weekday = calendar.component(.weekday, from: date)
                    let day = calendar.component(.day, from: date)
                    let month = calendar.component(.month, from: date)
                    Button {
                        toggleDay(key)
                    } label: {
                        AlarmDayCell(top: Self.weekdaySymbols[weekday - 1],
                                     topColor: Self.weekdayColor(weekday),
                                     main: day == 1 ? "\(month)/1" : "\(day)",
                                     time: timeText, isToday: offset == 0, isOff: isOff)
                    }
                    .buttonStyle(.plain)
                    .containerRelativeFrame(.horizontal, count: 7, spacing: 4)
                    .accessibilityLabel(Text(verbatim: date.formatted(.dateTime.month(.wide).day().weekday(.wide)) + " " + timeText))
                    .accessibilityValue(isOff ? String(localized: "アラームを止めています") : String(localized: "アラームが鳴ります"))
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .sensoryFeedback(.selection, trigger: skipDays)
    }

    private func toggleDay(_ key: String) {
        var days = AlarmSettings.prunedDays(AlarmSettings.parseDays(skipDays))
        if days.contains(key) {
            days.remove(key)
        } else {
            days.insert(key)
        }
        skipDays = AlarmSettings.joined(days)
        monitor.applySchedule()
    }

    // MARK: - 曜日で選ぶ

    private func weekdayRow(from today: Date) -> some View {
        let weekdays = AlarmSettings.parseWeekdays(skipWeekdays)
        let todayWeekday = calendar.component(.weekday, from: today)
        return HStack(spacing: 4) {
            ForEach(0..<7, id: \.self) { offset in
                let weekday = (todayWeekday - 1 + offset) % 7 + 1
                let isOff = weekdays.contains(weekday)
                Button {
                    toggleWeekday(weekday)
                } label: {
                    AlarmDayCell(top: nil, topColor: .secondary,
                                 main: Self.weekdaySymbols[weekday - 1],
                                 time: timeText, isToday: offset == 0, isOff: isOff)
                        .foregroundStyle(isOff ? Color.secondary : Self.weekdayColor(weekday, default: .primary))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel(Text(verbatim: Self.weekdayNames[weekday - 1] + " " + timeText))
                .accessibilityValue(isOff ? String(localized: "毎週アラームを止めています") : String(localized: "アラームが鳴ります"))
            }
        }
        .sensoryFeedback(.selection, trigger: skipWeekdays)
    }

    private func toggleWeekday(_ weekday: Int) {
        var weekdays = AlarmSettings.parseWeekdays(skipWeekdays)
        if weekdays.contains(weekday) {
            weekdays.remove(weekday)
        } else {
            weekdays.insert(weekday)
        }
        skipWeekdays = AlarmSettings.joined(weekdays)
        monitor.applySchedule()
    }

    /// 日曜は赤、土曜は青
    static func weekdayColor(_ weekday: Int, default other: Color = .secondary) -> Color {
        switch weekday {
        case 1: .red
        case 7: .blue
        default: other
        }
    }
}

/// 帯の 1 日分。上に曜日 (小)、まん中に日付か曜日 (大)、下にアラームの時刻 (小)。
/// 今日は枠で囲み、止めた日はグレーにして時刻に線を引く
private struct AlarmDayCell: View {
    let top: String?
    let topColor: Color
    let main: String
    let time: String
    let isToday: Bool
    let isOff: Bool

    var body: some View {
        VStack(spacing: 2) {
            if let top {
                Text(top)
                    .font(.caption2)
                    .foregroundStyle(isOff ? Color.secondary : topColor)
            }
            Text(main)
                .font(.title3.weight(isToday ? .bold : .regular))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            HStack(spacing: 1) {
                if isOff {
                    Image(systemName: "bell.slash")
                }
                Text(time)
                    .strikethrough(isOff)
            }
            .font(.caption2.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundStyle(isOff ? Color.secondary : Color.accentColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .opacity(isOff ? 0.5 : 1)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isOff ? Color.gray.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isToday ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
    }
}
