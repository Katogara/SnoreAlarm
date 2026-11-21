import SwiftUI

/// 始め忘れの防止で「アプリを自動で開く」を選んだ人に、ショートカットアプリでオートメーションを作る手順を
/// 1画面ずつ絵を見せながら案内する (パケざんの案内と同じ作り。iOS 27 の画面に合わせている)。
/// 絵は実際の画面を写したものではなく、押す所が分かるように描いた見本。
/// オートメーションの中身は「必要なら監視を開始」(iOS 26 から) だけ。夜の時間帯で、まだ監視していないときだけ
/// いびきアラームを前面に出して監視を始める (実機で、確認の画面なしに前面に出ることを確かめた。2026-11-21)。
/// iPhone がロック中だとアプリを開けないため、ロックが解除されている場面 (アプリを開いた・充電器につないだ) をきっかけにする
struct AutomationTutorialView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// ショートカットアプリと行き来しても続きから見られるよう、見ていたページを覚えておく
    @AppStorage("automationTutorialPage3") private var page = 0

    /// 手順の数 (0 ページ目は前置き、最後のページは完了)
    static let stepCount = 5
    /// オートメーションに入れるアクションの名前 (`StartMonitoringIfNeededIntent` の表示名)
    static let actionName = "必要なら監視を開始"

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

    // MARK: - ページ

    @ViewBuilder
    private var content: some View {
        switch page {
        case 0: intro
        case 1: newAutomation
        case 2: addAction
        case 3: chooseApp
        case 4: confirm
        case 5: charger
        default: finished
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppMark(size: 120)
                .frame(maxWidth: .infinity)
            Text("アプリを自動で開く設定")
                .font(.title2.bold())
                .frame(maxWidth: .infinity)
            PhraseText("寝る前に YouTube などのアプリを開いたとき、まだ監視していなければ、いびきアラームが自動で開いて監視を始めるようにします。")
            PhraseText("自動で始めるのは、夜の時間帯（\(windowText)）だけです。昼間や、すでに監視しているときは何も起きません。")
            PhraseText("iPhone がロックされているあいだは、iPhone の決まりでアプリを開けません。そのため、iPhone を触っている場面をきっかけにします。")
            VStack(alignment: .leading, spacing: 8) {
                Label("かかる時間：5分ほど", systemImage: "clock")
                Label("作るもの：オートメーション2つ", systemImage: "list.number")
            }
            PhraseText("夜の時間帯は設定の「お知らせ」から「自動終了」までの時刻です。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            PhraseText("このガイドとショートカットアプリを行き来しながら進めます。いびきアラームに戻ってくると、続きのページから見られます。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var newAutomation: some View {
        StepPage(title: "オートメーションを新しく作る",
                 message: "下のボタンでショートカットアプリを開きます。「ライブラリ」の画面で「オートメーション」を押し（①）、いちばん下のまん中の「＋」を押します（②）。出てきた画面で、右上の「編集」を押してください。",
                 tip: "ほかの画面が出たときは、左上の「＜」を何回か押して「ライブラリ」に戻ってください。以前このガイドで作ったオートメーションや、ショートカット「いびきをみはる」が残っていれば、ここで消してください。左にすべらせると消せます。") {
            Button {
                if let url = URL(string: "shortcuts://") { openURL(url) }
            } label: {
                Label("ショートカットアプリを開く", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
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

    private var addAction: some View {
        StepPage(title: "「\(Self.actionName)」を入れる",
                 message: "画面の下にある検索欄を、指で上に引き出します。「いびき」と入れると出てくる「\(Self.actionName)」を押してください。",
                 tip: "検索欄は画面の下のふちに小さく隠れています。下のふちに指を置いて、上へすっとなぞると出てきます。「監視を開始」や「監視が必要か調べる」ではなく、「\(Self.actionName)」を選んでください。") {
            MockScreen {
                MockSheet {
                    MockSearchField(text: "いびき")
                    MockNamedAction(title: Self.actionName)
                        .highlight()
                    MockNamedAction(title: "監視を開始")
                    MockNamedAction(title: "監視が必要か調べる")
                }
            }
        }
    }

    private var chooseApp: some View {
        StepPage(title: "きっかけを「アプリ」にする",
                 message: "もう一度検索欄を引き出し、青い「オートメーション」を押します（①）。下へ送り、「アプリ」の欄にある「アプリ」を押してください（②）。いちばん上に行が増えたら、行の中のアプリの名前を押して、寝る前によく使うアプリ（YouTube、Kindle など）をすべて選びます。",
                 tip: "いびきアラーム自身は選ばないでください。") {
            MockScreen {
                MockSheet {
                    MockSearchField(text: "")
                    HStack(spacing: 6) {
                        MockChip(systemImage: "clock", text: "オートメーション").highlight(number: 1)
                        MockChip(systemImage: "curlybraces", text: "スクリプティング")
                    }
                    VStack(spacing: 6) {
                        MockTriggerRow(color: .gray, title: "アプリ", example: "“‘天気’が開かれたかまたは閉じられたとき”").highlight(number: 2)
                        MockTriggerRow(color: .gray, title: "充電器", example: "“このデバイスが電源に接続されたとき”")
                    }
                }
            }
        }
    }

    private var confirm: some View {
        StepPage(title: "「開いた」ときにする",
                 message: "行の中の「開いたまたは閉じた」を押し、「開いた」を選びます（①）。次に、行の右の「⌄」を押して、「オートメーション」がオンになっているかを確かめてください（②）。",
                 tip: "「通知」はオフのままで大丈夫です。") {
            MockScreen {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text("YouTube ほか")
                            .font(.caption)
                            .foregroundStyle(Mock.blue)
                        Text("が")
                            .font(.caption.bold())
                            .foregroundStyle(Mock.text)
                        Text("開いた")
                            .font(.caption)
                            .foregroundStyle(Mock.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Mock.blue.opacity(0.12), in: .rect(cornerRadius: 6))
                            .highlight(number: 1)
                        Text("とき")
                            .font(.caption.bold())
                            .foregroundStyle(Mock.text)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    MockSettingRow(title: "オートメーション") { MockToggle(isOn: true) }
                        .highlight(number: 2)
                    MockSettingRow(title: "通知") { MockToggle(isOn: false) }
                }
                .background(Mock.card, in: .rect(cornerRadius: 14))
                MockNamedAction(title: Self.actionName)
            }
            PhraseText("確かめたら、左上の「＜」で戻ります。「オートメーション」の一覧に出ていれば、1つ目のオートメーションの完成です。")
        }
    }

    private var charger: some View {
        StepPage(title: "充電器のオートメーションも作る",
                 message: "手順 1〜4 をもう一度くり返し、きっかけだけを変えます。手順 3 で「電力」の欄にある「充電器」を選び、電源に「接続された」ときにしてください。",
                 tip: "寝る前に、iPhone を手に持ったまま充電器につないだときに働きます。") {
            Label {
                PhraseText("2つ目：「充電器」が「接続された」とき、「\(Self.actionName)」")
            } icon: {
                Image(systemName: "battery.100.bolt")
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
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
                PhraseText("・いびきアラームの画面に切り替わったあと、元のアプリに戻るには、画面の下のふちを右へなぞってください。監視は続きます。")
                PhraseText("・iPhone を手に持っているあいだは、いびきを数えません。iPhone を置いて\(Int(SnoreMonitor.resumeAfterStill / 60))分たつか、画面をロックして\(Int(SnoreMonitor.resumeAfterLock / 60))分たつと数え始めます。")
                PhraseText("・夜の時間帯に一度も iPhone を触らなかった夜は、自動では始められません。その夜の翌朝 \(MonitoringSchedule.timeText(window.endMinutes)) に「昨夜は監視していませんでした」とお知らせします。")
                PhraseText("・勝手に開くのをやめたいときは、設定の「始め忘れの防止」を「通知で知らせる」に変えてください。オートメーションが残っていても開かなくなります。")
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
