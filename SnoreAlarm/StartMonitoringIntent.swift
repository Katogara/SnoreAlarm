import AppIntents

/// ショートカットのオートメーションから呼ぶ「監視を開始」。監視を始め忘れた夜のために、自動で始める。
/// マイクの録音はアプリが前面にないと始められないため、アプリを開いてから始める。すでに監視中なら何もしない。
/// iPhone がロック中だとアプリを開けずに失敗するため、「監視が必要か調べる」と組み合わせて、
/// ロックが解除されている場面 (ほかのアプリを開いたときなど) をきっかけに使う
struct StartMonitoringIntent: AppIntent {
    static var title: LocalizedStringResource = "監視を開始"
    static var description = IntentDescription("いびきアラームを開いて、いびきの監視を始めます。すでに監視中なら何もしません。")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        await SnoreMonitor.shared.startUnlessMonitoring(source: .automation)
        return .result()
    }
}

/// ショートカットの「監視が必要か調べる」。アプリを開かずに裏で動き、夜の時間帯に入っていて、まだ監視していなければ true を返す。
/// オートメーションで「もし 監視が必要 なら 監視を開始」と組み合わせ、監視中や昼間にアプリが前面に出ないようにする
struct CheckMonitoringNeededIntent: AppIntent {
    static var title: LocalizedStringResource = "監視が必要か調べる"
    static var description = IntentDescription("夜の時間帯に入っていて、まだ監視していなければ「はい」を返します。いびきアラームの画面は開きません。")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let needed = SnoreMonitor.shared.checkMonitoringNeeded()
        return .result(value: needed)
    }
}

/// ショートカットアプリに、設定なしで「監視を開始」と「監視が必要か調べる」を出す
struct SnoreAlarmShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartMonitoringIntent(),
                    phrases: ["\(.applicationName)で監視を開始"],
                    shortTitle: "監視を開始",
                    systemImageName: "ear")
        AppShortcut(intent: CheckMonitoringNeededIntent(),
                    phrases: ["\(.applicationName)で監視が必要か調べる"],
                    shortTitle: "監視が必要か調べる",
                    systemImageName: "questionmark.circle")
    }
}
