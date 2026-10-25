import Foundation
import WatchConnectivity

/// いびきを知らせる端末
enum AlertDevice: String, CaseIterable, Identifiable {
    /// iPhone 本体の振動 (安定して動く)
    case iPhone = "iphone"
    /// Apple Watch の振動 (パートナーを起こさない)
    case watch

    var id: String { rawValue }
}

/// Apple Watch で知らせる仕組み。
///
/// iPhone の画面がロックされていて、Watch を腕に着けてロックを解除しているとき、iPhone の通知は Watch に転送され、
/// 手首が振動する (iPhone 側は鳴らない)。Watch 用のアプリは作らず、この転送を使う。
/// - iPhone から Watch のアプリを一晩中動かし続ける手段がない。WatchConnectivity のメッセージは、
///   Watch のアプリが前面で動いていないと届かず、Watch のアプリを起こしもしない
/// - Watch の長時間実行のセッション (WKExtendedRuntimeSession) にも、一晩続けられる睡眠向けの種類がない
///
/// 通知は 1 回で短く 1 度振動するだけなので、振動の長さの間、間隔をあけて繰り返し送る。
/// Watch で振動するのは、iPhone の「通知」設定でこのアプリのサウンドがオンのときだけ (サウンドなしの通知は振動しない)。
/// 届いたかどうかは iPhone から確かめられないため、Watch で知らせたあともいびきが続いたら iPhone も振動させられるようにする。
enum WatchAlert {
    /// 最初の数回は短い間隔で送って起こす
    static let quickTaps = 3
    static let quickTapInterval: TimeInterval = 1
    /// そのあとは少し間隔を広げる (実機で、4.5 秒おきでは起きられず、2 秒以下が必要だった)
    static let slowTapInterval: TimeInterval = 2
    /// 前回 Watch で知らせてからこの時間内にまたアラームになったら、Watch では起きなかったとみなす
    static let fallbackWindow: TimeInterval = 5 * 60

    /// 振動の長さ `duration` の間に通知を送る時刻 (アラーム開始からの秒)
    static func tapOffsets(duration: TimeInterval) -> [TimeInterval] {
        let end = max(duration, 1)
        var offsets: [TimeInterval] = []
        var offset: TimeInterval = 0
        while offset < end {
            offsets.append(offset)
            offset += offsets.count < quickTaps ? quickTapInterval : slowTapInterval
        }
        return offsets
    }

    /// Watch で知らせたあとも、いびきが続いてまたアラームになったか
    static func needsFallback(lastWatchAlarm: Date?, now: Date) -> Bool {
        guard let lastWatchAlarm else { return false }
        return now.timeIntervalSince(lastWatchAlarm) <= fallbackWindow
    }
}

/// Apple Watch とペアリングされているかを調べる (Watch 用のアプリがなくても分かる)。
final class WatchLink: NSObject, WCSessionDelegate {
    private let session: WCSession? = WCSession.isSupported() ? .default : nil

    override init() {
        super.init()
        session?.delegate = self
        session?.activate()
    }

    /// ペアリング済みか。まだ確かめられない (起動直後など) ときは nil
    var isPaired: Bool? {
        guard let session, session.activationState == .activated else { return nil }
        return session.isPaired
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // 別の Watch に切り替えたとき
        session.activate()
    }
}
