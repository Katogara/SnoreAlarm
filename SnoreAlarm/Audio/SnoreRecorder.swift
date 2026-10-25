import AVFoundation

/// マイク入力を 16kHz モノラルに変換して直近 6 秒だけ保持し、いびきと判定された区間を切り出す。
/// 常にファイルへ書き込むのではなく、いびきのときだけ `RecordingStore` で保存するため、ディスクと電池への負担が小さい。
/// `append(_:)` はオーディオスレッドから、`clip(start:duration:)` は任意のスレッドから呼べる。
final class SnoreRecorder: @unchecked Sendable {
    /// いびきの音色を聞き分けるのに十分で、データ量の少ないサンプルレート
    static let sampleRate = 16000.0
    /// 切り出すときにいびきの前後に付ける余白 (秒)。後ろは判定に使う無音 (0.25 秒) の範囲に収める
    static let preRoll: TimeInterval = 0.3
    static let postRoll: TimeInterval = 0.2

    private let converter: AVAudioConverter
    private let outputBuffer: AVAudioPCMBuffer
    private let lock = NSLock()
    /// いびき 1 回の最大長 3.5 秒 + 前後の余白 + 判定待ちを収められる長さ
    private var ring = SampleRingBuffer(capacity: Int(SnoreRecorder.sampleRate * 6))

    init?(inputFormat: AVAudioFormat) {
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16384) else {
            return nil
        }
        converter.downmix = true
        self.converter = converter
        self.outputBuffer = outputBuffer
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        var consumed = false
        outputBuffer.frameLength = 0
        let status = converter.convert(to: outputBuffer, error: nil) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let data = outputBuffer.floatChannelData?[0] else { return }
        let samples = UnsafeBufferPointer(start: data, count: Int(outputBuffer.frameLength))
        lock.withLock { ring.append(samples) }
    }

    /// 計測開始から `start` 秒、長さ `duration` 秒のいびきを、前後の余白付きで切り出す。
    func clip(start: TimeInterval, duration: TimeInterval) -> [Float] {
        let from = Int((start - Self.preRoll) * Self.sampleRate)
        let to = Int((start + duration + Self.postRoll) * Self.sampleRate)
        return lock.withLock { ring.samples(from: from, to: to) }
    }
}
