import Foundation

/// 録音の波形 (表示用)。時間を `binCount` 個の区間に分け、区間ごとの最大音量を 0...1 の高さにする。
/// 再生時は音量を上げて鳴らすが、波形は録音したままの音量 (dBFS) で作るので、録音どうしで大小を比べられる。
struct Waveform: Equatable {
    /// 表示する音量の範囲 (dBFS)。下限より小さい音は高さ 0
    static let floorDB: Float = -60

    /// 区間ごとの高さ 0...1 (時間の順)
    let heights: [Float]
    /// 録音全体の最大音量 (dBFS)
    let peakDB: Float
    /// 録音の長さ (秒)
    let duration: TimeInterval

    init(samples: UnsafeBufferPointer<Float>, sampleRate: Double, binCount: Int = 120) {
        duration = Double(samples.count) / sampleRate
        guard !samples.isEmpty, binCount > 0 else {
            heights = []
            peakDB = -.infinity
            return
        }
        var heights: [Float] = []
        heights.reserveCapacity(binCount)
        var overallPeak: Float = 0
        for bin in 0..<binCount {
            let start = samples.count * bin / binCount
            let end = max(samples.count * (bin + 1) / binCount, start + 1)
            var peak: Float = 0
            for index in start..<min(end, samples.count) {
                peak = max(peak, abs(samples[index]))
            }
            overallPeak = max(overallPeak, peak)
            heights.append(Self.height(ofPeak: peak))
        }
        self.heights = heights
        peakDB = Self.decibels(overallPeak)
    }

    static func decibels(_ amplitude: Float) -> Float {
        amplitude > 0 ? 20 * log10(amplitude) : -.infinity
    }

    /// 最大振幅を表示の高さ (0...1) にする。dB で並べるので、小さないびきも形が見える
    static func height(ofPeak peak: Float) -> Float {
        let db = decibels(peak)
        guard db > floorDB else { return 0 }
        return min((db - floorDB) / -floorDB, 1)
    }
}
