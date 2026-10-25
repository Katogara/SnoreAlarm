import Accelerate
import AudioToolbox
import AVFoundation

/// 録音したいびき (AAC) の保存・一覧・自動削除。
/// 入れ物は ADTS (.aac)。m4a は 1 ファイルごとに約 24KB の固定領域が付き、数秒のいびきでは音声データの 10 倍になるため使わない。
/// ファイル名に日時・長さ・最大音量を入れておき、一覧やグラフの表示のときにファイルを開かずに済むようにしている。
enum RecordingStore {
    struct Recording: Identifiable, Hashable {
        let url: URL
        let date: Date
        let duration: TimeInterval
        /// 録音したままの最大音量 (dBFS)。最大音量をファイル名に入れる前の録音では nil
        var peakDB: Float?

        var id: URL { url }
    }

    /// 録音を残す期間 (1週間)
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    /// 1回の監視で保存する上限。いびき 1 回 (約 4 秒) が約 12KB なので、上限でも 20MB 程度
    static let maxPerSession = 1500
    /// 16kHz・24kbps: いびきの音色を確かめるのに十分で、1秒あたり約 3KB
    static let bitRate = 24000

    private static let queue = DispatchQueue(label: "SnoreAlarm.RecordingStore", qos: .utility)

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
    }

    /// バックグラウンドのスレッドで保存し、終わったらメインスレッドで `completion` を呼ぶ (失敗時は nil)。
    static func save(_ samples: [Float], date: Date, completion: @escaping @MainActor (URL?) -> Void) {
        queue.async {
            let url = write(samples, date: date)
            Task { @MainActor in completion(url) }
        }
    }

    /// 1週間より古い録音をバックグラウンドのスレッドで削除する。
    static func deleteExpiredInBackground() {
        queue.async { deleteExpired() }
    }

    static func write(_ samples: [Float], date: Date, in directory: URL = directory) -> URL? {
        guard !samples.isEmpty else { return nil }
        let duration = Double(samples.count) / SnoreRecorder.sampleRate
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        let url = directory.appending(path: fileName(date: date, duration: duration, peakDB: Waveform.decibels(peak)))
        do {
            try prepare(directory)
            do {
                try encodeAAC(samples, to: url)
            } catch {
                // ビットレートを指定できない場合はエンコーダーの既定値で保存する
                try encodeWithDefaultBitRate(samples, to: url)
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    /// AAC で書き出す。AVAudioFile はビットレート指定 (AVEncoderBitRateKey) を反映しないことがあるため、
    /// ExtAudioFile の内部コンバーターに直接ビットレートを設定する。
    /// - Returns: 実際に設定したビットレートと、エンコーダーが受け付けるビットレートの一覧
    @discardableResult
    static func encodeAAC(_ samples: [Float], to url: URL) throws -> (bitRate: UInt32, applicable: [Double]) {
        var fileFormat = AudioStreamBasicDescription()
        fileFormat.mSampleRate = SnoreRecorder.sampleRate
        fileFormat.mFormatID = kAudioFormatMPEG4AAC
        fileFormat.mChannelsPerFrame = 1
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &formatSize, &fileFormat), "FormatInfo")

        var fileRef: ExtAudioFileRef?
        try check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileAAC_ADTSType, &fileFormat, nil,
                                            AudioFileFlags.eraseFile.rawValue, &fileRef), "CreateWithURL")
        guard let file = fileRef else { throw failure("CreateWithURL", kAudio_ParamError) }
        defer { ExtAudioFileDispose(file) }

        var clientFormat = AudioStreamBasicDescription(
            mSampleRate: SnoreRecorder.sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                          UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientFormat),
                  "ClientDataFormat")

        var converter: AudioConverterRef?
        var converterSize = UInt32(MemoryLayout<AudioConverterRef?>.size)
        try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &converterSize, &converter),
                  "AudioConverter")
        guard let converter else { throw failure("AudioConverter", kAudio_ParamError) }

        // エンコーダーが受け付けるビットレートのうち、目標に最も近いものを使う
        var applicable: [Double] = []
        var rangesSize: UInt32 = 0
        if AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates, &rangesSize, nil) == noErr,
           rangesSize > 0 {
            var ranges = [AudioValueRange](repeating: AudioValueRange(),
                                           count: Int(rangesSize) / MemoryLayout<AudioValueRange>.size)
            if AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates, &rangesSize, &ranges) == noErr {
                applicable = Array(Set(ranges.flatMap { [$0.mMinimum, $0.mMaximum] })).sorted()
            }
        }
        let target = Double(bitRate)
        var encodeBitRate = UInt32(applicable.min { abs($0 - target) < abs($1 - target) } ?? target)
        try check(AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate,
                                            UInt32(MemoryLayout<UInt32>.size), &encodeBitRate), "EncodeBitRate")
        // コンバーターの設定変更を ExtAudioFile に反映させる (設定値は NULL を渡す決まり)
        var config: UnsafeRawPointer?
        try check(ExtAudioFileSetProperty(file, kExtAudioFileProperty_ConverterConfig,
                                          UInt32(MemoryLayout<UnsafeRawPointer?>.size), &config), "ConverterConfig")
        // 反映のときにコンバーターが作り直されてビットレートが既定値に戻ることがあるため、取り直して確かめる
        var current: AudioConverterRef?
        converterSize = UInt32(MemoryLayout<AudioConverterRef?>.size)
        try check(ExtAudioFileGetProperty(file, kExtAudioFileProperty_AudioConverter, &converterSize, &current),
                  "AudioConverter (after config)")
        if let current {
            var actual: UInt32 = 0
            var actualSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioConverterGetProperty(current, kAudioConverterEncodeBitRate, &actualSize, &actual) == noErr,
               actual != encodeBitRate {
                try check(AudioConverterSetProperty(current, kAudioConverterEncodeBitRate,
                                                    UInt32(MemoryLayout<UInt32>.size), &encodeBitRate),
                          "EncodeBitRate (after config)")
            }
            actualSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioConverterGetProperty(current, kAudioConverterEncodeBitRate, &actualSize, &actual) == noErr {
                encodeBitRate = actual
            }
        }

        try samples.withUnsafeBufferPointer { buffer in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(buffer.count * MemoryLayout<Float>.size),
                                      mData: UnsafeMutableRawPointer(mutating: buffer.baseAddress)))
            try check(ExtAudioFileWrite(file, UInt32(buffer.count), &list), "Write")
        }
        return (encodeBitRate, applicable)
    }

    private static func encodeWithDefaultBitRate(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SnoreRecorder.sampleRate,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            throw failure("PCMBuffer", kAudio_ParamError)
        }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: SnoreRecorder.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else { throw failure(step, status) }
    }

    private static func failure(_ step: String, _ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "\(step) failed (OSStatus \(status))"])
    }

    static func list(in directory: URL = directory) -> [Recording] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap(recording(at:)).sorted { $0.date > $1.date }
    }

    static func deleteExpired(now: Date = Date(), in directory: URL = directory) {
        for recording in list(in: directory) where now.timeIntervalSince(recording.date) > retention {
            try? FileManager.default.removeItem(at: recording.url)
        }
    }

    static func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.url)
    }

    /// `snore-<日時 ms>-<長さ ms>-<最大音量 -dB の 10 倍>.aac`。区切りの "-" と紛れないよう、最大音量は符号を外して入れる
    static func fileName(date: Date, duration: TimeInterval, peakDB: Float? = nil) -> String {
        var name = "snore-\(Int64(date.timeIntervalSince1970 * 1000))-\(Int(duration * 1000))"
        if let peakDB {
            let tenths = peakDB.isFinite ? Int((min(-peakDB, 999) * 10).rounded()) : 9999
            name += "-\(max(tenths, 0))"
        }
        return name + ".aac"
    }

    static func recording(at url: URL) -> Recording? {
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
        guard url.pathExtension == "aac", parts.count == 3 || parts.count == 4, parts[0] == "snore",
              let millis = Double(parts[1]), let durationMillis = Double(parts[2]) else {
            return nil
        }
        let peakDB = parts.count == 4 ? Float(parts[3]).map { -$0 / 10 } : nil
        return Recording(url: url, date: Date(timeIntervalSince1970: millis / 1000), duration: durationMillis / 1000,
                         peakDB: peakDB)
    }

    /// 最大音量をファイル名に持たない (以前の版の) 録音を読み込んで、最大音量を測る。
    static func measurePeakDB(_ url: URL) -> Float? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(max(file.length, 0)) + 4096),
              (try? file.read(into: buffer)) != nil,
              buffer.frameLength > 0,
              let channel = buffer.floatChannelData?[0] else {
            return nil
        }
        var peak: Float = 0
        vDSP_maxmgv(channel, 1, &peak, vDSP_Length(buffer.frameLength))
        return Waveform.decibels(peak)
    }

    private static func prepare(_ directory: URL) throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // iCloud バックアップの容量を使わないようにする
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(values)
    }
}
