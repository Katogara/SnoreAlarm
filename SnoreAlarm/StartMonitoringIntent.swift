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

#if compiler(>=6.2)
/// ショートカットの「必要なら監視を開始」(iOS 26 から)。裏で動いて監視が必要かを調べ、必要なときだけアプリを前面に出して監視を始める。
/// 「監視が必要か調べる」と「if文」と「監視を開始」を組み合わせたショートカットを、利用者に作ってもらわずに済ませるためのもの。
/// 前面に出るとき、iOS が利用者に確認を求めることがある (`alwaysConfirm: false` は「確認しないことがある」という指定)。
/// 実機で確認が出るかを見るため、診断ログに前後を書く
@available(iOS 26.0, *)
struct StartMonitoringIfNeededIntent: AppIntent {
    static var title: LocalizedStringResource = "必要なら監視を開始"
    static var description = IntentDescription("夜の時間帯に入っていて、まだ監視していなければ、いびきアラームを開いて監視を始めます。昼間や、すでに監視しているときは何もしません。")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @MainActor
    func perform() async throws -> some IntentResult {
        let monitor = SnoreMonitor.shared
        guard monitor.checkMonitoringNeeded() else { return .result() }
        if systemContext.currentMode == .background {
            guard systemContext.currentMode.canContinueInForeground else {
                DiagnosticLog.write("start-if-needed: cannot continue in foreground")
                return .result()
            }
            DiagnosticLog.write("start-if-needed: continueInForeground")
            do {
                try await continueInForeground(alwaysConfirm: false)
            } catch {
                DiagnosticLog.write("start-if-needed: continueInForeground failed \(error)")
                throw error
            }
            DiagnosticLog.write("start-if-needed: now foreground")
        }
        await monitor.startUnlessMonitoring(source: .automation)
        return .result()
    }
}
#endif

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
