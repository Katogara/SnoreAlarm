import Accelerate

/// 音声フレームから音量と低周波エネルギー比を計算する。
final class SpectralAnalyzer {
    struct Result {
        var levelDB: Float
        var lowBandRatio: Float
    }

    /// いびきのエネルギーが集中する帯域
    static let lowBand: ClosedRange<Double> = 40...600
    /// 比較対象とする全体の帯域
    static let fullBand: ClosedRange<Double> = 40...4000

    let frameSize: Int
    let sampleRate: Double

    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var magnitudes: [Float]
    private let lowBins: ClosedRange<Int>
    private let fullBins: ClosedRange<Int>

    init(frameSize: Int = 2048, sampleRate: Double) {
        precondition(frameSize > 0 && frameSize & (frameSize - 1) == 0, "frameSize must be a power of two")
        self.frameSize = frameSize
        self.sampleRate = sampleRate
        log2n = vDSP_Length(log2(Double(frameSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameSize, isHalfWindow: false)
        windowed = [Float](repeating: 0, count: frameSize)
        real = [Float](repeating: 0, count: frameSize / 2)
        imag = [Float](repeating: 0, count: frameSize / 2)
        magnitudes = [Float](repeating: 0, count: frameSize / 2)

        let binHz = sampleRate / Double(frameSize)
        func bins(_ band: ClosedRange<Double>) -> ClosedRange<Int> {
            let lo = max(1, Int((band.lowerBound / binHz).rounded(.up)))
            let hi = max(lo, min(frameSize / 2 - 1, Int(band.upperBound / binHz)))
            return lo...hi
        }
        lowBins = bins(Self.lowBand)
        fullBins = bins(Self.fullBand)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func analyze(_ samples: UnsafeBufferPointer<Float>) -> Result {
        precondition(samples.count == frameSize)
        let half = frameSize / 2

        var rms: Float = 0
        vDSP_rmsqv(samples.baseAddress!, 1, &rms, vDSP_Length(frameSize))
        let levelDB = 20 * log10(max(rms, 1e-9))

        vDSP_vmul(samples.baseAddress!, 1, window, 1, &windowed, 1, vDSP_Length(frameSize))
        real.withUnsafeMutableBufferPointer { realPtr in
            imag.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                magnitudes.withUnsafeMutableBufferPointer { mags in
                    vDSP_zvmags(&split, 1, mags.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        let low = magnitudes[lowBins].reduce(0, +)
        let full = magnitudes[fullBins].reduce(0, +)
        let ratio = full > 1e-12 ? min(1, low / full) : 0
        return Result(levelDB: levelDB, lowBandRatio: ratio)
    }
}
