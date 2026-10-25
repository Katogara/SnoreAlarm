import Foundation

/// いびき検知デモ用の疑似音声 (フレーム特徴量の列)。
///
/// 静かな部屋で、設定した回数のいびきが判定時間内に続く状況を再現する。
/// 実際の `SnoreDetector` に流すので、感度・回数・判定時間は監視中と同じ条件で判定される。
enum DemoSignal {
    /// 実際のマイク入力と同じフレーム長 (48kHz で 2048 サンプル)
    static let frameDuration = 2048.0 / 48000.0
    static let quietDB: Float = -60
    static let quietRatio: Float = 0.3
    static let snoreRatio: Float = 0.8
    static let leadIn: TimeInterval = 2
    static let snoreSeconds: TimeInterval = 1
    static let pauseSeconds: TimeInterval = 1.5

    /// 感度のしきい値より 10dB 大きいいびき
    static func snoreDB(for sensitivity: Sensitivity) -> Float {
        quietDB + sensitivity.marginDB + 10
    }

    /// アラームになるまでのおおよその秒数
    static func secondsUntilAlarm(for settings: AlarmSettings, leadIn: TimeInterval = leadIn) -> TimeInterval {
        leadIn + Double(settings.requiredSnores) * (snoreSeconds + pauseSeconds) - pauseSeconds
    }

    /// - Parameter leadIn: いびきが始まるまでの静かな時間 (Apple Watch で試すときは、画面をロックする時間をとるため長くする)
    static func frames(for settings: AlarmSettings, leadIn: TimeInterval = leadIn) -> [FrameFeatures] {
        var segments: [(seconds: TimeInterval, db: Float, ratio: Float)] = [(leadIn, quietDB, quietRatio)]
        for _ in 0..<settings.requiredSnores {
            segments.append((snoreSeconds, snoreDB(for: settings.sensitivity), snoreRatio))
            segments.append((pauseSeconds, quietDB, quietRatio))
        }

        var frames: [FrameFeatures] = []
        var time = 0.0
        for segment in segments {
            let end = time + segment.seconds
            while time < end {
                frames.append(FrameFeatures(time: time, duration: frameDuration,
                                            levelDB: segment.db, lowBandRatio: segment.ratio))
                time += frameDuration
            }
        }
        return frames
    }
}
