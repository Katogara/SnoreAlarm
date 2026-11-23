import SwiftUI

struct SettingsView: View {
    @Environment(SnoreMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss

    @AppStorage(AlarmSettings.Key.sensitivity) private var sensitivity = AlarmSettings.Default.sensitivity
    @AppStorage(AlarmSettings.Key.requiredSnores) private var requiredSnores = AlarmSettings.Default.requiredSnores
    @AppStorage(AlarmSettings.Key.windowSeconds) private var windowSeconds = AlarmSettings.Default.windowSeconds
    @AppStorage(AlarmSettings.Key.vibrationSeconds) private var vibrationSeconds = AlarmSettings.Default.vibrationSeconds
    @AppStorage(AlarmSettings.Key.startDelayMinutes) private var startDelayMinutes = AlarmSettings.Default.startDelayMinutes
    @AppStorage(AlarmSettings.Key.recordSnores) private var recordSnores = AlarmSettings.Default.recordSnores
    @AppStorage(AlarmSettings.Key.scheduleEnabled) private var scheduleEnabled = AlarmSettings.Default.scheduleEnabled
    @AppStorage(AlarmSettings.Key.scheduleStartMinutes) private var scheduleStartMinutes = AlarmSettings.Default.scheduleStartMinutes
    @AppStorage(AlarmSettings.Key.scheduleEndMinutes) private var scheduleEndMinutes = AlarmSettings.Default.scheduleEndMinutes
    @AppStorage(AlarmSettings.Key.dayBoundaryMinutes) private var dayBoundaryMinutes = AlarmSettings.Default.dayBoundaryMinutes
    @AppStorage(AlarmSettings.Key.watchFallback) private var watchFallback = AlarmSettings.Default.watchFallback
    @AppStorage(AlarmSettings.Key.autoOpenEnabled) private var autoOpenEnabled = false
    @AppStorage(AlarmSettings.Key.bedtimeAlarmEnabled) private var bedtimeAlarmEnabled = false
    @AppStorage(AlarmSettings.Key.skipWeekdays) private var skipWeekdays = ""
    @AppStorage(AlarmSettings.Key.skipDays) private var skipDays = ""
    @AppStorage(AlarmSettings.Key.skipMode) private var skipMode = AlarmSettings.SkipMode.days.rawValue
    @State private var showingAutomation = false
    @State private var alarmAuthorization = BedtimeAlarm.Authorization.unsupported

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
            case .off: "使わない"
            case .notify: "通知で知らせる"
            case .alarm: "アラームで知らせる"
            case .autoOpen: "アプリを自動で開く"
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
    }

    private var startGuard: StartGuard {
        if autoOpenEnabled && StartGuard.available.contains(.autoOpen) { return .autoOpen }
        if bedtimeAlarmEnabled && StartGuard.available.contains(.alarm) { return .alarm }
        return scheduleEnabled ? .notify : .off
    }

    /// やり方を選ぶと、お知らせ・自動終了 (`scheduleEnabled`)、アラーム (`bedtimeAlarmEnabled`)、
    /// 自動で開く (`autoOpenEnabled`) をまとめて切り替える
    private var startGuardBinding: Binding<StartGuard> {
        Binding {
            startGuard
        } set: { mode in
            scheduleEnabled = mode != .off
            autoOpenEnabled = mode == .autoOpen
            bedtimeAlarmEnabled = mode == .alarm
            if mode == .alarm {
                Task { alarmAuthorization = await BedtimeAlarm.requestAuthorization() }
            }
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

    private var skipFooter: String {
        var text = "夜勤の日など、知らせてほしくない夜を選びます。休む夜は、通知もアラームも出さず、アプリを自動で開くこともしません。"
        if skipMode == AlarmSettings.SkipMode.weekdays.rawValue {
            text += "選んだ曜日は毎週休みます。「曜日で選ぶ」に変えると、日付で選んだ休む日は消えます。"
        } else {
            text += "日付は、お知らせの時刻が来る日で選んでください。"
        }
        if startGuard == .alarm {
            text += "メイン画面の上に並ぶ日付 (曜日) を押しても、休む日を選べます。"
        } else {
            text += "急に休みたいときは、メイン画面の「今夜は知らせない」を使ってください。"
        }
        return text
    }

    private var skipWeekdaysBinding: Binding<Set<Int>> {
        Binding {
            AlarmSettings.parseWeekdays(skipWeekdays)
        } set: {
            skipWeekdays = AlarmSettings.joined($0)
        }
    }

    /// 監視を自動で始める夜の時間帯 (お知らせ・自動終了の時刻か、22:00〜5:00)
    private var nightWindow: MonitoringSchedule {
        MonitoringSchedule(isOn: scheduleEnabled, startMinutes: scheduleStartMinutes,
                           endMinutes: scheduleEndMinutes).nightWindow
    }

    @ViewBuilder
    private var startGuardFooter: some View {
        switch startGuard {
        case .off:
            PhraseText("監視の始め忘れを防ぐ仕組みを使いません。")
        case .notify:
            PhraseText("毎日お知らせの時刻に「監視を始めましょう」と通知し、監視を始めるまで15分おきに4回まで繰り返します。通知の「監視を開始」を押すか、通知をタップすると監視を始めます。先に監視を始めていれば、その夜は通知しません。アプリを終了していても通知は届きます。監視は自動終了の時刻に止まります。")
        case .alarm:
            VStack(alignment: .leading, spacing: 4) {
                PhraseText("毎日お知らせの時刻に、時計アプリの目覚ましと同じアラームで、止めるまで音と振動で知らせます。マナーモードや睡眠モードのときも鳴ります。アラームの「監視を開始」を押すと、いびきアラームが開いて監視を始めます。「止める」を押すと、その夜はもう鳴りません。先に監視を始めていれば、その夜は鳴りません。監視は自動終了の時刻に止まります。")
                if alarmAuthorization == .denied {
                    PhraseText("アラームが許可されていないため、代わりに通知で知らせます。「設定」アプリでいびきアラームを開き、アラームを許可してください。")
                        .foregroundStyle(.red)
                }
            }
        case .autoOpen:
            PhraseText("通知で知らせるのに加えて、夜の時間帯（\(MonitoringSchedule.timeText(nightWindow.startMinutes))〜\(MonitoringSchedule.timeText(nightWindow.endMinutes))）に YouTube などのアプリを開いたとき、まだ監視していなければ、いびきアラームの画面に切り替えて監視を始めます。元のアプリに戻るには、画面の下のふちを右へなぞります。使うには、iPhone の「ショートカット」アプリへの登録が必要です。監視しなかった夜は翌朝 \(MonitoringSchedule.timeText(nightWindow.endMinutes)) にお知らせします。")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if monitor.isActive {
                    Section {
                        PhraseText("検知・振動・録音の変更は次に監視を開始したときに反映されます (お知らせ・自動終了の時刻はこの画面を閉じるとすぐに反映されます)。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Picker("感度", selection: $sensitivity) {
                        ForEach(Sensitivity.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }
                    Stepper("いびき \(requiredSnores) 回", value: $requiredSnores, in: 2...10)
                    Picker("検知する時間", selection: $windowSeconds) {
                        Text("30秒以内").tag(30)
                        Text("1分以内").tag(60)
                        Text("2分以内").tag(120)
                        Text("3分以内").tag(180)
                    }
                } header: {
                    Text("検知")
                } footer: {
                    PhraseText("指定した時間内に指定回数のいびきを検知すると振動します。誤検知が多い場合は感度を下げるか回数を増やしてください。")
                }

                Section("振動") {
                    Stepper("振動の長さ \(vibrationSeconds) 秒", value: $vibrationSeconds, in: 3...60)
                    Button("振動をテスト") {
                        monitor.testVibration()
                    }
                }

                Section {
                    Toggle(isOn: $watchFallback) {
                        PhraseText("Watch で止まらないときは iPhone も振動")
                    }
                    NavigationLink("Apple Watch で使うための準備") {
                        ScrollView {
                            WatchSetupGuide()
                                .padding()
                        }
                        .navigationTitle("Apple Watch")
                        .navigationBarTitleDisplayMode(.inline)
                    }
                } header: {
                    Text("Apple Watch")
                } footer: {
                    PhraseText("Apple Watch で知らせる設定のとき、Watch に通知を送ってから\(Int(WatchAlert.fallbackWindow / 60))分以内にまたいびきで振動の条件に達したら、Watch では起きなかったとみなして iPhone も振動させます。Watch に通知が届いたかどうかは iPhone から確かめられないためです。Watch などで「振動を止める」を押して止めたときは、起きたとみなして iPhone は振動させません。両方で知らせる設定のときは、はじめから iPhone も振動します。")
                }

                Section {
                    Picker("やり方", selection: startGuardBinding) {
                        ForEach(StartGuard.available) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    if scheduleEnabled {
                        DatePicker("お知らせ", selection: timeBinding($scheduleStartMinutes), displayedComponents: .hourAndMinute)
                        DatePicker("自動終了", selection: timeBinding($scheduleEndMinutes), displayedComponents: .hourAndMinute)
                    }
                    if startGuard == .autoOpen {
                        Button("自動で開くための登録の手順") {
                            showingAutomation = true
                        }
                    }
                } header: {
                    Text("始め忘れの防止")
                } footer: {
                    if scheduleEnabled && scheduleStartMinutes == scheduleEndMinutes {
                        PhraseText("お知らせと自動終了に別の時刻を指定してください。")
                            .foregroundStyle(.red)
                    } else {
                        startGuardFooter
                    }
                }

                if startGuard != .off {
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
                        Text("始め忘れの防止を休む日")
                    } footer: {
                        PhraseText(skipFooter)
                    }
                }

                Section {
                    Picker("開始までの待ち時間", selection: $startDelayMinutes) {
                        Text("なし").tag(0)
                        Text("10分").tag(10)
                        Text("20分").tag(20)
                        Text("30分").tag(30)
                        Text("60分").tag(60)
                    }
                } header: {
                    Text("開始")
                } footer: {
                    PhraseText("寝付くまでの間は検知しないようにできます。")
                }

                Section {
                    Toggle("いびきを録音する", isOn: $recordSnores)
                } header: {
                    Text("録音")
                } footer: {
                    PhraseText("いびきと判定した数秒間だけを端末内に保存し、1週間で自動的に削除します。1回あたり約12KBです。")
                }

                Section {
                    DatePicker("1日の区切り", selection: timeBinding($dayBoundaryMinutes), displayedComponents: .hourAndMinute)
                } header: {
                    Text("一晩の記録")
                } footer: {
                    PhraseText("この時刻から翌日のこの時刻の前までに始めた監視を一晩としてまとめ、最初の開始から最後の終了までをグラフにします (初期値 12:00)。昼に眠る場合は、起きている時間帯の時刻にしてください。")
                }

                #if DIAGNOSTICS
                DiagnosticsSection()
                #endif
            }
            .navigationTitle("設定")
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

    /// 0 時からの分を DatePicker の時刻として扱う
    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        minutesBinding(minutes)
    }

    /// 休む日の行に出す件数 (今日より前の日は数えない)
    private var skipDaysSummary: String {
        let today = MonitoringSchedule.dayKey(Date())
        let count = AlarmSettings.parseDays(skipDays).filter { $0 >= today }.count
        return count == 0 ? "なし" : "\(count)日"
    }
}

/// 休む曜日を 7 つの丸で選ぶ。選んだ曜日を塗りつぶす
private struct WeekdayPicker: View {
    @Binding var selection: Set<Int>
    private static let symbols = ["日", "月", "火", "水", "木", "金", "土"]

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
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(isSelected ? Color.accentColor : Color.secondary.opacity(0.15)))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(Self.symbols[weekday - 1])曜日")
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
