import Foundation

/// 1フレーム分の音響特徴量。
struct FrameFeatures: Equatable {
    /// 計測開始からの経過秒 (フレーム先頭)
    var time: TimeInterval
    /// フレームの長さ (秒)
    var duration: TimeInterval
    /// 音量 (dBFS)
    var levelDB: Float
    /// 全帯域に対する低周波帯域 (いびき帯域) のエネルギー比 0...1
    var lowBandRatio: Float
}

struct SnoreDetectorConfig: Equatable {
    /// 環境音 (ノイズフロア) から何 dB 大きければ「音がある」とみなすか
    var marginDB: Float = 12
    /// これより小さい音は無視する絶対しきい値 (dBFS)
    var absoluteMinDB: Float = -65
    /// いびきとみなす低周波エネルギー比の下限
    var minLowBandRatio: Float = 0.55
    /// いびき1回の長さの範囲
    var minEventDuration: TimeInterval = 0.3
    var maxEventDuration: TimeInterval = 3.5
    /// 1回のいびきの途中で許容する無音の長さ
    var gapTolerance: TimeInterval = 0.25
    /// 連続するいびきの最小間隔 (呼吸周期より短いものは同じいびきとみなす)
    var minInterval: TimeInterval = 1.5
    /// `windowSeconds` 秒以内に `requiredSnores` 回いびきを検知したらアラーム
    var requiredSnores: Int = 4
    var windowSeconds: TimeInterval = 60
}

struct SnoreEvent: Equatable {
    var start: TimeInterval
    var duration: TimeInterval
    var peakDB: Float
    var lowBandRatio: Float
}

enum DetectorEvent: Equatable {
    case snore(SnoreEvent)
    case alarm(snoreCount: Int)
}

/// フレーム特徴量の列からいびきを検出する。
///
/// 1. 環境音の大きさ (ノイズフロア) を追従し、それより十分大きいフレームを「音あり」とする
/// 2. 連続した「音あり」区間を1つの音イベントにまとめる
/// 3. 長さと周波数特性 (低音が支配的か) でいびきかどうかを判定する
/// 4. 一定時間内にいびきが規定回数あればアラームを出す
struct SnoreDetector {
    var config: SnoreDetectorConfig
    private(set) var noiseFloorDB: Float?
    private var current: Candidate?
    private var recentSnores: [TimeInterval] = []
    /// 音イベントの判定結果の内訳 (診断用。`takeStats()` で取り出して数え直す)
    private(set) var stats = Stats()

    struct Stats: Equatable {
        var tooShort = 0
        var tooLong = 0
        var notLowPitched = 0
        var tooSoon = 0
        var snores = 0

        var description: String {
            "snore=\(snores) short=\(tooShort) long=\(tooLong) notLow=\(notLowPitched) soon=\(tooSoon)"
        }
    }

    mutating func takeStats() -> Stats {
        defer { stats = Stats() }
        return stats
    }

    private struct Candidate {
        var start: TimeInterval
        var end: TimeInterval
        var peakDB: Float
        var ratioSum: Float
        var loudFrames: Int

        var duration: TimeInterval { end - start }
        var meanRatio: Float { loudFrames > 0 ? ratioSum / Float(loudFrames) : 0 }
    }

    init(config: SnoreDetectorConfig = SnoreDetectorConfig()) {
        self.config = config
    }

    var thresholdDB: Float? {
        noiseFloorDB.map { max($0 + config.marginDB, config.absoluteMinDB) }
    }

    /// 検出途中の状態といびき履歴を消去する (ノイズフロアは保持)。
    mutating func reset() {
        current = nil
        recentSnores.removeAll()
    }

    mutating func process(_ frame: FrameFeatures) -> [DetectorEvent] {
        guard let threshold = thresholdDB else {
            noiseFloorDB = frame.levelDB
            return []
        }

        if frame.levelDB >= threshold {
            if current == nil {
                current = Candidate(start: frame.time, end: frame.time, peakDB: frame.levelDB, ratioSum: 0, loudFrames: 0)
            }
            current!.end = frame.time + frame.duration
            current!.peakDB = max(current!.peakDB, frame.levelDB)
            current!.ratioSum += frame.lowBandRatio
            current!.loudFrames += 1
            // 長く続く音 (扇風機・エアコン等) はいびきではないので、ノイズフロアに取り込んでいく
            if current!.duration > config.maxEventDuration {
                adaptFloor(toward: frame.levelDB, rate: 0.01)
            }
            return []
        }

        updateFloor(with: frame.levelDB)
        guard let candidate = current, frame.time - candidate.end >= config.gapTolerance else {
            return []
        }
        current = nil
        return finish(candidate)
    }

    private mutating func finish(_ candidate: Candidate) -> [DetectorEvent] {
        guard candidate.duration >= config.minEventDuration else {
            stats.tooShort += 1
            return []
        }
        guard candidate.duration <= config.maxEventDuration else {
            stats.tooLong += 1
            return []
        }
        guard candidate.meanRatio >= config.minLowBandRatio else {
            stats.notLowPitched += 1
            return []
        }
        if let last = recentSnores.last, candidate.start - last < config.minInterval {
            stats.tooSoon += 1
            return []
        }
        stats.snores += 1

        let event = SnoreEvent(start: candidate.start, duration: candidate.duration,
                               peakDB: candidate.peakDB, lowBandRatio: candidate.meanRatio)
        recentSnores.append(candidate.start)
        recentSnores.removeAll { candidate.start - $0 > config.windowSeconds }

        var events: [DetectorEvent] = [.snore(event)]
        if recentSnores.count >= config.requiredSnores {
            events.append(.alarm(snoreCount: recentSnores.count))
            recentSnores.removeAll()
        }
        return events
    }

    private mutating func updateFloor(with levelDB: Float) {
        // 静かになる方向には速く、うるさくなる方向にはゆっくり追従する
        let rate: Float = levelDB < (noiseFloorDB ?? levelDB) ? 0.1 : 0.005
        adaptFloor(toward: levelDB, rate: rate)
    }

    private mutating func adaptFloor(toward levelDB: Float, rate: Float) {
        guard let floor = noiseFloorDB else { return }
        noiseFloorDB = max(floor + rate * (levelDB - floor), -100)
    }
}
