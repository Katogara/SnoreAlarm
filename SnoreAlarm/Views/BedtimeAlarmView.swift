import SwiftUI

/// おやすみコール (始め忘れの防止) の画面。メイン画面の右上の目覚ましのボタンから開く。
/// いちばん上に「アラームで知らせる」を置き、通知・アプリを自動で開くは「ほかの知らせ方」として下に置く。
/// アラームが使えない iOS 26 より前は、「始め忘れの防止」として知らせ方を選ぶ画面になる
struct BedtimeAlarmView: View {
    @Environment(SnoreMonitor.self) private var monitor
    @Environment(SubscriptionStore.self) private var subscription
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AlarmSettings.Key.scheduleEnabled) private var scheduleEnabled = AlarmSettings.Default.scheduleEnabled
    @AppStorage(AlarmSettings.Key.scheduleStartMinutes) private var scheduleStartMinutes = AlarmSettings.Default.scheduleStartMinutes
    @AppStorage(AlarmSettings.Key.scheduleEndMinutes) private var scheduleEndMinutes = AlarmSettings.Default.scheduleEndMinutes
    @AppStorage(AlarmSettings.Key.autoOpenEnabled) private var autoOpenEnabled = false
    @AppStorage(AlarmSettings.Key.bedtimeAlarmEnabled) private var bedtimeAlarmEnabled = false
    @AppStorage(AlarmSettings.Key.skipWeekdays) private var skipWeekdays = ""
    @AppStorage(AlarmSettings.Key.skipDays) private var skipDays = ""
    @AppStorage(AlarmSettings.Key.skipMode) private var skipMode = AlarmSettings.SkipMode.days.rawValue
    @State private var showingAutomation = false
    @State private var alarmAuthorization = BedtimeAlarm.Authorization.unsupported

    /// 画面の名前。メイン画面のボタンの読み上げにも使う
    @MainActor
    static var title: String { BedtimeAlarm.isSupported ? String(localized: "おやすみコール") : String(localized: "始め忘れの防止") }

    /// 始め忘れの防止のやり方
    enum StartGuard: String, Identifiable {
        /// 使わない
        case off
        /// 決めた時刻に通知で知らせる (簡単。勝手に画面は変わらない)
        case notify
        /// 決めた時刻に目覚ましのアラームで知らせる (止めるまで鳴る。iOS 26 から)
        case alarm
        /// 通知に加えて、夜にほかのアプリを開いたとき、いびきアラームを前面に出して監視を始める (強め。ショートカットの登録が要る)
        case autoOpen

        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: String(localized: "使わない")
            case .notify: String(localized: "通知で知らせる")
            case .alarm: String(localized: "アラームで知らせる")
            case .autoOpen: String(localized: "アプリを自動で開く")
            }
        }

        /// 「アラームで知らせる」(AlarmKit) と「アプリを自動で開く」(「必要なら監視を開始」) は iOS 26 からのため、
        /// それより前の iOS では出さない
        @MainActor
        static var available: [StartGuard] {
            var modes: [StartGuard] = [.off, .notify]
            if BedtimeAlarm.isSupported { modes.append(.alarm) }
            if #available(iOS 26.0, *) { modes.append(.autoOpen) }
            return modes
        }

        /// 「ほかの知らせ方」に並べるもの (アラームは上のスイッチで選ぶ)
        @MainActor
        static var others: [StartGuard] { available.filter { $0 != .alarm } }
    }

    private var startGuard: StartGuard {
        if autoOpenEnabled && StartGuard.available.contains(.autoOpen) { return .autoOpen }
        if bedtimeAlarmEnabled && StartGuard.available.contains(.alarm) { return .alarm }
        return scheduleEnabled ? .notify : .off
    }

    /// やり方を選ぶと、お知らせ・自動終了 (`scheduleEnabled`)、アラーム (`bedtimeAlarmEnabled`)、
    /// 自動で開く (`autoOpenEnabled`) をまとめて切り替える
    private func select(_ mode: StartGuard) {
        scheduleEnabled = mode != .off
        autoOpenEnabled = mode == .autoOpen
        bedtimeAlarmEnabled = mode == .alarm
        if mode == .alarm {
            Task { alarmAuthorization = await BedtimeAlarm.requestAuthorization() }
        }
    }

    private var alarmBinding: Binding<Bool> {
        Binding {
            startGuard == .alarm
        } set: { isOn in
            withAnimation { select(isOn ? .alarm : .off) }
        }
    }

    private var otherBinding: Binding<StartGuard> {
        Binding {
            startGuard
        } set: { mode in
            withAnimation { select(mode) }
        }
    }

    /// 休み方を「曜日で選ぶ」に変えたら、日付で選んだ休む日は消す (見えないまま休み続けないように)
    private var skipModeBinding: Binding<AlarmSettings.SkipMode> {
        Binding {
            AlarmSettings.SkipMode(rawValue: skipMode) ?? .days
        } set: { mode in
            if mode == .weekdays && skipMode != mode.rawValue {
                skipDays = ""
            }
            skipMode = mode.rawValue
        }
    }

    private var skipWeekdaysBinding: Binding<Set<Int>> {
        Binding {
            AlarmSettings.parseWeekdays(skipWeekdays)
        } set: {
            skipWeekdays = AlarmSettings.joined($0)
        }
    }

    private var skipFooter: String {
        var text = [String(localized: "夜勤の日など、知らせてほしくない夜を選びます。休む夜は、通知もアラームも出さず、アプリを自動で開くこともしません。")]
        if skipMode == AlarmSettings.SkipMode.weekdays.rawValue {
            text.append(String(localized: "選んだ曜日は毎週休みます。「曜日で選ぶ」に変えると、日付で選んだ休む日は消えます。"))
        } else {
            text.append(String(localized: "日付は、お知らせの時刻が来る日で選んでください。"))
        }
        if startGuard == .alarm {
            text.append(String(localized: "メイン画面の上に並ぶ日付 (曜日) を押しても、休む日を選べます。"))
        } else {
            text.append(String(localized: "急に休みたいときは、メイン画面の「今夜は知らせない」を使ってください。"))
        }
        return Phrases.joinSentences(text)
    }

    /// 監視を自動で始める夜の時間帯 (お知らせ・自動終了の時刻か、22:00〜5:00)
    private var nightWindow: MonitoringSchedule {
        MonitoringSchedule(isOn: scheduleEnabled, startMinutes: scheduleStartMinutes,
                           endMinutes: scheduleEndMinutes).nightWindow
    }

    private var timesAreSame: Bool {
        scheduleEnabled && scheduleStartMinutes == scheduleEndMinutes
    }

    var body: some View {
        NavigationStack {
            Form {
                if !subscription.canMonitor {
                    Section {
                        Label {
                            PhraseText("サブスクリプションに登録していないため、アラームもお知らせも出しません。登録は「設定」からできます。")
                        } icon: {
                            Image(systemName: "exclamationmark.circle")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
                if BedtimeAlarm.isSupported {
                    alarmSection
                }
                if startGuard != .alarm {
                    otherSection
                }
                if startGuard != .off {
                    skipSection
                }
            }
            .navigationTitle(Self.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .onAppear {
                // この設定ができる前にオートメーションを作っていた人は「アプリを自動で開く」から始める
                if UserDefaults.standard.object(forKey: AlarmSettings.Key.autoOpenEnabled) == nil {
                    autoOpenEnabled = AlarmSettings.autoOpenEnabled()
                }
                alarmAuthorization = BedtimeAlarm.authorization
                let pruned = AlarmSettings.joined(AlarmSettings.prunedDays(AlarmSettings.parseDays(skipDays)))
                if pruned != skipDays { skipDays = pruned }
            }
            .onDisappear {
                // 時刻を選んでいる途中で何度も予約し直さないよう、画面を閉じたときにまとめて反映する
                monitor.applySchedule()
            }
            // Form の Section に付けると行ごとに付いて開いた直後に閉じるため、ここで出す
            .sheet(isPresented: $showingAutomation) {
                AutomationTutorialView()
            }
        }
    }

    // MARK: - アラーム

    private var alarmSection: some View {
        Section {
            HStack(spacing: 14) {
                Image(systemName: startGuard == .alarm ? "alarm.waves.left.and.right.fill" : "alarm")
                    .font(.system(size: 30))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(
                        Circle().fill(LinearGradient(colors: startGuard == .alarm ? [.indigo, .purple] : [.gray, .gray.opacity(0.7)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .contentTransition(.symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text(startGuard == .alarm ? MonitoringSchedule.timeText(scheduleStartMinutes) : String(localized: "オフ"))
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    PhraseText(startGuard == .alarm ? "まだ監視していなければ鳴ります" : "寝る時刻に監視を始めていなければ鳴らします")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)

            Toggle("アラームで知らせる", isOn: alarmBinding)
            if startGuard == .alarm {
                DatePicker("鳴らす時刻", selection: minutesBinding($scheduleStartMinutes), displayedComponents: .hourAndMinute)
                DatePicker("監視の自動終了", selection: minutesBinding($scheduleEndMinutes), displayedComponents: .hourAndMinute)
            }
        } footer: {
            if startGuard == .alarm && timesAreSame {
                PhraseText("鳴らす時刻と自動終了に別の時刻を指定してください。")
                    .foregroundStyle(.red)
            } else if startGuard == .alarm {
                VStack(alignment: .leading, spacing: 4) {
                    PhraseText("毎日この時刻に、時計アプリの目覚ましと同じアラームで、止めるまで音と振動で知らせます。マナーモードや睡眠モードのときも、アプリを終了していても鳴ります。アラームの「監視を開始」を押すと、いびきアラームが開いて監視を始めます。「止める」を押すと、その夜はもう鳴りません。先に監視を始めていれば、その夜は鳴りません。お風呂などでまだ寝ないときは、メイン画面の「まだ寝ないとき」で、15分後か30分後にもう一度鳴らせます。監視は自動終了の時刻に止まります。")
                    if alarmAuthorization == .denied {
                        PhraseText("アラームが許可されていないため、代わりに通知で知らせます。「設定」アプリでいびきアラームを開き、アラームを許可してください。")
                            .foregroundStyle(.red)
                    }
                }
            } else {
                PhraseText("オンにすると、毎日決めた時刻に、まだ監視を始めていなければ、時計アプリの目覚ましと同じアラームで知らせます。アラームから、そのまま監視を始められます。")
            }
        }
    }

    // MARK: - ほかの知らせ方

    private var otherSection: some View {
        Section {
            Picker("やり方", selection: otherBinding) {
                ForEach(StartGuard.others) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            if scheduleEnabled {
                DatePicker("お知らせ", selection: minutesBinding($scheduleStartMinutes), displayedComponents: .hourAndMinute)
                DatePicker("自動終了", selection: minutesBinding($scheduleEndMinutes), displayedComponents: .hourAndMinute)
            }
            if startGuard == .autoOpen {
                Button("自動で開くための登録の手順") {
                    showingAutomation = true
                }
            }
        } header: {
            Text(BedtimeAlarm.isSupported ? String(localized: "ほかの知らせ方") : String(localized: "始め忘れの防止"))
        } footer: {
            if timesAreSame {
                PhraseText("お知らせと自動終了に別の時刻を指定してください。")
                    .foregroundStyle(.red)
            } else {
                otherFooter
            }
        }
    }

    @ViewBuilder
    private var otherFooter: some View {
        switch startGuard {
        case .off, .alarm:
            PhraseText(BedtimeAlarm.isSupported
                       ? "アラームを使わずに、通知などで監視の始め忘れを防ぐこともできます。"
                       : "監視の始め忘れを防ぐ仕組みを使いません。")
        case .notify:
            PhraseText("毎日お知らせの時刻に「監視を始めましょう」と通知し、監視を始めるまで15分おきに4回まで繰り返します。通知の「監視を開始」を押すか、通知をタップすると監視を始めます。先に監視を始めていれば、その夜は通知しません。アプリを終了していても通知は届きます。監視は自動終了の時刻に止まります。")
        case .autoOpen:
            PhraseText("通知で知らせるのに加えて、夜の時間帯（\(MonitoringSchedule.timeText(nightWindow.startMinutes))〜\(MonitoringSchedule.timeText(nightWindow.endMinutes))）に YouTube などのアプリを開いたとき、まだ監視していなければ、いびきアラームの画面に切り替えて監視を始めます。元のアプリに戻るには、画面の下のふちを右へなぞります。使うには、iPhone の「ショートカット」アプリへの登録が必要です。監視しなかった夜は翌朝 \(MonitoringSchedule.timeText(nightWindow.endMinutes)) にお知らせします。")
        }
    }

    // MARK: - 休む日

    private var skipSection: some View {
        Section {
            Picker("休み方", selection: skipModeBinding) {
                ForEach(AlarmSettings.SkipMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            if skipMode == AlarmSettings.SkipMode.weekdays.rawValue {
                VStack(alignment: .leading, spacing: 8) {
                    Text("休む曜日")
                    WeekdayPicker(selection: skipWeekdaysBinding)
                }
            } else {
                NavigationLink {
                    SkipDaysView(skipDays: $skipDays)
                } label: {
                    LabeledContent("休む日", value: skipDaysSummary)
                }
            }
        } header: {
            Text("休む日")
        } footer: {
            PhraseText(verbatim: skipFooter)
        }
    }

    /// 休む日の行に出す件数 (今日より前の日は数えない)
    private var skipDaysSummary: String {
        let today = MonitoringSchedule.dayKey(Date())
        let count = AlarmSettings.parseDays(skipDays).filter { $0 >= today }.count
        return count == 0 ? String(localized: "なし") : String(localized: "\(count)日")
    }
}

/// 休む曜日を 7 つの丸で選ぶ。選んだ曜日を塗りつぶす
private struct WeekdayPicker: View {
    @Binding var selection: Set<Int>
    private static var symbols: [String] { AlarmStripSection.weekdaySymbols }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...7, id: \.self) { weekday in
                let isSelected = selection.contains(weekday)
                // Form の行の中に複数のボタンを置くため、.plain にして行全体が押されないようにする
                Button {
                    if isSelected {
                        selection.remove(weekday)
                    } else {
                        selection.insert(weekday)
                    }
                } label: {
                    Text(Self.symbols[weekday - 1])
                        .font(.subheadline.weight(isSelected ? .bold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.15)))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: AlarmStripSection.weekdayNames[weekday - 1]))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// 休む日をカレンダーで選ぶ
private struct SkipDaysView: View {
    @Binding var skipDays: String
    @Environment(\.calendar) private var calendar

    /// 保存している "yyyy-MM-dd" と、カレンダーの選択 (年月日の DateComponents) を相互に変える
    private var selection: Binding<Set<DateComponents>> {
        Binding {
            Set(AlarmSettings.parseDays(skipDays).compactMap { key -> DateComponents? in
                let parts = key.split(separator: "-").compactMap { Int($0) }
                guard parts.count == 3,
                      let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
                else { return nil }
                return calendar.dateComponents([.calendar, .era, .year, .month, .day], from: date)
            })
        } set: { components in
            let keys = components.compactMap { component -> String? in
                guard let year = component.year, let month = component.month, let day = component.day else { return nil }
                return String(format: "%04d-%02d-%02d", year, month, day)
            }
            skipDays = AlarmSettings.joined(Set(keys))
        }
    }

    var body: some View {
        Form {
            Section {
                MultiDatePicker("休む日", selection: selection)
            } footer: {
                PhraseText("休む夜の、お知らせの時刻が来る日を選んでください。もう一度押すと外せます。過ぎた日は自動で消えます。")
            }
        }
        .navigationTitle("休む日")
        .navigationBarTitleDisplayMode(.inline)
    }
}
