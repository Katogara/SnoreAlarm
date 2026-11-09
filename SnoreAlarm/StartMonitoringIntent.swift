import AppIntents

/// ショートカットのオートメーションから呼ぶ「監視を開始」。監視を始め忘れた夜のために、決まった時刻に自動で始める。
/// マイクの録音はアプリが前面にないと始められないため、アプリを開いてから始める。すでに監視中なら何もしない
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

/// ショートカットアプリに、設定なしで「監視を開始」を出す
struct SnoreAlarmShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartMonitoringIntent(),
                    phrases: ["\(.applicationName)で監視を開始"],
                    shortTitle: "監視を開始",
                    systemImageName: "ear")
    }
}
