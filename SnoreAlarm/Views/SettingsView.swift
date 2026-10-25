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
                    Toggle("寝る時刻のお知らせと自動終了", isOn: $scheduleEnabled)
                    if scheduleEnabled {
                        DatePicker("お知らせ", selection: timeBinding($scheduleStartMinutes), displayedComponents: .hourAndMinute)
                        DatePicker("自動終了", selection: timeBinding($scheduleEndMinutes), displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("開始忘れの防止")
                } footer: {
                    if scheduleEnabled && scheduleStartMinutes == scheduleEndMinutes {
                        PhraseText("お知らせと自動終了に別の時刻を指定してください。")
                            .foregroundStyle(.red)
                    } else {
                        PhraseText("毎日お知らせの時刻に「監視を始めましょう」と通知し、監視を始めるまで15分おきに4回まで繰り返します。通知の「監視を開始」を押すか、通知をタップすると監視を始めます。先に監視を始めていれば、その夜は通知しません。アプリを終了していても通知は届きます。監視は自動終了の時刻に止まります。")
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
            .onDisappear {
                // 時刻を選んでいる途中で何度も予約し直さないよう、画面を閉じたときにまとめて反映する
                monitor.applySchedule()
            }
        }
    }

    /// 0 時からの分を DatePicker の時刻として扱う
    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60,
                                  second: 0, of: Date()) ?? Date()
        } set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes.wrappedValue = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        }
    }
}
