import CoreMotion
import Foundation

/// 加速度センサーで、iPhone が手に持たれて動いているか (枕元に置かれて静止しているか) を見る。
/// 手に持って操作していると細かい揺れが絶えず出るので、前の値との差が `threshold` を超えたら「動いた」とする。
/// 画面を使用中のあいだだけ動かす (ロック中は止めて電池を節約する)。
final class HandlingMonitor: @unchecked Sendable {
    /// 動いたとみなす、前の値との差 (G)。机や布団の上で静止しているときの揺れは 0.005G 程度
    static let threshold = 0.03
    static let interval: TimeInterval = 0.1

    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "SnoreAlarm.HandlingMonitor"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let lock = NSLock()
    private var last: CMAcceleration?
    private var lastMotion: Date?

    var isAvailable: Bool { manager.isAccelerometerAvailable }
    var isRunning: Bool { manager.isAccelerometerActive }

    /// 最後に動いた時刻。まだ動いていなければ nil
    var lastMotionDate: Date? {
        lock.withLock { lastMotion }
    }

    func start() {
        guard isAvailable, !isRunning else { return }
        lock.withLock {
            last = nil
            lastMotion = nil
        }
        manager.accelerometerUpdateInterval = Self.interval
        manager.startAccelerometerUpdates(to: queue) { [weak self] data, _ in
            guard let self, let acceleration = data?.acceleration else { return }
            self.lock.withLock {
                if let last = self.last, Self.isMotion(from: last, to: acceleration) {
                    self.lastMotion = Date()
                }
                self.last = acceleration
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        manager.stopAccelerometerUpdates()
    }

    static func isMotion(from a: CMAcceleration, to b: CMAcceleration) -> Bool {
        let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
        return (dx * dx + dy * dy + dz * dz).squareRoot() > threshold
    }
}
