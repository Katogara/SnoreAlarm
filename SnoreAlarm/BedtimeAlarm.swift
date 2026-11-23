import Foundation
#if canImport(AlarmKit)
import AlarmKit
import AppIntents
import SwiftUI
#endif

/// 始め忘れの防止の「アラームで知らせる」(iOS 26 から)。お知らせの時刻に、時計アプリの目覚ましと同じように
/// 止めるまで音と振動で知らせる (マナーモードや集中モードでも鳴る)。アラームの「監視を開始」で、アプリを開いて監視を始める。
/// 1 日ずつ 7 日先まで予約し、監視を始めた夜と休む夜は予約しない (`MonitoringSchedule.alarmDates`)。
/// 予約し直すたびに、このアプリのアラームをすべて取り消してから入れ直す
@MainActor
enum BedtimeAlarm {
    enum Authorization {
        case notDetermined, authorized, denied, unsupported
    }

    /// この iOS で使えるか
    static var isSupported: Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    static var authorization: Authorization {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *) {
            switch AlarmManager.shared.authorizationState {
            case .authorized: return .authorized
            case .denied: return .denied
            case .notDetermined: return .notDetermined
            @unknown default: return .denied
            }
        }
        #endif
        return .unsupported
    }

    static var isAuthorized: Bool { authorization == .authorized }

    /// まだ聞いていなければ、アラームを使う許可を求める
    static func requestAuthorization() async -> Authorization {
        #if canImport(AlarmKit)
        if #available(iOS 26.0, *), AlarmManager.shared.authorizationState == .notDetermined {
            do {
                _ = try await AlarmManager.shared.requestAuthorization()
            } catch {
                DiagnosticLog.write("alarm authorization failed \(error)")
            }
        }
        #endif
        return authorization
    }

    /// 前の予約し直しが終わるのを待ってから次を始め、取り消しと予約が入り混じらないようにする
    private static var task: Task<Void, Never>?

    /// このアプリのアラームを `dates` に入れ替える (空ならすべて取り消す)
    static func reschedule(at dates: [Date]) {
        #if canImport(AlarmKit)
        guard #available(iOS 26.0, *), AlarmManager.shared.authorizationState == .authorized else { return }
        let previous = task
        task = Task {
            await previous?.value
            await BedtimeAlarmScheduler.replace(with: dates)
        }
        #endif
    }
}

#if canImport(AlarmKit)
@available(iOS 26.0, *)
struct BedtimeAlarmMetadata: AlarmMetadata {}

@available(iOS 26.0, *)
@MainActor
private enum BedtimeAlarmScheduler {
    static func replace(with dates: [Date]) async {
        let manager = AlarmManager.shared
        let existing = (try? manager.alarms) ?? []
        for alarm in existing {
            try? manager.cancel(id: alarm.id)
        }
        var scheduled = 0
        for date in dates {
            do {
                _ = try await manager.schedule(id: UUID(), configuration: configuration(at: date))
                scheduled += 1
            } catch {
                DiagnosticLog.write("alarm schedule failed \(error)")
            }
        }
        DiagnosticLog.write("alarms: cancelled \(existing.count), scheduled \(scheduled)"
            + (dates.first.map { " next=\($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
    }

    private static func configuration(at date: Date) -> AlarmManager.AlarmConfiguration<BedtimeAlarmMetadata> {
        let alert = AlarmPresentation.Alert(
            title: "いびきの監視を始めましょう",
            stopButton: AlarmButton(text: "止める", textColor: .white, systemImageName: "xmark"),
            secondaryButton: AlarmButton(text: "監視を開始", textColor: .white, systemImageName: "ear"),
            secondaryButtonBehavior: .custom)
        let attributes = AlarmAttributes<BedtimeAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: BedtimeAlarmMetadata(),
            tintColor: .indigo)
        return AlarmManager.AlarmConfiguration(
            countdownDuration: nil,
            schedule: .fixed(date),
            attributes: attributes,
            stopIntent: nil,
            secondaryIntent: StartMonitoringFromAlarmIntent())
    }
}

/// アラームの「監視を開始」ボタン。アプリを開いて監視を始める (すでに監視中なら何もしない)
@available(iOS 26.0, *)
struct StartMonitoringFromAlarmIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "アラームから監視を開始"
    static var openAppWhenRun = true
    static var isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        DiagnosticLog.write("alarm: start monitoring")
        await SnoreMonitor.shared.startUnlessMonitoring(source: .alarm)
        return .result()
    }
}
#endif
