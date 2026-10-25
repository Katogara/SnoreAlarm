import Accelerate
import AVFoundation
import Observation

/// 録音したいびきの再生。監視中はマイクが再生音を拾うため、画面側で再生できないようにしている。
/// 録音はマイクの生の音量 (自動ゲイン調整なし) のため小さく、そのままでは聞こえにくい。
/// 再生時にファイル全体を読み込み、最大音量がそろうように音量を上げてから鳴らす (いびき 1 回は数秒・数十 KB なので負担は小さい)。
@MainActor
@Observable
final class SnorePlayer {
    private(set) var playingURL: URL?
    /// 最後に再生した録音の波形 (録音したままの音量)。数秒で終わるため、再生が終わったあとも表示し続ける
    private(set) var waveform: Waveform?
    private(set) var waveformURL: URL?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var node: AVAudioPlayerNode?
    /// 古い再生の完了通知で新しい再生を止めないための番号
    @ObservationIgnored private var playbackID = 0

    /// 再生時の最大音量 (1.0 = フルスケール)
    nonisolated static let targetPeak: Float = 0.9
    /// 音量を上げる上限 (+30dB)。無音に近い録音で雑音だけが大きくならないようにする
    nonisolated static let maxGain: Float = 31.6

    /// 再生中のものなら止め、そうでなければ再生する。
    func toggle(_ url: URL) {
        if playingURL == url {
            stop()
            return
        }
        stop()
        guard let loaded = Self.loadForPlayback(url) else { return }
        let (buffer, waveform) = loaded
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            let engine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: buffer.format)
            try engine.start()
            playbackID += 1
            let id = playbackID
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.playbackID == id else { return }
                    self.stop()
                }
            }
            node.play()
            self.engine = engine
            self.node = node
            self.waveform = waveform
            waveformURL = url
            playingURL = url
        } catch {
            playingURL = url
            stop()
        }
    }

    func stop() {
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
        guard playingURL != nil else { return }
        playingURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 再生せずに波形だけを表示する (一晩の記録でいびきを選んだとき)。ほかの録音の再生中は何もしない
    func showWaveform(of url: URL) async {
        guard waveformURL != url else { return }
        let waveform = await Task.detached(priority: .userInitiated) { Self.loadWaveform(url) }.value
        guard let waveform, playingURL == nil || playingURL == url, waveformURL != url else { return }
        self.waveform = waveform
        waveformURL = url
    }

    /// 再生位置 (秒)。波形の上に再生位置を表示するために使う
    func currentTime() -> TimeInterval? {
        guard let node, let nodeTime = node.lastRenderTime, let time = node.playerTime(forNodeTime: nodeTime),
              time.sampleRate > 0 else {
            return nil
        }
        return max(Double(time.sampleTime) / time.sampleRate, 0)
    }

    /// 録音を読み込み、録音したままの音量で波形を作ってから、
    /// 最大音量が `targetPeak` になるよう音量を上げる (上げ幅は `maxGain` まで)。
    nonisolated static func loadForPlayback(_ url: URL) -> (AVAudioPCMBuffer, Waveform)? {
        guard let buffer = read(url), let waveform = waveform(of: buffer) else { return nil }
        normalize(buffer)
        return (buffer, waveform)
    }

    /// 録音したままの音量で波形を作る (再生はしない)
    nonisolated static func loadWaveform(_ url: URL) -> Waveform? {
        read(url).flatMap(waveform(of:))
    }

    private nonisolated static func read(_ url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(max(file.length, 0)) + 4096),
              (try? file.read(into: buffer)) != nil,
              buffer.frameLength > 0 else {
            return nil
        }
        return buffer
    }

    private nonisolated static func waveform(of buffer: AVAudioPCMBuffer) -> Waveform? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        return Waveform(samples: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)),
                        sampleRate: buffer.format.sampleRate)
    }

    nonisolated static func normalize(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let count = vDSP_Length(buffer.frameLength)
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            var channelPeak: Float = 0
            vDSP_maxmgv(channels[channel], 1, &channelPeak, count)
            peak = max(peak, channelPeak)
        }
        guard peak > 0 else { return }
        var gain = min(targetPeak / peak, maxGain)
        guard gain > 1 else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            vDSP_vsmul(channels[channel], 1, &gain, channels[channel], 1, count)
        }
    }
}
