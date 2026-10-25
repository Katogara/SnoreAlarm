import SwiftUI

@main
struct SnoreAlarmApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var monitor: SnoreMonitor
    @State private var player: SnorePlayer

    init() {
        let monitor = SnoreMonitor()
        let player = SnorePlayer()
        // 寝る時刻のお知らせからなどでマイクを使い始めるときは、録音の再生を止める
        monitor.onWillUseMicrophone = { player.stop() }
        _monitor = State(initialValue: monitor)
        _player = State(initialValue: player)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(monitor)
                .environment(player)
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // 寝る時刻のお知らせを予約し直す (7 日分なので、アプリを開くたびに先へ延ばす)
            if phase == .active {
                monitor.applySchedule()
                // 「設定」アプリで通知を変えて戻ってきたときに、Watch で知らせられるかを調べ直す
                Task { await monitor.refreshWatchReadiness() }
            }
        }
    }
}
