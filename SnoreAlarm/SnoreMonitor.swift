import AVFoundation
import Observation
import UIKit

/// マイク監視・いびき検出・バイブレーションをまとめて管理する。
@MainActor
@Observable
final class SnoreMonitor {
    enum State: Equatable {
        case idle
        case waiting(until: Date)
        case monitoring
        case alarming
    }

    struct LogEntry: Identifiable {
        enum Kind { case info, snore, alarm }

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
    private(set) var alarmCount = 0
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

    struct WatchProblem: Hashable {
        /// 「〜ため」に続く形の説明
        let message: String
        /// Watch に届かないことが確実 (iPhone で振動する)
        let isBlocking: Bool
        /// このアプリの通知設定で直せる
        var fixInNotificationSettings = false
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

    /// この秒数マイク入力が来なければ、止まったとみなして再開する
    static let inputStallSeconds: TimeInterval = 10

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

    // MARK: - 開始 / 停止

    /// - Parameter fromReminder: 寝る時刻のお知らせから開始した
    func start(fromReminder: Bool = false) async {
        guard state == .idle else { return }
        errorMessage = nil

        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "マイクへのアクセスが許可されていません。「設定」アプリ > プライバシーとセキュリティ > マイク から許可してください。"
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
            errorMessage = "マイクを開始できませんでした: \(error.localizedDescription)"
            teardown()
            return
        }

        observeSystemNotifications()
        scheduledEnd = schedule.isEnabled ? schedule.nextEnd(after: Date()) : nil
        resetAlarmCounts()
        log.removeAll()
        startedAt = Date()
        MonitoringSessionStore.begin()
        append(.info, fromReminder ? "寝る時刻のお知らせから監視を開始しました" : "監視を開始しました")
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
            append(.info, String(format: "マイクの入力が%.0f秒止まっていたため、再開します", silentFor))
        }
        restartAudio(reason: "入力の停止", quietly: true)
    }

    private func resetAlarmCounts() {
        snoreCount = 0
        alarmCount = 0
        watchAlertCount = 0
        iPhoneFallbackCount = 0
        lastWatchAlarmAt = nil
    }

    /// 監視・デモの開始時に、どの端末で知らせるかと、Watch で知らせるうえでの問題をログに出す
    private func appendAlertDeviceStatus(notificationsAllowed: Bool) {
        guard AlarmSettings.load().alertDevice == .watch else {
            if !notificationsAllowed {
                append(.info, "通知が許可されていないため、画面ロック中は振動だけで知らせます")
            }
            return
        }
        append(.info, "Apple Watch で知らせます。iPhone の画面をロック (自動ロックで可) し、Watch を着けたままにしてください")
        for problem in watchProblems {
            append(.info, problem.isBlocking
                   ? "\(problem.message)ため、Watch には届きません (iPhone で振動します)"
                   : "\(problem.message)ため、Watch が振動しないことがあります (メイン画面の「通知の設定を開く」から直せます)")
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

    private func finishMonitoring(_ message: String) {
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
        if isDemo {
            finishDemo("デモを終了しました (監視を開始するため)")
        }
        guard state == .idle else { return }
        await start(fromReminder: true)
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

    /// 寝る時刻のお知らせを予約し直す。監視中はその夜の残りのお知らせを出さない。
    private func updateReminders() {
        let monitoringUntil = (state != .idle && !isDemo) ? scheduledEnd : nil
        notifier.scheduleReminders(at: schedule.reminderDates(after: Date(), monitoringUntil: monitoringUntil))
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
        demoBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SnoreDemo") { [weak self] in
            MainActor.assumeIsolated { self?.finishDemo("デモを終了しました (バックグラウンドの制限時間)") }
        }

        // Watch で知らせる設定なら Watch に通知する。Watch に届くのは iPhone の画面がロックされているときだけなので、
        // いびきが始まるまでを長くして、画面をロックする時間をとる
        let leadIn = DemoSignal.leadIn + (settings.alertDevice == .watch ? Self.watchTestDelay : 0)
        if settings.alertDevice == .watch {
            append(.info, "Apple Watch で知らせるデモです。すぐに iPhone の画面をロックしてください (画面が点いていると iPhone で振動します)")
        }
        let frames = DemoSignal.frames(for: settings, leadIn: leadIn)
        let config = settings.detectorConfig
        demoTask = Task { [weak self] in
            var detector = SnoreDetector(config: config)
            for frame in frames {
                try? await Task.sleep(for: .seconds(frame.duration))
                guard !Task.isCancelled, let self, self.isDemo, self.state == .monitoring else { return }
                let events = detector.process(frame)
                self.levelDB = frame.levelDB
                self.thresholdDB = detector.thresholdDB
                for event in events {
                    switch event {
                    case .snore(let snore):
                        self.snoreCount += 1
                        self.append(.snore, String(format: "[デモ] いびきを検知 (%.1f秒, %.0f dB)", snore.duration, snore.peakDB))
                    case .alarm(let count):
                        self.alarmCount += 1
                        self.append(.alarm, "[デモ] \(count)回のいびきを検知したため振動しました")
                        self.startAlarm(snoreCount: count)
                        return
                    }
                }
            }
            guard !Task.isCancelled, let self, self.isDemo else { return }
            self.finishDemo("デモを終了しました (振動の条件に達しませんでした)")
        }
    }

    private func finishDemo(_ message: String) {
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
                          userInfo: [NSLocalizedDescriptionKey: "マイク入力が見つかりません"])
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
    private func restartAudio(reason: String, quietly: Bool = false) {
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
            errorMessage = "マイクを再開できませんでした: \(error.localizedDescription)"
            append(.info, "マイクの再開に失敗しました (\(reason))。再開を試み続けます")
            if isInBackground {
                notifier.notify(title: "いびきの監視が止まっています",
                                body: "マイクを再開できませんでした。アプリを開くと再開を試みます。")
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
    }

    /// 画面に戻ったとき、見えていなかった間の様子をログに出し、マイクが止まっていれば再開する
    private func willEnterForeground() {
        processor?.setReportsLevels(true)
        guard state != .idle, !isDemo else { return }
        if let since = backgroundSince {
            let seconds = Int(Date().timeIntervalSince(since))
            if seconds >= 20 {
                let span = seconds >= 60 ? "\(seconds / 60)分" : "\(seconds)秒"
                // アプリごと止められていた場合は stallsInBackground を数えられないため、入力の間隔でも確かめる
                let gap = processor?.longestInputGap ?? 0
                let input: String
                if stallsInBackground > 0 {
                    input = "マイク入力が\(stallsInBackground)回止まりました"
                } else if gap >= Self.inputStallSeconds {
                    input = gap >= 60 ? "マイク入力が最長\(Int(gap / 60))分途切れました" : String(format: "マイク入力が最長%.0f秒途切れました", gap)
                } else {
                    input = "マイク入力は正常"
                }
                append(.info, "画面が見えていなかった\(span)間: いびき\(snoreCount - snoreCountAtBackground)回を検知 (\(input))")
            }
        }
        backgroundSince = nil
        checkInput()
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
            case .snore(let snore):
                snoreCount += 1
                let logID = append(.snore, String(format: "いびきを検知 (%.1f秒, %.0f dB)", snore.duration, snore.peakDB))
                saveRecording(of: snore, logID: logID)
            case .alarm(let count):
                guard state == .monitoring else { continue }
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
        let title = isDemo ? "[デモ] いびきを検知しました" : "いびきを検知しました"
        let detected = "\(settings.windowSeconds)秒以内に\(count)回のいびきを検知しました。"
        // 知らせる端末は監視中に切り替えても次のアラームから反映する
        if AlarmSettings.load().alertDevice == .watch {
            alertWithWatch(duration: duration, title: title, body: detected + "寝返りを打ってください。")
            return
        }
        recordAlarm(.iPhone)
        vibrateIPhone(duration: duration)
        if isInBackground {
            notifier.notify(title: title, body: detected + "\(settings.vibrationSeconds)秒間振動します。", stoppable: true)
        }
    }

    private func vibrateIPhone(duration: TimeInterval) {
        vibrator.start(duration: duration) { [weak self] in
            self?.finishAlarm()
        }
    }

    /// Apple Watch で知らせる (`WatchAlert`)。届かないと分かっているときは iPhone で振動する。
    private func alertWithWatch(duration: TimeInterval, title: String, body: String) {
        let prefix = isDemo ? "[デモ] " : ""
        if !isInBackground {
            // iPhone の画面が点いているあいだは、通知が Watch に転送されない
            iPhoneFallbackCount += 1
            append(.info, prefix + "画面を表示中のため iPhone で振動しました (Watch に届くのは iPhone の画面がロックされているときだけです)")
            recordAlarm(.iPhone)
            vibrateIPhone(duration: duration)
            return
        }
        if let issue = watchProblems.first(where: \.isBlocking) {
            iPhoneFallbackCount += 1
            append(.info, prefix + "\(issue.message)ため、iPhone で振動しました")
            recordAlarm(.iPhone)
            vibrateIPhone(duration: duration)
            return
        }

        let now = Date()
        if settings.watchFallback && WatchAlert.needsFallback(lastWatchAlarm: lastWatchAlarmAt, now: now) {
            iPhoneFallbackCount += 1
            append(.info, prefix + "Watch で知らせたあともいびきが続いたため、iPhone も振動させました")
            recordAlarm(.both)
            vibrator.start(duration: duration)
        } else {
            recordAlarm(.watch)
        }
        lastWatchAlarmAt = now
        watchAlertCount += 1
        watchAlarmSerial += 1
        let alarm = watchAlarmSerial
        append(.info, prefix + "Apple Watch に通知を送りました")
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
        if AlarmSettings.load().alertDevice == .watch {
            _ = await notifier.requestAuthorization()
        }
        await refreshWatchReadiness()
    }

    /// Apple Watch で知らせられるかを調べ直す。Watch を選んだとき・アプリを開いたとき・監視を始めるときに呼ぶ。
    func refreshWatchReadiness() async {
        guard AlarmSettings.load().alertDevice == .watch else {
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
            problems.append(WatchProblem(message: "Apple Watch がペアリングされていない", isBlocking: true))
        }
        if !readiness.authorized {
            problems.append(WatchProblem(message: "通知が許可されていない", isBlocking: true,
                                         fixInNotificationSettings: true))
        } else if !readiness.soundEnabled {
            // サウンドなしの通知では Watch が振動しないことがある
            problems.append(WatchProblem(message: "このアプリの通知のサウンドがオフになっている", isBlocking: false,
                                         fixInNotificationSettings: true))
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

    /// いびきの前後の音を切り出して保存し、終わったらログに録音を結び付ける。
    private func saveRecording(of snore: SnoreEvent, logID: UUID) {
        guard let recorder, savedRecordings < RecordingStore.maxPerSession else { return }
        let samples = recorder.clip(start: snore.start, duration: snore.duration)
        guard !samples.isEmpty else { return }
        savedRecordings += 1
        if savedRecordings == RecordingStore.maxPerSession {
            append(.info, "録音が\(RecordingStore.maxPerSession)件に達したため、今回はこれ以上録音しません")
        }
        RecordingStore.save(samples, date: Date()) { [weak self] url in
            guard let self, let url, let index = self.log.firstIndex(where: { $0.id == logID }) else { return }
            self.log[index].recordingURL = url
        }
    }

    @discardableResult
    private func append(_ kind: LogEntry.Kind, _ message: String) -> UUID {
        let entry = LogEntry(kind: kind, message: message)
        DiagnosticLog.write("log[\(kind)]: \(message)")
        log.insert(entry, at: 0)
        if log.count > 500 {
            log.removeLast(log.count - 500)
        }
        return entry.id
    }
}
