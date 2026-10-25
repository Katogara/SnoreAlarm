import AudioToolbox

/// 指定時間、バイブレーションを繰り返す。
/// `kSystemSoundID_Vibrate` はバックグラウンド (画面ロック中) でも動作する。
@MainActor
final class VibrationAlarm {
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    /// - Parameter onFinish: 時間いっぱい振動し終えたときに呼ばれる (`stop()` した場合は呼ばれない)
    func start(duration: TimeInterval, onFinish: @escaping @MainActor () -> Void = {}) {
        stop()
        task = Task { [weak self] in
            let end = Date().addingTimeInterval(duration)
            while Date() < end, !Task.isCancelled {
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                try? await Task.sleep(for: .milliseconds(700))
            }
            guard !Task.isCancelled else { return }
            self?.task = nil
            onFinish()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
