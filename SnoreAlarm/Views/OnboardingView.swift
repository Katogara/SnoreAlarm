import SwiftUI

/// 初回起動時の案内。いびきを知らせる端末 (iPhone / Apple Watch) を選ぶ。あとからメイン画面のスイッチで切り替えられる。
struct OnboardingView: View {
    @Environment(SnoreMonitor.self) private var monitor
    @AppStorage(AlarmSettings.Key.alertDevice) private var alertDevice = AlarmSettings.Default.alertDevice
    @AppStorage(AlarmSettings.Key.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @State private var selection: AlertDevice?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("いびきアラームへようこそ")
                        .font(.title.bold())
                    PhraseText("いびきが続いたときに、振動で知らせて寝返りを促します。どちらで知らせるかを選んでください。あとからメイン画面のスイッチで切り替えられます。")
                        .foregroundStyle(.secondary)
                }

                DeviceChoice(device: .iPhone, symbol: "iphone", title: "iPhone",
                             detail: "安定した動作", note: nil, selection: $selection)
                DeviceChoice(device: .watch, symbol: "applewatch", title: "Apple Watch",
                             detail: "パートナーの睡眠を妨げない",
                             note: "Apple Watchのバージョンによっては動作が不安定になる事があります",
                             selection: $selection)

                if selection == .watch {
                    WatchSetupGuide()
                }

                Button {
                    finish()
                } label: {
                    Text("はじめる")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(selection == nil)
            }
            .padding()
        }
        .interactiveDismissDisabled()
    }

    private func finish() {
        guard let selection else { return }
        alertDevice = selection
        hasCompletedOnboarding = true
        Task { await monitor.prepareAlerts() }
    }
}

private struct DeviceChoice: View {
    let device: AlertDevice
    let symbol: String
    let title: String
    let detail: String
    let note: String?
    @Binding var selection: AlertDevice?

    var body: some View {
        let isSelected = selection == device
        Button {
            selection = device
        } label: {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.system(size: 36))
                    .frame(width: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    PhraseText(detail)
                        .font(.subheadline)
                    if let note {
                        PhraseText("(\(note))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .padding()
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Apple Watch で知らせるための準備。iPhone の通知を Watch に転送して振動させるため、転送の条件をそろえてもらう。
struct WatchSetupGuide: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var readiness: AlarmNotifier.Readiness?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Apple Watch で使うための準備")
                .font(.headline)
            ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .monospacedDigit()
                    VStack(alignment: .leading, spacing: 6) {
                        PhraseText(step)
                        if index == Self.notificationStepIndex {
                            notificationStatus
                        }
                    }
                }
                .font(.subheadline)
            }
            PhraseText("Watch のアプリを入れる必要はありません。iPhone の通知を Watch に転送して振動させます。Watch に届かないと分かっているとき (ペアリングされていない・通知が許可されていない・iPhone の画面が点いている) は、iPhone で振動します。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .task { await refreshReadiness() }
        .onChange(of: scenePhase) { _, phase in
            // 「設定」アプリで直して戻ってきたときに結果を更新する
            if phase == .active {
                Task { await refreshReadiness() }
            }
        }
    }

    static let steps = [
        "寝るときは Apple Watch を着けたままにし、iPhone の画面をロックしてください (自動ロックで可。iPhone の通知は、画面がロックされているときだけ Watch に届きます。Watch を外していると、iPhone で通知音が鳴ります)",
        "Apple Watch を消音モードにしてください。Watch のサイドボタンを押して (または画面の下から上にスワイプして) コントロールセンターを開き、ベルのボタンをタップします。消音モードでも振動で知らせます。消音モードにしないと、Watch から通知音が鳴って隣の人を起こしてしまいます",
        "いびきアラームの通知を許可し「サウンド」をオンにしてください。オンになっているかはアプリが確かめて、下に結果を出します (Watch はサウンド付きの通知で振動します。Watch に届いているあいだ iPhone は鳴りません)",
        "寝ているあいだに「睡眠」や「おやすみモード」がオンになる場合 (ヘルスケアの睡眠スケジュールや Watch の睡眠記録を使っていると自動でオンになります) は、そのままだと通知が止められて Watch が振動しません。「設定」アプリ > 集中モード > 睡眠 (おやすみモードも同じ) > App で「いびきアラーム」を許可してください。使っていなければ不要です",
        "iPhone の Watch アプリ > 通知 > いびきアラーム が「iPhone を反映」になっていることを確かめてください",
    ]

    /// steps のうち、通知の設定を自動で確かめる手順
    static let notificationStepIndex = 2

    /// 通知の許可とサウンドを確かめた結果。直す必要があるときだけ通知設定を開くボタンを出す
    @ViewBuilder
    private var notificationStatus: some View {
        if let readiness {
            if readiness.isReady {
                Label("確認しました：通知とサウンドはオンです", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if !readiness.requested {
                PhraseText("Apple Watch で知らせる設定にすると、通知の許可を求める画面が出ます")
                    .foregroundStyle(.secondary)
            } else {
                Label(readiness.authorized ? "通知のサウンドがオフです" : "通知が許可されていません",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                NotificationSettingsButton()
            }
        }
    }

    private func refreshReadiness() async {
        readiness = await AlarmNotifier.readiness()
    }
}

/// 「設定」アプリの、このアプリの通知設定を直接開く
struct NotificationSettingsButton: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
            openURL(url)
        } label: {
            Label("通知の設定を開く", systemImage: "bell.badge")
        }
        .buttonStyle(.bordered)
    }
}
