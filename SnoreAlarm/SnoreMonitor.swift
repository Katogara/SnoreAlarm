import AVFoundation
import LocalAuthentication
import Observation
import UIKit

/// マイク監視・いびき検出・バイブレーションをまとめて管理する。
@MainActor
@Observable
final class SnoreMonitor {
    /// アプリ全体で 1 つ (ショートカットの「監視を開始」からも使う)
    static let shared = SnoreMonitor()

    enum State: Equatable {
        case idle
        case waiting(until: Date)
        case monitoring
        case alarming
    }

    struct LogEntry: Identifiable {
        enum Kind { case info, snore, noise, alarm }

        let id = UUID()
        let date = Date()
        let kind: Kind
        let message: String
        /// このいびきの録音 (保存が終わると入る)
        var recordingURL: URL?
    }

    private(set) var state: State = .idle
    private(set) var levelDB: Float = -100
    private(set) var thresholdDB: Float?
    private(set) var snoreCount = 0
    /// いびきの条件に近いが、途切れ途切れのためいびきに数えなかった物音の回数
    private(set) var noiseCount = 0
    /// 休止中に拾った、いびきの条件に合った音の回数 (数えずに録音した)
    private(set) var pausedSoundCount = 0
    private(set) var alarmCount = 0
    /// iPhone を手に持って使っているため、いびきを数えるのを休止している (`updatePause`)
    private(set) var isPausedForScreen = false
    private(set) var startedAt: Date?
    private(set) var log: [LogEntry] = []
    /// いびき検知デモの実行中 (マイクは使わない)
    private(set) var isDemo = false
    /// 自動終了する時刻 (監視中で、お知らせ・自動終了がオンのとき)
    private(set) var scheduledEnd: Date?
    /// 今回の監視で Apple Watch に通知を送った回数
    private(set) var watchAlertCount = 0
    /// Watch で知らせる設定なのに iPhone で振動した回数 (届かないと分かっていたとき・Watch で起きなかったとき)
    private(set) var iPhoneFallbackCount = 0
    /// Apple Watch で知らせるうえでの問題 (Watch で知らせる設定のときだけ調べる)
    private(set) var watchProblems: [WatchProblem] = []
    var errorMessage: String?

    /// 文はほかの言語に訳せるよう、文の切れ端をつながず、1 文ずつ丸ごと持つ
    struct WatchProblem: Hashable {
        enum Kind: Hashable {
            case notPaired
            case notificationsDenied
            case soundOff
        }

        let kind: Kind

        /// Watch に届かないことが確実 (iPhone で振動する)
        var isBlocking: Bool { kind != .soundOff }
        /// このアプリの通知設定で直せる
        var fixInNotificationSettings: Bool { kind != .notPaired }

        /// 問題と、そのためにどうなるか (メイン画面に出す)
        var summary: String {
            switch kind {
            case .notPaired: String(localized: "Apple Watch がペアリングされていないため、Watch には届きません (iPhone で振動します)")
            case .notificationsDenied: String(localized: "通知が許可されていないため、Watch には届きません (iPhone で振動します)")
            case .soundOff: String(localized: "このアプリの通知のサウンドがオフになっているため、Watch が振動しないことがあります")
            }
        }

        /// 監視の開始時のログ
        var logMessage: String {
            switch kind {
            case .soundOff: String(localized: "このアプリの通知のサウンドがオフになっているため、Watch が振動しないことがあります (メイン画面の「通知の設定を開く」から直せます)")
            default: summary
            }
        }

        /// Watch に届かないため iPhone で振動したときのログ
        var fallbackMessage: String {
            switch kind {
            case .notPaired: String(localized: "Apple Watch がペアリングされていないため、iPhone で振動しました")
            case .notificationsDenied: String(localized: "通知が許可されていないため、iPhone で振動しました")
            case .soundOff: String(localized: "このアプリの通知のサウンドがオフになっているため、iPhone で振動しました")
            }
        }
    }

    /// マイクを使い始める直前に呼ぶ (録音の再生を止めるため)
    @ObservationIgnored var onWillUseMicrophone: (@MainActor () -> Void)?

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let vibrator = VibrationAlarm()
    @ObservationIgnored private var processor: AudioProcessor?
    @ObservationIgnored private var recorder: SnoreRecorder?
    @ObservationIgnored private var savedRecordings = 0
    @ObservationIgnored private var settings = AlarmSettings()
    @ObservationIgnored private var schedule = AlarmSettings.load().schedule
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var scheduleTask: Task<Void, Never>?
    @ObservationIgnored private var demoTask: Task<Void, Never>?
    @ObservationIgnored private var demoBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// デモのあいだ、画面ロック中も動けるよう録音を動かしている (`startDemoAudio`)
    @ObservationIgnored private var demoUsesAudio = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let notifier = AlarmNotifier()
    @ObservationIgnored private let watchLink = WatchLink()
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var lastWatchAlarmAt: Date?
    @ObservationIgnored private var watchAlarmSerial = 0
    @ObservationIgnored private var healthTask: Task<Void, Never>?
    /// マイク入力が止まっていると判断してから、まだ再開できていない
    @ObservationIgnored private var inputStalled = false
    /// 画面が見えなくなった時刻と、そのときのいびきの回数 (戻ったときに、その間の様子をログに出す)
    @ObservationIgnored private var backgroundSince: Date?
    @ObservationIgnored private var snoreCountAtBackground = 0
    @ObservationIgnored private var stallsInBackground = 0
    /// iPhone を手に持っているか (加速度センサー)
    @ObservationIgnored private let handling = HandlingMonitor()
    /// 画面を使わなくなった (ロックした) 時刻
    @ObservationIgnored private var screenIdleSince: Date?
    /// 画面を使い始めた時刻
    @ObservationIgnored private var screenInUseSince: Date?
    /// 休止を始めた時刻
    @ObservationIgnored private var pausedSince: Date?
    /// 休止が `maxPause` 続いて数え始めた。画面をロックするまで、手に持っていても休止しない
    @ObservationIgnored private var pauseLimitReached = false

    /// この秒数マイク入力が来なければ、止まったとみなして再開する
    static let inputStallSeconds: TimeInterval = 10
    /// 画面をロックしてから、いびきを数え始めるまでの秒数。眠りに入るのはロックしてしばらくあとなので、
    /// 起きているあいだの物音 (画面のタップなど) をいびきと間違えないよう、それまでは数えない
    static let resumeAfterLock: TimeInterval = 3 * 60
    /// 画面を使用中でも、iPhone がこの秒数動かなければ (置いたまま動画や音楽を流しているなど) 数え始める
    static let resumeAfterStill: TimeInterval = 5 * 60
    /// 休止はこの秒数までにする。迷ったら数える側に倒し、黙って一晩検知しないことを防ぐ
    static let maxPause: TimeInterval = 30 * 60

    var isActive: Bool { state != .idle }

    init() {
        // 通知の「振動を止める」ボタン
        notifier.onStop = { [weak self] in self?.dismissAlarm() }
        // 寝る時刻のお知らせの「監視を開始」ボタン・お知らせのタップ
        notifier.onStart = { [weak self] in
            guard let self else { return }
            Task { await self.startFromReminder() }
        }
        RecordingStore.deleteExpiredInBackground()
        DiagnosticLog.write("app launched")
    }

    /// 画面に表示されていない (ロック中・他のアプリを使用中など)
    private var isInBackground: Bool {
        UIApplication.shared.applicationState != .active
    }

    /// 画面に表示されていないが、iPhone の画面は点いている (他のアプリを使用中)。
    /// パスコードを設定していると、ロックしてから 10 秒ほどで保護データが使えなくなるので、それで見分ける。
    /// パスコードがないと見分けられないため、ロック中とみなす
    private var isUsingOtherApp: Bool {
        guard isInBackground, UIApplication.shared.isProtectedDataAvailable else { return false }
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// 画面を使用中 (このアプリを表示中か、他のアプリを使用中)
    private var isScreenInUse: Bool {
        !isInBackground || isUsingOtherApp
    }

    /// iPhone を手に持って使っているあいだは、いびきを数えるのを休止する (検知と録音は続け、振動だけしない)。
    /// - 画面を使用中で、手に持って動かしている → 休止。`resumeAfterStill` 動かなければ数え始める
    /// - 画面をロックした → ロックから `resumeAfterLock` たったら数え始める
    /// - 休止が `maxPause` 続いた → 数え始め、画面をロックするまで休止しない
    /// 監視の開始時、画面の表示が切り替わったとき、`runHealthCheck` の 5 秒ごとに呼ぶ
    private func updatePause() {
        guard state != .idle, !isDemo else { return }
        let now = Date()
        if isScreenInUse {
            screenIdleSince = nil
            let inUseSince = screenInUseSince ?? now
            screenInUseSince = inUseSince
            handling.start()
            // 加速度センサーがない端末では動きが分からないため、画面を使っているあいだは手に持っているとみなす
            let lastHandled = max(handling.lastMotionDate ?? inUseSince, inUseSince)
            let isStill = handling.isAvailable && now.timeIntervalSince(lastHandled) >= Self.resumeAfterStill
            if isPausedForScreen, let since = pausedSince, now.timeIntervalSince(since) >= Self.maxPause {
                pauseLimitReached = true
                endPause("休止が\(Int(Self.maxPause / 60))分続いたため、いびきを数え始めました (画面をロックするまで休止しません)")
            } else if isPausedForScreen && isStill {
                endPause("iPhone を置いて\(Int(Self.resumeAfterStill / 60))分たったため、いびきを数え始めました")
            } else if !isPausedForScreen && !isStill && !pauseLimitReached {
                beginPause(at: now)
            }
            return
        }
        screenInUseSince = nil
        pauseLimitReached = false
        handling.stop()
        let since = screenIdleSince ?? now
        screenIdleSince = since
        if isPausedForScreen && now.timeIntervalSince(since) >= Self.resumeAfterLock {
            endPause("画面をロックして\(Int(Self.resumeAfterLock / 60))分たったため、いびきを数え始めました")
        }
    }

    private func beginPause(at date: Date) {
        isPausedForScreen = true
        pausedSince = date
        PauseStore.begin(at: date)
        append(.info, "iPhone を手に持って使っているため、いびきを数えるのを休止しています (いびきに似た音は録音します。iPhone を置いて\(Int(Self.resumeAfterStill / 60))分たつか、画面をロックして\(Int(Self.resumeAfterLock / 60))分たつと数え始めます)")
    }

    private func endPause(_ message: String.LocalizationValue) {
        isPausedForScreen = false
        pausedSince = nil
        PauseStore.end()
        // 休止中に拾った音をいびきの回数に入れない
        processor?.resetHistory()
        append(.info, message)
    }

    // MARK: - 開始 / 停止

    /// 監視を始めたきっかけ (ログに出す)
    enum StartSource {
        case manual
        /// 寝る時刻のお知らせ
        case reminder
        /// ショートカットのオートメーション (`StartMonitoringIntent`)
        case automation
        /// おやすみコール (`BedtimeAlarm`) の「監視を開始」
        case alarm

        var message: String.LocalizationValue {
            switch self {
            case .manual: "監視を開始しました"
            case .reminder: "寝る時刻のお知らせから監視を開始しました"
            case .automation: "ショートカットのオートメーションから監視を開始しました"
            case .alarm: "おやすみコールから監視を開始しました"
            }
        }
    }

    func start(source: StartSource = .manual) async {
        guard state == .idle else { return }
        errorMessage = nil

        // サブスクリプションに登録していなければ、監視せずに登録の画面を出す
        // (おやすみコールなどから裏で呼ばれたときは、次にアプリを開いたときに出る)
        let subscription = SubscriptionStore.shared
        if SubscriptionStore.isRequired {
            await subscription.refresh()
        }
        guard subscription.canMonitor else {
            DiagnosticLog.write("start blocked: not subscribed (\(source))")
            subscription.isPaywallPresented = true
            return
        }
        guard state == .idle else { return }

        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = String(localized: "マイクへのアクセスが許可されていません。「設定」アプリ > プライバシーとセキュリティ > マイク から許可してください。")
            return
        }
        let notificationsAllowed = await notifier.requestAuthorization()
        await refreshWatchReadiness()
        guard state == .idle else { return }

        // 再生中なら止める
        onWillUseMicrophone?()
        settings = AlarmSettings.load()
        schedule = settings.schedule
        savedRecordings = 0
        RecordingStore.deleteExpiredInBackground()
        do {
            try configureSession()
            try startEngine()
        } catch {
            errorMessage = String(localized: "マイクを開始できませんでした: \(error.localizedDescription)")
            teardown()
            return
        }

        observeSystemNotifications()
        scheduledEnd = schedule.isEnabled ? schedule.nextEnd(after: Date()) : nil
        resetAlarmCounts()
        log.removeAll()
        startedAt = Date()
        MonitoringSessionStore.begin()
        append(.info, source.message)
        if let scheduledEnd {
            append(.info, "\(scheduledEnd.formatted(date: .omitted, time: .shortened)) に自動で終了します")
        }
        appendAlertDeviceStatus(notificationsAllowed: notificationsAllowed)

        if settings.startDelayMinutes > 0 {
            let until = Date().addingTimeInterval(TimeInterval(settings.startDelayMinutes * 60))
            state = .waiting(until: until)
            processor?.setSuppressed(true)
            append(.info, "\(settings.startDelayMinutes)分後から検知します")
            resumeDetection(after: TimeInterval(settings.startDelayMinutes * 60))
        } else {
            state = .monitoring
        }
        updatePause()
        runScheduleTimer()
        runHealthCheck()
        updateReminders()
    }

    /// 監視中、マイク入力が止まっていないかを定期的に確かめ、止まっていれば再開する。
    /// 監視していることの記録 (`MonitoringSessionStore.touch`) もここで更新する。
    private func runHealthCheck() {
        healthTask?.cancel()
        inputStalled = false
        healthTask = Task { [weak self] in
            var lastTouch = Date()
            var lastStatus = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self, self.state != .idle, !self.isDemo else { return }
                if Date().timeIntervalSince(lastTouch) >= MonitoringSessionStore.heartbeatInterval {
                    MonitoringSessionStore.touch()
                    lastTouch = Date()
                }
                if DiagnosticLog.isEnabled && Date().timeIntervalSince(lastStatus) >= 60 {
                    DiagnosticLog.write("status: " + self.diagnosticStatus())
                    lastStatus = Date()
                }
                self.checkInput()
                self.updatePause()
            }
        }
    }

    /// 診断ログ用の現在の状態 (アプリ・画面ロック・オーディオセッション・マイク入力)
    private func diagnosticStatus() -> String {
        let session = AVAudioSession.sharedInstance()
        let app: String
        switch UIApplication.shared.applicationState {
        case .active: app = "active"
        case .inactive: app = "inactive"
        case .background: app = "background"
        @unknown default: app = "unknown"
        }
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue)" }.joined(separator: ",")
        let lastInput = processor?.lastInputDate.map { String(format: "%.1fs ago", Date().timeIntervalSince($0)) } ?? "none"
        return "state=\(state) app=\(app) protectedData=\(UIApplication.shared.isProtectedDataAvailable) "
            + "engine=\(engine.isRunning) lastInput=\(lastInput) inputs=[\(inputs)] inputAvailable=\(session.isInputAvailable) "
            + "inputMuted=\(AVAudioApplication.shared.isInputMuted) category=\(session.category.rawValue) "
            + "mode=\(session.mode.rawValue) otherAudio=\(session.isOtherAudioPlaying) snores=\(snoreCount) alarms=\(alarmCount) "
            + "alertDevice=\(AlarmSettings.load().alertDevice.rawValue)"
    }

    private func checkInput() {
        let lastInput = processor?.lastInputDate
        // 作り直した直後はまだ入力がないため、作った時刻から数える
        let silentFor = Date().timeIntervalSince(lastInput ?? processor?.createdAt ?? .distantPast)
        guard silentFor >= Self.inputStallSeconds else {
            if inputStalled && lastInput != nil {
                inputStalled = false
                append(.info, "マイクの入力が戻りました")
            }
            return
        }
        if !inputStalled {
            inputStalled = true
            if backgroundSince != nil {
                stallsInBackground += 1
            }
            append(.info, "マイクの入力が\(Int(silentFor.rounded()))秒止まっていたため、再開します")
        }
        restartAudio(reason: "入力の停止", quietly: true)
    }

    private func resetAlarmCounts() {
        snoreCount = 0
        noiseCount = 0
        pausedSoundCount = 0
        alarmCount = 0
        watchAlertCount = 0
        iPhoneFallbackCount = 0
        lastWatchAlarmAt = nil
    }

    /// 監視・デモの開始時に、どの端末で知らせるかと、Watch で知らせるうえでの問題をログに出す
    private func appendAlertDeviceStatus(notificationsAllowed: Bool) {
        let device = AlarmSettings.load().alertDevice
        guard device.usesWatch else {
            if !notificationsAllowed {
                append(.info, "通知が許可されていないため、画面ロック中は振動だけで知らせます")
            }
            return
        }
        if device == .both {
            append(.info, "Apple Watch と iPhone の両方で知らせます。iPhone の画面をロック (自動ロックで可) し、Watch を着けたままにしてください")
        } else {
            append(.info, "Apple Watch で知らせます。iPhone の画面をロック (自動ロックで可) し、Watch を着けたままにしてください")
        }
        for problem in watchProblems {
            appendText(.info, problem.logMessage)
        }
    }

    func stop() {
        guard state != .idle else { return }
        if isDemo {
            finishDemo("デモを終了しました")
            return
        }
        finishMonitoring("監視を終了しました")
    }

    private func finishMonitoring(_ message: String.LocalizationValue) {
        append(.info, message)
        MonitoringSessionStore.end()
        teardown()
        updateReminders()
    }

    // MARK: - 寝る時刻のお知らせ・自動終了

    /// お知らせ・自動終了の設定を読み直して反映する。アプリが前面に来たときと、設定画面を閉じたときに呼ぶ。
    /// 監視が始まるまでマイクは使わない (イヤホンのマイクや、画面上部のマイク使用中の表示に影響しないように)。
    func applySchedule() {
        schedule = AlarmSettings.load().schedule
        if state != .idle && !isDemo {
            scheduledEnd = schedule.isEnabled ? schedule.nextEnd(after: Date()) : nil
            runScheduleTimer()
        }
        if schedule.isEnabled {
            // お知らせを出すための許可 (2 回目以降はダイアログを出さない)
            Task { _ = await notifier.requestAuthorization() }
        }
        updateReminders()
    }

    /// 寝る時刻のお知らせから監視を始める。デモ中ならデモを終えてから始める。
    private func startFromReminder() async {
        await startUnlessMonitoring(source: .reminder)
    }

    /// お知らせやオートメーションから監視を始める。すでに監視中なら何もしない。デモ中ならデモを終えてから始める。
    func startUnlessMonitoring(source: StartSource) async {
        if isDemo {
            finishDemo("デモを終了しました (監視を開始するため)")
        }
        guard state == .idle else { return }
        await start(source: source)
    }

    // MARK: - あとでもう一度鳴らす

    /// 「あとでもう一度鳴らす」で選べる時間 (分)
    static let snoozeChoices = [15, 30]

    /// あとでもう一度鳴らすおやすみコールの時刻。監視を始めると消す
    private(set) var snoozeAlarmAt: Date? = SnoreMonitor.savedSnooze()

    nonisolated private static func savedSnooze() -> Date? {
        let value = UserDefaults.standard.double(forKey: AlarmSettings.Key.snoozeAlarmAt)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    private func setSnooze(_ date: Date?) {
        snoozeAlarmAt = date
        if let date {
            UserDefaults.standard.set(date.timeIntervalSince1970, forKey: AlarmSettings.Key.snoozeAlarmAt)
        } else {
            UserDefaults.standard.removeObject(forKey: AlarmSettings.Key.snoozeAlarmAt)
        }
    }

    /// お風呂などで、まだ監視を始めたくないとき。監視を始めずに (監視中なら終えて)、`minutes` 分後にもう一度
    /// おやすみコールで知らせる
    func snoozeBedtimeAlarm(minutes: Int) {
        let date = Date().addingTimeInterval(TimeInterval(minutes * 60))
        if isDemo {
            finishDemo("デモを終了しました")
        }
        let message: String.LocalizationValue = "\(date.formatted(date: .omitted, time: .shortened)) にもう一度アラームで知らせます"
        if state != .idle {
            // 監視を終えてから予約する (監視中のままだと、予約したアラームを消してしまうため)
            append(.info, "監視を終了しました")
            MonitoringSessionStore.end()
            teardown()
        }
        setSnooze(date)
        append(.info, message)
        updateReminders()
    }

    /// あとでもう一度鳴らすアラームを取り消す
    func cancelSnooze() {
        guard snoozeAlarmAt != nil else { return }
        setSnooze(nil)
        append(.info, "もう一度鳴らすアラームを取り消しました")
        updateReminders()
    }

    /// 監視中に終了時刻まで待つ。時計の変更にも追従できるよう、1 分ごとに起きて時刻を確かめる。
    private func runScheduleTimer() {
        scheduleTask?.cancel()
        scheduleTask = nil
        guard let target = scheduledEnd else { return }
        scheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                let remaining = target.timeIntervalSinceNow
                if remaining <= 0 { break }
                try? await Task.sleep(for: .seconds(min(remaining, 60)))
            }
            guard !Task.isCancelled, let self else { return }
            await self.scheduleTimerFired()
        }
    }

    private func scheduleTimerFired() async {
        scheduleTask = nil
        if let end = scheduledEnd, Date() >= end, state != .idle, !isDemo {
            finishMonitoring("終了時刻になったため監視を終了しました")
        }
    }

    /// 寝る時刻のお知らせ (またはアラーム) と、「昨夜は監視していませんでした」の知らせを予約し直す。
    /// 監視中はその夜の残りのお知らせを出さず、監視した夜の翌朝の知らせも出さない。休む夜はどれも出さない。
    private func updateReminders() {
        // サブスクリプションに登録していなければ監視を始められないため、お知らせもアラームも予約しない
        guard SubscriptionStore.shared.canMonitor else {
            notifier.scheduleReminders(at: [])
            BedtimeAlarm.reschedule(at: [])
            notifier.scheduleMissedNightNotices(at: [])
            return
        }
        let isMonitoring = state != .idle && !isDemo
        let monitoringUntil = isMonitoring ? scheduledEnd : nil
        // 「アラームで知らせる」は、アラームの許可があれば通知の代わりにアラームを鳴らす (許可がなければ通知で知らせる)
        let useAlarm = UserDefaults.standard.bool(forKey: AlarmSettings.Key.bedtimeAlarmEnabled) && BedtimeAlarm.isAuthorized
        notifier.scheduleReminders(at: useAlarm ? [] : schedule.reminderDates(after: Date(), monitoringUntil: monitoringUntil))
        // 監視を始めたら、あとでもう一度鳴らすアラームは要らない
        if let snooze = snoozeAlarmAt, isMonitoring || snooze <= Date() {
            setSnooze(nil)
        }
        var alarmDates = useAlarm ? schedule.alarmDates(after: Date(), monitoringUntil: monitoringUntil) : []
        if useAlarm, let snooze = schedule.snoozeAlarmDate(snoozeAlarmAt, now: Date(), isMonitoring: isMonitoring) {
            alarmDates.append(snooze)
            alarmDates.sort()
        }
        BedtimeAlarm.reschedule(at: alarmDates)
        // 翌朝の知らせは、始め忘れの防止で「アプリを自動で開く」を選んだ人にだけ出す
        notifier.scheduleMissedNightNotices(at: AlarmSettings.autoOpenEnabled()
            ? schedule.missedNightDates(after: Date(), sessions: MonitoringSessionStore.load(), isMonitoring: isMonitoring)
            : [])
    }

    /// ショートカットの「監視が必要か調べる」(`CheckMonitoringNeededIntent`)。アプリの画面は開かずに裏で呼ばれる。
    /// 夜の時間帯に入っていて、まだ監視していなければ true。始め忘れの防止で「アプリを自動で開く」を選んでいなければ、いつも false
    func checkMonitoringNeeded() -> Bool {
        let firstTime = UserDefaults.standard.object(forKey: AlarmSettings.Key.automationCheckedAt) == nil
        UserDefaults.standard.set(Date(), forKey: AlarmSettings.Key.automationCheckedAt)
        schedule = AlarmSettings.load().schedule
        let isMonitoring = state != .idle && !isDemo
        let autoOpen = AlarmSettings.autoOpenEnabled()
        let needed = autoOpen && schedule.needsMonitoring(at: Date(), isMonitoring: isMonitoring)
        DiagnosticLog.write("automation check: needed=\(needed) monitoring=\(isMonitoring) autoOpen=\(autoOpen)")
        if firstTime {
            // 初めて動いたときに、翌朝の知らせの予約を始める
            updateReminders()
        }
        return needed
    }

    // MARK: - いびき検知デモ

    /// 監視していないときだけ、設定どおりの条件でいびきを検知したときの動作を再現する。
    /// デモ中に画面をロックしても、iOS が許す間 (30秒程度) は続けて通知と振動を試せる。
    func startDemo() async {
        guard state == .idle else { return }
        errorMessage = nil
        let notificationsAllowed = await notifier.requestAuthorization()
        await refreshWatchReadiness()
        guard state == .idle else { return }
        settings = AlarmSettings.load()
        resetAlarmCounts()
        log.removeAll()
        startedAt = Date()
        isDemo = true
        state = .monitoring
        append(.info, "デモを開始しました (\(settings.windowSeconds)秒以内に\(settings.requiredSnores)回のいびきで振動)")
        appendAlertDeviceStatus(notificationsAllowed: notificationsAllowed)
        // 画面をロックしても止まらないよう、監視と同じくマイクの録音を動かしておく (音はデモに使わない)。
        // 録音中でなければ、iOS がバックグラウンドで動ける 30 秒ほどでデモが止まり、ロック中の iPhone の振動も出ない。
        // マイクを使えないときだけ、バックグラウンドの時間をもらって動かす
        if !startDemoAudio() {
            demoBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SnoreDemo") { [weak self] in
                MainActor.assumeIsolated { self?.finishDemo("デモを終了しました (バックグラウンドの制限時間)") }
            }
        }

        // Watch で知らせる設定なら Watch に通知する。Watch に届くのは iPhone の画面がロックされているときだけなので、
        // 画面がロックされてから、いびきを始める
        let usesWatch = settings.alertDevice.usesWatch
        if usesWatch {
            append(.info, "Apple Watch で知らせるデモです。すぐに iPhone の画面をロックしてください (画面が点いていると iPhone で振動します)")
        }
        let frames = DemoSignal.frames(for: settings)
        let config = settings.detectorConfig
        demoTask = Task { [weak self] in
            if usesWatch {
                // ロックしないまま `demoLockTimeout` 秒たったら、そのまま始める
                let deadline = Date().addingTimeInterval(Self.demoLockTimeout)
                while Date() < deadline {
                    guard !Task.isCancelled, let self, self.isDemo else { return }
                    if self.isInBackground { break }
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            var detector = SnoreDetector(config: config)
            // 画面ロック中は短い待ちが間引かれて遅れるため、1 フレームずつ待たずに、過ぎた時間の分をまとめて流す
            let start = Date()
            var next = 0
            while next < frames.count {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.isDemo, self.state == .monitoring else { return }
                let elapsed = Date().timeIntervalSince(start)
                while next < frames.count, frames[next].time <= elapsed {
                    let frame = frames[next]
                    next += 1
                    let events = detector.process(frame)
                    self.levelDB = frame.levelDB
                    self.thresholdDB = detector.thresholdDB
                    for event in events {
                        switch event {
                        case .snore(let snore):
                            self.snoreCount += 1
                            self.append(.snore, "[デモ] いびきを検知 (\(Self.seconds(snore.duration))秒, \(Self.decibels(snore.peakDB)) dB)")
                        case .noise:
                            break
                        case .alarm(let count):
                            self.alarmCount += 1
                            self.append(.alarm, "[デモ] \(count)回のいびきを検知したため振動しました")
                            self.startAlarm(snoreCount: count)
                            return
                        }
                    }
                }
            }
            guard !Task.isCancelled, let self, self.isDemo else { return }
            self.finishDemo("デモを終了しました (振動の条件に達しませんでした)")
        }
    }

    private func finishDemo(_ message: String.LocalizationValue) {
        demoTask?.cancel()
        demoTask = nil
        if watchTask != nil {
            notifier.clearWatchAlerts()
        }
        watchTask?.cancel()
        watchTask = nil
        vibrator.stop()
        isDemo = false
        state = .idle
        levelDB = -100
        thresholdDB = nil
        append(.info, message)
        if demoBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(demoBackgroundTask)
            demoBackgroundTask = .invalid
        }
        if demoUsesAudio {
            demoUsesAudio = false
            stopEngine()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    /// デモのあいだ、画面をロックしてもアプリが止まらないよう録音を動かす。マイクの音は捨てる。
    /// マイクが許可されていない・使えないときは false
    private func startDemoAudio() -> Bool {
        guard AVAudioApplication.shared.recordPermission == .granted else { return false }
        do {
            try configureSession()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                return false
            }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { _, _ in }
            engine.prepare()
            try engine.start()
            demoUsesAudio = true
            return true
        } catch {
            DiagnosticLog.write("demo audio start failed: \(error)")
            stopEngine()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            return false
        }
    }

    /// 振動中に画面や通知 (Watch からも) で止めた場合
    func dismissAlarm() {
        guard state == .alarming else { return }
        watchTask?.cancel()
        vibrator.stop()
        // 自分で止めた = 起きたので、次のアラームで「Watch では起きなかった」とみなして iPhone を振動させない
        lastWatchAlarmAt = nil
        if !isDemo {
            AlarmEventStore.markLastStopped()
        }
        append(.info, "アラームを止めました")
        finishAlarm()
    }

    /// 一晩の記録に出すため、振動したことを残す (デモは残さない)
    private func recordAlarm(_ device: AlarmEventStore.Event.Device) {
        guard !isDemo else { return }
        AlarmEventStore.record(device)
    }

    func testVibration() {
        switch state {
        case .alarming:
            return
        case .monitoring:
            processor?.setSuppressed(true)
            vibrator.start(duration: 2) { [weak self] in
                self?.resumeDetection(after: 2)
            }
        case .idle, .waiting:
            vibrator.start(duration: 2)
        }
    }

    private func teardown() {
        resumeTask?.cancel()
        resumeTask = nil
        scheduleTask?.cancel()
        scheduleTask = nil
        scheduledEnd = nil
        healthTask?.cancel()
        healthTask = nil
        inputStalled = false
        backgroundSince = nil
        if isPausedForScreen {
            PauseStore.end()
        }
        isPausedForScreen = false
        pausedSince = nil
        pauseLimitReached = false
        screenIdleSince = nil
        screenInUseSince = nil
        handling.stop()
        if watchTask != nil {
            notifier.clearWatchAlerts()
        }
        watchTask?.cancel()
        watchTask = nil
        vibrator.stop()
        removeObservers()
        stopEngine()
        processor = nil
        recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .idle
        levelDB = -100
        thresholdDB = nil
    }

    // MARK: - オーディオ

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        // .measurement: 自動ゲイン調整などを無効にして音量を安定して測る
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker])
        // 録音中はデフォルトでバイブレーションが抑制されるため、明示的に許可する
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try session.setActive(true)
    }

    /// マイク入力のタップを付け直してエンジンを開始する。
    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "SnoreAlarm", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "マイク入力が見つかりません")])
        }

        let processor = AudioProcessor(sampleRate: format.sampleRate, config: settings.detectorConfig) { [weak self] output in
            Task { @MainActor in self?.handle(output) }
        }
        processor.setSuppressed(state == .alarming || isWaiting)
        processor.setReportsLevels(!isInBackground)
        self.processor = processor
        // 検出と同じ時刻の基準で音を保持するため、AudioProcessor と同時に作り直す
        let recorder = settings.recordSnores ? SnoreRecorder(inputFormat: format) : nil
        self.recorder = recorder

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            recorder?.append(buffer)
            processor.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            DiagnosticLog.write("engine start failed: \(error) status: \(diagnosticStatus())")
            throw error
        }
        DiagnosticLog.write("engine started: \(format.sampleRate)Hz \(format.channelCount)ch status: \(diagnosticStatus())")
    }

    private func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// - Parameter quietly: 入力の停止から定期的に再開を試みる場合。失敗の知らせは 1 回だけにする
    private func restartAudio(reason: String.LocalizationValue, quietly: Bool = false) {
        let reason = String(localized: reason)
        // デモはマイクを使わない
        guard state != .idle, !isDemo else { return }
        stopEngine()
        do {
            try configureSession()
            try startEngine()
            if !quietly {
                append(.info, "マイクを再開しました (\(reason))")
            }
        } catch {
            // 失敗しても監視中のままにし、runHealthCheck で再開を試み続ける
            if quietly && errorMessage != nil { return }
            errorMessage = String(localized: "マイクを再開できませんでした: \(error.localizedDescription)")
            append(.info, "マイクの再開に失敗しました (\(reason))。再開を試み続けます")
            if isInBackground {
                notifier.notify(title: String(localized: "いびきの監視が止まっています"),
                                body: String(localized: "マイクを再開できませんでした。アプリを開くと再開を試みます。"))
            }
        }
    }

    private func didEnterBackground() {
        processor?.setReportsLevels(false)
        guard state != .idle, !isDemo else { return }
        backgroundSince = Date()
        snoreCountAtBackground = snoreCount
        stallsInBackground = 0
        processor?.resetLongestGap()
        updatePause()
    }

    /// 画面に戻ったとき、ロック中・他のアプリを使用中だった間の様子をログに出し、マイクが止まっていれば再開する
    private func willEnterForeground() {
        processor?.setReportsLevels(true)
        guard state != .idle, !isDemo else { return }
        if let since = backgroundSince {
            let seconds = Int(Date().timeIntervalSince(since))
            if seconds >= 20 {
                let span = seconds >= 60 ? String(localized: "\(seconds / 60)分") : String(localized: "\(seconds)秒")
                // アプリごと止められていた場合は stallsInBackground を数えられないため、入力の間隔でも確かめる
                let gap = processor?.longestInputGap ?? 0
                let input: String
                if stallsInBackground > 0 {
                    input = String(localized: "マイク入力が\(stallsInBackground)回止まりました")
                } else if gap >= Self.inputStallSeconds {
                    input = gap >= 60 ? String(localized: "マイク入力が最長\(Int(gap / 60))分途切れました")
                        : String(localized: "マイク入力が最長\(Int(gap.rounded()))秒途切れました")
                } else {
                    input = String(localized: "マイク入力は正常")
                }
                append(.info, "画面をロック中・ほかのアプリを使用中だった\(span)間: いびき\(snoreCount - snoreCountAtBackground)回を検知 (\(input))")
            }
        }
        backgroundSince = nil
        checkInput()
        updatePause()
    }

    private var isWaiting: Bool {
        if case .waiting = state { return true }
        return false
    }

    private func observeSystemNotifications() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // 電話などで中断された後に再開する
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            DiagnosticLog.write("interruption: \(note.userInfo ?? [:])")
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            MainActor.assumeIsolated {
                switch type {
                case .began:
                    // 終了の知らせが来ないこともあるため、再開は runHealthCheck でも試みる
                    self?.append(.info, "マイクがほかの機能 (電話・Siri など) に中断されました")
                case .ended:
                    self?.restartAudio(reason: "中断から復帰")
                @unknown default:
                    break
                }
            }
        })
        // イヤホンの抜き差しなどで入力構成が変わったとき
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange,
                                            object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAudio(reason: "入力の変更") }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartAudio(reason: "オーディオのリセット") }
        })
        // 画面が見えない間は入力レベルの表示更新を止める (電池消費と発熱を抑える)
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didEnterBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willEnterForeground() }
        })
        #if DIAGNOSTICS
        // 不具合の調査用: 画面ロック・オーディオ経路・メモリ不足など、検知に影響しうる出来事を記録する
        let diagnosticEvents: [Notification.Name] = [
            AVAudioSession.routeChangeNotification,
            AVAudioSession.mediaServicesWereLostNotification,
            AVAudioSession.mediaServicesWereResetNotification,
            AVAudioSession.silenceSecondaryAudioHintNotification,
            .AVAudioEngineConfigurationChange,
            UIApplication.protectedDataWillBecomeUnavailableNotification,
            UIApplication.protectedDataDidBecomeAvailableNotification,
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willEnterForegroundNotification,
            UIApplication.didBecomeActiveNotification,
            UIApplication.willResignActiveNotification,
            UIApplication.didReceiveMemoryWarningNotification,
            UIApplication.willTerminateNotification,
        ]
        for name in diagnosticEvents {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    let info = note.userInfo.map { " \($0)" } ?? ""
                    DiagnosticLog.write("event \(note.name.rawValue)\(info) status: \(self?.diagnosticStatus() ?? "-")")
                }
            })
        }
        #endif
    }

    private func removeObservers() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    // MARK: - 検出結果

    private func handle(_ output: AudioProcessor.Output) {
        guard state != .idle else { return }
        levelDB = output.levelDB
        thresholdDB = output.thresholdDB

        for event in output.events {
            switch event {
            case .snore(let snore) where isPausedForScreen:
                // 休止中は数えず、いびきを見逃していないかを朝に確かめられるよう録音だけする
                pausedSoundCount += 1
                let logID = append(.noise, "休止中に、いびきに似た音を検知 (数えずに録音します。\(Self.seconds(snore.duration))秒, \(Self.decibels(snore.peakDB)) dB)")
                saveRecording(of: snore, kind: .paused, logID: logID)
            case .snore(let snore):
                snoreCount += 1
                let logID = append(.snore, "いびきを検知 (\(Self.seconds(snore.duration))秒, \(Self.decibels(snore.peakDB)) dB)")
                saveRecording(of: snore, logID: logID)
            case .noise(let noise):
                noiseCount += 1
                let logID = append(.noise, "物音を検知 (途切れ途切れの音のため、いびきに数えません。\(Self.seconds(noise.duration))秒, \(Self.decibels(noise.peakDB)) dB)")
                saveRecording(of: noise, kind: .noise, logID: logID)
            case .alarm(let count):
                guard state == .monitoring, !isPausedForScreen else { continue }
                alarmCount += 1
                append(.alarm, "\(count)回のいびきを検知したため振動しました")
                startAlarm(snoreCount: count)
            }
        }
    }

    private func startAlarm(snoreCount count: Int) {
        state = .alarming
        // 振動音をマイクが拾っていびきと誤検知しないよう、振動中は検出を止める
        processor?.setSuppressed(true)
        let duration = TimeInterval(settings.vibrationSeconds)
        let title = isDemo ? String(localized: "[デモ] いびきを検知しました") : String(localized: "いびきを検知しました")
        let window = settings.windowSeconds
        let vibration = settings.vibrationSeconds
        let vibrateBody = String(localized: "\(window)秒以内に\(count)回のいびきを検知しました。\(vibration)秒間振動します。")
        // 知らせる端末は監視中に切り替えても次のアラームから反映する
        let device = AlarmSettings.load().alertDevice
        if device.usesWatch {
            alertWithWatch(duration: duration, title: title,
                           body: String(localized: "\(window)秒以内に\(count)回のいびきを検知しました。寝返りを打ってください。"),
                           iPhoneBody: vibrateBody,
                           alsoIPhone: device == .both)
            return
        }
        recordAlarm(.iPhone)
        vibrateIPhone(duration: duration)
        if isInBackground {
            notifier.notify(title: title, body: vibrateBody, stoppable: true)
        }
    }

    /// ログに出す秒数 (小数 1 桁) と音量
    private static func seconds(_ value: Double) -> String { String(format: "%.1f", value) }
    private static func decibels(_ value: Float) -> String { String(format: "%.0f", value) }

    /// デモのときはログの頭に「[デモ]」を付ける
    private func appendAlert(_ message: String.LocalizationValue) {
        let text = String(localized: message)
        appendText(.info, isDemo ? String(localized: "[デモ] ") + text : text)
    }

    private func vibrateIPhone(duration: TimeInterval) {
        vibrator.start(duration: duration) { [weak self] in
            self?.finishAlarm()
        }
    }

    /// Apple Watch で知らせる (`WatchAlert`)。届かないと分かっているときは iPhone で振動する。
    /// - Parameters:
    ///   - iPhoneBody: Watch に届かず、他のアプリを使用中に iPhone で振動するときの通知の本文
    ///   - alsoIPhone: iPhone も同時に振動させる (両方で知らせる設定)。どちらの通知や画面で止めても両方止まる
    private func alertWithWatch(duration: TimeInterval, title: String, body: String, iPhoneBody: String,
                                alsoIPhone: Bool = false) {
        // パスコードを設定していると、ロックしてから 10 秒ほどは「ほかのアプリを使用中」と見分けがつかない。
        // デモはロックしてもらってから始めるので、裏に回っていればロック中とみなす
        let usingOtherApp = isDemo ? false : isUsingOtherApp
        if !isInBackground || usingOtherApp {
            // iPhone の画面が点いているあいだは、通知が Watch に転送されない
            if !alsoIPhone {
                iPhoneFallbackCount += 1
            }
            if usingOtherApp {
                appendAlert("ほかのアプリを使用中のため iPhone で振動しました (Watch に届くのは iPhone の画面がロックされているときだけです)")
            } else {
                appendAlert("画面を表示中のため iPhone で振動しました (Watch に届くのは iPhone の画面がロックされているときだけです)")
            }
            recordAlarm(.iPhone)
            vibrateIPhone(duration: duration)
            if usingOtherApp {
                notifier.notify(title: title, body: iPhoneBody, stoppable: true)
            }
            return
        }
        if let issue = watchProblems.first(where: \.isBlocking) {
            if !alsoIPhone {
                iPhoneFallbackCount += 1
            }
            appendText(.info, isDemo ? String(localized: "[デモ] ") + issue.fallbackMessage : issue.fallbackMessage)
            recordAlarm(.iPhone)
            vibrateIPhone(duration: duration)
            return
        }

        let now = Date()
        if alsoIPhone {
            appendAlert("iPhone を振動させました")
            recordAlarm(.both)
            vibrator.start(duration: duration)
        } else if settings.watchFallback && WatchAlert.needsFallback(lastWatchAlarm: lastWatchAlarmAt, now: now) {
            iPhoneFallbackCount += 1
            appendAlert("Watch で知らせたあともいびきが続いたため、iPhone も振動させました")
            recordAlarm(.both)
            vibrator.start(duration: duration)
        } else {
            recordAlarm(.watch)
        }
        lastWatchAlarmAt = now
        watchAlertCount += 1
        watchAlarmSerial += 1
        let alarm = watchAlarmSerial
        appendAlert("Apple Watch に通知を送りました")
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            let start = Date()
            for (tap, offset) in WatchAlert.tapOffsets(duration: duration).enumerated() {
                try? await Task.sleep(for: .seconds(max(offset - Date().timeIntervalSince(start), 0)))
                guard !Task.isCancelled, let self, self.state == .alarming else { return }
                self.notifier.notifyWatch(title: title, body: body, alarm: alarm, tap: tap)
            }
            try? await Task.sleep(for: .seconds(max(duration - Date().timeIntervalSince(start), 0)))
            guard !Task.isCancelled, let self, self.state == .alarming else { return }
            self.vibrator.stop()
            self.finishAlarm()
        }
    }

    /// 「Watch に届くかテスト」で OK を押してから通知を出すまでの秒数 (その間に iPhone をロックしてもらう)
    nonisolated static let watchTestDelay: TimeInterval = 5
    /// Apple Watch のデモで、「開始」を押してから画面をロックするまでのおおよその秒数 (案内に出す秒数の見積もりに使う)
    nonisolated static let demoLockDelay: TimeInterval = 3
    /// 通知を出してから Watch が振動し始めるまでのおおよその秒数 (デモの実機で約 5 秒。2026-11-26)
    nonisolated static let demoWatchArrival: TimeInterval = 5
    /// Apple Watch のデモで、画面のロックを待つ長さ。過ぎたら、ロックしていなくてもいびきを始める
    nonisolated static let demoLockTimeout: TimeInterval = 20
    /// OK を押してから Watch が振動するまでのおおよその秒数 (通知を出してから Watch に届くまでにも数秒かかる。実機で 8〜10 秒)
    nonisolated static let watchTestArrival: TimeInterval = 10

    /// Watch に届くかを試す (watchTestDelay 秒後に通知。そのあいだに iPhone の画面をロックしてもらう)。
    /// 時刻を指定した通知の予約は iOS の都合で遅れることがあるため、画面をロックしても少しの間動ける
    /// バックグラウンドの時間をもらい、アプリから時刻どおりに出す
    func testWatchAlert() async {
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "WatchTest")
        defer { UIApplication.shared.endBackgroundTask(backgroundTask) }
        _ = await notifier.requestAuthorization()
        await refreshWatchReadiness()
        try? await Task.sleep(for: .seconds(Self.watchTestDelay))
        notifier.notifyWatchTest()
    }

    /// 知らせる端末を選んだときに呼ぶ。Watch なら通知の許可を求めてから (Watch には通知で知らせるため)、状態を調べ直す。
    func prepareAlerts() async {
        if AlarmSettings.load().alertDevice.usesWatch {
            _ = await notifier.requestAuthorization()
        }
        await refreshWatchReadiness()
    }

    /// Apple Watch で知らせられるかを調べ直す。Watch を選んだとき・アプリを開いたとき・監視を始めるときに呼ぶ。
    func refreshWatchReadiness() async {
        guard AlarmSettings.load().alertDevice.usesWatch else {
            watchProblems = []
            return
        }
        var paired = watchLink.isPaired
        if paired == nil {
            // 起動直後は Watch との接続の確認が終わっていないことがある
            try? await Task.sleep(for: .seconds(1))
            paired = watchLink.isPaired
        }
        let readiness = await AlarmNotifier.readiness()
        var problems: [WatchProblem] = []
        if paired == false {
            problems.append(WatchProblem(kind: .notPaired))
        }
        if !readiness.authorized {
            problems.append(WatchProblem(kind: .notificationsDenied))
        } else if !readiness.soundEnabled {
            // サウンドなしの通知では Watch が振動しないことがある
            problems.append(WatchProblem(kind: .soundOff))
        }
        watchProblems = problems
    }

    private func finishAlarm() {
        watchTask = nil
        // Watch 向けの通知はアラームの間は消さずに残しているので、ここでまとめて消す
        notifier.clearWatchAlerts()
        if isDemo {
            finishDemo("デモを終了しました")
            return
        }
        state = .monitoring
        resumeDetection(after: 2)
    }

    private func resumeDetection(after seconds: TimeInterval) {
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            if self.isWaiting {
                self.state = .monitoring
                self.append(.info, "検知を開始しました")
            }
            self.processor?.setSuppressed(false)
        }
    }

    /// いびき (または物音) の前後の音を切り出して保存し、終わったらログに録音を結び付ける。
    private func saveRecording(of snore: SnoreEvent, kind: RecordingStore.Kind = .snore, logID: UUID) {
        guard let recorder, savedRecordings < RecordingStore.maxPerSession else { return }
        let samples = recorder.clip(start: snore.start, duration: snore.duration)
        guard !samples.isEmpty else { return }
        savedRecordings += 1
        if savedRecordings == RecordingStore.maxPerSession {
            append(.info, "録音が\(RecordingStore.maxPerSession)件に達したため、今回はこれ以上録音しません")
        }
        RecordingStore.save(samples, date: Date(), kind: kind) { [weak self] url in
            guard let self, let url, let index = self.log.firstIndex(where: { $0.id == logID }) else { return }
            self.log[index].recordingURL = url
        }
    }

    /// ログに足す。文は画面の言語に訳す
    @discardableResult
    private func append(_ kind: LogEntry.Kind, _ message: String.LocalizationValue) -> UUID {
        appendText(kind, String(localized: message))
    }

    /// 訳し終えた文をログに足す
    @discardableResult
    private func appendText(_ kind: LogEntry.Kind, _ message: String) -> UUID {
        let entry = LogEntry(kind: kind, message: message)
        DiagnosticLog.write("log[\(kind)]: \(message)")
        log.insert(entry, at: 0)
        if log.count > 500 {
            log.removeLast(log.count - 500)
        }
        return entry.id
    }
}
