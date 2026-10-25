import SwiftUI

/// 録音の波形。左から右へ時間が進み、上下の大きさが音の大きさ (録音したままの音量、-60〜0 dB)。
/// 再生済みの部分は色を変え、再生位置に縦線を引く。
struct WaveformView: View {
    let waveform: Waveform
    /// 再生位置 0...1 (nil なら再生していない)
    var progress: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                let count = waveform.heights.count
                guard count > 0 else { return }
                let middle = size.height / 2
                // 目安の線: 中心と -20dB・-40dB の高さ
                context.fill(Path(CGRect(x: 0, y: middle - 0.5, width: size.width, height: 1)),
                             with: .color(Color.secondary.opacity(0.4)))
                for db: Float in [-20, -40] {
                    let offset = CGFloat(Waveform.height(ofPeak: pow(10, db / 20))) * middle
                    for y in [middle - offset, middle + offset] {
                        context.fill(Path(CGRect(x: 0, y: y - 0.25, width: size.width, height: 0.5)),
                                     with: .color(Color.secondary.opacity(0.25)))
                    }
                }

                let step = size.width / CGFloat(count)
                let barWidth = max(step * 0.7, 1)
                for (index, height) in waveform.heights.enumerated() {
                    let half = max(CGFloat(height) * middle, 0.5)
                    let rect = CGRect(x: CGFloat(index) * step + (step - barWidth) / 2, y: middle - half,
                                      width: barWidth, height: half * 2)
                    let played = (Double(index) + 0.5) / Double(count) <= (progress ?? 1)
                    context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2),
                                 with: .color(played ? Color.accentColor : Color.secondary.opacity(0.5)))
                }

                if let progress {
                    let x = size.width * CGFloat(min(max(progress, 0), 1))
                    context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.orange))
                }
            }
            .frame(height: 64)

            HStack {
                Text("0秒")
                Spacer()
                Text(peakText)
                Spacer()
                Text(String(format: "%.1f秒", waveform.duration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("いびきの波形")
        .accessibilityValue(peakText)
    }

    private var peakText: String {
        waveform.peakDB.isFinite ? String(format: "最大 %.0f dB (線は -20・-40 dB)", waveform.peakDB) : "無音"
    }
}

/// `url` の録音の波形と再生位置。再生が終わっても、ほかの録音を再生するまで表示しておく。
/// 画面の更新は再生中だけ行う。
struct PlaybackWaveform: View {
    @Environment(SnorePlayer.self) private var player
    let url: URL

    var body: some View {
        if player.waveformURL == url, let waveform = player.waveform {
            let isPlaying = player.playingURL == url
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isPlaying)) { _ in
                WaveformView(waveform: waveform, progress: isPlaying ? progress(of: waveform) : nil)
            }
        }
    }

    private func progress(of waveform: Waveform) -> Double {
        guard waveform.duration > 0 else { return 0 }
        return min((player.currentTime() ?? 0) / waveform.duration, 1)
    }
}
