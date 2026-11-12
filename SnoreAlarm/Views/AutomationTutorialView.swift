import SwiftUI

/// ショートカットアプリに「夜の時間帯に、まだ監視していなければ、いびきアラームの監視を始める」仕組みを作る手順を、
/// 1画面ずつ絵を見せながら案内する (パケざんの案内と同じ作り。iOS 27 の画面に合わせている)。
/// 絵は実際の画面を写したものではなく、押す所が分かるように描いた見本。
/// 前半でショートカット「いびきの見張り」(監視が必要か調べる → もし はい なら 監視を開始) を作り、
/// 後半でそれを動かすオートメーション (アプリを開いたとき・充電器につないだとき・時刻) を作る。
/// iPhone がロック中だとアプリを開けないため、ロックが解除されている場面をきっかけの中心にしている
struct AutomationTutorialView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// ショートカットアプリと行き来しても続きから見られるよう、見ていたページを覚えておく
    @AppStorage("automationTutorialPage2") private var page = 0

    /// 手順の数 (0 ページ目は前置き、最後のページは完了)
    static let stepCount = 10
    /// 作るショートカットの名前
    static let shortcutName = "いびきの見張り"

    /// 監視を自動で始める夜の時間帯 (お知らせ・自動終了の時刻か、22:00〜5:00)
    private let window = AlarmSettings.load().schedule.nightWindow

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: Double(min(page, Self.stepCount)), total: Double(Self.stepCount))
                    .padding(.horizontal)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        content
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(page)
            }
            .navigationTitle((1...Self.stepCount).contains(page) ? "手順 \(page) / \(Self.stepCount)" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("とじる") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { footer }
        }
    }

    /// 夜の時間帯 (例: 22:00〜5:00)
    private var windowText: String {
        "\(MonitoringSchedule.timeText(window.startMinutes))〜\(MonitoringSchedule.timeText(window.endMinutes))"
    }

    /// 時刻のきっかけにすすめる時刻 (夜の時間帯の始まりから 1 時間後と 2 時間後)
    private var suggestedTimesText: String {
        [60, 120].map { MonitoringSchedule.timeText((window.startMinutes + $0) % (24 * 60)) }.joined(separator: " と ")
    }

    // MARK: - ページ

    @ViewBuilder
    private var content: some View {
        switch page {
        case 0: intro
        case 1: newShortcut
        case 2: nameShortcut
        case 3: addCheck
        case 4: addIf
        case 5: addStart
        case 6: newAutomation
        case 7: addShortcut
        case 8: chooseApp
        case 9: confirm
        case 10: moreTriggers
        default: finished
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppMark(size: 120)
                .frame(maxWidth: .infinity)
            Text("監視の始め忘れを防ぐ設定")
                .font(.title2.bold())
                .frame(maxWidth: .infinity)
            PhraseText("寝る前に YouTube などのアプリを開いたとき、まだ監視していなければ、いびきアラームが自動で開いて監視を始めるようにします。")
            PhraseText("自動で始めるのは、夜の時間帯（\(windowText)）だけです。昼間や、すでに監視しているときは何も起きません。")
            PhraseText("iPhone がロックされているあいだは、iPhone の決まりでアプリを開けません。そのため、iPhone を触っている場面をきっかけにします。")
            VStack(alignment: .leading, spacing: 8) {
                Label("かかる時間：10分ほど", systemImage: "clock")
                Label("作るもの：ショートカット1つと、オートメーション3つ", systemImage: "list.number")
            }
            PhraseText("夜の時間帯は、設定の「寝る時刻のお知らせと自動終了」の時刻です。オフのときは 22:00〜5:00 です。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            PhraseText("このガイドとショートカットアプリを行き来しながら進めます。いびきアラームに戻ってくると、続きのページから見られます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var newShortcut: some View {
        StepPage(title: "ショートカットを新しく作る",
                 message: "下のボタンでショートカットアプリを開きます。「すべてのショートカット」の画面で「＋」を押してください。",
                 tip: "ほかの画面が出たときは、左上の「＜」を何回か押して「ライブラリ」に戻り、「すべてのショートカット」を押してください。") {
            Button {
                if let url = URL(string: "shortcuts://") { openURL(url) }
            } label: {
                Label("ショートカットアプリを開く", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            MockScreen {
                HStack {
                    MockCircleButton(systemImage: "chevron.left")
                    Spacer()
                    MockPill(text: "選択")
                }
                MockLargeTitle(text: "すべてのショートカット")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(0..<4, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 12)
                            .fill([Color.blue, .pink, .orange, .purple][index].opacity(0.35))
                            .frame(height: 44)
                    }
                }
                MockCircleButton(systemImage: "plus", size: 46)
                    .highlight()
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var nameShortcut: some View {
        StepPage(title: "名前を「\(Self.shortcutName)」にする",
                 message: "いちばん上の「新規ショートカット」を押し、「名前を変更」を選んで「\(Self.shortcutName)」と入れます（①）。名前を入れたら、右上の「編集」を押してください（②）。",
                 tip: "名前はあとでオートメーションから探すときに使います。「みはり」と入れても探せます。") {
            MockScreen {
                HStack {
                    MockCircleButton(systemImage: "chevron.left")
                    Spacer()
                    Text(Self.shortcutName)
                        .font(.caption.bold())
                        .foregroundStyle(Mock.text)
                        .highlight(number: 1)
                    Spacer()
                    MockPill(text: "編集").highlight(number: 2)
                }
                Text("ショートカットでどのような操作を実行しますか？")
                    .font(.caption.bold())
                    .foregroundStyle(Mock.text)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 28)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity)
                    .background(Color(red: 0.88, green: 0.93, blue: 1), in: .rect(cornerRadius: 22))
            }
        }
    }

    private var addCheck: some View {
        StepPage(title: "「監視が必要か調べる」を入れる",
                 message: "画面の下にある検索欄を、指で上に引き出します。「いびき」と入れると出てくる「監視が必要か調べる」を押してください。",
                 tip: "検索欄は画面の下のふちに小さく隠れています。下のふちに指を置いて、上へすっとなぞると出てきます。") {
            MockScreen {
                MockSheet {
                    MockSearchField(text: "いびき")
                    MockNamedAction(title: "監視が必要か調べる")
                        .highlight()
                    MockNamedAction(title: "監視を開始")
                }
            }
        }
    }

    private var addIf: some View {
        StepPage(title: "「もし」を入れて条件を決める",
                 message: "もう一度検索欄を引き出し、「もし」と入れて出てくる「もし」を押します。「もし 監視が必要 条件」の行が増えたら、「条件」を押して「が次と等しい」を選び、右の値を「はい」にしてください。",
                 tip: "条件や値の言葉が少し違うときは、「等しい」「はい」「オン」「真」に近いものを選んでください。") {
            MockScreen {
                MockNamedAction(title: "監視が必要か調べる")
                MockIfBlock(condition: "条件", highlightsCondition: true, inner: nil)
            }
        }
    }

    private var addStart: some View {
        StepPage(title: "「監視を開始」を「もし」の中に入れる",
                 message: "検索欄で「いびき」と入れて「監視を開始」を押します。いちばん下に入るので、長押ししたまま上へ動かし、「もし」のすぐ下（「その他」より上）に置いてください。",
                 tip: "置けたら、左上の「＜」でショートカットの一覧に戻ります。これで「\(Self.shortcutName)」ができました。") {
            MockScreen {
                MockNamedAction(title: "監視が必要か調べる")
                MockIfBlock(condition: "はい", highlightsCondition: false, inner: "監視を開始")
            }
        }
    }

    private var newAutomation: some View {
        StepPage(title: "オートメーションを新しく作る",
                 message: "左上の「＜」を押して「ライブラリ」に戻り、「オートメーション」を押します（①）。いちばん下のまん中の「＋」を押し（②）、出てきた画面で右上の「編集」を押してください。",
                 tip: "ほかのアプリのオートメーションがすでに並んでいても、そのまま「＋」を押して大丈夫です。以前このガイドで作った、時刻に「監視を開始」するオートメーションは、ここで消してください（左にすべらせると消せます）。") {
            MockScreen {
                MockLargeTitle(text: "ライブラリ")
                VStack(spacing: 0) {
                    MockListRow(systemImage: "square.stack", text: "すべてのショートカット")
                    MockListRow(systemImage: "square.grid.2x2", text: "ギャラリー")
                    MockListRow(systemImage: "clock", text: "オートメーション").highlight(number: 1)
                }
                .background(Mock.card, in: .rect(cornerRadius: 14))
                MockCircleButton(systemImage: "plus", size: 46)
                    .highlight(number: 2)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var addShortcut: some View {
        StepPage(title: "「\(Self.shortcutName)」を入れる",
                 message: "検索欄を引き出して「みはり」と入れ、出てくる「\(Self.shortcutName)」を押してください。",
                 tip: "出てこないときは、ショートカットの名前が「\(Self.shortcutName)」になっているかを確かめてください。") {
            MockScreen {
                MockSheet {
                    MockSearchField(text: "みはり")
                    MockNamedAction(title: Self.shortcutName)
                        .highlight()
                }
            }
        }
    }

    private var chooseApp: some View {
        StepPage(title: "きっかけを「App」にする",
                 message: "もう一度検索欄を引き出し、青い「オートメーション」を押して（①）、「App」を押します（②）。「App」を押して、寝る前によく使うアプリ（YouTube、X、LINE など）をすべて選び、「開いている」に印を付けてください。",
                 tip: "「閉じている」には印を付けません。いびきアラーム自身は選ばないでください。") {
            MockScreen {
                MockSheet {
                    MockSearchField(text: "")
                    HStack(spacing: 6) {
                        MockChip(systemImage: "clock", text: "オートメーション").highlight(number: 1)
                        MockChip(systemImage: "curlybraces", text: "スクリプティング")
                    }
                    VStack(spacing: 6) {
                        MockTriggerRow(color: .orange, title: "時刻", example: "“平日の午前8:00”")
                        MockTriggerRow(color: .blue, title: "App", example: "“YouTube が開いているとき”").highlight(number: 2)
                        MockTriggerRow(color: .green, title: "充電器", example: "“充電器に接続されたとき”")
                    }
                }
            }
        }
    }

    private var confirm: some View {
        StepPage(title: "すぐに実行するようにする",
                 message: "きっかけの行の右にある「＞」を押します。「すぐに実行」になっていて、「オートメーション」がオンなら大丈夫です。",
                 tip: "「実行前に確認」になっていたら「すぐに実行」に変えてください。「通知」はオフのままで大丈夫です。") {
            MockScreen {
                VStack(spacing: 0) {
                    MockSettingRow(title: "App") { Text("YouTube ほか").foregroundStyle(Mock.blue) }
                    MockSettingRow(title: "すぐに実行") { Image(systemName: "checkmark").foregroundStyle(Mock.blue) }
                        .highlight(showsHand: false)
                    MockSettingRow(title: "オートメーション") { MockToggle(isOn: true) }
                        .highlight(showsHand: false)
                    MockSettingRow(title: "通知") { MockToggle(isOn: false) }
                }
                .background(Mock.card, in: .rect(cornerRadius: 14))
            }
            PhraseText("確かめたら、左上の「＜」で戻ります。「オートメーション」の一覧に出ていれば、1つ目のオートメーションの完成です。")
        }
    }

    private var moreTriggers: some View {
        StepPage(title: "残りの2つも作る",
                 message: "手順 6〜9 をもう2回くり返し、きっかけだけを変えたオートメーションを作ります。",
                 tip: "時刻のきっかけは、iPhone がロックされていると失敗します（失敗の通知が出ます）。そのときにスマホを触っていれば、監視を始められます。") {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    PhraseText("2つ目：「充電器」を選び、「接続されている」にします。寝る前に手に持ったまま充電器につないだときに働きます。")
                } icon: {
                    Image(systemName: "battery.100.bolt")
                }
                Label {
                    PhraseText("3つ目：「時刻」を選び、\(suggestedTimesText) のように、夜の時間帯の中の時刻にします。「繰り返し」は「毎日」です。時刻ごとに1つずつ作ります。")
                } icon: {
                    Image(systemName: "clock")
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppMark(size: 120)
                .frame(maxWidth: .infinity)
            Text("おつかれさまでした！")
                .font(.title2.bold())
                .frame(maxWidth: .infinity)
            PhraseText("設定はこれでおしまいです。夜の時間帯（\(windowText)）に、まだ監視していないままきっかけのアプリを開くと、いびきアラームが開いて監視を始めます。")
            VStack(alignment: .leading, spacing: 10) {
                Label("知っておいてほしいこと", systemImage: "info.circle")
                    .font(.headline)
                PhraseText("・いびきアラームの画面に切り替わったあと、元のアプリには自分で戻ってください。監視は続きます。")
                PhraseText("・iPhone を手に持っているあいだは、いびきを数えません。iPhone を置いて\(Int(SnoreMonitor.resumeAfterStill / 60))分たつか、画面をロックして\(Int(SnoreMonitor.resumeAfterLock / 60))分たつと数え始めます。")
                PhraseText("・夜の時間帯に一度も iPhone を触らなかった夜は、自動では始められません。その夜の翌朝 \(MonitoringSchedule.timeText(window.endMinutes)) に「昨夜は監視していませんでした」とお知らせします。")
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
        }
    }

    // MARK: - 下のボタン

    private var footer: some View {
        HStack(spacing: 12) {
            if page > 0 {
                Button {
                    page -= 1
                } label: {
                    Text("もどる")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            Button {
                if page > Self.stepCount {
                    // 次に開いたときは最初から見られるようにする
                    page = 0
                    dismiss()
                } else {
                    page += 1
                }
            } label: {
                Text(nextTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .padding()
        .background(.bar)
    }

    private var nextTitle: String {
        if page == 0 { return "はじめる" }
        if page == Self.stepCount { return "できた！" }
        return page > Self.stepCount ? "とじる" : "次へ"
    }
}

/// 入れたアクションの行 (名前を指定)
private struct MockNamedAction: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            AppMark(size: 24)
            Text(title)
                .font(.callout.bold())
                .foregroundStyle(Mock.text)
            Spacer()
        }
        .padding(10)
        .background(Mock.card, in: .capsule)
    }
}

/// 「もし」のかたまり (もし 〜 / 中のアクション / その他 / もし終了)
private struct MockIfBlock: View {
    let condition: String
    let highlightsCondition: Bool
    /// 「もし」の中に入れたアクションの名前
    let inner: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(Mock.secondary)
                Text("もし")
                    .font(.callout.bold())
                    .foregroundStyle(Mock.text)
                Text("監視が必要")
                    .font(.caption)
                    .foregroundStyle(Mock.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Mock.blue.opacity(0.12), in: .rect(cornerRadius: 6))
                conditionText
                Spacer()
            }
            .padding(10)
            .background(Mock.card, in: .rect(cornerRadius: 14))
            if let inner {
                MockNamedAction(title: inner)
                    .padding(.leading, 18)
                    .highlight()
            }
            Text("その他")
                .font(.callout.bold())
                .foregroundStyle(Mock.text)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Mock.card, in: .rect(cornerRadius: 14))
            Text("もし終了")
                .font(.callout.bold())
                .foregroundStyle(Mock.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Mock.card, in: .rect(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private var conditionText: some View {
        let text = Text(condition)
            .font(.caption)
            .foregroundStyle(Mock.blue)
        if highlightsCondition {
            text.highlight()
        } else {
            text
        }
    }
}

/// 0 時からの分を DatePicker の時刻として扱う
func minutesBinding(_ minutes: Binding<Int>) -> Binding<Date> {
    Binding {
        Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60,
                              second: 0, of: Date()) ?? Date()
    } set: { date in
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        minutes.wrappedValue = (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

/// いびきアラームの印 (アプリのアイコンの代わりに、案内の絵で使う)
private struct AppMark: View {
    var size: CGFloat

    var body: some View {
        Image(systemName: "moon.zzz.fill")
            .font(.system(size: size * 0.45))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.indigo.gradient, in: .rect(cornerRadius: size * 0.22))
    }
}

// MARK: - 手順のページの型

private struct StepPage<Content: View>: View {
    let title: String
    let message: String
    let tip: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title2.bold())
            PhraseText(message)
            content
            if let tip {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                    PhraseText(tip)
                        .font(.callout)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.15), in: .rect(cornerRadius: 14))
            }
        }
    }
}

// MARK: - 画面の見本の部品 (iOS のライトモードの色で描く)

private enum Mock {
    static let background = Color(red: 0.95, green: 0.95, blue: 0.97)
    static let card = Color.white
    static let text = Color.black
    static let secondary = Color(white: 0.5)
    static let blue = Color(red: 0.2, green: 0.48, blue: 1)
}

/// 押す所を、脈打つオレンジの枠と指の印で示す
private struct Highlight: ViewModifier {
    var showsHand: Bool
    var number: Int?
    @State private var pulse = false

    func body(content: Content) -> some View {
        content
            .padding(3)
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.orange, lineWidth: 3)
                    .scaleEffect(pulse ? 1.06 : 1)
                    .opacity(pulse ? 0.45 : 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if showsHand {
                    Image(systemName: "hand.point.up.left.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                        .shadow(color: .white, radius: 2)
                        .offset(x: 10, y: 16)
                }
            }
            .overlay(alignment: .topLeading) {
                if let number {
                    Text("\(number)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.orange, in: .circle)
                        .offset(x: -8, y: -8)
                }
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

private extension View {
    func highlight(showsHand: Bool = true, number: Int? = nil) -> some View {
        modifier(Highlight(showsHand: showsHand || number != nil, number: number))
    }
}

/// iPhone の画面に見立てた枠
private struct MockScreen<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .frame(maxWidth: 300)
        .background(Mock.background, in: .rect(cornerRadius: 32))
        .overlay {
            RoundedRectangle(cornerRadius: 32)
                .stroke(Color(white: 0.75), lineWidth: 4)
        }
        .frame(maxWidth: .infinity)
        .environment(\.colorScheme, .light)
        .accessibilityHidden(true)
    }
}

private struct MockCircleButton: View {
    let systemImage: String
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Mock.text)
            .frame(width: size, height: size)
            .background(Mock.card, in: .circle)
            .overlay { Circle().stroke(Color(white: 0.85)) }
    }
}

private struct MockPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.bold())
            .foregroundStyle(Mock.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Mock.card, in: .capsule)
            .overlay { Capsule().stroke(Color(white: 0.85)) }
    }
}

private struct MockLargeTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.title3.bold())
            .foregroundStyle(Mock.text)
    }
}

private struct MockListRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(Mock.blue)
                .frame(width: 22)
            Text(text)
                .font(.callout)
                .foregroundStyle(Mock.text)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Mock.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// 下から引き出す検索の板
private struct MockSheet<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule()
                .fill(Color(white: 0.8))
                .frame(width: 40, height: 4)
                .frame(maxWidth: .infinity)
            content
        }
        .padding(12)
        .background(Color(white: 0.97), in: .rect(cornerRadius: 24))
        .overlay {
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color(white: 0.85))
        }
    }
}

private struct MockSearchField: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
            Text(text.isEmpty ? "検索" : text)
                .foregroundStyle(text.isEmpty ? Mock.secondary : Mock.text)
            Spacer()
        }
        .font(.callout)
        .foregroundStyle(Mock.text)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.89), in: .capsule)
    }
}

private struct MockChip: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.bold())
            .foregroundStyle(Mock.blue)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Mock.card, in: .capsule)
    }
}

private struct MockTriggerRow: View {
    let color: Color
    let title: String
    let example: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.fill")
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.bold())
                    .foregroundStyle(Mock.text)
                Text(example)
                    .font(.caption2)
                    .foregroundStyle(Mock.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Mock.card, in: .rect(cornerRadius: 14))
    }
}

private struct MockTimeRow: View {
    let time: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.fill")
                .foregroundStyle(.orange)
            Text(time)
                .font(.callout)
                .foregroundStyle(Mock.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Mock.blue.opacity(0.12), in: .rect(cornerRadius: 8))
            Text("に")
                .font(.callout.bold())
                .foregroundStyle(Mock.text)
            Image(systemName: "chevron.right.circle")
                .foregroundStyle(Mock.blue)
                .highlight(showsHand: true)
            Spacer()
        }
        .padding(10)
        .background(Mock.card, in: .capsule)
    }
}

/// 入れたアクション「監視を開始」の行
private struct MockActionRow: View {
    var body: some View {
        HStack(spacing: 10) {
            AppMark(size: 24)
            Text("監視を開始")
                .font(.callout.bold())
                .foregroundStyle(Mock.text)
            Spacer()
        }
        .padding(10)
        .background(Mock.card, in: .capsule)
    }
}

private struct MockSettingRow<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(Mock.text)
            Spacer()
            trailing
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct MockToggle: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? Color.green : Color(white: 0.85))
            .frame(width: 44, height: 26)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .padding(2)
            }
    }
}
