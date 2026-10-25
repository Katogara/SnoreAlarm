import AVFoundation
import XCTest
@testable import SnoreAlarm

final class SnoreDetectorTests: XCTestCase {
    private let frameDuration = 2048.0 / 48000.0

    private struct Segment {
        var seconds: Double
        var db: Float
        var ratio: Float

        static func quiet(_ seconds: Double) -> Segment { Segment(seconds: seconds, db: -60, ratio: 0.3) }
        static func snore(_ seconds: Double) -> Segment { Segment(seconds: seconds, db: -30, ratio: 0.8) }
        static func speech(_ seconds: Double) -> Segment { Segment(seconds: seconds, db: -30, ratio: 0.2) }
    }

    private func run(_ segments: [Segment], config: SnoreDetectorConfig = SnoreDetectorConfig()) -> [DetectorEvent] {
        var detector = SnoreDetector(config: config)
        var time = 0.0
        var events: [DetectorEvent] = []
        for segment in segments {
            let end = time + segment.seconds
            while time < end {
                events += detector.process(FrameFeatures(time: time, duration: frameDuration,
                                                         levelDB: segment.db, lowBandRatio: segment.ratio))
                time += frameDuration
            }
        }
        return events
    }

    private func snores(in events: [DetectorEvent]) -> [SnoreEvent] {
        events.compactMap { if case .snore(let e) = $0 { e } else { nil } }
    }

    private func alarmCount(in events: [DetectorEvent]) -> Int {
        events.filter { if case .alarm = $0 { true } else { false } }.count
    }

    func testRepeatedSnoringTriggersAlarm() {
        var segments: [Segment] = [.quiet(5)]
        for _ in 0..<4 {
            segments += [.snore(1), .quiet(3)]
        }
        let events = run(segments)

        XCTAssertEqual(snores(in: events).count, 4)
        XCTAssertEqual(alarmCount(in: events), 1)
        XCTAssertEqual(events.last, .alarm(snoreCount: 4))
        for snore in snores(in: events) {
            XCTAssertEqual(snore.duration, 1, accuracy: 0.1)
        }
    }

    func testFewerSnoresThanRequiredDoesNotAlarm() {
        var segments: [Segment] = [.quiet(5)]
        for _ in 0..<3 {
            segments += [.snore(1), .quiet(3)]
        }
        let events = run(segments)

        XCTAssertEqual(snores(in: events).count, 3)
        XCTAssertEqual(alarmCount(in: events), 0)
    }

    func testSnoresOutsideWindowDoNotAccumulate() {
        var segments: [Segment] = [.quiet(5)]
        for _ in 0..<3 {
            segments += [.snore(1), .quiet(3)]
        }
        segments += [.quiet(70), .snore(1), .quiet(3)]
        let events = run(segments)

        XCTAssertEqual(snores(in: events).count, 4)
        XCTAssertEqual(alarmCount(in: events), 0)
    }

    func testHighFrequencySoundIsNotSnoring() {
        var segments: [Segment] = [.quiet(5)]
        for _ in 0..<8 {
            segments += [.speech(1), .quiet(3)]
        }
        XCTAssertTrue(run(segments).isEmpty)
    }

    func testContinuousNoiseIsAbsorbedIntoNoiseFloor() {
        var detector = SnoreDetector()
        var time = 0.0
        var events: [DetectorEvent] = []
        for (seconds, db) in [(5.0, Float(-60)), (60.0, Float(-30))] {
            let end = time + seconds
            while time < end {
                events += detector.process(FrameFeatures(time: time, duration: frameDuration, levelDB: db, lowBandRatio: 0.9))
                time += frameDuration
            }
        }
        XCTAssertTrue(events.isEmpty)
        XCTAssertGreaterThan(detector.noiseFloorDB ?? -100, -45)
    }

    func testTooShortAndTooLongSoundsAreIgnored() {
        let events = run([.quiet(5), .snore(0.1), .quiet(3), .snore(6), .quiet(3)])
        XCTAssertTrue(snores(in: events).isEmpty)
    }

    /// 診断ログ用に、いびきと判定しなかった理由を数える
    func testStatsCountRejectionReasons() {
        var detector = SnoreDetector()
        var time = 0.0
        for segment: Segment in [.quiet(5), .snore(0.1), .quiet(3), .snore(6), .quiet(3), .speech(1), .quiet(3), .snore(1), .quiet(3)] {
            let end = time + segment.seconds
            while time < end {
                _ = detector.process(FrameFeatures(time: time, duration: frameDuration,
                                                   levelDB: segment.db, lowBandRatio: segment.ratio))
                time += frameDuration
            }
        }
        let stats = detector.takeStats()
        XCTAssertEqual(stats, SnoreDetector.Stats(tooShort: 1, tooLong: 1, notLowPitched: 1, tooSoon: 0, snores: 1))
        XCTAssertEqual(detector.stats, SnoreDetector.Stats())
    }

    func testSoundsCloserThanMinIntervalCountOnce() {
        // 0.5 秒の間隔で途切れる音は1回のいびきとして数える
        let events = run([.quiet(5), .snore(0.8), .quiet(0.5), .snore(0.8), .quiet(3)])
        XCTAssertEqual(snores(in: events).count, 1)
    }

    func testAlarmClearsHistory() {
        var segments: [Segment] = [.quiet(5)]
        for _ in 0..<7 {
            segments += [.snore(1), .quiet(3)]
        }
        // 4回目でアラーム、その後の3回だけではアラームにならない
        XCTAssertEqual(alarmCount(in: run(segments)), 1)
    }
}

final class DemoSignalTests: XCTestCase {
    func testDemoTriggersAlarmOnLastSnoreForEverySetting() {
        for sensitivity in Sensitivity.allCases {
            for required in 2...10 {
                var settings = AlarmSettings()
                settings.sensitivity = sensitivity
                settings.requiredSnores = required
                settings.windowSeconds = 30 // 設定できる最短の判定時間

                var detector = SnoreDetector(config: settings.detectorConfig)
                let events = DemoSignal.frames(for: settings).flatMap { detector.process($0) }
                let snores = events.filter { if case .snore = $0 { true } else { false } }

                XCTAssertEqual(snores.count, required, "\(sensitivity) \(required)")
                XCTAssertEqual(events.last, .alarm(snoreCount: required), "\(sensitivity) \(required)")
            }
        }
    }

    /// Apple Watch で試すときは静かな時間を長くして画面をロックする時間をとる。アラームはその分だけ遅れて同じように出る
    func testLongerLeadInDelaysAlarm() {
        let settings = AlarmSettings()
        let leadIn = DemoSignal.leadIn + 5
        var detector = SnoreDetector(config: settings.detectorConfig)
        let frames = DemoSignal.frames(for: settings, leadIn: leadIn)
        guard let alarmFrame = frames.first(where: { detector.process($0).contains(.alarm(snoreCount: settings.requiredSnores)) }) else {
            return XCTFail("アラームにならない")
        }
        // 最後のいびきのあと、途切れたと判定するまでの少しの間 (0.5 秒ほど) 遅れる。案内の「約○秒」に使うので 1 秒以内でよい
        XCTAssertEqual(alarmFrame.time, DemoSignal.secondsUntilAlarm(for: settings, leadIn: leadIn), accuracy: 1)
    }
}

final class RecordingTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRingBufferKeepsOnlyLatestSamples() {
        var ring = SampleRingBuffer(capacity: 5)
        let input = (0..<12).map(Float.init)
        input.withUnsafeBufferPointer { ring.append(UnsafeBufferPointer(rebasing: $0[0..<8])) }
        input.withUnsafeBufferPointer { ring.append(UnsafeBufferPointer(rebasing: $0[8..<12])) }

        XCTAssertEqual(ring.totalCount, 12)
        XCTAssertEqual(ring.samples(from: 0, to: 12), [7, 8, 9, 10, 11])
        XCTAssertEqual(ring.samples(from: 8, to: 10), [8, 9])
        XCTAssertEqual(ring.samples(from: 10, to: 20), [10, 11])
        XCTAssertEqual(ring.samples(from: 0, to: 5), [])
    }

    /// 2 秒の 150Hz の音
    private let twoSecondTone = (0..<32000).map { Float(0.3 * sin(2 * Double.pi * 150 * Double($0) / SnoreRecorder.sampleRate)) }

    func testAACEncoderUsesLowBitRate() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "encode.aac")
        do {
            let result = try RecordingStore.encodeAAC(twoSecondTone, to: url)
            print("AAC bit rate: \(result.bitRate), applicable: \(result.applicable)")
            XCTAssertLessThanOrEqual(result.bitRate, 32000)
        } catch {
            XCTFail("encodeAAC: \(error.localizedDescription)")
        }
    }

    func testWriteAndListRecording() throws {
        let samples = twoSecondTone
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let url = try XCTUnwrap(RecordingStore.write(samples, date: date, in: directory))

        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        print("recording size for 2 seconds: \(size) bytes")
        XCTAssertGreaterThan(size, 1000)
        XCTAssertLessThan(size, 10000, "24kbps なら 2 秒で 10KB 未満に収まること")

        // 再生できる形式で、長さが保たれていること
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 2, accuracy: 0.2)

        let recordings = RecordingStore.list(in: directory)
        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings.first?.date, date)
        XCTAssertEqual(recordings.first?.duration ?? 0, 2, accuracy: 0.01)
        // 最大音量をファイル名から読めること (グラフ表示のため)
        let expectedPeak = Waveform.decibels(peak(samples[...]))
        XCTAssertEqual(recordings.first?.peakDB ?? 0, expectedPeak, accuracy: 0.06)
        XCTAssertEqual(RecordingStore.measurePeakDB(url) ?? 0, expectedPeak, accuracy: 3)
    }

    func testOldFileNamesWithoutPeakAreStillListed() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        FileManager.default.createFile(atPath: directory.appending(path: RecordingStore.fileName(date: date, duration: 1.5)).path,
                                       contents: Data([0]))
        FileManager.default.createFile(atPath: directory.appending(path: RecordingStore.fileName(date: date.addingTimeInterval(10), duration: 2, peakDB: -31.24)).path,
                                       contents: Data([0]))
        let recordings = RecordingStore.list(in: directory)
        XCTAssertEqual(recordings.count, 2)
        XCTAssertNil(recordings[1].peakDB)
        XCTAssertEqual(recordings[0].peakDB ?? 0, -31.2, accuracy: 0.001)
        XCTAssertEqual(recordings[0].duration, 2, accuracy: 0.001)
    }

    private func peak(_ samples: ArraySlice<Float>) -> Float {
        samples.map(abs).max() ?? 0
    }

    /// マイクの音 (48kHz) → 検出 → いびき区間の切り出し → 保存 → 再生用の読み込み まで通して、
    /// 録音にいびきの音が正しい位置に入っていて、再生時に十分な音量になること
    func testSnoreRecordingContainsAudibleSoundEndToEnd() throws {
        let inputRate = 48000.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: inputRate, channels: 1))
        let recorder = try XCTUnwrap(SnoreRecorder(inputFormat: format))
        var snores: [SnoreEvent] = []
        let processor = AudioProcessor(sampleRate: inputRate, config: SnoreDetectorConfig()) { output in
            for case .snore(let snore) in output.events {
                snores.append(snore)
            }
        }

        // 静か 3 秒 (-63dB の高い音) → いびき 1 秒 (150Hz、ピーク 0.03 = 約 -30dBFS) → 静か 2 秒
        let snoreAmplitude: Float = 0.03
        var signal: [Float] = []
        for (seconds, frequency, amplitude) in [(3.0, 3000.0, Float(0.001)), (1.0, 150.0, snoreAmplitude), (2.0, 3000.0, Float(0.001))] {
            for _ in 0..<Int(seconds * inputRate) {
                let t = Double(signal.count) / inputRate
                signal.append(amplitude * Float(sin(2 * Double.pi * frequency * t)))
            }
        }
        let chunk = 4800
        for offset in stride(from: 0, to: signal.count, by: chunk) {
            let count = min(chunk, signal.count - offset)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            signal.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress! + offset, count: count) }
            recorder.append(buffer)
            processor.process(buffer)
        }

        XCTAssertEqual(snores.count, 1)
        let snore = try XCTUnwrap(snores.first)
        XCTAssertEqual(snore.start, 3, accuracy: 0.1)
        XCTAssertEqual(snore.duration, 1, accuracy: 0.1)

        let clip = recorder.clip(start: snore.start, duration: snore.duration)
        let rate = SnoreRecorder.sampleRate
        print("clip: \(clip.count) samples, peak \(peak(clip[...]))")
        XCTAssertEqual(Double(clip.count) / rate, snore.duration + SnoreRecorder.preRoll + SnoreRecorder.postRoll, accuracy: 0.05)
        // 前の余白は静か、真ん中はいびき (切り出し位置がずれていないこと)
        let head = clip[..<Int(0.2 * rate)]
        let middle = clip[Int((SnoreRecorder.preRoll + 0.2) * rate)..<Int((SnoreRecorder.preRoll + 0.8) * rate)]
        XCTAssertLessThan(peak(head), 0.005)
        XCTAssertEqual(peak(middle), snoreAmplitude, accuracy: 0.005)

        let url = try XCTUnwrap(RecordingStore.write(clip, date: Date(), in: directory))
        let file = try AVAudioFile(forReading: url)
        let stored = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length) + 4096))
        try file.read(into: stored)
        let storedSamples = Array(UnsafeBufferPointer(start: stored.floatChannelData![0], count: Int(stored.frameLength)))
        print("stored: \(storedSamples.count) samples, peak \(peak(storedSamples[...]))")
        XCTAssertEqual(peak(storedSamples[...]), snoreAmplitude, accuracy: snoreAmplitude * 0.4, "保存した AAC にいびきの音が入っていること")

        let (playback, waveform) = try XCTUnwrap(SnorePlayer.loadForPlayback(url))
        let playbackSamples = Array(UnsafeBufferPointer(start: playback.floatChannelData![0], count: Int(playback.frameLength)))
        print("playback: peak \(peak(playbackSamples[...]))")
        XCTAssertEqual(peak(playbackSamples[...]), SnorePlayer.targetPeak, accuracy: 0.01, "再生時は聞こえる大きさに上げること")

        // 波形は音量を上げる前の大きさ (約 -30dB → 高さ 0.5)。いびきの区間が高く、前の余白は低い
        print("waveform: peak \(waveform.peakDB) dB, heights \(waveform.heights.map { String(format: "%.2f", $0) }.joined(separator: " "))")
        XCTAssertEqual(waveform.peakDB, Waveform.decibels(snoreAmplitude), accuracy: 3)
        XCTAssertEqual(waveform.duration, Double(storedSamples.count) / rate, accuracy: 0.01)
        let middleBin = waveform.heights.count / 2
        XCTAssertEqual(waveform.heights[middleBin], 0.5, accuracy: 0.1)
        XCTAssertLessThan(waveform.heights[waveform.heights.count / 20], 0.15)
    }

    func testWaveformHeightsFollowLoudnessOverTime() {
        // 0.5 秒ずつ: 無音 → -40dB → -20dB → 0dB
        let rate = 1000.0
        var samples: [Float] = []
        for amplitude: Float in [0, 0.01, 0.1, 1] {
            samples += (0..<500).map { amplitude * Float(sin(Double($0) * 0.5)) }
        }
        let waveform = samples.withUnsafeBufferPointer { Waveform(samples: $0, sampleRate: rate, binCount: 4) }
        XCTAssertEqual(waveform.duration, 2)
        XCTAssertEqual(waveform.heights.count, 4)
        XCTAssertEqual(waveform.heights[0], 0)
        XCTAssertEqual(waveform.heights[1], 1.0 / 3, accuracy: 0.02)
        XCTAssertEqual(waveform.heights[2], 2.0 / 3, accuracy: 0.02)
        XCTAssertEqual(waveform.heights[3], 1, accuracy: 0.02)
        XCTAssertEqual(waveform.peakDB, 0, accuracy: 0.1)
    }

    func testNormalizeDoesNotAmplifyNearSilenceBeyondLimit() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: SnoreRecorder.sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
        buffer.frameLength = 100
        for i in 0..<100 { buffer.floatChannelData![0][i] = i == 50 ? 0.0001 : 0 }
        SnorePlayer.normalize(buffer)
        XCTAssertEqual(buffer.floatChannelData![0][50], 0.0001 * SnorePlayer.maxGain, accuracy: 1e-6)
    }

    func testRecordingsOlderThanOneWeekAreDeleted() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        for days in [1.0, 6.9, 7.1, 30] {
            let date = now.addingTimeInterval(-days * 24 * 60 * 60)
            FileManager.default.createFile(atPath: directory.appending(path: RecordingStore.fileName(date: date, duration: 1)).path,
                                           contents: Data([0]))
        }
        RecordingStore.deleteExpired(now: now, in: directory)
        XCTAssertEqual(RecordingStore.list(in: directory).count, 2)
    }
}

final class MonitoringScheduleTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testOvernightWindow() {
        let schedule = MonitoringSchedule(isOn: true, startMinutes: 23 * 60, endMinutes: 7 * 60)
        XCTAssertTrue(schedule.isEnabled)
        XCTAssertTrue(schedule.contains(date(21, 23, 0), calendar: calendar))
        XCTAssertTrue(schedule.contains(date(22, 3, 0), calendar: calendar))
        XCTAssertTrue(schedule.contains(date(22, 6, 59), calendar: calendar))
        XCTAssertFalse(schedule.contains(date(22, 7, 0), calendar: calendar))
        XCTAssertFalse(schedule.contains(date(21, 22, 59), calendar: calendar))
        XCTAssertFalse(schedule.contains(date(21, 12, 0), calendar: calendar))

        // 22:00 の次のお知らせはその日の 23:00、その監視は翌朝 7:00 に終了する
        let start = schedule.nextStart(after: date(21, 22, 0), calendar: calendar)
        XCTAssertEqual(start, date(21, 23, 0))
        XCTAssertEqual(schedule.nextEnd(after: start!, calendar: calendar), date(22, 7, 0))
        // 開始時刻ちょうどのあとは翌日の開始時刻
        XCTAssertEqual(schedule.nextStart(after: date(21, 23, 0), calendar: calendar), date(22, 23, 0))
        // 7:00 に終了したあとの次の開始はその日の夜
        XCTAssertEqual(schedule.nextStart(after: date(22, 7, 0), calendar: calendar), date(22, 23, 0))
    }

    func testSameDayWindow() {
        let schedule = MonitoringSchedule(isOn: true, startMinutes: 1 * 60 + 30, endMinutes: 6 * 60 + 15)
        XCTAssertTrue(schedule.contains(date(21, 1, 30), calendar: calendar))
        XCTAssertTrue(schedule.contains(date(21, 6, 14), calendar: calendar))
        XCTAssertFalse(schedule.contains(date(21, 6, 15), calendar: calendar))
        XCTAssertFalse(schedule.contains(date(21, 23, 0), calendar: calendar))
        XCTAssertEqual(schedule.nextStart(after: date(21, 12, 0), calendar: calendar), date(22, 1, 30))
        XCTAssertEqual(schedule.nextEnd(after: date(21, 2, 0), calendar: calendar), date(21, 6, 15))
    }

    /// 寝る時刻のお知らせ: 毎日 23:00 から 15 分おきに 4 回。7 日分
    func testReminderDatesRepeatEveryFifteenMinutes() {
        let schedule = MonitoringSchedule(isOn: true, startMinutes: 23 * 60, endMinutes: 7 * 60)
        let dates = schedule.reminderDates(after: date(21, 12, 0), monitoringUntil: nil, calendar: calendar)
        XCTAssertEqual(dates.count, 28)
        XCTAssertEqual(Array(dates.prefix(5)), [date(21, 23, 0), date(21, 23, 15), date(21, 23, 30), date(21, 23, 45),
                                                date(22, 23, 0)])
        XCTAssertEqual(dates.last, date(27, 23, 45))
    }

    /// お知らせの途中でも、今夜の残りのお知らせを出す
    func testReminderDatesDuringTonightKeepRemainingOnes() {
        let schedule = MonitoringSchedule(isOn: true, startMinutes: 23 * 60, endMinutes: 7 * 60)
        let dates = schedule.reminderDates(after: date(21, 23, 20), monitoringUntil: nil, calendar: calendar)
        XCTAssertEqual(Array(dates.prefix(3)), [date(21, 23, 30), date(21, 23, 45), date(22, 23, 0)])
    }

    /// 監視を始めたら (終了は翌朝 7:00)、その夜のお知らせは出さず、次の夜から出す
    func testReminderDatesSkipTonightWhileMonitoring() {
        let schedule = MonitoringSchedule(isOn: true, startMinutes: 23 * 60, endMinutes: 7 * 60)
        let dates = schedule.reminderDates(after: date(21, 22, 30), monitoringUntil: date(22, 7, 0), calendar: calendar)
        XCTAssertEqual(dates.first, date(22, 23, 0))
        XCTAssertTrue(MonitoringSchedule(isOn: false).reminderDates(after: date(21, 22, 30), monitoringUntil: nil,
                                                                    calendar: calendar).isEmpty)
    }

    func testDisabledWhenOffOrStartEqualsEnd() {
        XCTAssertFalse(MonitoringSchedule(isOn: false, startMinutes: 23 * 60, endMinutes: 7 * 60).isEnabled)
        XCTAssertFalse(MonitoringSchedule(isOn: true, startMinutes: 7 * 60, endMinutes: 7 * 60).isEnabled)
    }

    func testSettingsLoadSchedule() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertEqual(AlarmSettings.load(from: defaults).schedule,
                       MonitoringSchedule(isOn: false, startMinutes: 23 * 60, endMinutes: 7 * 60))
        defaults.set(true, forKey: AlarmSettings.Key.scheduleEnabled)
        defaults.set(22 * 60 + 30, forKey: AlarmSettings.Key.scheduleStartMinutes)
        defaults.set(6 * 60, forKey: AlarmSettings.Key.scheduleEndMinutes)
        XCTAssertEqual(AlarmSettings.load(from: defaults).schedule,
                       MonitoringSchedule(isOn: true, startMinutes: 22 * 60 + 30, endMinutes: 6 * 60))
    }
}

final class WatchAlertTests: XCTestCase {
    /// 振動の長さのあいだ、繰り返し通知を送る (1 回の通知は短く 1 度振動するだけのため)
    func testTapOffsetsCoverVibrationDuration() {
        // 最初の 3 回は 1 秒おき、そのあとは 2 秒おき
        XCTAssertEqual(WatchAlert.tapOffsets(duration: 10), [0, 1, 2, 4, 6, 8])
        XCTAssertEqual(WatchAlert.tapOffsets(duration: 3), [0, 1, 2])
        XCTAssertEqual(WatchAlert.tapOffsets(duration: 0), [0])
        XCTAssertEqual(WatchAlert.tapOffsets(duration: 60).count, 31)
    }

    /// Watch で知らせてから 5 分以内にまたアラームになったら iPhone も振動させる
    func testFallbackWhenSnoringContinuesAfterWatchAlert() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertFalse(WatchAlert.needsFallback(lastWatchAlarm: nil, now: now))
        XCTAssertTrue(WatchAlert.needsFallback(lastWatchAlarm: now.addingTimeInterval(-4 * 60), now: now))
        XCTAssertTrue(WatchAlert.needsFallback(lastWatchAlarm: now.addingTimeInterval(-5 * 60), now: now))
        XCTAssertFalse(WatchAlert.needsFallback(lastWatchAlarm: now.addingTimeInterval(-6 * 60), now: now))
    }

    func testSettingsLoadAlertDevice() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertEqual(AlarmSettings.load(from: defaults).alertDevice, .iPhone)
        XCTAssertTrue(AlarmSettings.load(from: defaults).watchFallback)
        defaults.set(AlertDevice.watch.rawValue, forKey: AlarmSettings.Key.alertDevice)
        defaults.set(false, forKey: AlarmSettings.Key.watchFallback)
        XCTAssertEqual(AlarmSettings.load(from: defaults).alertDevice, .watch)
        XCTAssertFalse(AlarmSettings.load(from: defaults).watchFallback)
    }
}

final class NightRecordTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func recording(_ date: Date, peakDB: Float = -30) -> RecordingStore.Recording {
        RecordingStore.Recording(url: URL(fileURLWithPath: "/tmp/\(date.timeIntervalSince1970).aac"), date: date,
                                 duration: 2, peakDB: peakDB)
    }

    private typealias Session = MonitoringSessionStore.Session

    func testDayStartUsesBoundary() {
        XCTAssertEqual(NightRecord.dayStart(containing: date(21, 23, 0), boundaryMinutes: 12 * 60, calendar: calendar), date(21, 12, 0))
        XCTAssertEqual(NightRecord.dayStart(containing: date(22, 11, 59), boundaryMinutes: 12 * 60, calendar: calendar), date(21, 12, 0))
        XCTAssertEqual(NightRecord.dayStart(containing: date(22, 12, 0), boundaryMinutes: 12 * 60, calendar: calendar), date(22, 12, 0))
    }

    /// 夜中に何度か止めて再開しても、午後の最初の開始から翌朝の最後の終了までを一晩にする
    func testRepeatedStopsInOneNightAreOneCycle() {
        let sessions = [
            Session(start: date(21, 22, 30), end: date(22, 1, 0)),
            Session(start: date(22, 1, 10), end: date(22, 3, 0)),
            Session(start: date(22, 3, 30), end: date(22, 6, 45)),
            Session(start: date(22, 23, 0), end: date(23, 6, 0)),
        ]
        let recordings = [recording(date(21, 23, 15)), recording(date(22, 2, 0)), recording(date(22, 5, 0)),
                          recording(date(23, 2, 0))]
        let nights = NightRecord.nights(sessions: sessions, recordings: recordings, boundaryMinutes: 12 * 60,
                                        isMonitoring: false, now: date(23, 8, 0), calendar: calendar)
        XCTAssertEqual(nights.count, 2)
        let first = nights[1]
        XCTAssertEqual(first.dayStart, date(21, 12, 0))
        XCTAssertEqual(first.start, date(21, 22, 30))
        XCTAssertEqual(first.end, date(22, 6, 45))
        XCTAssertEqual(first.periods.count, 3)
        XCTAssertEqual(first.recordings.count, 3)
        XCTAssertEqual(first.monitoredDuration, (150 + 110 + 195) * 60)
        XCTAssertEqual(nights[0].recordings.count, 1)
    }

    /// 昼に眠る人: 区切りを 18:00 にすると、朝 8 時から夕方 16 時までの監視が一晩になる
    func testCustomBoundaryForDaySleepers() {
        let sessions = [
            Session(start: date(21, 8, 0), end: date(21, 12, 0)),
            Session(start: date(21, 12, 30), end: date(21, 16, 0)),
        ]
        let shifted = NightRecord.nights(sessions: sessions, recordings: [], boundaryMinutes: 18 * 60,
                                         isMonitoring: false, now: date(21, 20, 0), calendar: calendar)
        XCTAssertEqual(shifted.count, 1)
        XCTAssertEqual(shifted[0].start, date(21, 8, 0))
        XCTAssertEqual(shifted[0].end, date(21, 16, 0))
        // 区切りが 12:00 のままだと 2 つに分かれる
        let split = NightRecord.nights(sessions: sessions, recordings: [], boundaryMinutes: 12 * 60,
                                       isMonitoring: false, now: date(21, 20, 0), calendar: calendar)
        XCTAssertEqual(split.count, 2)
    }

    /// 終了を記録できなかった監視 (アプリの終了) は最後の録音まで、監視中のものは今まで
    func testUnfinishedSessions() {
        let killed = [Session(start: date(21, 23, 0), end: nil), Session(start: date(22, 23, 0), end: nil)]
        let recordings = [recording(date(22, 4, 0)), recording(date(22, 23, 30))]
        let nights = NightRecord.nights(sessions: killed, recordings: recordings, boundaryMinutes: 12 * 60,
                                        isMonitoring: true, now: date(23, 2, 0), calendar: calendar)
        XCTAssertEqual(nights.count, 2)
        XCTAssertEqual(nights[1].end, date(22, 4, 0))
        XCTAssertEqual(nights[0].end, date(23, 2, 0))
    }

    /// 監視の記録がない以前の録音だけでも、録音の時刻から一晩を作る
    func testRecordingsWithoutSessions() {
        let recordings = [recording(date(21, 23, 0)), recording(date(22, 3, 0))]
        let nights = NightRecord.nights(sessions: [], recordings: recordings, boundaryMinutes: 12 * 60,
                                        isMonitoring: false, now: date(22, 9, 0), calendar: calendar)
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights[0].start, date(21, 23, 0).addingTimeInterval(-2))
        XCTAssertEqual(nights[0].end, date(22, 3, 0))
        // 監視していた時間は「記録なし」と表示する (0 分ではない)
        XCTAssertFalse(nights[0].hasMonitoringRecord)
    }

    /// 終了を記録できず録音もない監視は、最後に動いていた時刻 (lastSeen) までとする
    func testUnfinishedSessionUsesLastSeen() {
        let sessions = [Session(start: date(21, 23, 0), end: nil, lastSeen: date(22, 5, 30)),
                        Session(start: date(22, 23, 0), end: date(23, 6, 0))]
        let nights = NightRecord.nights(sessions: sessions, recordings: [], boundaryMinutes: 12 * 60,
                                        isMonitoring: false, now: date(23, 8, 0), calendar: calendar)
        XCTAssertEqual(nights.count, 2)
        XCTAssertTrue(nights[1].hasMonitoringRecord)
        XCTAssertEqual(nights[1].monitoredDuration, 6.5 * 60 * 60)
    }

    func testSessionStoreBeginAndEnd() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        MonitoringSessionStore.begin(at: date(21, 23, 0), in: defaults)
        MonitoringSessionStore.touch(at: date(22, 3, 0), in: defaults)
        MonitoringSessionStore.end(at: date(22, 6, 0), in: defaults)
        MonitoringSessionStore.end(at: date(22, 7, 0), in: defaults)
        MonitoringSessionStore.touch(at: date(22, 8, 0), in: defaults)
        XCTAssertEqual(MonitoringSessionStore.load(from: defaults),
                       [Session(start: date(21, 23, 0), end: date(22, 6, 0), lastSeen: date(22, 3, 0))])
        // 1 週間より古い記録は次の開始のときに消す
        MonitoringSessionStore.begin(at: date(30, 23, 0), in: defaults)
        XCTAssertEqual(MonitoringSessionStore.load(from: defaults),
                       [Session(start: date(30, 23, 0), end: nil, lastSeen: date(30, 23, 0))])
    }

    /// 振動の記録も、監視と同じ夜にまとめる
    func testAlarmsBelongToTheirNight() {
        let sessions = [Session(start: date(21, 23, 0), end: date(22, 6, 0)),
                        Session(start: date(22, 23, 0), end: date(23, 6, 0))]
        let alarms = [AlarmEventStore.Event(date: date(22, 2, 0), device: .watch, stopped: true),
                      AlarmEventStore.Event(date: date(23, 3, 0), device: .both)]
        let nights = NightRecord.nights(sessions: sessions, recordings: [], alarms: alarms, boundaryMinutes: 12 * 60,
                                        isMonitoring: false, now: date(23, 8, 0), calendar: calendar)
        XCTAssertEqual(nights.count, 2)
        XCTAssertEqual(nights[1].alarms.map(\.device), [.watch])
        XCTAssertEqual(nights[0].alarms.map(\.device), [.both])
    }

    func testAlarmEventStoreRecordsAndMarksStopped() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        AlarmEventStore.record(.watch, at: date(22, 2, 0), in: defaults)
        AlarmEventStore.record(.iPhone, at: date(22, 3, 0), in: defaults)
        AlarmEventStore.markLastStopped(in: defaults)
        XCTAssertEqual(AlarmEventStore.load(from: defaults).map(\.stopped), [false, true])
        // 古い記録は次に残すときに消す
        AlarmEventStore.record(.iPhone, at: date(31, 3, 0), in: defaults)
        XCTAssertEqual(AlarmEventStore.load(from: defaults).count, 1)
    }

    /// 拡大したときの横軸の目盛りは 6 本程度に収める
    @MainActor
    func testAxisStrideFollowsZoom() {
        XCTAssertEqual(NightView.axisStrideMinutes(for: 3 * 60), 1)
        XCTAssertEqual(NightView.axisStrideMinutes(for: 30 * 60), 5)
        XCTAssertEqual(NightView.axisStrideMinutes(for: 8 * 60 * 60), 120)
    }
}

final class SpectralAnalyzerTests: XCTestCase {
    private func analyze(frequency: Double, amplitude: Float = 0.5) -> SpectralAnalyzer.Result {
        let sampleRate = 48000.0
        let analyzer = SpectralAnalyzer(frameSize: 2048, sampleRate: sampleRate)
        let samples = (0..<2048).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
        return samples.withUnsafeBufferPointer { analyzer.analyze($0) }
    }

    func testLowFrequencyToneHasHighLowBandRatio() {
        let result = analyze(frequency: 150)
        XCTAssertGreaterThan(result.lowBandRatio, 0.9)
        XCTAssertEqual(result.levelDB, 20 * log10(0.5 / Float(2).squareRoot()), accuracy: 0.5)
    }

    func testHighFrequencyToneHasLowLowBandRatio() {
        XCTAssertLessThan(analyze(frequency: 2000).lowBandRatio, 0.1)
    }

    func testSilenceIsVeryQuiet() {
        let result = analyze(frequency: 150, amplitude: 0)
        XCTAssertLessThan(result.levelDB, -100)
        XCTAssertEqual(result.lowBandRatio, 0)
    }
}
