import SwiftUI

/// 初回起動時の案内。紙芝居のように左へめくって、アプリが誰のためのものかを伝え、
/// 最後のページでいびきを知らせる端末 (iPhone / Apple Watch / 両方) を選んでメイン画面に移る。
/// 端末はあとからメイン画面で切り替えられる。設定の「はじめの説明を見る」から、もう一度見られる
struct OnboardingView: View {
    @Environment(SnoreMonitor.self) private var monitor
    @AppStorage(AlarmSettings.Key.alertDevice) private var alertDevice = AlarmSettings.Default.alertDevice
    @AppStorage(AlarmSettings.Key.hasCompletedOnboarding) private var hasCompletedOnboarding = false
    @State private var selection: AlertDevice?
    @State private var page = 0

    /// 紙芝居のページ。この後ろに端末を選ぶページが付く
    private static let stories: [StoryPage] = [
        StoryPage(symbol: "bed.double.fill", accent: "zzz",
                  colors: [Color(red: 0.10, green: 0.12, blue: 0.32), Color(red: 0.24, green: 0.20, blue: 0.52)],
                  title: "寝る姿勢で、いびきをかく人へ",
                  lines: ["このアプリは、特定の寝る姿勢のときだけいびきをかいてしまう人のためのアプリです。"]),
        StoryPage(symbol: "cloud.drizzle.fill", accent: nil,
                  colors: [Color(red: 0.20, green: 0.24, blue: 0.36), Color(red: 0.36, green: 0.40, blue: 0.52)],
                  title: "寝返りを打てればいいのに",
                  lines: ["ほんとうは寝返りを打てればいいのですが、寝ているあいだは思いどおりになりません。",
                          "翌朝、頭がずーんと重くて、つらい気持ちになります。"]),
        StoryPage(symbol: "iphone.radiowaves.left.and.right", accent: nil,
                  colors: [Color(red: 0.26, green: 0.16, blue: 0.50), Color(red: 0.50, green: 0.30, blue: 0.72)],
                  title: "ブブっとお知らせ",
                  lines: ["そんなあなたに、いびきをかき始めたらバイブでブブっとお知らせして、寝返りを促します。"]),
        StoryPage(symbol: "stethoscope", accent: nil,
                  colors: [Color(red: 0.06, green: 0.30, blue: 0.36), Color(red: 0.14, green: 0.48, blue: 0.52)],
                  title: "いつもいびきをかく人は",
                  lines: ["いつもいびきをかく人や、姿勢に関係なくいびきをかく人は、このアプリではなく、適切な医療機関で診断や治療を受けてください。",
                          "医者にかかる踏ん切りがつかない方は、アプリ「いびきラボ」(Reviva Softworks Ltd) などで測ってみるのもおすすめです。"]),
        StoryPage(symbol: "sun.horizon.fill", accent: nil,
                  colors: [Color(red: 0.98, green: 0.55, blue: 0.30), Color(red: 1.00, green: 0.80, blue: 0.45)],
                  title: "より良い朝を",
                  lines: ["このアプリで、より良い朝を迎えられますように。"]),
    ]

    /// 端末を選ぶページの番号
    private static var devicePage: Int { stories.count }

    private var isStory: Bool { page < Self.devicePage }

    var body: some View {
        ZStack {
            background
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.5), value: page)

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("スキップ") {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { page = Self.devicePage }
                    }
                    .font(.subheadline.bold())
                    .foregroundStyle(.white.opacity(0.8))
                    .opacity(isStory ? 1 : 0)
                    .disabled(!isStory)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)

                TabView(selection: $page) {
                    ForEach(Self.stories.indices, id: \.self) { index in
                        StoryCard(story: Self.stories[index], number: index + 1, total: Self.stories.count,
                                  isCurrent: page == index)
                            .tag(index)
                    }
                    deviceChoicePage
                        .tag(Self.devicePage)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                StoryDots(count: Self.devicePage + 1, current: page, onDark: isStory)
                    .padding(.vertical, 12)

                if isStory {
                    Button {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { page += 1 }
                    } label: {
                        Text("次へ")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.25))
                    .controlSize(.large)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
            }
        }
        .interactiveDismissDisabled()
        .onAppear {
            // もう一度見るときは、いま選んでいる端末を選んだ状態にしておく
            if UserDefaults.standard.object(forKey: AlarmSettings.Key.alertDevice) != nil {
                selection = alertDevice
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        if isStory {
            LinearGradient(colors: Self.stories[page].colors, startPoint: .top, endPoint: .bottom)
        } else {
            Color(.systemBackground)
        }
    }

    /// 最後のページ。知らせる端末を選んで、メイン画面に移る
    private var deviceChoicePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("知らせる端末を選んでください")
                        .font(.title2.bold())
                    PhraseText("いびきが続いたときに、どの端末の振動で知らせるかを選んでください。あとからメイン画面で切り替えられます。")
                        .foregroundStyle(.secondary)
                }

                DeviceChoice(device: .iPhone, symbol: "iphone", title: "iPhone",
                             detail: "安定した動作", note: nil, selection: $selection)
                DeviceChoice(device: .watch, symbol: "applewatch", title: "Apple Watch",
                             detail: "パートナーの睡眠を妨げない",
                             note: "Apple Watchのバージョンによっては動作が不安定になる事があります",
                             selection: $selection)
                DeviceChoice(device: .both, symbol: "applewatch.radiowaves.left.and.right", title: "両方",
                             detail: "Watch と iPhone を同時に振動。どちらかで止めると両方止まる",
                             note: nil, selection: $selection)

                if selection?.usesWatch == true {
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
    }

    private func finish() {
        guard let selection else { return }
        alertDevice = selection
        hasCompletedOnboarding = true
        Task { await monitor.prepareAlerts() }
    }
}

/// 紙芝居の 1 枚分の中身
private struct StoryPage {
    /// 絵にする SF Symbols
    let symbol: String
    /// 絵の右上に浮かべる小さな SF Symbols (寝息の zzz など)
    let accent: String?
    /// 背景のグラデーション (上から下へ)。夜から朝へ移っていく
    let colors: [Color]
    let title: String
    let lines: [String]
}

/// 紙芝居の 1 枚。紙の色のカードに、上に絵、下に文を置く。めくって来たときに絵が弾んで出てくる
private struct StoryCard: View {
    let story: StoryPage
    let number: Int
    let total: Int
    let isCurrent: Bool
    @State private var appeared = false

    /// 紙の色と文字の色。暗い画面の設定でも紙は明るいままにする
    private static let paper = Color(red: 1.0, green: 0.98, blue: 0.94)
    private static let ink = Color(red: 0.22, green: 0.20, blue: 0.26)

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: story.colors.map { $0.opacity(0.18) },
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 170, height: 170)
                    Image(systemName: story.symbol)
                        .font(.system(size: 76))
                        .foregroundStyle(LinearGradient(colors: story.colors.reversed(),
                                                        startPoint: .top, endPoint: .bottom))
                        .symbolEffect(.pulse, isActive: isCurrent && story.symbol.contains("radiowaves"))
                        .scaleEffect(appeared ? 1 : 0.5)
                        .rotationEffect(.degrees(appeared ? 0 : -10))
                        .animation(.spring(response: 0.55, dampingFraction: 0.5), value: appeared)
                    if let accent = story.accent {
                        Image(systemName: accent)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundStyle(story.colors.last ?? .indigo)
                            .offset(x: 62, y: appeared ? -62 : -40)
                            .opacity(appeared ? 1 : 0)
                            .animation(.easeOut(duration: 0.8).delay(0.25), value: appeared)
                    }
                }
                .padding(.top, 28)
                .accessibilityHidden(true)

                Text("\(number) / \(total)")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(Self.ink.opacity(0.45))

                PhraseText(story.title)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Self.ink)

                VStack(alignment: .leading, spacing: 14) {
                    ForEach(story.lines, id: \.self) { line in
                        PhraseText(line)
                    }
                }
                .font(.system(.body, design: .rounded))
                .foregroundStyle(Self.ink.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 12)
                .animation(.easeOut(duration: 0.5).delay(0.15), value: appeared)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 28)
                    .fill(Self.paper)
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 10)
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear { if isCurrent { appeared = true } }
        .onChange(of: isCurrent) { _, current in
            // めくって来たら弾ませて出し、離れたら元に戻しておく (次に来たときにもう一度弾ませるため)
            appeared = current
        }
    }
}

/// ページの位置。今のページだけ横に伸びた丸
private struct StoryDots: View {
    let count: Int
    let current: Int
    /// 暗い背景の上 (紙芝居のページ) なら白、端末を選ぶページなら アクセントの色
    let onDark: Bool

    var body: some View {
        let color: Color = onDark ? .white : .accentColor
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? color : color.opacity(0.3))
                    .frame(width: index == current ? 24 : 8, height: 8)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: current)
        .accessibilityHidden(true)
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
