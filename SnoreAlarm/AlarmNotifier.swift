import UserNotifications

private enum NotificationID {
    static let category = "snoreAlarm"
    static let stopAction = "stopVibration"
    static let reminderCategory = "bedtimeReminder"
    static let startAction = "startMonitoring"
    /// 寝る時刻のお知らせ (1 日 4 回 × 7 日)
    static let maxReminders = 28
    static func reminder(_ index: Int) -> String { "bedtimeReminder-\(index)" }
    /// 以前の版の「自動開始できませんでした」のお知らせ (残っていれば消す)
    static let legacyReminders = (0..<7).map { "scheduleReminder-\($0)" }
    static let watchAlertPrefix = "watchAlert-"
    static func watchAlert(_ alarm: Int, _ tap: Int) -> String { "\(watchAlertPrefix)\(alarm)-\(tap)" }
}

/// バックグラウンドで監視中の出来事 (いびきでの振動など)、Apple Watch での知らせ、寝る時刻のお知らせをローカル通知で行う。
@MainActor
final class AlarmNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// 通知の「振動を止める」が押されたとき
    var onStop: (@MainActor () -> Void)?
    /// 寝る時刻のお知らせの「監視を開始」が押されたとき・お知らせがタップされたとき
    var onStart: (@MainActor () -> Void)?

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        let stop = UNNotificationAction(identifier: NotificationID.stopAction, title: "振動を止める", options: [])
        // マイクは画面に出ているときしか使い始められないため、アプリを開いてから監視を始める
        let start = UNNotificationAction(identifier: NotificationID.startAction, title: "監視を開始", options: [.foreground])
        center.setNotificationCategories([
            // 通知を払いのけた (閉じた) ときも知らせてもらい、振動を止める
            UNNotificationCategory(identifier: NotificationID.category, actions: [stop], intentIdentifiers: [],
                                   options: [.customDismissAction]),
            UNNotificationCategory(identifier: NotificationID.reminderCategory, actions: [start], intentIdentifiers: []),
        ])
        center.delegate = self
    }

    /// 通知の許可を求める (2回目以降はダイアログを出さず現在の状態を返す)。許可されていれば true。
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    /// - Parameter stoppable: 通知に「振動を止める」ボタンを付ける
    func notify(title: String, body: String, stoppable: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = Phrases.wrapped(body)
        // 振動は VibrationAlarm で設定どおりに行うため、通知音は鳴らさない
        content.sound = nil
        if stoppable {
            content.categoryIdentifier = NotificationID.category
        }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Apple Watch で知らせるための通知 (`WatchAlert`)。iPhone の画面ロック中は Watch に転送されて手首が振動する。
    /// 1 回のアラームで何度も送るが、アラームの間は前に送った分を消さない。Watch で「振動を止める」を押すまでに
    /// 次の通知が来て前の通知を消すと、押したボタンが効かなくなるため (アラームが終わったら `clearWatchAlerts` でまとめて消す)。
    /// - Parameters:
    ///   - alarm: アラームの通し番号
    ///   - tap: そのアラームの中で何回目か
    func notifyWatch(title: String, body: String, alarm: Int, tap: Int) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = Phrases.wrapped(body)
        // サウンドなしの通知は Watch に転送されない (実機で確認)。iPhone の画面ロック中は Watch に転送され、iPhone 側は鳴らない。
        // Watch で音を出さないためには Watch を消音モードにしてもらう
        content.sound = .default
        content.categoryIdentifier = NotificationID.category
        center.add(UNNotificationRequest(identifier: NotificationID.watchAlert(alarm, tap), content: content, trigger: nil))
    }

    /// アラームが終わったとき、Watch 向けに送った通知をまとめて消す
    func clearWatchAlerts() {
        let center = center
        center.getDeliveredNotifications { notifications in
            let ids = notifications.map(\.request.identifier).filter { $0.hasPrefix(NotificationID.watchAlertPrefix) }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// Watch に届くかを寝る前に試すための通知 (すぐに出す。待つ時間は呼び出し側でとる)
    func notifyWatchTest() {
        let content = UNMutableNotificationContent()
        content.title = "Apple Watch のテスト"
        content.body = Phrases.wrapped("手首が振動すれば、いびきのときも Watch で知らせられます。")
        content.sound = .default
        center.add(UNNotificationRequest(identifier: "watchTest", content: content, trigger: nil))
    }

    /// Apple Watch で知らせるのに必要な通知の設定
    struct Readiness: Equatable {
        /// 通知の許可をすでに求めた (まだなら許可もサウンドも判定できない)
        var requested: Bool
        var authorized: Bool
        /// このアプリの通知のサウンドがオン (オフだと Watch が振動しない)
        var soundEnabled: Bool

        var isReady: Bool { authorized && soundEnabled }
    }

    /// 準備の画面からも調べるので、インスタンスを持たずに呼べるようにしている
    static func readiness() async -> Readiness {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let authorized = settings.authorizationStatus == .authorized || settings.authorizationStatus == .ephemeral
        return Readiness(requested: settings.authorizationStatus != .notDetermined,
                         authorized: authorized, soundEnabled: settings.soundSetting == .enabled)
    }

    /// 寝る時刻のお知らせを予約し直す。監視を始めたら呼び直して、その夜の残りを取り消す。
    /// 予約は iOS が持つので、アプリを終了していても届く。
    func scheduleReminders(at dates: [Date]) {
        center.removePendingNotificationRequests(withIdentifiers: (0..<NotificationID.maxReminders).map(NotificationID.reminder)
                                                 + NotificationID.legacyReminders)
        for (index, date) in dates.prefix(NotificationID.maxReminders).enumerated() {
            let content = UNMutableNotificationContent()
            content.title = "いびきの監視を始めましょう"
            content.body = Phrases.wrapped("寝る時刻になりました。「監視を開始」を押すか、この通知をタップすると監視を始めます。")
            content.sound = .default
            content.categoryIdentifier = NotificationID.reminderCategory
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            center.add(UNNotificationRequest(identifier: NotificationID.reminder(index), content: content,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        let isReminder = category == NotificationID.reminderCategory
        DiagnosticLog.write("notification response: \(action) id=\(response.notification.request.identifier)")
        // いびきの通知は「振動を止める」だけでなく、タップや払いのけ (閉じる) でも止める
        if action == NotificationID.stopAction
            || (category == NotificationID.category
                && (action == UNNotificationDefaultActionIdentifier || action == UNNotificationDismissActionIdentifier)) {
            Task { @MainActor in self.onStop?() }
        } else if action == NotificationID.startAction
                    || (isReminder && action == UNNotificationDefaultActionIdentifier) {
            Task { @MainActor in self.onStart?() }
        }
        completionHandler()
    }

    /// アプリを開いているときも寝る時刻のお知らせは表示する (いびきの通知は画面に出ているときは出さない)
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if notification.request.content.categoryIdentifier == NotificationID.reminderCategory {
            completionHandler([.banner, .list, .sound])
        } else {
            completionHandler([])
        }
    }
}
