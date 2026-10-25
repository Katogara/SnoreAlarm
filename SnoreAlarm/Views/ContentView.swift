import SwiftUI

struct ContentView: View {
    @Environment(SnoreMonitor.self) private var monitor
    @State private var showingSettings = false
    @State private var showingRecordings = false
    @State private var showingNight = false
    @State private var showingWatchTest = false
    @AppStorage(AlarmSettings.Key.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @AppStorage(AlarmSettings.Key.alertDevice) private var alertDevice = AlarmSettings.Default.alertDevice

    var body: some View {
        NavigationStack {
            List {
                Section {
                    StatusCard()
                        .listRowInsets(EdgeInsets())
                }

                AlertDeviceSection(showingWatchTest: $showingWatchTest)

                Section("入力レベル") {
                    LevelMeter(levelDB: monitor.levelDB, thresholdDB: monitor.thresholdDB)
                        .padding(.vertical, 4)
                }

                if monitor.isActive || !monitor.log.isEmpty {
                    Section("今回の記録") {
                        LabeledContent("いびき検知", value: "\(monitor.snoreCount) 回")
                        LabeledContent("振動アラーム", value: "\(monitor.alarmCount) 回")
                        if monitor.watchAlertCount > 0 || monitor.iPhoneFallbackCount > 0 {
                            LabeledContent("Apple Watch に通知", value: "\(monitor.watchAlertCount) 回")
                            LabeledContent("代わりに iPhone で振動", value: "\(monitor.iPhoneFallbackCount) 回")
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
                        PhraseText("iPhoneを充電しながら枕元に置き、「監視を開始」を押してください。画面をロックしても検知を続けます。\n\nいびきが続くとバイブレーションで知らせます (画面ロック中は通知も出します)。寝返りを打つなど、姿勢を変えるきっかけにしてください。\n\n「いびき検知デモ」を押すと、設定した条件でいびきを検知したときの動作 (ログと振動) を試せます。デモ中に画面をロックすると、通知も確認できます (知らせる端末が Apple Watch なら Watch に通知します)。\n\n設定の「寝る時刻のお知らせと自動終了」をオンにすると、毎日決まった時刻に監視の開始を通知でお知らせし、朝は自動で監視を止めます。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("いびきアラーム")
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
                ToolbarItem(placement: .topBarTrailing) {
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
                PhraseText(monitor.errorMessage ?? "")
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
                Picker("知らせる端末", selection: $alertDevice) {
                    Text("iPhone").tag(AlertDevice.iPhone)
                    Text("Apple Watch").tag(AlertDevice.watch)
                    Text("両方").tag(AlertDevice.both)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
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
                        PhraseText(problem.isBlocking
                             ? "⚠️ \(problem.message)ため、Watch には届きません (iPhone で振動します)"
                             : "⚠️ \(problem.message)ため、Watch が振動しないことがあります")
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
        case .monitoring: monitor.isDemo ? "waveform" : "ear"
        case .alarming: "iphone.radiowaves.left.and.right"
        }
    }

    private var color: Color {
        switch monitor.state {
        case .idle: .gray
        case .waiting: .indigo
        case .monitoring: monitor.isDemo ? .purple : .blue
        case .alarming: .orange
        }
    }

    private var title: String {
        switch monitor.state {
        case .idle: "停止中"
        case .waiting: "開始待ち"
        case .monitoring: monitor.isDemo ? "デモ: いびきを再現中" : "いびきを監視中"
        case .alarming: monitor.isDemo ? "デモ: 振動中" : "振動中"
        }
    }

    private var subtitle: String {
        switch monitor.state {
        case .idle:
            return "監視を開始するとマイクで周囲の音を解析します"
        case .waiting(let until):
            return "\(until.formatted(date: .omitted, time: .shortened)) から検知します"
        case .monitoring:
            if monitor.isDemo {
                return "マイクは使わず、設定どおりの条件でいびきを流しています"
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
                    Label(monitor.isDemo ? "デモを終了" : "監視を終了", systemImage: "stop.fill")
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
            let seconds = Int(DemoSignal.secondsUntilAlarm(for: AlarmSettings.load(),
                                                           leadIn: DemoSignal.leadIn + SnoreMonitor.watchTestDelay))
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
                PhraseText(entry.message)
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
        case .alarm: "iphone.radiowaves.left.and.right"
        }
    }

    private var color: Color {
        switch entry.kind {
        case .info: .secondary
        case .snore: .blue
        case .alarm: .orange
        }
    }
}

#Preview {
    ContentView()
        .environment(SnoreMonitor())
        .environment(SnorePlayer())
}
