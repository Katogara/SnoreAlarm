import AVFoundation

/// マイク入力のタップから呼ばれ、フレーム単位で解析・検出を行う。
/// `process(_:)` はオーディオスレッドからのみ呼ばれる。`setSuppressed(_:)` は任意のスレッドから呼べる。
final class AudioProcessor: @unchecked Sendable {
    struct Output {
        var levelDB: Float
        var thresholdDB: Float?
        var events: [DetectorEvent]
    }

    private let analyzer: SpectralAnalyzer
    private var detector: SnoreDetector
    private let frameDuration: TimeInterval
    private let onOutput: (Output) -> Void
    private var pending: [Float] = []
    private var frameIndex = 0
    private var wasSuppressed = false

    private let lock = NSLock()
    private var suppressed = false
    private var reportsLevels = true
    private var lastInput: Date?
    let createdAt = Date()

    /// 最後にマイク入力を受け取った時刻 (入力が止まっていないかを確かめるため)。まだ受け取っていなければ nil
    var lastInputDate: Date? {
        lock.withLock { lastInput }
    }

    /// `resetLongestGap()` からあとで、マイク入力の間隔がいちばん空いた秒数 (今まで途切れている分も含む)
    private var longestGap: TimeInterval = 0

    var longestInputGap: TimeInterval {
        lock.withLock { max(longestGap, Date().timeIntervalSince(lastInput ?? createdAt)) }
    }

    func resetLongestGap() {
        lock.withLock { longestGap = 0 }
    }

    #if DIAGNOSTICS
    /// 診断ログ用の 1 分ごとの集計 (オーディオスレッドだけで使う)
    private var summaryStart: TimeInterval = 0
    private var summaryFrames = 0
    private var summaryBuffers = 0
    private var summaryLevelSum: Float = 0
    private var summaryLevelMax: Float = -.infinity
    private var summarySuppressedFrames = 0
    static let summaryInterval: TimeInterval = 60

    private func summarize(_ result: SpectralAnalyzer.Result, time: TimeInterval, suppressed: Bool) {
        summaryFrames += 1
        summaryLevelSum += result.levelDB
        summaryLevelMax = max(summaryLevelMax, result.levelDB)
        if suppressed {
            summarySuppressedFrames += 1
        }
        guard time - summaryStart >= Self.summaryInterval else { return }
        let stats = detector.takeStats()
        let floor = detector.noiseFloorDB.map { String(format: "%.1f", $0) } ?? "-"
        let threshold = detector.thresholdDB.map { String(format: "%.1f", $0) } ?? "-"
        DiagnosticLog.write(String(format: "audio %.0fs: buffers=%d frames=%d level avg=%.1f max=%.1f floor=%@ threshold=%@ suppressed=%d %@",
                                   time - summaryStart, summaryBuffers, summaryFrames,
                                   summaryLevelSum / Float(max(summaryFrames, 1)), summaryLevelMax,
                                   floor, threshold, summarySuppressedFrames, stats.description))
        summaryStart = time
        summaryFrames = 0
        summaryBuffers = 0
        summaryLevelSum = 0
        summaryLevelMax = -.infinity
        summarySuppressedFrames = 0
    }
    #endif

    init(sampleRate: Double, config: SnoreDetectorConfig, onOutput: @escaping (Output) -> Void) {
        analyzer = SpectralAnalyzer(sampleRate: sampleRate)
        detector = SnoreDetector(config: config)
        frameDuration = Double(analyzer.frameSize) / sampleRate
        self.onOutput = onOutput
    }

    /// true の間はいびき検出を止める (振動中や開始待ちの間)。
    func setSuppressed(_ value: Bool) {
        lock.withLock { suppressed = value }
    }

    /// false の間は入力レベル表示用の通知を止め、いびきの検出結果だけを通知する。
    /// 画面が見えないとき (ロック中など) にメインスレッドを起こさず、電池消費と発熱を抑える。
    func setReportsLevels(_ value: Bool) {
        lock.withLock { reportsLevels = value }
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let now = Date()
        lock.withLock {
            longestGap = max(longestGap, now.timeIntervalSince(lastInput ?? createdAt))
            lastInput = now
        }
        #if DIAGNOSTICS
        summaryBuffers += 1
        #endif
        pending.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))

        let frameSize = analyzer.frameSize
        var offset = 0
        while pending.count - offset >= frameSize {
            let result = pending.withUnsafeBufferPointer {
                analyzer.analyze(UnsafeBufferPointer(rebasing: $0[offset..<offset + frameSize]))
            }
            offset += frameSize
            handle(result)
        }
        pending.removeFirst(offset)
    }

    private func handle(_ result: SpectralAnalyzer.Result) {
        let features = FrameFeatures(time: Double(frameIndex) * frameDuration, duration: frameDuration,
                                     levelDB: result.levelDB, lowBandRatio: result.lowBandRatio)
        frameIndex += 1

        var events: [DetectorEvent] = []
        let (isSuppressed, reportsLevels) = lock.withLock { (suppressed, self.reportsLevels) }
        if isSuppressed {
            wasSuppressed = true
        } else {
            if wasSuppressed {
                detector.reset()
                wasSuppressed = false
            }
            events = detector.process(features)
        }
        #if DIAGNOSTICS
        summarize(result, time: features.time, suppressed: isSuppressed)
        #endif

        // UI 更新は 1/4 に間引く (約 10 回/秒)
        if !events.isEmpty || (reportsLevels && frameIndex % 4 == 0) {
            onOutput(Output(levelDB: result.levelDB, thresholdDB: detector.thresholdDB, events: events))
        }
    }
}
