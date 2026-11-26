import SwiftUI

struct ContentView: View {
    @Environment(SnoreMonitor.self) private var monitor
    @Environment(SubscriptionStore.self) private var subscription
    @State private var showingSettings = false
    @State private var showingBedtimeAlarm = false
    /// 「あとでもう一度鳴らす」の表示を時刻に合わせて切り替えるための時計
    @State private var clock = Date()
    @State private var showingRecordings = false
    @State private var showingNight = false
    @State private var showingWatchTest = false
    @AppStorage(AlarmSettings.Key.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(AlarmSettings.Key.alertDevice) private var alertDevice = AlarmSettings.Default.alertDevice

    var body: some View {
        NavigationStack {
            List {
                AlarmStripSection()

                Section {
                    StatusCard()
                        .listRowInsets(EdgeInsets())
                }
                SnoozeSection(now: clock)


                AlertDeviceSection(showingWatchTest: $showingWatchTest)

                if !monitor.isActive {
                    TonightSkipSection()
                }

                Section("入力レベル") {
                    LevelMeter(levelDB: monitor.levelDB, thresholdDB: monitor.thresholdDB)
                        .padding(.vertical, 4)
                }

                if monitor.isActive || !monitor.log.isEmpty {
                    Section("今回の記録") {
                        LabeledContent("いびき検知", value: String(localized: "\(monitor.snoreCount) 回"))
                        if monitor.noiseCount > 0 {
                            LabeledContent("いびきに数えなかった物音", value: String(localized: "\(monitor.noiseCount) 回"))
                        }
                        if monitor.pausedSoundCount > 0 {
                            LabeledContent("休止中に録音した音", value: String(localized: "\(monitor.pausedSoundCount) 回"))
                        }
                        LabeledContent("振動で知らせた回数", value: String(localized: "\(monitor.alarmCount) 回"))
                        if monitor.watchAlertCount > 0 || monitor.iPhoneFallbackCount > 0 {
                            LabeledContent("Apple Watch に通知", value: String(localized: "\(monitor.watchAlertCount) 回"))
                            LabeledContent("代わりに iPhone で振動", value: String(localized: "\(monitor.iPhoneFallbackCount) 回"))
                        }
                        if let startedAt = monitor.startedAt {
                            LabeledContent("開始時刻", value: startedAt.formatted(date: .omitted, time: .shortened))
                        }
                        if monitor.isActive, let end = monitor.scheduledEnd {
                            LabeledContent("自動終了", value: end.formatted(date: .omitted, time: .shortened))
                        }
                    }

                    Section {
                        // ログが長いとフッターは見えないため、先頭に出す
                        if monitor.isActive && !monitor.isDemo {
                            Label {
                                PhraseText("監視中は録音を再生できません (再生した音をいびきと誤検知しないため)。監視を終了すると再生できます。")
                            } icon: {
                                Image(systemName: "speaker.slash")
                            }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(monitor.log) { entry in
                            LogRow(entry: entry)
                        }
                    } header: {
                        Text("ログ")
                    }
                } else {
                    Section {
                        PhraseText("iPhoneを充電しながら枕元に置き、「監視を開始」を押してください。画面をロックしても検知を続けます。\n\nいびきが続くとバイブレーションで知らせます (画面ロック中は通知も出します)。寝返りを打つなど、姿勢を変えるきっかけにしてください。\n\n「いびき検知デモ」を押すと、設定した条件でいびきを検知したときの動作 (ログと振動) を試せます。デモ中に画面をロックすると、通知も確認できます (知らせる端末が Apple Watch なら Watch に通知します)。\n\n右上の目覚ましのボタンから「おやすみコール」をオンにすると、監視を始め忘れた夜に、決めた時刻にアラームで知らせます。朝は自動で監視を止めます。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("いびきアラーム")
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20))
                    clock = Date()
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button {
                        showingRecordings = true
                    } label: {
                        Image(systemName: "waveform.circle")
                    }
                    .accessibilityLabel("録音したいびき")
                    Button {
                        showingNight = true
                    } label: {
                        Image(systemName: "chart.bar.xaxis")
                    }
                    .accessibilityLabel("一晩の記録")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingBedtimeAlarm = true
                    } label: {
                        Image(systemName: "alarm")
                    }
                    .accessibilityLabel(BedtimeAlarmView.title)
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("設定")
                }
            }
            .safeAreaInset(edge: .bottom) {
                ControlButtons()
                    .padding()
                    .background(.bar)
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingBedtimeAlarm) {
                BedtimeAlarmView()
            }
            .sheet(isPresented: $showingRecordings) {
                RecordingsView()
            }
            .sheet(isPresented: $showingNight) {
                NightView()
            }
            // List の Section に付けると行ごとに付いて、開いた直後に閉じてしまうため、ここで出す
            .sheet(isPresented: $showingWatchTest) {
                WatchTestSheet()
            }
            // 登録していないのに監視を始めようとしたとき (おやすみコールからを含む)
            .sheet(isPresented: Binding(
                get: { subscription.isPaywallPresented && hasCompletedOnboarding },
                set: { subscription.isPaywallPresented = $0 }
            )) {
                PaywallView()
            }
            .onChange(of: alertDevice) {
                Task { await monitor.prepareAlerts() }
            }
            .fullScreenCover(isPresented: Binding(
                get: { !hasCompletedOnboarding },
                set: { if !$0 { hasCompletedOnboarding = true } }
            )) {
                OnboardingView()
            }
            .alert("エラー", isPresented: Binding(
                get: { monitor.errorMessage != nil },
                set: { if !$0 { monitor.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                PhraseText(verbatim: monitor.errorMessage ?? "")
            }
        }
    }
}

/// いびきを知らせる端末の切り替え (iPhone / Apple Watch / 両方)。監視中に切り替えても次のアラームから反映する。
private struct AlertDeviceSection: View {
    @Environment(SnoreMonitor.self) private var monitor
    @AppStorage(AlarmSettings.Key.alertDevice) private var alertDevice = AlarmSettings.Default.alertDevice
    @Binding var showingWatchTest: Bool

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("知らせる端末")
                AlertDeviceCarousel(selection: $alertDevice)
            }
            if alertDevice.usesWatch && !monitor.isActive {
                Button {
                    showingWatchTest = true
                } label: {
                    Label("Watch に届くかテスト", systemImage: "applewatch.radiowaves.left.and.right")
                }
            }
        } footer: {
            if alertDevice.usesWatch {
                VStack(alignment: .leading, spacing: 4) {
                    if alertDevice == .both {
                        PhraseText("Apple Watch と iPhone の両方を振動させて知らせます。どちらかで止めると、両方の振動が止まります。iPhone の画面をロック (自動ロックで可) し、Watch を消音モードにして (音を出さず振動だけにするため) 着けたまま寝てください。寝る前に「Watch に届くかテスト」で確かめられます。")
                    } else {
                        PhraseText("Apple Watch の振動で知らせます (パートナーの睡眠を妨げません)。iPhone の画面をロック (自動ロックで可) し、Watch を消音モードにして (音を出さず振動だけにするため) 着けたまま寝てください。寝る前に「Watch に届くかテスト」で確かめられます。")
                    }
                    ForEach(monitor.watchProblems, id: \.self) { problem in
                        PhraseText(verbatim: "⚠️ " + problem.summary)
                            .foregroundStyle(.orange)
                    }
                    if monitor.watchProblems.contains(where: \.fixInNotificationSettings) {
                        NotificationSettingsButton()
                    }
                }
            } else {
                PhraseText("iPhone 本体の振動で知らせます (安定して動きます)。")
            }
        }
    }
}

/// 「あとでもう一度鳴らす」。お風呂などで、まだ監視を始めたくないときに、15 分後か 30 分後にもう一度アラームで知らせる。
/// 「アラームで知らせる」を使っていて、今夜まだ監視していないとき (アラームを「止める」で止めたときなど) か、
/// 監視を始めて間もないとき (アラームの「監視を開始」で始めたときなど) に出す
private struct SnoozeSection: View {
    @Environment(SnoreMonitor.self) private var monitor
    @AppStorage(AlarmSettings.Key.scheduleEnabled) private var scheduleEnabled = AlarmSettings.Default.scheduleEnabled
    @AppStorage(AlarmSettings.Key.scheduleStartMinutes) private var scheduleStartMinutes = AlarmSettings.Default.scheduleStartMinutes
    @AppStorage(AlarmSettings.Key.scheduleEndMinutes) private var scheduleEndMinutes = AlarmSettings.Default.scheduleEndMinutes
    @AppStorage(AlarmSettings.Key.autoOpenEnabled) private var autoOpenEnabled = false
    @AppStorage(AlarmSettings.Key.bedtimeAlarmEnabled) private var bedtimeAlarmEnabled = false
    @AppStorage(AlarmSettings.Key.skipWeekdays) private var skipWeekdays = ""
    @AppStorage(AlarmSettings.Key.skipDays) private var skipDays = ""
    @AppStorage(AlarmSettings.Key.skipMode) private var skipMode = AlarmSettings.SkipMode.days.rawValue
    let now: Date

    /// 監視を始めてからこの時間までは、監視をやめて「あとでもう一度鳴らす」を選べる
    private static let recentStart: TimeInterval = 30 * 60

    private var usesAlarm: Bool {
        scheduleEnabled && bedtimeAlarmEnabled && !autoOpenEnabled && BedtimeAlarm.isSupported && BedtimeAlarm.isAuthorized
            && scheduleStartMinutes != scheduleEndMinutes
    }

    private var isMonitoring: Bool { monitor.isActive && !monitor.isDemo }

    private var pendingSnooze: Date? {
        guard let snooze = monitor.snoozeAlarmAt, snooze > now, !monitor.isActive else { return nil }
        return snooze
    }

    private var canSnooze: Bool {
        let schedule = AlarmSettings.load().schedule
        if isMonitoring {
            guard let startedAt = monitor.startedAt else { return false }
            return now.timeIntervalSince(startedAt) < Self.recentStart
        }
        return !monitor.isActive && schedule.needsMonitoring(at: now, isMonitoring: false)
    }

    var body: some View {
        if usesAlarm, let snooze = pendingSnooze {
            Section {
                Label {
                    Text("\(snooze.formatted(date: .omitted, time: .shortened)) にもう一度鳴らします")
                } icon: {
                    Image(systemName: "alarm.fill")
                        .foregroundStyle(.indigo)
                }
                Button("取り消す", role: .destructive) {
                    monitor.cancelSnooze()
                }
            } footer: {
                PhraseText("寝る準備ができたら、アラームを待たずに「監視を開始」を押してください。監視を始めると、このアラームは取り消します。")
            }
        } else if usesAlarm && canSnooze {
            Section {
                HStack(spacing: 12) {
                    ForEach(SnoreMonitor.snoozeChoices, id: \.self) { minutes in
                        Button {
                            monitor.snoozeBedtimeAlarm(minutes: minutes)
                        } label: {
                            Label("\(minutes)分後", systemImage: "alarm")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.indigo)
                        .controlSize(.large)
                    }
                }
                .padding(.vertical, 2)
            } header: {
                Text("まだ寝ないとき")
            } footer: {
                PhraseText(isMonitoring
                           ? "お風呂などで、まだ監視を始めたくないときに押します。監視を終えて、選んだ時間のあとにもう一度アラームで知らせます。"
                           : "お風呂などで、まだ監視を始めたくないときに押します。選んだ時間のあとに、もう一度アラームで知らせます。")
            }
        }
    }
}
/// 「今夜は知らせない」。始め忘れの防止を使っているときだけ出し、押した夜だけ通知・アラーム・自動で開くを休む
/// (休む日 `skipDays` に今夜の日付を入れる。翌日からは元に戻る)
private struct TonightSkipSection: View {
    @Environment(SnoreMonitor.self) private var monitor
    @AppStorage(AlarmSettings.Key.scheduleEnabled) private var scheduleEnabled = AlarmSettings.Default.scheduleEnabled
    @AppStorage(AlarmSettings.Key.scheduleStartMinutes) private var scheduleStartMinutes = AlarmSettings.Default.scheduleStartMinutes
    @AppStorage(AlarmSettings.Key.scheduleEndMinutes) private var scheduleEndMinutes = AlarmSettings.Default.scheduleEndMinutes
    @AppStorage(AlarmSettings.Key.autoOpenEnabled) private var autoOpenEnabled = false
    @AppStorage(AlarmSettings.Key.bedtimeAlarmEnabled) private var bedtimeAlarmEnabled = false
    @AppStorage(AlarmSettings.Key.skipWeekdays) private var skipWeekdays = ""
    @AppStorage(AlarmSettings.Key.skipDays) private var skipDays = ""
    @AppStorage(AlarmSettings.Key.skipMode) private var skipMode = AlarmSettings.SkipMode.days.rawValue

    private var schedule: MonitoringSchedule {
        var schedule = MonitoringSchedule(isOn: scheduleEnabled, startMinutes: scheduleStartMinutes, endMinutes: scheduleEndMinutes)
        schedule.skipWeekdays = AlarmSettings.parseWeekdays(skipWeekdays)
        schedule.skipByWeekday = skipMode == AlarmSettings.SkipMode.weekdays.rawValue
        return schedule
    }

    /// 「アラームで知らせる」のときは、上の日付の帯で休む日を選ぶため出さない
    private var usesAlarmStrip: Bool {
        bedtimeAlarmEnabled && !autoOpenEnabled && BedtimeAlarm.isSupported
    }

    private var tonightKey: String? {
        schedule.tonightStart(at: Date()).map { MonitoringSchedule.dayKey($0) }
    }

    /// 今夜が休む曜日にあたる
    private var isSkipWeekday: Bool {
        guard let start = schedule.tonightStart(at: Date()) else { return false }
        return schedule.isSkipped(nightStart: start)
    }

    private var skipTonight: Binding<Bool> {
        Binding {
            guard let key = tonightKey else { return false }
            return AlarmSettings.parseDays(skipDays).contains(key)
        } set: { skip in
            guard let key = tonightKey else { return }
            var days = AlarmSettings.prunedDays(AlarmSettings.parseDays(skipDays))
            if skip {
                days.insert(key)
            } else {
                days.remove(key)
            }
            skipDays = AlarmSettings.joined(days)
            monitor.applySchedule()
        }
    }

    /// 今夜休むもの。文はほかの言語に訳せるよう、休むものごとに丸ごと持つ
    private enum Target { case autoOpen, alarm, notification }

    private var target: Target {
        if autoOpenEnabled { return .autoOpen }
        if bedtimeAlarmEnabled && BedtimeAlarm.isSupported { return .alarm }
        return .notification
    }

    private var weekdayFooter: LocalizedStringResource {
        switch target {
        case .autoOpen: "今夜は設定で休む曜日にしているため、通知とアプリを自動で開く仕組みを休みます。"
        case .alarm: "今夜は設定で休む曜日にしているため、アラームを休みます。"
        case .notification: "今夜は設定で休む曜日にしているため、通知を休みます。"
        }
    }

    private var toggleFooter: LocalizedStringResource {
        let time = MonitoringSchedule.timeText(scheduleStartMinutes)
        switch target {
        case .autoOpen: return "オンにすると、今夜 \(time) の通知とアプリを自動で開く仕組みを休みます。明日の夜からは元に戻ります。"
        case .alarm: return "オンにすると、今夜 \(time) のアラームを休みます。明日の夜からは元に戻ります。"
        case .notification: return "オンにすると、今夜 \(time) の通知を休みます。明日の夜からは元に戻ります。"
        }
    }

    var body: some View {
        if schedule.isEnabled && !usesAlarmStrip {
            Section {
                if isSkipWeekday {
                    LabeledContent("今夜は知らせない", value: String(localized: "休む曜日"))
                } else {
                    Toggle("今夜は知らせない", isOn: skipTonight)
                }
            } footer: {
                if isSkipWeekday {
                    PhraseText(weekdayFooter)
                } else {
                    PhraseText(toggleFooter)
                }
            }
        }
    }
}

private struct StatusCard: View {
    @Environment(SnoreMonitor.self) private var monitor

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(color)
                .symbolEffect(.pulse, isActive: monitor.state == .alarming)
                .frame(width: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                PhraseText(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .background(color.opacity(0.12))
    }

    private var icon: String {
        switch monitor.state {
        case .idle: "moon.zzz"
        case .waiting: "hourglass"
        case .monitoring: monitor.isDemo ? "waveform" : monitor.isPausedForScreen ? "pause.circle" : "ear"
        case .alarming: "iphone.radiowaves.left.and.right"
        }
    }

    private var color: Color {
        switch monitor.state {
        case .idle: .gray
        case .waiting: .indigo
        case .monitoring: monitor.isDemo ? .purple : monitor.isPausedForScreen ? .indigo : .blue
        case .alarming: .orange
        }
    }

    private var title: LocalizedStringResource {
        switch monitor.state {
        case .idle: "停止中"
        case .waiting: "開始待ち"
        case .monitoring: monitor.isDemo ? "デモ: いびきを再現中" : monitor.isPausedForScreen ? "休止中 (iPhone を使用中)" : "いびきを監視中"
        case .alarming: monitor.isDemo ? "デモ: 振動中" : "振動中"
        }
    }

    private var subtitle: LocalizedStringResource {
        switch monitor.state {
        case .idle:
            return "監視を開始するとマイクで周囲の音を解析します"
        case .waiting(let until):
            return "\(until.formatted(date: .omitted, time: .shortened)) から検知します"
        case .monitoring:
            if monitor.isDemo {
                return "マイクは使わず、設定どおりの条件でいびきを流しています"
            }
            if monitor.isPausedForScreen {
                return "手に持って使っているあいだは、タップの音などをいびきと間違えないよう、いびきを数えません (いびきに似た音は録音します)。iPhone を置いて\(Int(SnoreMonitor.resumeAfterStill / 60))分たつか、画面をロックして\(Int(SnoreMonitor.resumeAfterLock / 60))分たつと数え始めます"
            }
            if let end = monitor.scheduledEnd {
                return "画面をロックしても監視を続け、いびきを検知すると通知と振動で知らせます。\(end.formatted(date: .omitted, time: .shortened)) に自動で終了します"
            }
            return "画面をロックしても監視を続け、いびきを検知すると通知と振動で知らせます"
        case .alarming:
            return "いびきを検知しました"
        }
    }
}

private struct ControlButtons: View {
    @Environment(SnoreMonitor.self) private var monitor
    @Environment(SnorePlayer.self) private var player
    @AppStorage(AlarmSettings.Key.alertDevice) private var alertDevice = AlarmSettings.Default.alertDevice
    @State private var showingWatchDemo = false

    var body: some View {
        VStack(spacing: 12) {
            if monitor.state == .alarming {
                Button {
                    monitor.dismissAlarm()
                } label: {
                    Label("振動を止める", systemImage: "hand.raised.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.large)
            }

            if monitor.isActive {
                Button(role: .destructive) {
                    monitor.stop()
                } label: {
                    Label(monitor.isDemo ? String(localized: "デモを終了") : String(localized: "監視を終了"), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                Button {
                    player.stop()
                    Task { await monitor.start() }
                } label: {
                    Label("監視を開始", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    if alertDevice.usesWatch {
                        showingWatchDemo = true
                    } else {
                        startDemo()
                    }
                } label: {
                    Label("いびき検知デモ", systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.purple)
                .controlSize(.large)
            }
        }
        // Watch に届くのは iPhone の画面がロックされているときだけなので、始める前にロックを案内する
        .alert("Apple Watch でデモ", isPresented: $showingWatchDemo) {
            Button("開始") { startDemo() }
            Button("やめる", role: .cancel) {}
        } message: {
            // 画面をロックしてから、いびきを始める。通知を出してから Watch に届くまでにも数秒かかる
            let seconds = Int(SnoreMonitor.demoLockDelay + DemoSignal.secondsUntilAlarm(for: AlarmSettings.load())
                              + SnoreMonitor.demoWatchArrival)
            PhraseText("「開始」を押したら、すぐに iPhone のサイドボタンを押して画面をロックしてください。約\(seconds)秒後に Apple Watch が振動します。画面が点いたままだと、Watch ではなく iPhone が振動します。")
        }
    }

    private func startDemo() {
        player.stop()
        Task { await monitor.startDemo() }
    }
}

private struct LogRow: View {
    @Environment(SnoreMonitor.self) private var monitor
    @Environment(SnorePlayer.self) private var player
    let entry: SnoreMonitor.LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .frame(width: 20)
                PhraseText(verbatim: entry.message)
                    .font(.subheadline)
                Spacer()
                Text(entry.date.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let url = entry.recordingURL {
                    PlayButton(url: url)
                        // 監視中はマイクが再生音を拾ってしまうため再生しない
                        .disabled(monitor.isActive)
                }
            }
            if let url = entry.recordingURL {
                PlaybackWaveform(url: url)
            }
        }
    }

    private var symbol: String {
        switch entry.kind {
        case .info: "info.circle"
        case .snore: "waveform"
        case .noise: "hand.tap"
        case .alarm: "iphone.radiowaves.left.and.right"
        }
    }

    private var color: Color {
        switch entry.kind {
        case .info: .secondary
        case .snore: .blue
        case .noise: .gray
        case .alarm: .orange
        }
    }
}

#Preview {
    ContentView()
        .environment(SnoreMonitor())
        .environment(SnorePlayer())
        .environment(SubscriptionStore.shared)
}
